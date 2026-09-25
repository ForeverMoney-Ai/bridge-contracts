// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StakeProbe — exercises the 0x805 staking primitives against the LIVE 964 runtime.
///
/// @notice Not a unit test and not forkable. The staking precompile is native runtime code, not
///         EVM bytecode: `eth_getCode` at 0x805 returns nothing, so a Foundry fork has nothing to
///         execute and every call reverts. Anything mocked here would only prove the mock matches
///         itself. The primitives can therefore only be checked by transacting on 964.
///
/// @dev Each primitive is its OWN external call, deliberately. A single "run everything" function
///      would stop at the first revert and tell us nothing about the calls after it — and the whole
///      question is *which* of these work. Every mutator reports the getStake delta it caused,
///      because the precompile returns nothing and the delta is the only honest evidence.
///
///      Funding: V2 takes the amount as an argument and does NOT read msg.value; TAO is debited
///      from the CALLER's mapped coldkey. So this contract must hold native TAO, and the coldkey
///      being debited is blake2b_256("evm:" + address(this)) — its own, not the deployer's.
interface IStaking {
    function addStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;
    function removeStake(bytes32 hotkey, uint256 amount, uint256 netuid) external payable;
    function moveStake(
        bytes32 originHotkey,
        bytes32 destinationHotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amount
    ) external payable;
    function transferStake(
        bytes32 destinationColdkey,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amount
    ) external payable;
    function transferStakeFrom(
        address sourceAddress,
        address destinationAddress,
        bytes32 hotkey,
        uint256 originNetuid,
        uint256 destinationNetuid,
        uint256 amount
    ) external;
    function approve(address spenderAddress, uint256 netuid, uint256 absoluteAmount) external;
    function allowance(address sourceAddress, address spenderAddress, uint256 netuid)
        external view returns (uint256);
    function getStake(bytes32 hotkey, bytes32 coldkey, uint256 netuid)
        external view returns (uint256);
}

contract StakeProbe {
    IStaking constant S = IStaking(0x0000000000000000000000000000000000000805);

    address public immutable owner;

    /// @param what   which primitive ran
    /// @param before staked RAO on (hotkey, thisColdkey, netuid) before
    /// @param aft    the same, after
    /// @param delta  signed change — negative means stake LEFT this coldkey, which is the whole
    ///               point for transferStake and moveStake
    event Probe(string what, uint256 before, uint256 aft, int256 delta);

    error NotOwner();

    constructor() payable {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable {}

    function stakeOf(bytes32 hotkey, bytes32 coldkey, uint256 netuid)
        external view returns (uint256)
    {
        return S.getStake(hotkey, coldkey, netuid);
    }

    function _report(string memory what, bytes32 hotkey, bytes32 ck, uint256 netuid, uint256 before)
        private
    {
        uint256 aft = S.getStake(hotkey, ck, netuid);
        emit Probe(what, before, aft, int256(aft) - int256(before));
    }

    /// Baseline: does staking work at all from a contract's own mapped coldkey?
    function probeAddStake(bytes32 hotkey, uint256 netuid, uint256 rao, bytes32 selfColdkey)
        external onlyOwner
    {
        uint256 before = S.getStake(hotkey, selfColdkey, netuid);
        S.addStake(hotkey, rao, netuid);
        _report("addStake", hotkey, selfColdkey, netuid, before);
    }

    /// Same-netuid transfer to another coldkey. Used by withdrawStaked and by migration.
    function probeTransferStake(
        bytes32 destColdkey,
        bytes32 hotkey,
        uint256 netuid,
        uint256 rao,
        bytes32 selfColdkey
    ) external onlyOwner {
        uint256 before = S.getStake(hotkey, selfColdkey, netuid);
        S.transferStake(destColdkey, hotkey, netuid, netuid, rao);
        _report("transferStake", hotkey, selfColdkey, netuid, before);
    }

    /// Validator migration: same netuid, different hotkey. Backs migrateValidator.
    function probeMoveStake(
        bytes32 fromHotkey,
        bytes32 toHotkey,
        uint256 netuid,
        uint256 rao,
        bytes32 selfColdkey
    ) external onlyOwner {
        uint256 before = S.getStake(fromHotkey, selfColdkey, netuid);
        S.moveStake(fromHotkey, toHotkey, netuid, netuid, rao);
        _report("moveStake(origin)", fromHotkey, selfColdkey, netuid, before);
    }

    /// Delegated pull. Backs depositStaked, where the VAULT pulls a user's existing stake.
    function probeApprove(address spender, uint256 netuid, uint256 rao) external onlyOwner {
        S.approve(spender, netuid, rao);
    }

    function allowanceOf(address src, address spender, uint256 netuid)
        external view returns (uint256)
    {
        return S.allowance(src, spender, netuid);
    }

    /// Called BY the spender, pulling from `src`. Deployed as a second probe so the caller is a
    /// different account than the source, which is the case depositStaked actually needs.
    function probeTransferStakeFrom(
        address src,
        address dst,
        bytes32 hotkey,
        uint256 netuid,
        uint256 rao,
        bytes32 srcColdkey
    ) external onlyOwner {
        uint256 before = S.getStake(hotkey, srcColdkey, netuid);
        S.transferStakeFrom(src, dst, hotkey, netuid, netuid, rao);
        _report("transferStakeFrom(src)", hotkey, srcColdkey, netuid, before);
    }

    /// Unstake, so the probe's TAO can be recovered.
    function probeRemoveStake(bytes32 hotkey, uint256 netuid, uint256 rao, bytes32 selfColdkey)
        external onlyOwner
    {
        uint256 before = S.getStake(hotkey, selfColdkey, netuid);
        S.removeStake(hotkey, rao, netuid);
        _report("removeStake", hotkey, selfColdkey, netuid, before);
    }

    function sweep(address payable to) external onlyOwner {
        (bool ok, ) = to.call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }
}

/* ---------------------------------------------------------------------------------------------
   RESULTS — mainnet 964, 2026-08-17. Probes 0xA025e923... and 0x051712BB..., root validator
   0x40c47b6a..., second validator 0x84d83d08..., all on netuid 0. Total cost 0.024 TAO.

     addStake            5e7 asked -> 5e7 staked                       EXACT
     transferStake       2e7 sent  -> 19,999,999 credited              -1 RAO
     transferStakeFrom   1e7 sent  -> 1e7 credited                     EXACT
     moveStake           1e7 moved -> 1e7 arrived on the new hotkey    EXACT
     removeStake         unstaked and swept back                       OK

   The single lost RAO is on POSITION CREATION, not per transfer: transferStake opened probe2's
   position from zero and lost one; transferStakeFrom then added to that same position and lost
   nothing. Share-pool initialisation rounding.

   The sender is debited the full amount either way, so this is invisible from the vault's own
   accounting — which is exactly why it needed measuring rather than assuming.

   Not reproducible under `forge test`: 0x805 is native runtime code, so eth_getCode returns
   nothing and a fork has nothing to execute. This file is run by transacting, not by the runner.
--------------------------------------------------------------------------------------------- */
