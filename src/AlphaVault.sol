// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {IAlphaToken} from "./interfaces/IAlphaToken.sol";
import {IAlphaVault} from "./interfaces/IAlphaVault.sol";
import {AlphaToken} from "./AlphaToken.sol";

/// @title AlphaVault — MULTI-TOKEN singleton wrapper for staked Bittensor positions (Subtensor EVM, 964).
/// @notice ONE vault serves every wrapped asset. Each asset is a thin AlphaToken ERC20 (the CCIP
///         pools require a distinct token per asset) registered here with its position config:
///           netuid = 0  -> "TAO":  the root staked position (root alpha ≈ TAO 1:1)
///           netuid = X  -> "SN_X": the staked alpha of subnet X
///         Tokens are ALPHA-DENOMINATED: 1e18 token == 1e9 RAO of alpha.
///
///         Per-token isolation comes from the chain itself: stake is keyed by (validator, coldkey,
///         netuid) on the precompile, so each listed token's position is a separate ledger entry —
///         and the vault enforces ONE token per netuid (one subnet, one wrapped token — a second
///         listing is rejected even with a different validator). Native TAO is never held between
///         transactions: an unstake credits the vault and pays out in the same call, so there is no
///         resting native balance to commingle in the first place. Untracked balance (donations,
///         rounding residue) is sweepable but can never be counted as any token's backing.
///
///         Four user routes per token (per-tx choice), each AMM-touching one bounded by a caller min:
///           depositLiquid(token, minAlphaOut)      payable — stake TAO->alpha; mints measured alpha
///           depositStaked(token, alpha)                    — pull existing stake; zero slippage
///           withdrawLiquid(token, wad, minTaoOut)          — unstake alpha->TAO; pays measured
///           withdrawStaked(token, wad, destColdkey)        — transfer staked position out; zero slippage
///
/// @dev  Design rules (carried over from the single-token vault reviews):
///        1. MEASURE, don't assume. Deposits mint the getStake delta; liquid withdrawals pay the
///           balance delta. AMM fee/slippage lands on the user who chose the AMM route.
///        2. ALPHA UNITS for backing/emissions. `harvestableAlphaRao` is the STAKED surplus only.
///        3. BACKING IS THE STAKED POSITION, and only that. There is no native buffer to fall back
///           on: withdrawLiquid unstakes exactly what it pays and reverts if the position is short.
///        4. SLIPPAGE IS EXPLICIT. Every AMM conversion takes a caller min-received (the staked
///           routes have no AMM leg, so there is nothing to bound).
///
///        Access control (docs/access-control.md): three GLOBAL tiers on
///        AccessControlDefaultAdminRules (root rotation is 2-step + time-delayed). One
///        admin/operator/guardian set governs all tokens; the halt is global (a vault-logic incident
///        affects every token; per-token granularity can be added later if ever needed).
///          - DEFAULT_ADMIN_ROLE : slow/root tier (Timelock -> multisig). Reroutes value
///            (setEmissionsRecipient), manages roles, sets gateway lanes, and points `ccipAdmin`
///            (setCcipAdmin) — it does NOT list tokens.
///          - OPERATOR_ROLE      : fast multisig-direct tier (createToken, addToken,
///            migrateValidator, setSkimMargin, skim, skimStaked, claimRoot, claimRootFor,
///            sweepExcess, unpause, adminHold).
///            Listing is deliberately a FAST-lane action: AlphaToken.getCCIPAdmin() resolves to
///            `ccipAdmin` (normally this same multisig), so the operator can both list a token and
///            complete its CCIP registration without waiting on the timelock. CCIP reads
///            getCCIPAdmin only at REGISTRATION — repointing `ccipAdmin` does NOT move an
///            already-registered token's administrator, which must be handed over per token
///            (transferAdminRole + acceptAdminRole). See AlphaToken.getCCIPAdmin.
///          - GUARDIAN_ROLE      : fast low-trust tier. Only `guardianPause` — auto-expiring FULL
///            HALT, extend-only, capped per shot, cooldown between shots.
///        skim() and the claim routes are OPERATOR-gated. They were permissionless on the
///        argument that the destination is hard-wired so a stranger could only help. That was
///        wrong: both SELL at market with no protocol-controlled floor -- skim takes minTaoOut
///        from its caller (zero is accepted) and the root claim has no slippage bound at all --
///        so an attacker could pick a manipulated moment and burn protocol revenue for free.
///        Hard-wiring the destination bounds who gets paid, not what the sale fetches.
///
///        Precompile behaviour, measured on mainnet 964 (see test-onchain/StakeProbe.sol):
///        removeStake credits atomically in-tx; getStake is readable; addStake, moveStake and
///        transferStakeFrom move the exact RAO asked for.
///
///        transferStake is NOT exact. Creating a position that did not exist loses ONE RAO to
///        share-pool rounding: 20,000,000 sent, 19,999,999 credited, while the sender was debited
///        the full amount. Adding to a position that already exists is exact. So `withdrawStaked`
///        to a coldkey with no prior position on that (validator, netuid) delivers 1 RAO less
///        than was burned — a rounding crumb worth ~1e-9 TAO, borne by that withdrawer and never
///        by the pool. Called out because the sender-side debit looks exact, so the discrepancy
///        is invisible from this contract's own accounting.
contract AlphaVault is AccessControlDefaultAdminRules, ReentrancyGuard {
    struct TokenConfig {
        bytes32 validator; // hotkey the token's position delegates to (OPERATOR-migratable)
        uint256 netuid;
        uint256 skimMarginRao; // cushion kept above supply, in alpha RAO
        bool listed;
    }

    IStaking public immutable STAKING; // 0x805 in production; injectable for tests
    uint256 private constant RAO = 1e9; // wei per RAO; 1e18 token == 1e9 alpha RAO

    /// @dev Subtensor enforces its own minimums on the staking precompile — measured on mainnet
    ///      964: `removeStake` reverts below 2,000,000 RAO, `transferStake` below 1,000,000 RAO.
    ///      They are deliberately NOT mirrored as constants here. This contract is immutable and
    ///      those are runtime parameters: pinning them would permanently block withdrawals the
    ///      runtime is willing to serve if a floor is ever lowered, which is a worse failure than
    ///      the precompile's own revert. Callers that want an early, named rejection get it at the
    ///      bridge edge (SpokeGateway.MIN_LIQUID_EXIT_WEI), where the cost of being wrong is a
    ///      rejected message rather than a stuck position.

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Initial delay for the built-in 2-step DEFAULT_ADMIN_ROLE rotation (governance can
    ///         retune via changeDefaultAdminDelay).
    uint48 public constant INITIAL_ADMIN_DELAY = 2 days;

    /// @notice Emergency FULL-HALT bounds (docs/access-control.md), global across all tokens.
    uint256 public constant MAX_PAUSE = 2 days; // guardian can never exceed this in one shot
    uint256 public constant COOLDOWN = 12 hours; // anti-chain-freeze: min gap before re-pausing

    /// @notice This contract's EVM-mapped substrate coldkey = blake2b_256("evm:" + address(this)).
    ///         One vault -> one coldkey; positions are separated per (validator, netuid) by the
    ///         chain. Immutable, no setter -> not an access-control surface.
    bytes32 public immutable vaultColdkey;

    mapping(address => TokenConfig) private _configs;
    /// @notice netuid -> the ONE wrapped token for that subnet. One subnet, one token: a second
    ///         listing for the same netuid is rejected even with a different validator. Keying on
    ///         netuid alone (rather than validator+netuid) is deliberate — it is what makes the
    ///         product 1:1, and it also means a validator migration can never collide, since no
    ///         other token shares the netuid.
    mapping(uint256 => address) public tokenForNetuid;
    address public emissionsRecipient; // global: all tokens' emissions route here

    /// @notice Notice period before a migration may execute. Deposits stop the moment a migration
    ///         is initiated, so nobody can enter and the position can only shrink. Withdrawals are
    ///         NOT guaranteed to stay open across the window: OPERATOR can halt them with
    ///         `adminHold`. The intent is that holders are migrated together with the backing,
    ///         not that they exit through the old vault.
    uint256 public constant MIGRATION_DELAY = 7 days;

    address public migrationTarget;
    bytes32 public migrationColdkey;
    uint256 public migrationReadyAt; // 0 = no migration announced
    /// @notice Set once by `finishMigration`, never unset. The vault is retired: deposits are shut
    ///         permanently, no further migration can be announced, and every value route is halted
    ///         (`pausedUntil` is set to max). OPERATOR can lift that halt with `unpause`/`adminHold`
    ///         if backing was left behind.
    bool public migrationFinished;
    /// @notice True once ANY token's position has actually been moved. Cancellation is a way back
    ///         only while nothing has left; after the first `executeMigration` there is no way
    ///         back, and pretending otherwise would reopen deposits into a vault that has already
    ///         lost backing.
    bool public migrationExecuted;

    /// @notice The address `AlphaToken.getCCIPAdmin()` resolves to — i.e. the account Chainlink's
    ///         `registerAdminViaGetCCIPAdmin` requires as msg.sender, and which then becomes the
    ///         token's registry administrator (holding `setPool`). Normally the OPERATOR multisig,
    ///         so listing a token is a one-step ops action rather than a timelocked one. Repointed
    ///         only by DEFAULT_ADMIN, and only affects tokens registered AFTER the change.
    address public ccipAdmin;

    /// @notice Halt state (global). `pausedUntil` = timestamp the halt lifts itself; `pauseableAfter`
    ///         = the earliest a guardian may re-pause (cooldown).
    uint256 public pausedUntil;
    uint256 public pauseableAfter;

    /// @dev Open only around a removeStake call, so `receive()` accepts a precompile credit but
    ///      bounces every plain send. 1/2 (never 0) to keep the write warm-slot cheap.
    uint256 private constant _WINDOW_SHUT = 1;
    uint256 private constant _WINDOW_OPEN = 2;
    uint256 private _unstakeWindow = _WINDOW_SHUT;

    event Initialized(
        address indexed staking, bytes32 indexed vaultColdkey, address indexed emissionsRecipient, address admin
    );
    event TokenAdded(address indexed token, bytes32 indexed validator, uint256 netuid);
    event DepositLiquid(address indexed token, address indexed dst, uint256 taoIn, uint256 minted);
    event DepositStaked(address indexed token, address indexed dst, uint256 alphaRao, uint256 minted);
    event WithdrawLiquid(address indexed token, address indexed src, uint256 burned, uint256 taoOut);
    event WithdrawStaked(address indexed token, address indexed src, uint256 burned, bytes32 indexed destColdkey);
    event Skimmed(address indexed token, address indexed to, uint256 alphaRao, uint256 taoOut);
    event SkimmedStaked(address indexed token, bytes32 indexed toColdkey, uint256 alphaRao);
    event ValidatorChanged(address indexed token, bytes32 indexed from, bytes32 indexed to, uint256 movedAlpha);
    event EmissionsRecipientChanged(address indexed to);
    event CcipAdminChanged(address indexed to);
    event SkimMarginChanged(address indexed token, uint256 marginRao);

    /// @param alphaGained The measured increase in staked alpha. The precompile returns nothing,
    ///        so this delta is the only report of what a claim actually paid.
    event RootClaimed(address indexed token, uint256 alphaGained);
    event MigrationInitiated(address indexed target, bytes32 targetColdkey, uint256 readyAt);
    event MigrationCancelled(address indexed target);
    event MigrationExecuted(address indexed token, address indexed target, uint256 alphaRao);
    event MigrationFinished(address indexed target);
    event ExcessSwept(address indexed to, uint256 amount);
    event Halted(address indexed by, uint256 until);
    event Unhalted(address indexed by);

    error ZeroAddress();
    error ZeroValidator();
    error ZeroAmount();
    error NotWholeRao();
    error Slippage();
    error Insolvent();
    error NothingToSkim();
    error MigrationNotInitiated();
    error MigrationAlreadyFinished();
    error MigrationIrreversible();
    error NothingMigrated();
    error NetuidTooLarge(uint256 netuid);
    error NotRootToken(uint256 netuid);
    error MigrationPending();
    error MigrationNotReady();
    error MigrationInProgress();
    error ColdkeyMismatch();
    error NativeTransferFailed();
    error IsHalted();
    error PauseCapExceeded();
    error PauseCooldown();
    error UnknownToken();
    error AlreadyListed();
    error NetuidTaken(uint256 netuid, address existingToken);
    error WrongVault();
    error InsufficientBalance(uint256 balance, uint256 needed);
    error DirectSendNotAllowed();

    modifier whenNotHalted() {
        if (isPaused()) revert IsHalted();
        _;
    }

    /// @dev Deposits close the instant a migration is announced. Without this the notice period
    ///      would be meaningless — new depositors could keep buying into a vault that is about to
    ///      have its backing moved out from under them.
    modifier whenNotMigrating() {
        if (migrationReadyAt != 0 || migrationFinished) revert MigrationInProgress();
        _;
    }

    modifier onlyListed(address token) {
        if (!_configs[token].listed) revert UnknownToken();
        _;
    }

    /// @dev Explicit pre-burn balance guard: a caller trying to withdraw more than they hold gets a
    ///      clear vault-native error (with amounts) instead of the token's ERC20 burn revert.
    function _requireBalance(address token, uint256 wad) private view {
        uint256 bal = IAlphaToken(token).balanceOf(msg.sender);
        if (bal < wad) revert InsufficientBalance(bal, wad);
    }

    /// @dev The base grants DEFAULT_ADMIN_ROLE to `admin_` (2-step + delayed rotation). OPERATOR and
    ///      GUARDIAN are wired post-deploy via `grantRole` — see DeployAlpha.
    ///
    ///      `ccipAdmin` starts as `admin_` (the deployer during a deploy run) so the deploy script
    ///      can self-register the first token, and is repointed at the OPERATOR multisig as part of
    ///      the handoff. It is NOT defaulted to address(0): an unset ccipAdmin would make
    ///      getCCIPAdmin() return zero and brick registration.
    constructor(IStaking staking_, bytes32 vaultColdkey_, address emissionsRecipient_, address admin_)
        AccessControlDefaultAdminRules(INITIAL_ADMIN_DELAY, admin_)
    {
        if (address(staking_) == address(0) || emissionsRecipient_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        if (vaultColdkey_ == bytes32(0)) revert ZeroValidator();
        STAKING = staking_;
        vaultColdkey = vaultColdkey_;
        emissionsRecipient = emissionsRecipient_;
        ccipAdmin = admin_;
        emit Initialized(address(staking_), vaultColdkey_, emissionsRecipient_, admin_);
        emit CcipAdminChanged(admin_);
    }

    /// @notice Plain native sends BOUNCE: a direct transfer to the vault mints nothing and would end
    ///         up swept to emissionsRecipient, i.e. a user mistake becoming a user loss.
    /// @dev    Native is accepted ONLY while an unstake is in flight (`_unstakeWindow`). On today's
    ///         Subtensor the 0x805 credit is a direct substrate account mutation that executes no EVM
    ///         code, so this receive() is never hit — but if the runtime ever credited via an EVM
    ///         value transfer, a hard `revert` here would brick EVERY redemption (withdrawLiquid,
    ///         skim). The window makes correctness independent of that runtime
    ///         detail instead of betting on it, while keeping the bounce for user mistakes. The
    ///         window is opened only around the precompile call itself (see `_removeStake`), never
    ///         across an external call to a user, so it cannot be used to sneak in a donation.
    receive() external payable {
        if (_unstakeWindow != _WINDOW_OPEN) revert DirectSendNotAllowed();
    }

    /// @dev Unstake `alphaRao` of the token's position, returning the MEASURED native credited.
    ///      Single choke point for every removeStake in the contract.
    function _removeStake(TokenConfig storage c, uint256 alphaRao) private returns (uint256 received) {
        uint256 b0 = address(this).balance;
        _unstakeWindow = _WINDOW_OPEN;
        STAKING.removeStake(c.validator, alphaRao, c.netuid);
        _unstakeWindow = _WINDOW_SHUT;
        received = address(this).balance - b0;
    }

    // ------------------------------------------------------------------ token registry

    /// @notice ONE-CALL listing: deploy the AlphaToken AND list it on a netuid (delegating to
    ///         `validator_`) atomically — OPERATOR (fast tier: listing is an ops action, and the
    ///         matching CCIP registration is gated on `ccipAdmin`, normally the same multisig, so
    ///         the whole listing completes without the timelock). The preferred path: the vault
    ///         constructs the token itself, so the VAULT binding, mint/burn authority and listing
    ///         can never be mis-assembled.
    function createToken(string calldata name_, string calldata symbol_, bytes32 validator_, uint256 netuid_)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotMigrating
        returns (address token)
    {
        token = address(new AlphaToken(address(this), name_, symbol_));
        _list(token, validator_, netuid_);
    }

    /// @notice Low-level listing of a PRE-DEPLOYED AlphaToken (e.g. a vanity address) — must be
    ///         bound to this vault. Prefer `createToken`. OPERATOR, same fast tier as `createToken`.
    function addToken(address token, bytes32 validator_, uint256 netuid_)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotMigrating
    {
        if (token == address(0)) revert ZeroAddress();
        if (IAlphaToken(token).VAULT() != address(this)) revert WrongVault();
        _list(token, validator_, netuid_);
    }

    function _list(address token, bytes32 validator_, uint256 netuid_) private {
        // The runtime addresses subnets as uint16 (see IStaking.claimRoot's uint16[] and every
        // netuid field on chain). A larger value cannot name a real subnet, so listing one would
        // create a token whose position can never exist. Reject at the boundary rather than
        // discovering it as a permanently zero backing.
        if (netuid_ > type(uint16).max) revert NetuidTooLarge(netuid_);
        if (validator_ == bytes32(0)) revert ZeroValidator();
        if (_configs[token].listed) revert AlreadyListed();
        address existing = tokenForNetuid[netuid_];
        if (existing != address(0)) revert NetuidTaken(netuid_, existing);

        tokenForNetuid[netuid_] = token;
        _configs[token] = TokenConfig({
            validator: validator_,
            netuid: netuid_,
            skimMarginRao: 100_000, // 0.0001 alpha default cushion
            listed: true
        });
        emit TokenAdded(token, validator_, netuid_);
    }

    // ------------------------------------------------------------------ deposits

    /// @notice Liquid route: wrap native TAO. Stakes it into `token`'s position and mints the alpha
    ///         ACTUALLY received.
    function depositLiquid(address token, uint256 minAlphaRao)
        external
        payable
        whenNotHalted
        whenNotMigrating
        nonReentrant
        onlyListed(token)
        returns (uint256 minted)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value % RAO != 0) revert NotWholeRao();
        TokenConfig storage c = _configs[token];

        uint256 s0 = _stakedRao(c);
        STAKING.addStake(c.validator, msg.value / RAO, c.netuid);
        uint256 received = _stakedRao(c) - s0;
        if (received < minAlphaRao || received == 0) revert Slippage();

        minted = received * RAO;
        IAlphaToken(token).mint(msg.sender, minted);
        emit DepositLiquid(token, msg.sender, msg.value, minted);
    }

    /// @notice Staked route (zero slippage): pull `alphaRao` of the caller's EXISTING stake on this
    ///         token's subnet+validator. Caller must first 0x805 approve(vault, netuid, >= alphaRao).
    function depositStaked(address token, uint256 alphaRao)
        external
        whenNotHalted
        whenNotMigrating
        nonReentrant
        onlyListed(token)
        returns (uint256 minted)
    {
        if (alphaRao == 0) revert ZeroAmount();
        TokenConfig storage c = _configs[token];

        uint256 s0 = _stakedRao(c);
        STAKING.transferStakeFrom(msg.sender, address(this), c.validator, c.netuid, c.netuid, alphaRao);
        uint256 received = _stakedRao(c) - s0;
        if (received == 0) revert ZeroAmount();

        minted = received * RAO;
        IAlphaToken(token).mint(msg.sender, minted);
        emit DepositStaked(token, msg.sender, alphaRao, minted);
    }

    // ------------------------------------------------------------------ withdrawals

    /// @notice Liquid route: burn `wad` of `token`, receive native TAO. Unstakes exactly what it
    ///         pays out, from the token's own position.
    /// @dev    There is no buffer to draw on: if the position cannot cover `wad` the call reverts
    ///         with Insolvent and the burn rolls back. That is deliberate — a native fallback paid
    ///         at 1:1 is only exact on root, so on a subnet (alpha price != 1 TAO) it would pay
    ///         early withdrawers at par out of proceeds worth less than par, making redemption
    ///         first-come-first-served. Reverting keeps every holder's claim identical.
    function withdrawLiquid(address token, uint256 wad, uint256 minTaoOut)
        external
        whenNotHalted
        nonReentrant
        onlyListed(token)
        returns (uint256 taoOut)
    {
        if (wad == 0) revert ZeroAmount();
        if (wad % RAO != 0) revert NotWholeRao();
        _requireBalance(token, wad);
        TokenConfig storage c = _configs[token];
        IAlphaToken(token).burn(msg.sender, wad);

        uint256 alphaRao = wad / RAO;
        // The position must cover the whole redemption. No partial unstake, no fallback.
        if (alphaRao > _stakedRao(c)) revert Insolvent();

        // Measured, not assumed: `taoOut` is the actual native credited. Zero proceeds on a
        // non-zero unstake (an AMM that returned nothing) is not special-cased here — it simply
        // leaves taoOut smaller, and the `taoOut == 0` / `< minTaoOut` slippage check below rejects
        // it, rolling back the burn.
        taoOut = _removeStake(c, alphaRao);
        if (taoOut < minTaoOut || taoOut == 0) revert Slippage();

        (bool ok, ) = msg.sender.call{value: taoOut}("");
        if (!ok) revert NativeTransferFailed();
        emit WithdrawLiquid(token, msg.sender, wad, taoOut);
    }

    /// @notice Staked route (zero slippage): burn `wad`, transfer the corresponding staked alpha to
    ///         `destColdkey`. Position stays staked to the token's validator.
    function withdrawStaked(address token, uint256 wad, bytes32 destColdkey)
        external
        whenNotHalted
        nonReentrant
        onlyListed(token)
    {
        if (wad == 0) revert ZeroAmount();
        if (wad % RAO != 0) revert NotWholeRao();
        if (destColdkey == bytes32(0)) revert ZeroAddress();
        _requireBalance(token, wad);
        TokenConfig storage c = _configs[token];
        IAlphaToken(token).burn(msg.sender, wad);

        STAKING.transferStake(destColdkey, c.validator, c.netuid, c.netuid, wad / RAO);
        emit WithdrawStaked(token, msg.sender, wad, destColdkey);
    }

    // ------------------------------------------------------------------ liquidity ops (OPERATOR)

    /// @notice Sweep untracked native balance (donations, rounding residue) to emissionsRecipient.
    ///         The vault holds no native between transactions — an unstake is credited and paid out
    ///         within the same call — so any resting balance is by definition untracked.
    function sweepExcess() external onlyRole(OPERATOR_ROLE) nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert ZeroAmount();
        (bool ok, ) = emissionsRecipient.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit ExcessSwept(emissionsRecipient, amount);
    }

    // ------------------------------------------------------------------ emergency halt (global)

    /// @notice Fast, low-trust FULL HALT of all user value routes, across ALL tokens. Auto-expires
    ///         after `dur` (capped at MAX_PAUSE per shot); the cooldown forces a recurring open
    ///         window between halts. Extend-only; cannot unpause — only OPERATOR unpauses early or
    ///         holds past the cap.
    function guardianPause(uint256 dur) external onlyRole(GUARDIAN_ROLE) {
        if (dur == 0 || dur > MAX_PAUSE) revert PauseCapExceeded();
        if (block.timestamp < pauseableAfter) revert PauseCooldown();
        uint256 until = block.timestamp + dur;
        pauseableAfter = until + COOLDOWN; // this guardian's own re-pause cooldown
        // Extend-only: never shorten an existing (e.g. OPERATOR adminHold) halt.
        if (until > pausedUntil) pausedUntil = until;
        emit Halted(msg.sender, pausedUntil);
    }

    /// @notice Lift the halt immediately (OPERATOR / multisig only — unpausing is the dangerous side).
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _lift();
    }

    /// @notice OPERATOR override for the halt window: `until` in the future holds (may exceed the
    ///         guardian's cap); `until` at/below now LIFTS the halt (emits Unhalted).
    function adminHold(uint256 until) external onlyRole(OPERATOR_ROLE) {
        if (until > block.timestamp) {
            pausedUntil = until;
            // If this SHORTENS a halt, re-anchor the guardian cooldown to the new (earlier) end.
            uint256 cooldownEnd = until + COOLDOWN;
            if (cooldownEnd < pauseableAfter) pauseableAfter = cooldownEnd;
            emit Halted(msg.sender, until);
        } else {
            _lift();
        }
    }

    /// @dev Single writer for lifting a halt. Re-anchors the guardian cooldown to the ACTUAL end.
    function _lift() private {
        pausedUntil = 0;
        uint256 cooldownEnd = block.timestamp + COOLDOWN;
        if (cooldownEnd < pauseableAfter) pauseableAfter = cooldownEnd;
        emit Unhalted(msg.sender);
    }

    /// @notice True while all user value routes (every token) are halted. Sole predicate behind
    ///         `whenNotHalted`, so the view can never disagree with what the gated routes enforce.
    function isPaused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    // ------------------------------------------------------------------ views

    function _stakedRao(TokenConfig storage c) private view returns (uint256) {
        return STAKING.getStake(c.validator, vaultColdkey, c.netuid);
    }

    function isListed(address token) external view returns (bool) {
        return _configs[token].listed;
    }

    /// @notice The token's (validator, netuid) position. Reverts for unlisted tokens.
    function positionOf(address token) public view onlyListed(token) returns (bytes32, uint256) {
        TokenConfig storage c = _configs[token];
        return (c.validator, c.netuid);
    }

    function skimMarginOf(address token) external view returns (uint256) {
        return _configs[token].skimMarginRao;
    }

    /// @notice The token's current staked alpha backing, in RAO.
    function stakedValueRao(address token) public view onlyListed(token) returns (uint256) {
        return _stakedRao(_configs[token]);
    }

    /// @notice The token's backing: its staked position, in token units (alphaRao * 1e9). This is
    ///         the whole of it — there is no native component, so nothing here silently assumes an
    ///         alpha:TAO price the way summing two different units would.
    function backing(address token) public view returns (uint256 stakedAlpha) {
        return stakedValueRao(token) * RAO;
    }

    /// @notice Emissions available to harvest for `token`, in ALPHA RAO: the staked surplus over
    ///         supply + margin.
    function harvestableAlphaRao(address token) public view onlyListed(token) returns (uint256) {
        TokenConfig storage c = _configs[token];
        // ceil-divide: a partially-minted RAO still counts as owed supply, so a skim can never take
        // actual backing even with skimMarginRao set to 0.
        uint256 supplyAlpha = (IAlphaToken(token).totalSupply() + RAO - 1) / RAO;
        uint256 floor = supplyAlpha + c.skimMarginRao;
        uint256 staked = _stakedRao(c);
        return staked > floor ? staked - floor : 0;
    }

    // ------------------------------------------------------------------ emissions

    /// @notice Harvest `token`'s emissions as NATIVE TAO to `emissionsRecipient` (unstakes the
    ///         surplus). OPERATOR_ROLE only; AMM proceeds bounded by `minTaoOut`; use `skimStaked`
    ///         for a guaranteed zero-slippage harvest on illiquid subnets.
    function skim(address token, uint256 minTaoOut)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotHalted
        nonReentrant
        onlyListed(token)
        returns (uint256 taoOut)
    {
        TokenConfig storage c = _configs[token];
        uint256 surplusAlpha = harvestableAlphaRao(token);
        if (surplusAlpha == 0) revert NothingToSkim();
        taoOut = _removeStake(c, surplusAlpha);
        if (taoOut < minTaoOut || taoOut == 0) revert Slippage();
        (bool ok, ) = emissionsRecipient.call{value: taoOut}("");
        if (!ok) revert NativeTransferFailed();
        emit Skimmed(token, emissionsRecipient, surplusAlpha, taoOut);
    }

    /// @notice Harvest `token`'s emissions as STAKED alpha (zero slippage) to `destColdkey`.
    ///         OPERATOR_ROLE only; the destination is a free parameter.
    function skimStaked(address token, bytes32 destColdkey)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotHalted
        nonReentrant
        onlyListed(token)
        returns (uint256 alphaRao)
    {
        if (destColdkey == bytes32(0)) revert ZeroAddress();
        TokenConfig storage c = _configs[token];
        alphaRao = harvestableAlphaRao(token);
        if (alphaRao == 0) revert NothingToSkim();
        STAKING.transferStake(destColdkey, c.validator, c.netuid, c.netuid, alphaRao);
        emit SkimmedStaked(token, destColdkey, alphaRao);
    }

    // ------------------------------------------------------------------ root claiming

    /// @notice Redeem this vault's accrued beta-basket entitlement across every validator it root-
    ///         stakes to, and report what it paid.
    ///
    /// @dev OPERATOR_ROLE only. The destination is not a parameter: the runtime sells the basket
    ///      share and stakes the proceeds under THIS vault's coldkey, so a call can only ever
    ///      increase our backing.
    ///
    ///      This exists because nobody else can do it for us. `claim_root_with_hotkey` takes the
    ///      staker's coldkey as origin, and ours is the EVM mirror of this address — no private
    ///      key, reachable only through this contract. The documented automatic rotation was not
    ///      observable on chain (400 blocks scanned, every RootClaimed came from a signed
    ///      extrinsic), so relying on it would be relying on nothing.
    ///
    /// @param token The listed token whose position to measure the gain against.
    /// @return gained Increase in staked alpha, in RAO. The precompile returns nothing, so this
    ///         delta is the only honest report of the amount claimed.
    function claimRoot(address token)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotHalted
        nonReentrant
        onlyListed(token)
        returns (uint256 gained)
    {
        TokenConfig storage c = _configs[token];
        // Claim proceeds ALWAYS land on root (netuid 0) -- the runtime sells the basket and stakes
        // it there, and the destination is not a parameter. Measuring that against a subnet token's
        // ledger reads a netuid the proceeds never touched: `gained` would report 0 while real
        // root stake appeared that no token's backing represents. Root only.
        if (c.netuid != 0) revert NotRootToken(c.netuid);
        uint256 before = _stakedRao(c);
        STAKING.claimRoot(new uint16[](0));
        uint256 after_ = _stakedRao(c);
        // Underflow-safe: a claim cannot reduce stake, but reading defensively costs nothing and
        // a surprise here should surface as zero rather than a revert on an otherwise good tx.
        gained = after_ > before ? after_ - before : 0;
        emit RootClaimed(token, gained);
    }

    /// @notice As `claimRoot`, restricted to one token's validator. Cheaper, and the right call
    ///         once the vault holds positions across several validators.
    function claimRootFor(address token)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotHalted
        nonReentrant
        onlyListed(token)
        returns (uint256 gained)
    {
        TokenConfig storage c = _configs[token];
        // Claim proceeds ALWAYS land on root (netuid 0) -- the runtime sells the basket and stakes
        // it there, and the destination is not a parameter. Measuring that against a subnet token's
        // ledger reads a netuid the proceeds never touched: `gained` would report 0 while real
        // root stake appeared that no token's backing represents. Root only.
        if (c.netuid != 0) revert NotRootToken(c.netuid);
        uint256 before = _stakedRao(c);
        STAKING.claimRootWithHotkey(c.validator);
        uint256 after_ = _stakedRao(c);
        gained = after_ > before ? after_ - before : 0;
        emit RootClaimed(token, gained);
    }

    // ------------------------------------------------------------------ migration

    /// @notice Announce a move of this vault's backing to `target`, starting the notice period.
    ///
    /// @dev Deposits close immediately (see `whenNotMigrating`); withdrawals stay open. That
    ///      asymmetry is the point — the window only ever drains.
    ///
    ///      `targetColdkey` is supplied rather than derived because the EVM has no blake2b
    ///      precompile and hand-rolling one for a single value is a poor trade. It is checked
    ///      against the target's own `vaultColdkey()` instead, which is exactly the mismatch that
    ///      produced a duplicate vault storing another vault's coldkey during the v3 deploy.
    function initiateMigration(address target, bytes32 targetColdkey)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (target == address(0) || targetColdkey == bytes32(0)) revert ZeroAddress();
        if (migrationFinished) revert MigrationAlreadyFinished();
        if (migrationReadyAt != 0) revert MigrationPending();
        if (IAlphaVault(target).vaultColdkey() != targetColdkey) revert ColdkeyMismatch();

        migrationTarget = target;
        migrationColdkey = targetColdkey;
        migrationReadyAt = block.timestamp + MIGRATION_DELAY;
        emit MigrationInitiated(target, targetColdkey, migrationReadyAt);
    }

    /// @notice Abandon an announced migration and reopen deposits.
    /// @dev Only while NOTHING has moved. Once any `executeMigration` has run, this vault has less
    ///      backing than its tokens claim, and reopening deposits would put a new depositor's stake
    ///      underneath a supply that already includes holders whose backing left — they could
    ///      withdraw against the newcomer's money. After the first move the only exit is
    ///      `finishMigration`.
    function cancelMigration() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (migrationReadyAt == 0) revert MigrationNotInitiated();
        if (migrationExecuted) revert MigrationIrreversible();
        address t = migrationTarget;
        migrationTarget = address(0);
        migrationColdkey = bytes32(0);
        migrationReadyAt = 0;
        emit MigrationCancelled(t);
    }

    /// @notice End the migration and retire this vault. Separate from `executeMigration` on
    ///         purpose: that moves ONE token, and a vault listing several needs to move each of
    ///         them before anything is finalised.
    ///
    /// @dev Deliberately does NOT verify that every listed token has been moved. Which positions
    ///      are worth moving is an operator judgement — a dust position may not be worth the gas,
    ///      and a token may have been drained to zero by withdrawals — and a completeness check
    ///      would turn that judgement into a revert. `MigrationExecuted` per token plus this event
    ///      is the record of what was actually moved.
    ///
    ///      Retirement is PERMANENT and deposits never reopen. That is not tidiness, it is the
    ///      safety property: backing has left, but the migrated tokens' supply has not. If
    ///      deposits reopened, a new depositor's stake would sit under a token whose totalSupply
    ///      still counts stranded holders — and those holders could withdraw against the newcomer's
    ///      money. `cancelMigration` reopens deposits because nothing has moved yet; once anything
    ///      has, there is no way back and this makes that explicit.
    function finishMigration() external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Same two gates as executeMigration, because this is at least as destructive: it retires
        // the vault permanently and halts every route. Without them, initiateMigration ->
        // finishMigration in one block bricks a live vault with no notice served and nothing
        // moved -- the seven-day exit window skipped entirely.
        _requireMigrationReady();
        // And something must actually have moved. A migration where nothing was executed is an
        // abandoned one, and `cancelMigration` is the route for that -- it reopens deposits
        // instead of sealing the vault shut.
        if (!migrationExecuted) revert NothingMigrated();
        address t = migrationTarget;
        migrationFinished = true;
        migrationTarget = address(0);
        migrationColdkey = bytes32(0);
        migrationReadyAt = 0;

        // Halt every value route, indefinitely. Backing has moved but supply has not, so leaving
        // withdrawals open would let whoever is quickest drain whatever positions were NOT
        // migrated — first-come-first-served over other holders' backing. Stopping everything is
        // the honest state for a vault that can no longer honour its own tokens.
        //
        // Set rather than added to, and deliberately liftable: OPERATOR `unpause`/`adminHold` can
        // reopen it, which is the escape hatch if a listed token still has real backing that its
        // holders need to exit. A halt nobody can lift would be a second, worse, stranding.
        pausedUntil = type(uint256).max;
        emit Halted(msg.sender, pausedUntil);

        emit MigrationFinished(t);
    }

    /// @notice Move a token's whole staked position to the migration target's coldkey.
    ///
    /// @dev Executes REGARDLESS of outstanding supply. Whoever has not exited by now keeps tokens
    ///      that this vault can no longer honour: `withdrawLiquid`/`withdrawStaked` revert
    ///      `Insolvent` for them permanently, and nothing here gives them a second chance.
    ///
    ///      The protection is the NOTICE WINDOW, not a supply check. `initiateMigration` freezes
    ///      deposits immediately, so for seven days nobody can enter and the position can only
    ///      shrink. Withdrawals are not guaranteed to stay open across that window — OPERATOR may
    ///      halt them with `adminHold`, and the intent is that holders move with the backing
    ///      rather than exit here. Migrating is a deliberate, announced, admin-only act.
    ///
    ///      Earlier designs gated this on a supply cap and on a longer second delay. Both were
    ///      removed: a cap that can be raised and a delay that can be waited out are not
    ///      guarantees, and pretending otherwise made the real protection — the exit window —
    ///      look like a formality. This states the bargain plainly instead.
    ///
    ///      Same-netuid `transferStake` is fee-free and has no AMM leg, so this is not a round trip
    ///      through the pool. It can still credit 1 RAO less when it opens a new position.
    function executeMigration(address token)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        onlyListed(token)
        returns (uint256 alphaRao)
    {
        _requireMigrationReady();
        migrationExecuted = true;
        alphaRao = _move(token);
    }

    function _requireMigrationReady() private view {
        if (migrationReadyAt == 0) revert MigrationNotInitiated();
        if (block.timestamp < migrationReadyAt) revert MigrationNotReady();
    }

    function _move(address token) private returns (uint256 alphaRao) {
        TokenConfig storage c = _configs[token];
        alphaRao = _stakedRao(c);
        if (alphaRao == 0) revert ZeroAmount();
        STAKING.transferStake(migrationColdkey, c.validator, c.netuid, c.netuid, alphaRao);
        emit MigrationExecuted(token, migrationTarget, alphaRao);
    }

    // ------------------------------------------------------------------ config

    /// @notice Reroutes ALL tokens' emissions — the slow/root tier.
    function setEmissionsRecipient(address r) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (r == address(0)) revert ZeroAddress();
        emissionsRecipient = r;
        emit EmissionsRecipientChanged(r);
    }

    /// @notice Repoints `AlphaToken.getCCIPAdmin()` — the slow/root tier, because this decides who
    ///         may register future tokens with CCIP and thereby take `setPool` over them.
    /// @dev    Only affects tokens registered AFTER this call. TokenAdminRegistry snapshots the
    ///         administrator at registration and never re-reads getCCIPAdmin, so every ALREADY
    ///         registered token keeps its current administrator until governance walks it over with
    ///         `transferAdminRole(token, newAdmin)` + `acceptAdminRole(token)` per token, per chain.
    function setCcipAdmin(address a) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (a == address(0)) revert ZeroAddress();
        ccipAdmin = a;
        emit CcipAdminChanged(a);
    }

    function setSkimMargin(address token, uint256 marginRao)
        external
        onlyRole(OPERATOR_ROLE)
        onlyListed(token)
    {
        _configs[token].skimMarginRao = marginRao;
        emit SkimMarginChanged(token, marginRao);
    }

    /// @notice Re-delegate the token's ENTIRE staked position to a new validator (same-netuid
    ///         moveStake: custody and amount unchanged). OPERATOR (instant) so a misbehaving
    ///         validator can be exited fast; custody never leaves the vault coldkey.
    function migrateValidator(address token, bytes32 newValidator)
        external
        onlyRole(OPERATOR_ROLE)
        onlyListed(token)
    {
        if (newValidator == bytes32(0)) revert ZeroValidator();
        TokenConfig storage c = _configs[token];

        // No collision check needed: this token is the only one on its netuid, so whatever validator
        // it moves to, the (validator, netuid) position it lands on cannot belong to another token.
        bytes32 old = c.validator;
        uint256 amt = STAKING.getStake(old, vaultColdkey, c.netuid); // read under OLD hotkey
        if (amt > 0) {
            STAKING.moveStake(old, newValidator, c.netuid, c.netuid, amt);
        }
        c.validator = newValidator;
        emit ValidatorChanged(token, old, newValidator, amt);
    }
}
