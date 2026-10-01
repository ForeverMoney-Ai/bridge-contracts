// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";

/// @notice Faithful mock of the 0x805 V2 staking precompile for tests.
///         - Stake ledger keyed by (hotkey, coldkey, netuid) — matches the chain, so multi-token
///           (multi-position) isolation is REAL in tests.
///         - RAO amounts, no msg.value; caller balance debited/credited implicitly via vm.deal
///           (matches the unified substrate/EVM balance verified on mainnet).
///         - addStake enforces a minimum; transfers are exact/zero-fee; addStake/removeStake apply
///           an optional AMM fee + price to model subnets.
contract MockStakingP {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // hotkey => coldkey => netuid => alpha RAO
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public alpha;
    // source => spender => netuid => alpha RAO
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allow;
    uint256 public priceRao = 1e9; // TAO per alpha, 1e9 = 1.0
    uint256 public feeBps = 0;
    uint256 public minStake = 2_000_000; // 0.002 TAO

    /// @notice Model the ALTERNATIVE runtime: credit the unstaker by an EVM value transfer (which
    ///         executes their receive()) instead of a direct substrate account mutation. Today's
    ///         chain does the latter; this lets tests prove the vault works EITHER way.
    bool public creditViaCall;

    function setCreditViaCall(bool v) external {
        creditViaCall = v;
    }

    function _credit(address to, uint256 amountWei) internal {
        if (creditViaCall) {
            vm.deal(address(this), address(this).balance + amountWei);
            (bool ok, ) = to.call{value: amountWei}("");
            require(ok, "credit rejected");
        } else {
            vm.deal(to, to.balance + amountWei); // direct substrate mutation: no EVM code runs
        }
    }

    function setPrice(uint256 p) external {
        priceRao = p;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function ck(address a) public pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function addStake(bytes32 hotkey, uint256 taoRao, uint256 netuid) external payable {
        hk = hotkey;
        require(taoRao >= minStake, "AmountTooLow");
        uint256 wei_ = taoRao * 1e9;
        require(msg.sender.balance >= wei_, "insufficient balance");
        vm.deal(msg.sender, msg.sender.balance - wei_);
        uint256 net = taoRao - (taoRao * feeBps) / 10_000;
        alpha[hotkey][ck(msg.sender)][netuid] += (net * 1e9) / priceRao;
    }

    function removeStake(bytes32 hotkey, uint256 alphaRao, uint256 netuid) external payable {
        bytes32 c = ck(msg.sender);
        require(alpha[hotkey][c][netuid] >= alphaRao, "insufficient alpha");
        alpha[hotkey][c][netuid] -= alphaRao;
        uint256 taoRao = (alphaRao * priceRao) / 1e9;
        uint256 net = taoRao - (taoRao * feeBps) / 10_000;
        _credit(msg.sender, net * 1e9);
    }

    function transferStake(
        bytes32 destColdkey,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destNetuid,
        uint256 alphaRao
    ) external payable {
        bytes32 c = ck(msg.sender);
        require(alpha[hotkey][c][originNetuid] >= alphaRao, "insufficient alpha");
        alpha[hotkey][c][originNetuid] -= alphaRao;
        alpha[hotkey][destColdkey][destNetuid] += alphaRao;
    }

    function transferStakeFrom(
        address src,
        address dst,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destNetuid,
        uint256 alphaRao
    ) external {
        require(allow[src][msg.sender][originNetuid] >= alphaRao, "allowance");
        allow[src][msg.sender][originNetuid] -= alphaRao;
        require(alpha[hotkey][ck(src)][originNetuid] >= alphaRao, "insufficient alpha");
        alpha[hotkey][ck(src)][originNetuid] -= alphaRao;
        alpha[hotkey][ck(dst)][destNetuid] += alphaRao;
    }

    function approve(address spender, uint256 netuid, uint256 amount) external {
        allow[msg.sender][spender][netuid] = amount;
    }

    function allowance(address src, address spender, uint256 netuid) external view returns (uint256) {
        return allow[src][spender][netuid];
    }

    function moveStake(
        bytes32 originHotkey,
        bytes32 destHotkey,
        uint256 originNetuid,
        uint256 destNetuid,
        uint256 alphaRao
    ) external payable {
        bytes32 c = ck(msg.sender);
        require(alpha[originHotkey][c][originNetuid] >= alphaRao, "insufficient alpha");
        alpha[originHotkey][c][originNetuid] -= alphaRao;
        alpha[destHotkey][c][destNetuid] += alphaRao;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid) external view returns (uint256) {
        return alpha[hotkey][coldkey][netuid];
    }

    /// Pending beta-basket entitlement, per (hotkey, coldkey, netuid). Set by tests; a claim moves
    /// it into stake, which is exactly what the runtime does — sells the basket share and stakes the
    /// proceeds on root under the same coldkey.
    mapping(bytes32 => mapping(bytes32 => mapping(uint256 => uint256))) public claimable;

    function setClaimable(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 amt) external {
        claimable[hotkey][coldkey][netuid] = amt;
    }

    function claimRoot(uint16[] calldata) external {
        _claim(hk, ck(msg.sender));
    }

    function claimRootWithHotkey(bytes32 hotkey) external {
        _claim(hotkey, ck(msg.sender));
    }

    /// Root only (netuid 0): baskets pay out as TAO staked on root, never as subnet alpha.
    function _claim(bytes32 hotkey, bytes32 coldkey) internal {
        uint256 amt = claimable[hotkey][coldkey][0];
        if (amt == 0) return;               // a claim with nothing owed is a no-op, not a revert
        claimable[hotkey][coldkey][0] = 0;
        alpha[hotkey][coldkey][0] += amt;
    }

    /// Last hotkey seen by addStake, so claimRoot(uint16[]) has something to credit in tests that
    /// only ever use one validator.
    bytes32 public hk;

    function getNominatorMinRequiredStake() external view returns (uint256) {
        return minStake;
    }

    function accrue(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 alphaRao) external {
        alpha[hotkey][coldkey][netuid] += alphaRao;
    }

    /// Shrink a position without the vault doing anything — models the position going short of
    /// supply from the chain's side (validator trouble, runtime change), which is the only way
    /// withdrawLiquid can now hit Insolvent.
    function shrink(bytes32 hotkey, bytes32 coldkey, uint256 netuid, uint256 alphaRao) external {
        alpha[hotkey][coldkey][netuid] -= alphaRao;
    }

    function seed(bytes32 hotkey, address who, uint256 netuid, uint256 alphaRao) external {
        alpha[hotkey][ck(who)][netuid] += alphaRao;
    }

    receive() external payable {}
}
