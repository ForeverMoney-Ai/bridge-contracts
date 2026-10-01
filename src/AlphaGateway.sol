// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IAlphaVault} from "./interfaces/IAlphaVault.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IBalanceTransfer} from "./interfaces/IBalanceTransfer.sol";
import {ExitPayload} from "./ExitPayload.sol";
import {IntegratorFee} from "./IntegratorFee.sol";
import {StakeSource} from "./StakeSource.sol";

/// @title AlphaGateway — SHARED one-tx UX for the Subtensor-EVM (964) side of the AlphaVault bridge.
/// @notice ONE gateway serves every wrapped asset the (single, multi-token) vault lists. All routes
///         take the token as a parameter; inbound deliveries are routed by the token that arrives in
///         the CCIP message.
///
///   Finney -> Spoke: `bridgeOut(destSelector, token, recipient, taoAmount, stakedAlphaRao,
///                    minTokenOut)`
///                    bridges from liquid TAO (staked fresh) and/or the caller's EXISTING staked
///                    alpha (pulled from msg.sender) — either or both in one tx — minting the
///                    MEASURED token and ccipSending the total. `bridgeTokenOut` bridges tokens the
///                    caller already holds. Both take an optional trailing `IntegratorFee`: a cut of
///                    the bridged token paid to whoever prepared the tx, capped by governance.
///
///   Spoke -> Finney: three delivery modes, chosen by the exit payload. A coldkey with
///                    `wantLiquid=false` delivers the position as STAKED alpha via `withdrawStaked`
///                    (zero slippage, still staked, no gas needed on 964); `wantLiquid=true` unwraps
///                    to native TAO and exits via the 0x800 precompile; NO coldkey and
///                    `wantLiquid=false` hands the wrapped ERC20 itself to `evmFallback` on 964.
///
/// @dev  Holds no funds at rest. `_ccipReceive` never reverts: any failure books the released tokens as
///       claimable (per token) rather than stranding the CCIP message. Immutable, no owner.
///       CCT registration is permissionless, so a HOSTILE token can arrive via CCIP: every inbound
///       failure is namespaced by token (`claimableToken[token][user]`), and the gateway only ever
///       calls the token that carried the funds — a malicious token can only harm its own holders.
contract AlphaGateway is CCIPReceiver {
    IAlphaVault public immutable VAULT; // the ONE multi-token vault
    IStaking public immutable STAKING; // 0x805 (read from the vault) — for pulling caller stake
    IBalanceTransfer public constant SUBSTRATE_EXIT =
        IBalanceTransfer(0x0000000000000000000000000000000000000800);

    /// @dev This gateway's own substrate coldkey = blake2b("evm:"+address(this)). Supplied at
    ///      construction for the same reason AlphaVault takes `vaultColdkey`: blake2b is not
    ///      practical on-chain and the precompile exposes no address->coldkey lookup. Used only to
    ///      READ our own transient positions, so a wrong value makes deposits revert rather than
    ///      misroute funds.
    bytes32 public immutable GATEWAY_COLDKEY;

    address public immutable ROUTER;
    address public immutable rescuer;

    uint256 private constant RAO = 1e9;

    /// @notice Smallest position `add_stake` accepts, in wei (2,000,000 RAO = 0.002 TAO). Measured on
    ///         mainnet, where `addStake` reverts at 1,999,999 RAO and passes at 2,000,000. NOT the
    ///         same as `getNominatorMinRequiredStake()` (20,000,000 RAO), which bounds what a
    ///         nominator may LEAVE on a validator, not what may be added.
    uint256 internal constant MIN_ADD_STAKE_WEI = 2_000_000 * RAO;

    /// @dev Netuids on which the vault has been max-approved to pull this gateway's transient stake
    ///      (for depositStaked). Lazy, once per netuid. The gateway never holds alpha at rest, so a
    ///      standing self->vault approval carries no risk.
    mapping(uint256 => bool) private _vaultApprovedNetuid;

    /// @dev token => user => amount. Named generically: the same
    ///      mapping holds TAO (netuid 0) and every SN_X.
    mapping(address => mapping(address => uint256)) public claimableToken;
    mapping(address => uint256) public claimableNative;

    /// @notice Chain selectors this gateway will bridge to and accept deliveries from. Seeded with
    ///         BASE_SELECTOR at construction; further lanes are set by whoever holds the vault's
    ///         DEFAULT_ADMIN_ROLE, checked at call time — any delay depends on that holder, not on
    ///         this contract. The gateway itself has no owner or key. Removing a lane never traps
    ///         funds: in-flight arrivals over a de-allowed lane are booked claimable to the
    ///         sender's fallback.
    /// @dev    NOT sufficient on its own — the token's CCIP pool must also have the remote chain
    ///         registered (applyChainUpdates) for the lane to carry anything.
    mapping(uint64 => bool) public allowedLane;

    /// @param minted the amount that CROSSES. An integrator cut is charged on top and reported
    ///        separately in `IntegratorFeeCollected`.
    event BridgedOut(
        uint64 destChainSelector,
        address indexed token,
        address indexed sender,
        address indexed recipient,
        uint256 minted,
        bytes32 messageId
    );
    event DeliveredStaked(address indexed token, bytes32 indexed ss58, uint256 alphaRao);
    event DeliveredLiquid(address indexed token, bytes32 indexed ss58, uint256 taoOut);
    event Claimable(address indexed token, address indexed user, uint256 native, uint256 wsn);
    /// @notice Why an arrival was booked claimable instead of delivered.
    /// @dev    UnknownLane          — the source chain is not in `allowedLane` (trust).
    ///         AmbiguousTokenCount  — the message carried != 1 token, so the single-destination
    ///                                payload cannot say which token it meant (interpretability).
    enum NotDeliveredReason {
        UnknownLane,
        AmbiguousTokenCount
    }

    /// @notice An arrival whose payload was NOT honoured; the tokens were booked claimable to the
    ///         sender's own fallback instead, and remain fully recoverable.
    event NotDelivered(
        uint64 indexed sourceChainSelector, address indexed token, uint256 amount, NotDeliveredReason reason
    );
    event LaneSet(uint64 indexed selector, bool allowed);
    event Initialized(address indexed router, address indexed vault, address indexed rescuer);
    event Claimed(address indexed token, address indexed user, address indexed to, uint256 amount);
    /// @notice Sub-RAO remainder handed back as the token (it cannot be unstaked), so a dust-only claim is
    ///         still observable on-chain.
    event DustReturned(address indexed token, address indexed user, uint256 amount);

    error AmountNotWholeRAO();
    error InsufficientValue();
    error NativeTransferFailed();
    error ZeroAmount();
    error ZeroRecipient();
    error Slippage();
    error PullFailed();
    error TransferFailed();
    error NothingToClaim();
    error OnlySelf();
    error NotVaultAdmin();
    error LaneNotAllowed(uint64 selector);
    error UnsupportedToken(address token);
    error ZeroColdkey();
    error ZeroAddress();
    error ZeroSelector();

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00; // OZ AccessControl root role

    /// @notice Markup charged on top of the CCIP fee, in basis points. 0 = disabled.
    /// @dev A markup on the FEE. The integrator fee is separate: the bridged amount is minted from
    ///      the measured stake delta, and the integrator cut is a separate transfer that never
    ///      short-mints it, so the 1:1 backing every price consumer relies on still holds.
    uint16 public bridgeFeeBps;
    /// @notice Ceiling on the markup, so a fat-fingered setter cannot make a hop cost 100x.
    ///         A bound, not a policy: the intended setting is far below it.
    uint16 public constant MAX_BRIDGE_FEE_BPS = 5_000; // 50%

    /// @notice Where the markup goes. Zero means "wherever the vault sends emissions", which is
    ///         the default and keeps one place to change for the common case; set it to split fee
    ///         income away from emissions.
    address public feeRecipient;

    event BridgeFeeChanged(uint16 bps);
    event FeeRecipientChanged(address indexed to);
    event BridgeFeeCollected(address indexed to, uint256 amount);

    error BridgeFeeTooHigh(uint16 bps, uint16 max);
    error FeeTransferFailed();

    /// @notice Most staked positions one deposit may consolidate. Each costs ~35.4k gas
    ///         (measured on mainnet: 15 moveStake dispatches in one tx used 554,728 gas, and
    ///         subtensor applied NO rate limit), so this bound is about keeping a single
    ///         bridge transaction comfortably sized, not about a runtime constraint.
    uint256 public constant MAX_STAKE_SOURCES = 16;

    /// @notice Hard ceiling on the per-call integrator fee (a cut of the bridged token). Governance
    ///         can set `maxIntegratorFeeBps` anywhere up to it.
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 1_000; // 10%
    uint16 public constant DEFAULT_MAX_INTEGRATOR_FEE_BPS = 100; // 1%
    /// @notice Current ceiling on `IntegratorFee.bps` accepted by the bridge calls.
    uint16 public maxIntegratorFeeBps;

    event MaxIntegratorFeeChanged(uint16 bps);
    event IntegratorFeeCollected(address indexed token, address indexed recipient, uint256 amount);
    /// @notice A return leg delivered as the wrapped ERC20 straight to an EVM address on 964.
    event DeliveredToken(address indexed token, address indexed to, uint256 amount);

    error IntegratorFeeTooHigh(uint16 bps, uint16 max);
    error ZeroIntegrator();
    error TopUpBelowMinStake(uint256 topUp, uint256 min);
    error ZeroValidator();
    error NoStakeSources();
    error TooManyStakeSources(uint256 given, uint256 max);
    error DuplicateStakeSource(bytes32 validator);
    error StrandedStake(bytes32 validator, uint256 remainder);
    error IntegratorFeeTransferFailed();

    /// @param initialLane  the first allowed chain selector (Base at launch). Further lanes are
    ///                     added later via `setLane`; nothing about this contract is Base-specific.
    /// @dev `rescuer` is immutable ON PURPOSE: it is the terminal fallback that guarantees no
    ///      booking ever lands on address(0), so it must not be a governable pointer that could be
    ///      moved (or zeroed) out from under funds already booked to it.
    constructor(address router, address vault, uint64 initialLane, address rescuer_, bytes32 gatewayColdkey_)
        CCIPReceiver(router)
    {
        // ZeroAddress for the dependencies and ZeroSelector for the lane: ZeroRecipient means a
        // bridge recipient and LaneNotAllowed means governance declined a lane — neither describes
        // a malformed constructor argument. `router` is not checked here: the CCIPReceiver base
        // runs first and already reverts InvalidRouter for a zero address.
        if (vault == address(0) || rescuer_ == address(0)) revert ZeroAddress();
        if (initialLane == 0) revert ZeroSelector();
        if (gatewayColdkey_ == bytes32(0)) revert ZeroColdkey();
        VAULT = IAlphaVault(vault);
        GATEWAY_COLDKEY = gatewayColdkey_;
        ROUTER = router;
        rescuer = rescuer_;
        STAKING = IStaking(IAlphaVault(vault).STAKING());
        allowedLane[initialLane] = true; // bootstrap lane; more added via setLane
        maxIntegratorFeeBps = DEFAULT_MAX_INTEGRATOR_FEE_BPS;
        emit Initialized(router, vault, rescuer_);
        emit LaneSet(initialLane, true);
        emit MaxIntegratorFeeChanged(DEFAULT_MAX_INTEGRATOR_FEE_BPS);
    }

    /// @dev Authority is DELEGATED to the vault's DEFAULT_ADMIN_ROLE, so this contract holds no key
    ///      of its own. This is an immediate `hasRole` check: any delay comes from the role holder
    ///      (a timelock, a multisig, or neither).
    modifier onlyVaultAdmin() {
        if (!VAULT.hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotVaultAdmin();
        _;
    }

    /// @notice Set the markup charged on top of the CCIP fee — vault DEFAULT_ADMIN_ROLE.
    function setBridgeFeeBps(uint16 bps) external onlyVaultAdmin {
        if (bps > MAX_BRIDGE_FEE_BPS) revert BridgeFeeTooHigh(bps, MAX_BRIDGE_FEE_BPS);
        bridgeFeeBps = bps;
        emit BridgeFeeChanged(bps);
    }

    /// @notice Point fee income somewhere other than the vault's emissions recipient — vault
    ///         DEFAULT_ADMIN_ROLE. Zero restores the default.
    function setFeeRecipient(address to) external onlyVaultAdmin {
        feeRecipient = to;
        emit FeeRecipientChanged(to);
    }

    /// @notice Cap the per-call integrator fee — vault DEFAULT_ADMIN. Zero disables integrator fees.
    function setMaxIntegratorFeeBps(uint16 bps) external onlyVaultAdmin {
        if (bps > MAX_INTEGRATOR_FEE_BPS) revert IntegratorFeeTooHigh(bps, MAX_INTEGRATOR_FEE_BPS);
        maxIntegratorFeeBps = bps;
        emit MaxIntegratorFeeChanged(bps);
    }

    /// @dev A fee is valid when it is empty, or names a recipient and stays under the cap.
    function _validateIntegratorFee(IntegratorFee memory fee) private view {
        if (fee.bps == 0) return;
        if (fee.recipient == address(0) || fee.recipient == address(this)) revert ZeroIntegrator();
        if (fee.bps > maxIntegratorFeeBps) revert IntegratorFeeTooHigh(fee.bps, maxIntegratorFeeBps);
    }

    /// @dev The integrator fee is charged ON TOP: `bps` of the bridged amount, supplied by the caller
    ///      in addition to what crosses. The bridged amount itself is never reduced.
    function _integratorCut(uint256 amount, IntegratorFee memory fee) private pure returns (uint256) {
        return integratorCut(amount, fee.bps);
    }

    /// @notice Extra native TAO a liquid `bridgeOutWithFee` must carry for the integrator: `bps` of
    ///         `taoAmount`, rounded UP to a whole RAO. It is staked and minted as the wrapped token
    ///         for the integrator, exactly like the amount being bridged.
    function integratorTaoTopUp(uint256 taoAmount, uint16 bps) public pure returns (uint256) {
        uint256 raw = (taoAmount * bps) / 10_000;
        if (raw == 0) return 0;
        return ((raw + RAO - 1) / RAO) * RAO;
    }

    /// @notice The integrator's cut of `amount` at `bps`, rounded DOWN. This is BOTH the extra staked
    ///         alpha a `bridgeOutWithFee` pulls on the staked leg AND the extra token a
    ///         `bridgeTokenOutWithFee` pulls — the caller supplies `amount + integratorCut(amount, bps)`
    ///         in each case. (The liquid leg uses `integratorTaoTopUp`, which rounds UP to a whole RAO.)
    function integratorCut(uint256 amount, uint16 bps) public pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    /// @dev Hand `cut` of `token` (already held by this contract) to the integrator.
    function _payIntegrator(address token, uint256 cut, IntegratorFee memory fee) private {
        if (cut == 0) return;
        if (!IERC20(token).transfer(fee.recipient, cut)) revert IntegratorFeeTransferFailed();
        emit IntegratorFeeCollected(token, fee.recipient, cut);
    }

    /// @dev Resolved per call rather than cached: the fallback must track the vault's own recipient
    ///      if that moves, and a stale mirror here would silently keep paying the old address.
    function _feeRecipient() private view returns (address) {
        address to = feeRecipient;
        return to == address(0) ? VAULT.emissionsRecipient() : to;
    }

    /// @dev The total a caller must send: the router's fee plus our markup. Quoting this rather
    ///      than the bare CCIP fee is what keeps a caller from being told one number and charged
    ///      another.
    function _grossFee(uint256 ccipFee) private view returns (uint256) {
        return ccipFee + (ccipFee * bridgeFeeBps) / 10_000;
    }

    /// @notice Add or remove a supported chain selector — vault DEFAULT_ADMIN_ROLE.
    /// @dev Allowing a lane the router cannot route would let users bridge into a revert; removing
    ///      is always permitted (an unsupported lane must stay removable).
    function setLane(uint64 selector, bool allowed) external onlyVaultAdmin {
        if (allowed && !IRouterClient(ROUTER).isChainSupported(selector)) revert LaneNotAllowed(selector);
        allowedLane[selector] = allowed;
        emit LaneSet(selector, allowed);
    }

    // --------------------------------------------------------------- Finney/964 -> spoke chain

    /// @notice Quote the CCIP fee (native TAO) to bridge `mintedAmount` of `token` to `recipient`
    ///         on `destSelector`. The minted amount is only known after staking, so pass the
    ///         expected amount.
    /// @dev    Validates the SAME preconditions execution does, so a quote can never succeed for a
    ///         route `bridgeOut`/`bridgeTokenOut` would reject.
    function quoteBridgeOut(uint64 destSelector, address token, address recipient, uint256 mintedAmount)
        public
        view
        returns (uint256 grossFee)
    {
        (grossFee,) = _quoteBridgeOut(destSelector, token, recipient, mintedAmount, IntegratorFee(address(0), 0));
    }

    /// @notice Quote a `bridgeOutWithFee`: the native CCIP fee, the EXTRA native TAO to add for the
    ///         integrator (liquid leg), the EXTRA alpha to approve for them (staked leg), and the
    ///         amount that crosses — always the full `mintedAmount`, because the fee is on top.
    /// @dev    Send `taoAmount + nativeTopUp + grossFee` as msg.value, and approve
    ///         `stakedAlphaRao + alphaTopUp` on the staking precompile. A distinct name rather than an
    ///         overload: ethers cannot disambiguate an overload whose extra argument is a struct when
    ///         an overrides object is passed.
    function quoteBridgeOutWithFee(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 mintedAmount,
        uint256 taoAmount,
        uint256 stakedAlphaRao,
        IntegratorFee calldata fee
    ) external view returns (uint256 grossFee, uint256 nativeTopUp, uint256 alphaTopUp, uint256 crossing) {
        (grossFee, crossing) = _quoteBridgeOut(destSelector, token, recipient, mintedAmount, fee);
        nativeTopUp = integratorTaoTopUp(taoAmount, fee.bps);
        alphaTopUp = integratorCut(stakedAlphaRao, fee.bps);
    }

    function _quoteBridgeOut(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 mintedAmount,
        IntegratorFee memory fee
    ) private view returns (uint256 grossFee, uint256 crossing) {
        if (!allowedLane[destSelector]) revert LaneNotAllowed(destSelector);
        if (!VAULT.isListed(token)) revert UnsupportedToken(token);
        if (recipient == address(0)) revert ZeroRecipient();
        // CCIP rejects a zero token transfer at ccipSend, but getFee does not — without this a
        // quote would succeed for an amount no send can carry.
        if (mintedAmount == 0) revert ZeroAmount();
        _validateIntegratorFee(fee);
        // The fee is charged ON TOP, so the full `mintedAmount` crosses and the CCIP fee is quoted on
        // it. What the caller must supply extra is reported by the public helpers.
        crossing = mintedAmount;
        grossFee = _grossFee(IRouterClient(ROUTER).getFee(destSelector, _toRemoteMessage(token, recipient, crossing)));
    }

    /// @notice Bridge `token` out to `destSelector` from liquid TAO and/or the caller's already-staked
    ///         alpha — either or both in ONE tx.
    /// @param taoAmount        native TAO to stake fresh (0 = none). Must be whole-RAO.
    /// @param stakedAlphaRao   the CALLER's existing staked alpha (on the token's validator/netuid)
    ///                         to pull and bridge (0 = none). Caller must first 0x805 approve THIS
    ///                         gateway on that netuid.
    /// @param minTokenOut      slippage bound on the amount that CROSSES, in 18-dec token wei (NOT
    ///                         RAO — unlike the vault's minAlphaRao params). An integrator fee is
    ///                         charged on top and never reduces it, so this is the same number with
    ///                         or without a fee.
    /// @dev msg.value must be >= taoAmount + ccipFee; excess refunded. The staked pull is always from
    ///      msg.sender (never an arbitrary source) so a caller can only ever bridge their own stake.
    function bridgeOut(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 taoAmount,
        uint256 stakedAlphaRao,
        uint256 minTokenOut
    ) external payable returns (bytes32 messageId) {
        return _bridgeOut(destSelector, token, recipient, taoAmount, _canonicalSource(token, stakedAlphaRao), minTokenOut, IntegratorFee(address(0), 0));
    }

    /// @notice `bridgeOut` with an integrator fee ON TOP: the caller supplies `fee.bps` extra input
    ///         (`integratorTaoTopUp(taoAmount, bps)` more TAO in msg.value, `integratorCut(
    ///         stakedAlphaRao, bps)` more approved alpha); it is minted as the WRAPPED TOKEN for
    ///         `fee.recipient` while the requested amount crosses in full. Validated before any TAO
    ///         is staked.
    /// @dev    Distinct name, see `quoteBridgeOutWithFee`.
    function bridgeOutWithFee(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 taoAmount,
        uint256 stakedAlphaRao,
        uint256 minTokenOut,
        IntegratorFee calldata fee
    ) external payable returns (bytes32 messageId) {
        return _bridgeOut(destSelector, token, recipient, taoAmount, _canonicalSource(token, stakedAlphaRao), minTokenOut, fee);
    }

    /// @notice Bridge out wrapping alpha held across SEVERAL validators, plus optional native TAO.
    ///         Each entry names a hotkey the caller's alpha currently sits on and how much to take;
    ///         the gateway re-delegates every one to the token's canonical validator before
    ///         depositing, so the caller keeps their own delegation choices right up to the wrap.
    /// @dev    Distinct name rather than an overload: ethers cannot disambiguate an overload whose
    ///         extra argument is a struct array when an overrides object is passed.
    ///
    ///         Sizing `alphaRao`: whatever you LEAVE on a validator should be zero or still at least
    ///         `minStakeRequired()`. NOTHING enforces this — not the gateway (it never learns your
    ///         coldkey) and not the runtime (verified on mainnet: a sub-minimum remainder is
    ///         accepted and simply persists). Plan it off-chain; there will be no revert.
    function bridgeOutFromValidators(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 taoAmount,
        StakeSource[] calldata sources,
        uint256 minTokenOut
    ) external payable returns (bytes32 messageId) {
        if (sources.length == 0) revert NoStakeSources();
        return _bridgeOut(destSelector, token, recipient, taoAmount, sources, minTokenOut, IntegratorFee(address(0), 0));
    }

    /// @notice `bridgeOutFromValidators` with an integrator fee ON TOP. The integrator cut is split
    ///         pro-rata across every source (each pays its share of `integratorCut`), with
    ///         `sources[0]` absorbing the rounding remainder — budget every position accordingly.
    function bridgeOutFromValidatorsWithFee(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 taoAmount,
        StakeSource[] calldata sources,
        uint256 minTokenOut,
        IntegratorFee calldata fee
    ) external payable returns (bytes32 messageId) {
        if (sources.length == 0) revert NoStakeSources();
        return _bridgeOut(destSelector, token, recipient, taoAmount, sources, minTokenOut, fee);
    }

    function _bridgeOut(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 taoAmount,
        StakeSource[] memory sources,
        uint256 minTokenOut,
        IntegratorFee memory fee
    ) private returns (bytes32 messageId) {
        // Belt-and-braces: the vault would reject an unlisted token anyway (every path below is
        // onlyListed), but failing here is one call earlier, with a gateway-native error, and
        // before any value moves.
        if (!VAULT.isListed(token)) revert UnsupportedToken(token);
        _validateIntegratorFee(fee);
        uint256 minted;
        uint256 mintedForIntegrator;
        // The integrator is ALWAYS paid in the wrapped token, whichever leg the caller used — one
        // currency, one mental model. The extra input rides on top (extra native TAO in msg.value for
        // the liquid leg, extra approved alpha for the staked leg) and is minted for them, so what the
        // caller asked to bridge crosses in full. The wrapped token is a 1:1 claim on the same staked
        // position: `withdrawStaked` hands it over as stake with zero slippage, `withdrawLiquid` as
        // native TAO, and it bridges like any ERC20 — so this denies them nothing.
        uint256 taoTopUp = integratorTaoTopUp(taoAmount, fee.bps);
        // A top-up under the runtime's add_stake floor cannot be staked, so the whole bridge would
        // revert deep inside the vault. Fail here instead, before any value moves, with a reason the
        // caller can act on: raise the bridged amount, raise bps, or drop the fee.
        if (taoTopUp > 0 && taoTopUp < MIN_ADD_STAKE_WEI) revert TopUpBelowMinStake(taoTopUp, MIN_ADD_STAKE_WEI);
        if (msg.value < taoAmount + taoTopUp) revert InsufficientValue();

        if (taoAmount > 0) {
            if (taoAmount % RAO != 0) revert AmountNotWholeRAO();
            minted += VAULT.depositLiquid{value: taoAmount}(token, 0); // total bounded by minTokenOut below
            if (taoTopUp > 0) mintedForIntegrator += VAULT.depositLiquid{value: taoTopUp}(token, 0);
        }
        if (sources.length > 0) {
            // Extracted into a helper purely for stack depth (this file compiles without via-ir).
            (uint256 stakedMint, uint256 stakedFeeMint) = _stakedLeg(token, sources, fee);
            minted += stakedMint;
            mintedForIntegrator += stakedFeeMint;
        }

        if (minted == 0) revert ZeroAmount();
        if (minted < minTokenOut) revert Slippage();
        // A plain ERC20 transfer: no callback, so a caller-chosen recipient never gets control here.
        _payIntegrator(token, mintedForIntegrator, fee);

        messageId = _send(destSelector, token, recipient, minted, taoAmount + taoTopUp);
    }

    /// @dev The staked leg of a bridge. The integrator fee is charged ON TOP of, and computed on,
    ///      the TOTAL the caller asked to bridge — and it is drawn PRO-RATA from the sources they
    ///      listed, in the same proportions they chose. So a position is never raided to fund a fee
    ///      the caller did not apportion to it, and no single source bears the whole cut.
    ///
    ///      Sizing: with a fee, each position is pulled for its listed amount PLUS its share of the
    ///      cut, so every source needs that much headroom (and the allowance must cover the total
    ///      plus the cut). `integratorCut()` is public precisely so callers can compute this.
    function _stakedLeg(address token, StakeSource[] memory sources, IntegratorFee memory fee)
        private
        returns (uint256 minted, uint256 mintedForIntegrator)
    {
        // Summed ONCE and passed down: `_apportion` must divide by the PRE-apportionment total, and
        // recomputing it there would silently depend on being called before anything mutates
        // `sources`. Zero total implies zero cut, so the division below is unreachable at total == 0.
        uint256 total = _sumSources(sources);
        uint256 cut = integratorCut(total, fee.bps);
        if (cut > 0) _apportion(sources, total, cut);

        // ONE consolidation covering the bridged amount and the fee together: the fee no longer
        // costs a second pull, a second re-delegation or a second deposit.
        minted = _pullStakedMulti(token, sources);

        // depositStaked mints 1:1 with the alpha it received, so the cut converts exactly.
        mintedForIntegrator = cut * RAO;
        // Defensive: if the runtime ever stops being exact, the shortfall comes off the fee, never
        // off the caller — and `minTokenOut` still bounds what crosses.
        if (mintedForIntegrator > minted) mintedForIntegrator = minted;
        minted -= mintedForIntegrator;
    }

    /// @dev Add `cut` to `sources` in proportion to each entry's share of `total`, in place. The
    ///      FIRST source absorbs the rounding dust so the apportioned amounts sum to exactly `cut`.
    /// @param total The sum of `sources` BEFORE apportionment — the caller owns computing it, so the
    ///        proportions cannot drift as this function mutates the array.
    function _apportion(StakeSource[] memory sources, uint256 total, uint256 cut) private pure {
        uint256 assigned;
        for (uint256 i = 1; i < sources.length; ++i) {
            uint256 share = (cut * sources[i].alphaRao) / total;
            sources[i].alphaRao += share;
            assigned += share;
        }
        sources[0].alphaRao += cut - assigned;
    }

    function _sumSources(StakeSource[] memory sources) private pure returns (uint256 total) {
        for (uint256 i; i < sources.length; ++i) total += sources[i].alphaRao;
    }

    /// @dev Build the single-source list for the legacy scalar entry points: the caller's alpha is
    ///      assumed to sit on the token's own canonical validator, which is what those signatures
    ///      have always meant.
    function _canonicalSource(address token, uint256 stakedAlphaRao)
        private
        view
        returns (StakeSource[] memory sources)
    {
        if (stakedAlphaRao == 0) return new StakeSource[](0);
        (bytes32 validator,) = VAULT.positionOf(token);
        sources = new StakeSource[](1);
        sources[0] = StakeSource({validator: validator, alphaRao: stakedAlphaRao});
    }

    /// @dev Pull the CALLER's own staked alpha from the token's canonical validator only.
    ///      Thin wrapper over the multi-source path so there is ONE implementation.
    function _pullStaked(address token, uint256 stakedAlphaRao) private returns (uint256 minted) {
        (bytes32 validator,) = VAULT.positionOf(token);
        StakeSource[] memory one = new StakeSource[](1);
        one[0] = StakeSource({validator: validator, alphaRao: stakedAlphaRao});
        minted = _pullStakedMulti(token, one);
    }

    /// @dev Pull the CALLER's staked alpha from ONE OR MORE validators, re-delegate each to the
    ///      token's canonical validator, then hand the consolidated position to the vault.
    ///
    ///      Why this shape: `transferStakeFrom` takes a single hotkey, so a pull lands on the hotkey
    ///      it came from. Substrate solves this in one call (`transfer_stake_and_hotkey`) and batches
    ///      it with `Utility.batch`, but NEITHER is exposed to the EVM — verified against the live
    ///      precompile — so the loop here IS the EVM's equivalent of that batch.
    ///
    ///      Accounting: we measure ONLY the canonical position, once before and once after. Every
    ///      per-source rounding loss is therefore absorbed automatically and the caller is credited
    ///      with what actually arrived, never with what was requested. (AlphaVault's own header
    ///      records that creating a position that did not previously exist can cost ONE RAO.)
    function _pullStakedMulti(address token, StakeSource[] memory sources) private returns (uint256 minted) {
        if (sources.length == 0) revert NoStakeSources();
        if (sources.length > MAX_STAKE_SOURCES) revert TooManyStakeSources(sources.length, MAX_STAKE_SOURCES);

        (bytes32 canonical, uint256 netuid) = VAULT.positionOf(token);
        minted = STAKING.getStake(canonical, GATEWAY_COLDKEY, netuid); // opening balance; net out below

        for (uint256 i; i < sources.length; ++i) {
            _pullOne(sources, i, canonical, netuid);
        }

        // Net the canonical position against its opening balance: every per-source rounding loss is
        // absorbed here, so the caller is credited with what ARRIVED, never with what was requested.
        minted = STAKING.getStake(canonical, GATEWAY_COLDKEY, netuid) - minted;
        if (minted == 0) revert ZeroAmount();

        if (!_vaultApprovedNetuid[netuid]) {
            STAKING.approve(address(VAULT), netuid, type(uint256).max);
            _vaultApprovedNetuid[netuid] = true;
        }
        minted = VAULT.depositStaked(token, minted);
    }

    /// @dev One source: pull it to this gateway under its OWN hotkey, then re-delegate to the
    ///      canonical validator. Split out of the loop for stack depth.
    function _pullOne(StakeSource[] memory sources, uint256 i, bytes32 canonical, uint256 netuid) private {
        bytes32 v = sources[i].validator;
        if (v == bytes32(0)) revert ZeroValidator();
        if (sources[i].alphaRao == 0) revert ZeroAmount();
        // Bounded by MAX_STAKE_SOURCES, so the quadratic scan is cheap. A duplicate would move the
        // same intermediate balance twice and double-count it.
        for (uint256 j; j < i; ++j) {
            if (sources[j].validator == v) revert DuplicateStakeSource(v);
        }

        STAKING.transferStakeFrom(msg.sender, address(this), v, netuid, netuid, sources[i].alphaRao);
        if (v == canonical) return;

        // Move the WHOLE intermediate position, not the requested amount: that is what leaves
        // nothing behind when the transfer in was inexact.
        uint256 landed = STAKING.getStake(v, GATEWAY_COLDKEY, netuid);
        if (landed > 0) STAKING.moveStake(v, canonical, netuid, netuid, landed);
        // Anything stranded here sits outside AlphaVault.backing(), which reads only
        // (canonical, netuid), and would silently under-back the token. Refuse instead.
        landed = STAKING.getStake(v, GATEWAY_COLDKEY, netuid);
        if (landed != 0) revert StrandedStake(v, landed);
    }

    /// @notice The runtime's minimum nominator position. Size `alphaRao` so that whatever you LEAVE
    ///         on a validator is either zero or still at least this much.
    /// @dev    NOTHING enforces that. Verified on mainnet: pulling 10,000,000 RAO from a 25,000,000
    ///         position left 15,000,000 against this 20,000,000 reading and the runtime accepted it.
    ///         This value does NOT gate `add_stake` either: live calls pass at 2,000,000 RAO (see
    ///         MIN_ADD_STAKE_RAO), so treat it as advisory for what you LEAVE behind. The gateway
    ///         cannot enforce it either: it never learns the caller's coldkey (0x805 exposes no
    ///         address->coldkey lookup, and the coldkey is blake2b("evm:"+address)), so it cannot
    ///         read their positions. Callers must plan this off-chain; there will be no revert.
    function minStakeRequired() external view returns (uint256) {
        return STAKING.getNominatorMinRequiredStake();
    }

    /// @notice Bridge tokens the caller ALREADY holds on 964 out to `destSelector` (e.g. from a
    ///         direct `depositStaked`, or from a claim). Approve THIS gateway first.
    /// @dev    Restricted to LISTED tokens: this route pulls an arbitrary ERC20 by address, so
    ///         without the check the gateway would relay any token that has a CCIP pool.
    function bridgeTokenOut(uint64 destSelector, address token, address recipient, uint256 amount)
        external
        payable
        returns (bytes32 messageId)
    {
        return _bridgeTokenOut(destSelector, token, recipient, amount, IntegratorFee(address(0), 0));
    }

    /// @notice `bridgeTokenOut` with an integrator fee ON TOP: the caller must approve
    ///         `amount + integratorCut(amount, bps)`; the cut goes to the integrator and `amount`
    ///         crosses in full.
    function bridgeTokenOutWithFee(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 amount,
        IntegratorFee calldata fee
    ) external payable returns (bytes32 messageId) {
        return _bridgeTokenOut(destSelector, token, recipient, amount, fee);
    }

    function _bridgeTokenOut(
        uint64 destSelector,
        address token,
        address recipient,
        uint256 amount,
        IntegratorFee memory fee
    ) private returns (bytes32 messageId) {
        if (amount == 0) revert ZeroAmount();
        if (!VAULT.isListed(token)) revert UnsupportedToken(token);
        _validateIntegratorFee(fee);
        uint256 cut = _integratorCut(amount, fee);
        // pull the amount AND the integrator's cut on top; the full amount crosses
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount + cut)) revert PullFailed();
        _payIntegrator(token, cut, fee);
        messageId = _send(destSelector, token, recipient, amount, 0);
    }

    /// @dev Approve the router for `minted`, ccipSend it, refund the caller. `taoSpent` is the
    ///      native TAO already consumed by a liquid stake (0 for pure staked/token bridges).
    function _send(uint64 destSelector, address token, address recipient, uint256 minted, uint256 taoSpent)
        private
        returns (bytes32 messageId)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        if (!allowedLane[destSelector]) revert LaneNotAllowed(destSelector);
        IERC20(token).approve(ROUTER, minted);
        Client.EVM2AnyMessage memory message = _toRemoteMessage(token, recipient, minted);
        uint256 fee = IRouterClient(ROUTER).getFee(destSelector, message);
        uint256 gross = _grossFee(fee);
        uint256 markup = gross - fee;
        // taoSpent has already left the gateway (depositLiquid), transiently drawing on contract
        // balance if the caller under-funded — safe ONLY because this revert unwinds the whole tx.
        if (msg.value < taoSpent + gross) revert InsufficientValue();

        messageId = IRouterClient(ROUTER).ccipSend{value: fee}(destSelector, message);
        emit BridgedOut(destSelector, token, msg.sender, recipient, minted, messageId);

        // Markup goes out BEFORE the refund: the refund is a call to msg.sender, and settling our
        // own obligations first means a caller who reverts on receive cannot strand the fee here.
        if (markup > 0) {
            address to = _feeRecipient();
            (bool feeOk, ) = to.call{value: markup}("");
            if (!feeOk) revert FeeTransferFailed();
            emit BridgeFeeCollected(to, markup);
        }

        uint256 refund = msg.value - taoSpent - gross;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert NativeTransferFailed();
        }
    }

    function _toRemoteMessage(address token, address recipient, uint256 amount)
        private
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokens = new Client.EVMTokenAmount[](1);
        tokens[0] = Client.EVMTokenAmount({token: token, amount: amount});
        return Client.EVM2AnyMessage({
            receiver: abi.encode(recipient),
            data: "",
            tokenAmounts: tokens,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true})
            )
        });
    }

    // --------------------------------------------------------------- Spoke -> Finney (delivery)

    /// @dev Must stay `internal`: it overrides CCIPReceiver's virtual hook.
    /// @dev Never reverts. On any failure the released tokens are booked claimable (per token) to the
    ///      `evmFallback` decoded from the payload; the rescuer is used only when the payload does
    ///      not decode or that fallback is zero. The token is whatever the CCIP message carried —
    ///      possibly hostile; it is only ever used as the namespace and the asset handed back to its
    ///      own claimants.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        uint256 n = message.destTokenAmounts.length;
        if (n == 0) return; // nothing arrived; nothing to do

        // Resolve the user's fallback ONCE, up front, so every non-delivery path credits THEM rather
        // than the rescuer. Falls back to the rescuer only when the payload is undecodable (nobody
        // to credit) — mirroring handleExit's own zero-fallback default.
        address fb = _safeDecodeExit(message.data).evmFallback;

        // There are two INDEPENDENT reasons a delivery is not honoured. They are separate questions
        // and are checked separately:
        //
        //   1. TRUST — is the source lane one governance has allowed? If not, we do not act on its
        //      payload at all, whatever shape it is.
        if (!allowedLane[message.sourceChainSelector]) {
            _bookAll(message, fb, NotDeliveredReason.UnknownLane);
            return;
        }
        //   2. INTERPRETABILITY — the payload names ONE destination coldkey and ONE liquid/staked
        //      preference, so it can only describe a single token. A message carrying several is
        //      ambiguous (which token was the coldkey meant for?) and we refuse to guess. Only
        //      constructible by calling the router directly; our own senders always send exactly one.
        if (n != 1) {
            _bookAll(message, fb, NotDeliveredReason.AmbiguousTokenCount);
            return;
        }

        // Canonical: trusted lane, exactly one token -> honour the payload.
        address token = message.destTokenAmounts[0].token;
        uint256 amount = message.destTokenAmounts[0].amount;
        if (amount == 0) return;
        try this.handleExit(token, message.data, amount) {
            // delivered
        } catch {
            claimableToken[token][fb] += amount;
            emit Claimable(token, fb, 0, amount);
        }
    }

    /// @dev Book every token in the message claimable to `fb` instead of delivering it. Used for both
    ///      non-delivery reasons above. Booking rather than reverting is deliberate: the source
    ///      tokens are already burned, so a revert would make them permanently unclaimable, whereas a
    ///      booking is fully recoverable via claimStaked / claimLiquid / claimToken. It also keeps this
    ///      never-revert path to cheap storage writes rather than N unbounded vault deliveries.
    /// @dev `fb` is ALWAYS non-zero — guaranteed by `_safeDecodeExit`.
    function _bookAll(Client.Any2EVMMessage memory message, address fb, NotDeliveredReason reason)
        private
    {
        uint256 n = message.destTokenAmounts.length;
        for (uint256 i = 0; i < n; ++i) {
            address token = message.destTokenAmounts[i].token;
            uint256 amount = message.destTokenAmounts[i].amount;
            if (amount == 0) continue;
            claimableToken[token][fb] += amount;
            emit Claimable(token, fb, 0, amount);
            emit NotDelivered(message.sourceChainSelector, token, amount, reason);
        }
    }

    /// @dev Decode the exit payload with two guarantees the callers rely on:
    ///        1. NEVER REVERTS — a hand-crafted message with garbage bytes must not take down
    ///           `_ccipReceive` (the tokens are already burned at the source). The self-call via
    ///           `this` exists only to give `abi.decode` a catchable frame; you cannot try/catch
    ///           an internal call.
    ///        2. `evmFallback` IS NEVER ZERO — substituted with the rescuer both when the payload
    ///           omits it and when the payload is undecodable, so no booking can land on
    ///           address(0) and become permanently unclaimable.
    function _safeDecodeExit(bytes memory data) private view returns (ExitPayload.Params memory p) {
        try this.decodeExit(data) returns (ExitPayload.Params memory decoded) {
            return decoded;
        } catch {
            p.evmFallback = rescuer; // nobody to credit -> recoverable custody
        }
    }

    /// @dev External only so `_safeDecodeExit` can try/catch it. Pure; safe for anyone to call.
    function decodeExit(bytes calldata data) external view returns (ExitPayload.Params memory) {
        return ExitPayload.decode(data, rescuer);
    }

    /// @dev External so the parent can wrap it in try/catch. Only self-callable.
    ///      DELIVERY IS DIRECT: the staked route hands the position straight to the user's coldkey
    ///      and the liquid route sends native to their substrate account. `claimable*` is only the
    ///      failure path — nothing here is deferred for fee reasons.
    function handleExit(address token, bytes calldata data, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        ExitPayload.Params memory p = ExitPayload.decode(data, rescuer);
        bytes32 ss58 = p.ss58;
        address evmFallback = p.evmFallback; // never zero: decode substitutes the rescuer
        bool wantLiquid = p.wantLiquid;

        // Wrapped token, no coldkey: hand the ERC20 straight to the EVM fallback. The FULL amount,
        // dust included (an ERC20 transfer has no whole-RAO constraint), and regardless of a halt
        // (this never touches the vault). A false return or a revert propagates to the outer catch
        // in `_ccipReceive`, which books `amount` claimable to this same address.
        if (!wantLiquid && ss58 == bytes32(0)) {
            if (!IERC20(token).transfer(evmFallback, amount)) revert TransferFailed();
            emit DeliveredToken(token, evmFallback, amount);
            return;
        }

        uint256 exitAmount = amount - (amount % RAO); // whole-RAO
        uint256 dust = amount - exitAmount;

        // While the vault is halted, every withdrawal route reverts. Book the whole amount claimable
        // to the user's own fallback — redeemable (claimStaked/claimLiquid/claimToken) once unpaused.
        if (amount > 0 && VAULT.isPaused()) {
            claimableToken[token][evmFallback] += amount; // evmFallback is rescuer-defaulted, never zero
            emit Claimable(token, evmFallback, 0, amount);
            return;
        }

        if (exitAmount > 0) {
            // Both vault withdrawals can revert for reasons beyond a halt (e.g. the staked
            // position is short of the redemption -> Insolvent). Wrap them so ANY vault
            // failure books claimable to the USER's fallback rather than falling through to the
            // outer catch (which books to the same decoded fallback, just further from the cause).
            if (wantLiquid) {
                // unwrap to native TAO and exit to the substrate account (or evmFallback)
                try VAULT.withdrawLiquid(token, exitAmount, p.minTaoOut) returns (uint256 taoOut) {
                    if (ss58 != bytes32(0)) {
                        try SUBSTRATE_EXIT.transfer{value: taoOut}(ss58) {
                            emit DeliveredLiquid(token, ss58, taoOut);
                        } catch {
                            claimableNative[evmFallback] += taoOut;
                            emit Claimable(token, evmFallback, taoOut, 0);
                        }
                    } else {
                        (bool ok, ) = evmFallback.call{value: taoOut}("");
                        if (!ok) {
                            claimableNative[evmFallback] += taoOut;
                            emit Claimable(token, evmFallback, taoOut, 0);
                        }
                    }
                } catch {
                    claimableToken[token][evmFallback] += exitAmount;
                    emit Claimable(token, evmFallback, 0, exitAmount);
                }
            } else {
                // deliver the staked position directly to the destination coldkey (zero slippage)
                try VAULT.withdrawStaked(token, exitAmount, ss58) {
                    emit DeliveredStaked(token, ss58, exitAmount / RAO);
                } catch {
                    claimableToken[token][evmFallback] += exitAmount;
                    emit Claimable(token, evmFallback, 0, exitAmount);
                }
            }
        }
        if (dust > 0) {
            claimableToken[token][evmFallback] += dust; // evmFallback is rescuer-defaulted, never zero
            emit Claimable(token, evmFallback, 0, dust);
        }
    }

    // ---------------------------------------------------------------- claims (pull)
    //
    // Every claim credits the CALLER's own balance and lets them nominate where it lands (`to`).
    // The receiver parameter matters: a booking can be made to a contract that cannot accept native
    // TAO or is otherwise unable to act on 964, and without it that balance would be stuck forever.
    // Only the owner of the balance can move it, so this delegates delivery, never custody.

    /// @notice Claim a stuck native balance, sent to `to`.
    function claimNative(address to) external {
        if (to == address(0)) revert ZeroRecipient();
        uint256 amt = claimableNative[msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimableNative[msg.sender] = 0;
        (bool ok, ) = to.call{value: amt}("");
        if (!ok) revert NativeTransferFailed();
        emit Claimed(address(0), msg.sender, to, amt);
    }

    /// @notice Claim a stuck balance as the wrapped token itself, sent to `to`.
    function claimToken(address token, address to) external {
        if (to == address(0)) revert ZeroRecipient();
        uint256 amt = claimableToken[token][msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimableToken[token][msg.sender] = 0;
        if (!IERC20(token).transfer(to, amt)) revert TransferFailed();
        emit Claimed(token, msg.sender, to, amt);
    }

    /// @notice Claim a stuck balance as the underlying STAKED position, delivered straight to
    ///         `destColdkey` (zero slippage) — the preferred path, so the user never has to hold or
    ///         re-bridge the token. Any sub-RAO remainder (which cannot be unstaked) goes to `to`.
    /// @dev    Unwrapping is a withdrawal, so this reverts while the vault is halted — the revert
    ///         rolls everything back; retry once the halt lifts. CEI: balance zeroed before calls.
    /// @dev Requires a real coldkey: this route exists to deliver a STAKED position, and the
    ///      vault would reject a zero one anyway — checking here fails before the balance is
    ///      zeroed and gives a gateway-native error. A caller holding only sub-RAO dust (nothing
    ///      stakeable) should use `claimToken` instead.
    function claimStaked(address token, bytes32 destColdkey, address to) external {
        if (to == address(0)) revert ZeroRecipient();
        if (destColdkey == bytes32(0)) revert ZeroColdkey();
        uint256 amt = claimableToken[token][msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimableToken[token][msg.sender] = 0;
        uint256 exit = amt - (amt % RAO);
        uint256 dust = amt - exit;
        if (exit > 0) {
            VAULT.withdrawStaked(token, exit, destColdkey);
            emit DeliveredStaked(token, destColdkey, exit / RAO);
            emit Claimed(token, msg.sender, to, exit);
        }
        if (dust > 0) {
            if (!IERC20(token).transfer(to, dust)) revert TransferFailed();
            emit DustReturned(token, to, dust);
        }
    }

    /// @notice Claim a stuck balance as native TAO, sent to `to` (slippage-bounded). Sub-RAO dust is
    ///         returned as the token. Reverts while halted; retry after.
    function claimLiquid(address token, uint256 minTaoOut, address to) external {
        if (to == address(0)) revert ZeroRecipient();
        uint256 amt = claimableToken[token][msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimableToken[token][msg.sender] = 0;
        uint256 exit = amt - (amt % RAO);
        uint256 dust = amt - exit;
        if (exit > 0) {
            uint256 taoOut = VAULT.withdrawLiquid(token, exit, minTaoOut);
            (bool ok, ) = to.call{value: taoOut}("");
            if (!ok) revert NativeTransferFailed();
            emit DeliveredLiquid(token, bytes32(0), taoOut);
            emit Claimed(token, msg.sender, to, taoOut);
        }
        if (dust > 0) {
            if (!IERC20(token).transfer(to, dust)) revert TransferFailed();
            emit DustReturned(token, to, dust);
        }
    }

    receive() external payable {} // accept native from withdrawLiquid
}
