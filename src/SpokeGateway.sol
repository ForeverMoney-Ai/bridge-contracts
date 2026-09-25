// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {ExitPayload} from "./ExitPayload.sol";
import {IntegratorFee} from "./IntegratorFee.sol";

/// @title SpokeGateway
/// @notice SHARED one-transaction UX for a SPOKE chain — the return leg toward Bittensor. The
///         topology is hub-and-spoke: the hub is Subtensor EVM (964), where AlphaVault custodies
///         every staked position and AlphaGateway sends/receives; each spoke (Base today, others as
///         governance allows lanes) runs ONE of these, serving every listed asset (TAO, SN_X…).
///         Nothing here is Base-specific — the chain's CCIP router and the hub gateway address are
///         constructor arguments.
///         Pulls the given token from the user, burns it via CCIP, and delivers the position to the
///         user's Finney SS58 coldkey on the other side (through AlphaGateway's `ccipReceive`).
///
/// @dev  Holds no funds at rest. Immutable, no owner. The token rides in the CCIP tokenAmounts; the
///       destination SS58/fallback/liquidity-preference travel in the message payload. Tokens are
///       caller-supplied and unvalidated: an unsupported token simply has no CCIP pool, so
///       `ccipSend` reverts and the whole tx unwinds — nothing to steal from a stateless gateway.
contract SpokeGateway {
    address public immutable ROUTER;
    uint64 public immutable BITTENSOR_SELECTOR;
    address public immutable SUBTENSOR_GATEWAY; // the ONE shared receiver on 964

    /// @notice Who may change the fee, and where the fee goes. BOTH IMMUTABLE, on purpose.
    /// @dev This contract was deliberately ownerless. A settable fee needs an authority, so the
    ///      smallest possible concession is made: the authority and the destination are fixed at
    ///      construction and only the NUMBER moves. Nobody can transfer control of this contract,
    ///      redirect the proceeds, or reach the bridged tokens — the worst a compromised FEE_ADMIN
    ///      can do is set the markup to its capped maximum and make bridging expensive, which is
    ///      visible, reversible on redeploy, and steals nothing.
    address public immutable FEE_ADMIN;

    /// @notice Where the markup goes. Seeded at construction and repointable by FEE_ADMIN.
    /// @dev This was immutable, on the argument that a fixed destination meant a compromised admin
    ///      could not redirect proceeds. It is settable now by request, so that argument no longer
    ///      holds: FEE_ADMIN can send future fee income anywhere. What it still cannot do is reach
    ///      the bridged tokens or the caller's refund — only the markup, and only going forward.
    address public feeRecipient;

    /// @notice Markup on the CCIP fee, in basis points. 0 = disabled, which is the deployed default.
    uint16 public bridgeFeeBps;
    uint16 public constant MAX_BRIDGE_FEE_BPS = 5_000; // 50% ceiling; a bound, not a policy

    event BridgeFeeChanged(uint16 bps);
    event FeeRecipientChanged(address indexed to);
    event BridgeFeeCollected(address indexed to, uint256 amount);

    error NotFeeAdmin();
    error BridgeFeeTooHigh(uint16 bps, uint16 max);
    error FeeTransferFailed();

    /// @notice Hard ceiling on the per-call integrator fee (a cut of the bridged token); FEE_ADMIN
    ///         sets `maxIntegratorFeeBps` anywhere up to it.
    uint16 public constant MAX_INTEGRATOR_FEE_BPS = 1_000; // 10%
    uint16 public constant DEFAULT_MAX_INTEGRATOR_FEE_BPS = 100; // 1%
    uint16 public maxIntegratorFeeBps;

    event MaxIntegratorFeeChanged(uint16 bps);
    event IntegratorFeeCollected(address indexed token, address indexed recipient, uint256 amount);

    error IntegratorFeeTooHigh(uint16 bps, uint16 max);
    error ZeroIntegrator();
    error IntegratorFeeTransferFailed();

    /// @notice Default destination-execution gas budget for `handleExit` on 964. Sized for today's
    ///         exit logic; callers may override per-message via the 6-arg `bridgeToFinney` (passing 0
    ///         keeps this default). Too low -> the delivery fails on 964 and is recovered via a
    ///         claimable booking or CCIP manual re-execution (a deep OOG can starve even the catch's
    ///         booking, in which case ccipReceive reverts and the message is manually re-executable
    ///         with more gas); too high -> rejected or just costs more fee (excess refunded). Either
    ///         way an override can never lose funds.
    uint256 public constant DEFAULT_EXIT_GAS_LIMIT = 300_000;

    /// @param amount the amount that CROSSES. An integrator cut is charged on top (see `IntegratorFeeCollected`).
    event BridgedToFinney(
        address indexed token, address indexed sender, bytes32 indexed ss58, uint256 amount, bytes32 messageId
    );

    error ZeroAmount();
    error ZeroAddress();
    error ZeroSelector();
    error ZeroFallback();
    error InsufficientFee();
    error PullFailed();
    error RefundFailed();

    event Initialized(address indexed router, uint64 indexed hubSelector, address indexed hubGateway);

    constructor(
        address router,
        uint64 bittensorSelector,
        address subtensorGateway,
        address feeAdmin,
        address feeRecipient_
    ) {
        if (router == address(0) || subtensorGateway == address(0)) revert ZeroAddress();
        if (feeAdmin == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        FEE_ADMIN = feeAdmin;
        feeRecipient = feeRecipient_;
        if (bittensorSelector == 0) revert ZeroSelector();  // a uint64 selector, not an address
        ROUTER = router;
        BITTENSOR_SELECTOR = bittensorSelector;
        SUBTENSOR_GATEWAY = subtensorGateway;
        maxIntegratorFeeBps = DEFAULT_MAX_INTEGRATOR_FEE_BPS;
        emit Initialized(router, bittensorSelector, subtensorGateway);
        emit MaxIntegratorFeeChanged(DEFAULT_MAX_INTEGRATOR_FEE_BPS);
    }

    /// @notice Cap the per-call integrator fee. FEE_ADMIN only. Zero disables integrator fees.
    function setMaxIntegratorFeeBps(uint16 bps) external {
        if (msg.sender != FEE_ADMIN) revert NotFeeAdmin();
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

    /// @dev The integrator fee is ON TOP: `bps` of `amount`, pulled from the caller in addition to
    ///      the amount that crosses. The bridged amount is never reduced.
    function _integratorCut(uint256 amount, IntegratorFee memory fee) private pure returns (uint256) {
        return (amount * fee.bps) / 10_000;
    }

    function _payIntegrator(address token, uint256 cut, IntegratorFee memory fee) private {
        if (cut == 0) return;
        if (!IERC20(token).transfer(fee.recipient, cut)) revert IntegratorFeeTransferFailed();
        emit IntegratorFeeCollected(token, fee.recipient, cut);
    }

    /// @notice Set the markup charged on top of the CCIP fee. FEE_ADMIN only.
    function setBridgeFeeBps(uint16 bps) external {
        if (msg.sender != FEE_ADMIN) revert NotFeeAdmin();
        if (bps > MAX_BRIDGE_FEE_BPS) revert BridgeFeeTooHigh(bps, MAX_BRIDGE_FEE_BPS);
        bridgeFeeBps = bps;
        emit BridgeFeeChanged(bps);
    }

    /// @notice Point fee income at a different address. FEE_ADMIN only.
    /// @dev Zero is rejected rather than treated as a default: this gateway has no vault to fall
    ///      back to, so a zero recipient would burn the markup on every bridge.
    function setFeeRecipient(address to) external {
        if (msg.sender != FEE_ADMIN) revert NotFeeAdmin();
        if (to == address(0)) revert ZeroAddress();
        feeRecipient = to;
        emit FeeRecipientChanged(to);
    }

    /// @dev What a caller must actually send: router fee plus markup. Quoted rather than the bare
    ///      CCIP fee, so nobody is told one number and charged another.
    function _grossFee(uint256 ccipFee) private view returns (uint256) {
        return ccipFee + (ccipFee * bridgeFeeBps) / 10_000;
    }

    /// @notice Quote the CCIP fee (in native ETH) for bridging `amount` of `token` to Finney (default gas).
    function quoteBridgeToFinney(address token, uint256 amount, ExitPayload.Params calldata exit)
        external
        view
        returns (uint256 fee)
    {
        return quoteBridgeToFinney(token, amount, exit, 0);
    }

    /// @notice Quote the CCIP fee with an explicit destination-execution `gasLimit` (0 = default).
    function quoteBridgeToFinney(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit
    ) public view returns (uint256 fee) {
        (fee,,) = _quote(token, amount, exit, gasLimit, IntegratorFee(address(0), 0));
    }

    /// @notice Quote with an integrator fee: the native fee to send, the token cut the integrator
    ///         takes (pulled on top), and the amount that crosses (the full `amount`).
    /// @dev    A distinct name rather than an overload: ethers cannot disambiguate an overload whose
    ///         extra argument is a struct when an overrides object is passed.
    function quoteBridgeToFinneyWithFee(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit,
        IntegratorFee calldata integrator
    ) external view returns (uint256 fee, uint256 cut, uint256 net) {
        return _quote(token, amount, exit, gasLimit, integrator);
    }

    function _quote(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit,
        IntegratorFee memory integrator
    ) private view returns (uint256 fee, uint256 cut, uint256 net) {
        // Reject exactly what execution rejects, so a quote can never succeed for a bridge that would revert.
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();
        if (exit.evmFallback == address(0)) revert ZeroFallback();
        _validateIntegratorFee(integrator);
        cut = _integratorCut(amount, integrator);      // paid on top by the caller
        net = amount;                                    // crosses in full
        fee = _grossFee(IRouterClient(ROUTER).getFee(BITTENSOR_SELECTOR, _message(token, net, exit, _gas(gasLimit))));
    }

    /// @notice Bridge `amount` of `token` back to Finney.
    /// @param exit  where and how it lands: destination coldkey, EVM fallback, staked-vs-liquid, and
    ///              the slippage bound for a liquid unwrap. See `ExitPayload.Params`.
    /// @dev   Caller must `approve` this contract for `amount` first; msg.value must cover the fee.
    function bridgeToFinney(address token, uint256 amount, ExitPayload.Params calldata exit)
        external
        payable
        returns (bytes32 messageId)
    {
        return bridgeToFinney(token, amount, exit, 0);
    }

    /// @notice Bridge with an explicit destination-execution `gasLimit` for `handleExit` on 964.
    /// @param gasLimit  gas budget on the destination. Pass 0 to use DEFAULT_EXIT_GAS_LIMIT.
    function bridgeToFinney(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit
    ) public payable returns (bytes32 messageId) {
        return _bridge(token, amount, exit, gasLimit, IntegratorFee(address(0), 0));
    }

    /// @notice Bridge with an integrator fee ON TOP: `amount + amount * bps / 10_000` is pulled from
    ///         the caller, the cut goes to `integrator.recipient` on this chain, `amount` crosses in
    ///         full. Whoever prepares the tx sets it; FEE_ADMIN only caps it. Distinct name, see
    ///         `quoteBridgeToFinneyWithFee`.
    function bridgeToFinneyWithFee(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit,
        IntegratorFee calldata integrator
    ) external payable returns (bytes32 messageId) {
        return _bridge(token, amount, exit, gasLimit, integrator);
    }

    function _bridge(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit,
        IntegratorFee memory integrator
    ) private returns (bytes32 messageId) {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();
        if (exit.evmFallback == address(0)) revert ZeroFallback(); // must never enter the system zero
        _validateIntegratorFee(integrator);

        uint256 cut = _integratorCut(amount, integrator);
        // pull the amount AND the integrator's cut on top; the full amount crosses
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount + cut)) revert PullFailed();
        _payIntegrator(token, cut, integrator);
        IERC20(token).approve(ROUTER, amount);

        Client.EVM2AnyMessage memory message = _message(token, amount, exit, _gas(gasLimit));
        uint256 fee = IRouterClient(ROUTER).getFee(BITTENSOR_SELECTOR, message);
        uint256 gross = _grossFee(fee);
        if (msg.value < gross) revert InsufficientFee();

        messageId = IRouterClient(ROUTER).ccipSend{value: fee}(BITTENSOR_SELECTOR, message);
        emit BridgedToFinney(token, msg.sender, exit.ss58, amount, messageId);
        _settle(gross, fee);
    }

    /// @dev Pay the markup, then refund the caller the excess over `gross`.
    function _settle(uint256 gross, uint256 fee) private {
        // Settled before the refund: the refund calls msg.sender, and paying our own obligation
        // first means a caller that reverts on receive cannot strand the fee in this contract.
        uint256 markup = gross - fee;
        if (markup > 0) {
            // Cached: `feeRecipient` is storage, and the call below hands control to it. A
            // recipient that also holds FEE_ADMIN could repoint itself inside receive(), and a
            // second read would then log an address that was never paid. The transfer would still
            // be correct — it is the RECORD that would lie, which is worse, because fee
            // reconciliation is done from these events and nothing on chain would contradict it.
            address to = feeRecipient;
            (bool feeOk, ) = to.call{value: markup}("");
            if (!feeOk) revert FeeTransferFailed();
            emit BridgeFeeCollected(to, markup);
        }

        uint256 refund = msg.value - gross;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev Resolve a caller-supplied gas limit: 0 means "use the default".
    function _gas(uint256 gasLimit) private pure returns (uint256) {
        return gasLimit == 0 ? DEFAULT_EXIT_GAS_LIMIT : gasLimit;
    }

    function _message(
        address token,
        uint256 amount,
        ExitPayload.Params calldata exit,
        uint256 gasLimit
    ) private view returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokens = new Client.EVMTokenAmount[](1);
        tokens[0] = Client.EVMTokenAmount({token: token, amount: amount});
        return Client.EVM2AnyMessage({
            receiver: abi.encode(SUBTENSOR_GATEWAY),
            data: ExitPayload.encode(exit),
            tokenAmounts: tokens,
            feeToken: address(0), // native ETH
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            )
        });
    }
}
