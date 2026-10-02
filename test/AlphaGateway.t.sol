// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {AlphaVault} from "../src/AlphaVault.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {AlphaGateway} from "../src/AlphaGateway.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockStakingP} from "./mocks/MockStakingP.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockExit} from "./mocks/MockExit.sol";
import {ExitPayload} from "../src/ExitPayload.sol";

/// A token whose transfer returns false (never reverts).
contract FalseReturnToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// A token whose transfer reverts.
contract RevertingToken {
    function transfer(address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// A token that re-enters the gateway from inside the delivery transfer.
contract ReenteringToken {
    AlphaGateway public gw;
    bool public reentered;
    bool public innerOk;

    function arm(AlphaGateway g) external {
        gw = g;
    }

    function transfer(address to, uint256) external returns (bool) {
        if (!reentered) {
            reentered = true;
            // try to pull a claim for ourselves under our own namespace — nothing is booked, so
            // this must revert; the point is that it cannot touch anyone else's balance.
            try gw.claimToken(address(this), to) {
                innerOk = true;
            } catch {}
        }
        return true;
    }
}

contract AlphaGatewayTest is Test {
    event DeliveredToken(address indexed token, address indexed to, uint256 amount);

    MockStakingP staking;
    AlphaVault vault;
    AlphaToken wtao; // netuid 0, VAL
    MockRouter router;
    AlphaGateway gw;

    bytes32 constant VAL = bytes32(uint256(0x5A11));
    bytes32 constant VAL2 = bytes32(uint256(0xB0B2));
    uint64 constant BASE_SEL = 111;
    address recipient = makeAddr("recipient");
    address rescuer = makeAddr("rescuer");
    address user = makeAddr("user");
    address owner = address(this);
    bytes32 constant DEST_SS58 = bytes32(uint256(0xC01D));
    address constant EXIT = 0x0000000000000000000000000000000000000800;

    uint256 constant RAO = 1e9;
    uint256 constant FEE = 0.001 ether;

    function setUp() public {
        staking = new MockStakingP();
        bytes32 ck = staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vault = new AlphaVault(IStaking(address(staking)), ck, recipient, owner);
        wtao = new AlphaToken(address(vault), "TAO", "TAO");
        vault.grantRole(vault.OPERATOR_ROLE(), owner); // listing is OPERATOR-gated
        vault.addToken(address(wtao), VAL, 0);
        router = new MockRouter(FEE);
        gw = new AlphaGateway(address(router), address(vault), BASE_SEL, rescuer,
            staking.ck(vm.computeCreateAddress(address(this), vm.getNonce(address(this)))));
        vm.etch(EXIT, type(MockExit).runtimeCode);
        vm.deal(user, 100 ether);
        vm.deal(owner, 100 ether);
    }

    receive() external payable {}

    /// second token on the SAME vault/gateway: netuid 8 on VAL2
    function _mkSubnet() internal returns (AlphaToken t) {
        t = new AlphaToken(address(vault), "Subnet 8", "SN8");
        vault.addToken(address(t), VAL2, 8);
    }

    // ---- give the gateway `amount` wSN, backed by real stake (as a return leg would) ----
    function _fundGatewayWithWSN(uint256 taoAmount) internal returns (uint256 minted) {
        minted = vault.depositLiquid{value: taoAmount}(address(wtao), 0); // mints to owner
        wtao.transfer(address(gw), minted);
    }

    /// Book `amt` of wTAO claimable to `user` the way production now does it: a halted vault.
    function _bookToUser(uint256 amt) internal {
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.guardianPause(1 days);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));
        vault.unpause();
        assertEq(gw.claimableToken(address(wtao), user), amt);
    }

    function _msg(address token, uint256 amount, bytes memory data)
        internal
        pure
        returns (Client.Any2EVMMessage memory)
    {
        Client.EVMTokenAmount[] memory toks = new Client.EVMTokenAmount[](1);
        toks[0] = Client.EVMTokenAmount({token: token, amount: amount});
        return Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: BASE_SEL,
            sender: abi.encode(address(0xBEEF)),
            data: data,
            destTokenAmounts: toks
        });
    }

    // -------------------------------------------------- Finney -> Base

    function test_bridgeToBase_liquid_stakesAndSends() public {
        vm.prank(user);
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(wtao), recipient, 1 ether, 0, 0.99e18);
        assertEq(vault.stakedValueRao(address(wtao)), 1e9); // backing staked in the vault
        assertEq(wtao.totalSupply(), 1 ether); // 1 wSN minted (root 1:1)
        assertEq(wtao.balanceOf(address(gw)), 0); // pulled by the router (pool lock)
        assertEq(wtao.balanceOf(address(router)), 1 ether);
    }

    // -------- staked-input outbound: pull the caller's existing alpha and bridge it --------
    function test_bridgeToBase_stakedInput() public {
        staking.seed(VAL, user, 0, 3e9); // user holds 3 alpha, staked to the token's validator
        vm.startPrank(user);
        staking.approve(address(gw), 0, 3e9); // approve THE GATEWAY (not the vault) to pull it
        gw.bridgeOut{value: FEE}(BASE_SEL, address(wtao), recipient, 0, 3e9, 3e18);
        vm.stopPrank();
        assertEq(vault.stakedValueRao(address(wtao)), 3e9); // pulled into the vault
        assertEq(wtao.totalSupply(), 3 ether); // 3 wSN, zero slippage
        assertEq(wtao.balanceOf(address(router)), 3 ether); // bridged
        assertEq(staking.getStake(VAL, staking.ck(user), 0), 0); // left the user
    }

    // -------- BOTH liquid + staked in ONE tx --------
    function test_bridgeToBase_combinedLiquidAndStaked() public {
        staking.seed(VAL, user, 0, 2e9); // 2 alpha staked
        vm.startPrank(user);
        staking.approve(address(gw), 0, 2e9);
        // 1 TAO fresh (liquid) + 2 alpha staked -> 3 wSN total, one CCIP message
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(wtao), recipient, 1 ether, 2e9, 3e18);
        vm.stopPrank();
        assertEq(wtao.totalSupply(), 3 ether); // 1 (liquid) + 2 (staked)
        assertEq(vault.stakedValueRao(address(wtao)), 3e9);
        assertEq(wtao.balanceOf(address(router)), 3 ether);
    }

    // -------- bridge wSN the caller already holds --------
    function test_bridgeToken_existingWSN() public {
        uint256 amt = vault.depositLiquid{value: 2 ether}(address(wtao), 0); // owner mints directly
        wtao.transfer(user, amt);
        vm.startPrank(user);
        wtao.approve(address(gw), amt);
        gw.bridgeTokenOut{value: FEE}(BASE_SEL, address(wtao), recipient, amt);
        vm.stopPrank();
        assertEq(wtao.balanceOf(address(router)), amt); // bridged
        assertEq(wtao.balanceOf(user), 0);
    }

    // -------- ONE gateway serves multiple tokens --------
    function test_sharedGateway_bridgesTwoTokens() public {
        AlphaToken w8 = _mkSubnet();
        vm.startPrank(user);
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(wtao), recipient, 1 ether, 0, 0);
        gw.bridgeOut{value: 2 ether + FEE}(BASE_SEL, address(w8), recipient, 2 ether, 0, 0);
        vm.stopPrank();
        assertEq(wtao.balanceOf(address(router)), 1 ether);
        assertEq(w8.balanceOf(address(router)), 2 ether);
        assertEq(vault.stakedValueRao(address(wtao)), 1e9);
        assertEq(vault.stakedValueRao(address(w8)), 2e9);
    }

    function test_bridgeToBase_unlistedTokenReverts() public {
        AlphaToken t = new AlphaToken(address(vault), "x", "x"); // not listed
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.UnsupportedToken.selector, address(t)));
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(t), recipient, 1 ether, 0, 0);
    }

    function test_bridgeToBase_refundsExcess() public {
        uint256 before = user.balance;
        vm.prank(user);
        gw.bridgeOut{value: 1 ether + FEE + 0.5 ether}(BASE_SEL, address(wtao), recipient, 1 ether, 0, 0);
        // spent exactly 1 (staked) + FEE; 0.5 refunded
        assertEq(before - user.balance, 1 ether + FEE);
    }

    function test_bridgeToBase_slippageReverts() public {
        staking.setFee(100); // 1% -> 0.99 wSN minted
        vm.prank(user);
        vm.expectRevert(AlphaGateway.Slippage.selector);
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(wtao), recipient, 1 ether, 0, 1e18);
    }

    function test_bridgeToBase_nonWholeRaoReverts() public {
        vm.prank(user);
        vm.expectRevert(AlphaGateway.AmountNotWholeRAO.selector);
        gw.bridgeOut{value: 2 ether}(BASE_SEL, address(wtao), recipient, 1 ether + 1, 0, 0);
    }

    // -------------------------------------------------- Base -> Finney (staked delivery)

    function test_handleExit_deliversStakedToColdkey() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0})); // wantLiquid = false
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));

        assertEq(wtao.balanceOf(address(gw)), 0); // wSN burned
        assertEq(wtao.totalSupply(), 0);
        assertEq(staking.getStake(VAL, DEST_SS58, 0), 1e9); // staked alpha delivered to coldkey
    }

    // -------------------------------------------------- Base -> Finney (liquid delivery)

    function test_handleExit_deliversLiquidViaPrecompile() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: true, minTaoOut: 0})); // wantLiquid = true
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));

        assertEq(wtao.totalSupply(), 0);
        assertEq(MockExit(EXIT).lastValue(), 1 ether); // native exited to substrate via 0x800
        assertEq(MockExit(EXIT).lastSS58(), DEST_SS58);
    }

    // -------------------------------------------------- never-revert fallback

    // a truly malformed payload (undecodable) can't yield an evmFallback, so it books to the rescuer
    function test_ccipReceive_neverReverts_malformedBooksClaimable() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        bytes memory data = hex"00"; // too short to decode (bytes32,address,bool) -> outer catch
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data)); // must NOT revert

        assertEq(gw.claimableToken(address(wtao), rescuer), amt); // booked to rescuer
        assertEq(wtao.balanceOf(address(gw)), amt); // wSN retained (nothing burned)
    }

    // a HOSTILE/unlisted token arriving via CCIP is contained: booked claimable under ITS OWN
    // namespace (to the message's fallback; rescuer if none) — never touches listed tokens'
    // claimables or the vault.
    function test_ccipReceive_hostileToken_contained() public {
        address hostile = address(0xDEAD); // arbitrary token address, no vault listing
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(hostile, 1 ether, data)); // must NOT revert

        assertEq(gw.claimableToken(hostile, user), 1 ether); // namespaced by the hostile token
        assertEq(gw.claimableToken(address(wtao), rescuer), 0); // wtao accounting untouched
        assertEq(gw.claimableToken(address(wtao), user), 0);

        // no-fallback variant falls to the rescuer, still hostile-namespaced
        bytes memory noFallback = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: address(0), wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(hostile, 1 ether, noFallback));
        assertEq(gw.claimableToken(hostile, rescuer), 1 ether);
    }

    // -------------------------------------------------- Base -> Finney (push-to-EVM delivery)

    // no coldkey + not liquid = hand the wrapped ERC20 itself to the EVM fallback, dust included,
    // with nothing booked and nothing left on the gateway.
    function test_handleExit_noColdkey_pushesTokenToFallback() public {
        uint256 minted = vault.depositLiquid{value: 2 ether}(address(wtao), 0); // mints to owner
        uint256 amt = 1 ether + 123; // 123 wei of dust rides along
        wtao.transfer(address(gw), amt);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.expectEmit(true, true, false, true, address(gw));
        emit DeliveredToken(address(wtao), user, amt);
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));

        assertEq(wtao.balanceOf(user), amt, "full amount incl. dust delivered");
        assertEq(wtao.balanceOf(address(gw)), 0);
        assertEq(gw.claimableToken(address(wtao), user), 0, "nothing booked");
        assertEq(gw.claimableToken(address(wtao), rescuer), 0);
        assertEq(wtao.totalSupply(), minted, "no burn: the token itself was delivered");
    }

    // the push never touches the vault, so it works while the vault is halted
    function test_handleExit_pushWorksDuringHalt() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.guardianPause(1 days);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));
        assertEq(wtao.balanceOf(user), amt);
        assertEq(gw.claimableToken(address(wtao), user), 0);
    }

    // a token whose transfer returns false is booked claimable to the same fallback
    function test_handleExit_pushFalseReturnBooksClaimable() public {
        address t = address(new FalseReturnToken());
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(t, 1 ether + 5, data));
        assertEq(gw.claimableToken(t, user), 1 ether + 5, "full amount booked, dust included");
    }

    // a token whose transfer reverts is booked claimable to the same fallback
    function test_handleExit_pushRevertBooksClaimable() public {
        address t = address(new RevertingToken());
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(t, 1 ether, data));
        assertEq(gw.claimableToken(t, user), 1 ether);
    }

    // a token that re-enters from inside the push cannot reach anyone else's balance
    function test_handleExit_pushReentrancyContained() public {
        uint256 legit = _fundGatewayWithWSN(1 ether);
        _bookToUser(legit); // a real wTAO liability exists on the gateway
        ReenteringToken rt = new ReenteringToken();
        rt.arm(gw);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(rt), 1 ether, data));
        assertTrue(rt.reentered());
        assertFalse(rt.innerOk(), "nested claim had nothing to take");
        assertEq(gw.claimableToken(address(wtao), user), legit, "wTAO liability untouched");
        assertEq(wtao.balanceOf(address(gw)), legit);
    }

    // a hand-crafted message with no fallback pushes to the rescuer, never to address(0)
    function test_handleExit_pushZeroFallbackGoesToRescuer() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: address(0), wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));
        assertEq(wtao.balanceOf(rescuer), amt);
    }

    // the push path is cheap: it must stay well inside the spoke's 300k destination gas budget
    function test_handleExit_pushGasPin() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        Client.Any2EVMMessage memory m = _msg(address(wtao), amt, data);
        vm.prank(address(router));
        uint256 g = gasleft();
        gw.ccipReceive(m);
        assertLt(g - gasleft(), 150_000, "push delivery gas");
    }

    // the selectors the bots and Roles scopes pin must never move
    function test_selectorsArePinned() public pure {
        assertEq(bytes4(keccak256("bridgeOut(uint64,address,address,uint256,uint256,uint256)")), bytes4(0x46101418));
        assertEq(bytes4(keccak256("bridgeTokenOut(uint64,address,address,uint256)")), bytes4(0x71385e91));
        assertEq(bytes4(keccak256("quoteBridgeOut(uint64,address,address,uint256)")), bytes4(0x7b0f0879));
    }

    // THE CROSS-TOKEN SUBSTITUTION ATTACK (report's Critical): deliver token B to the gateway with a
    // payload that books a claim, then try to redeem it as token A. Claims are namespaced per token,
    // so the attacker can only ever claim back the token they actually sent.
    function test_crossTokenSubstitution_cannotClaimAnotherToken() public {
        AlphaToken w8 = _mkSubnet(); // the "other subnet" token
        // gateway holds 1 wTAO backing a legitimate pending claim
        uint256 legit = _fundGatewayWithWSN(1 ether);
        assertEq(wtao.balanceOf(address(gw)), legit);

        // attacker delivers w8 with the push payload (ss58=0, staked exit); the gateway holds
        // the 5 w8 that the pool released, as it would on a real arrival
        address attacker = makeAddr("attacker");
        uint256 got = vault.depositLiquid{value: 5 ether}(address(w8), 0);
        w8.transfer(address(gw), got);
        bytes memory data =
            ExitPayload.encode(ExitPayload.Params({ss58: bytes32(0), evmFallback: attacker, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(w8), got, data));

        // w8 is pushed under ITS OWN namespace — no wTAO claim was created, no wTAO moved
        assertEq(w8.balanceOf(attacker), got);
        assertEq(gw.claimableToken(address(wtao), attacker), 0);

        // claiming wTAO reverts (nothing booked); the legitimate wTAO backing is untouched
        vm.prank(attacker);
        vm.expectRevert(AlphaGateway.NothingToClaim.selector);
        gw.claimToken(address(wtao), user);
        assertEq(wtao.balanceOf(address(gw)), legit);
    }

    // a multi-token message is NOT delivered (one payload can't describe N destinations) — every
    // token is booked claimable to the sender's fallback, so nothing is stranded and nothing is
    // guessed. Only constructible by calling the router directly; SpokeGateway always sends one.
    function test_ccipReceive_multiTokenMessage_bookedNotDelivered() public {
        AlphaToken w8 = _mkSubnet();
        uint256 held = _fundGatewayWithWSN(1 ether); // real wTAO backing in the gateway
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0})); // a VALID delivery payload
        Client.EVMTokenAmount[] memory toks = new Client.EVMTokenAmount[](2);
        toks[0] = Client.EVMTokenAmount({token: address(wtao), amount: held});
        toks[1] = Client.EVMTokenAmount({token: address(w8), amount: 2 ether});
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: BASE_SEL,
            sender: abi.encode(address(0xBEEF)),
            data: data,
            destTokenAmounts: toks
        });
        vm.prank(address(router));
        gw.ccipReceive(m);

        assertEq(gw.claimableToken(address(wtao), user), held); // both booked to the user
        assertEq(gw.claimableToken(address(w8), user), 2 ether); // NOT stranded
        assertEq(staking.getStake(VAL, DEST_SS58, 0), 0); // payload NOT honoured for either token
        assertEq(wtao.balanceOf(address(gw)), held); // nothing burned
    }

    // a zero-token message is a no-op and never reverts
    function test_ccipReceive_noTokens_noop() public {
        Client.EVMTokenAmount[] memory none = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: BASE_SEL,
            sender: abi.encode(address(0xBEEF)),
            data: ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0})),
            destTokenAmounts: none
        });
        vm.prank(address(router));
        gw.ccipReceive(m); // must not revert
        assertEq(gw.claimableToken(address(wtao), user), 0);
    }

    // ---- multi-lane: governance adds a chain on the fly, via the VAULT's admin (no gateway key) ----

    function test_setLane_addsInboundAndOutbound() public {
        uint64 NEW_CHAIN = 999;
        assertFalse(gw.allowedLane(NEW_CHAIN));
        assertTrue(gw.allowedLane(BASE_SEL)); // bootstrapped at construction

        // only the vault's DEFAULT_ADMIN may add a lane
        vm.prank(user);
        vm.expectRevert(AlphaGateway.NotVaultAdmin.selector);
        gw.setLane(NEW_CHAIN, true);

        gw.setLane(NEW_CHAIN, true); // owner IS the vault's DEFAULT_ADMIN in this suite
        assertTrue(gw.allowedLane(NEW_CHAIN));

        // outbound to the new chain now works
        vm.prank(user);
        gw.bridgeOut{value: 1 ether + FEE}(NEW_CHAIN, address(wtao), recipient, 1 ether, 0, 0);
        assertEq(wtao.balanceOf(address(router)), 1 ether);

        // and an inbound delivery over it is honoured like Base
        uint256 amt = _fundGatewayWithWSN(1 ether);
        Client.Any2EVMMessage memory m = _msg(address(wtao), amt, ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0})));
        m.sourceChainSelector = NEW_CHAIN;
        vm.prank(address(router));
        gw.ccipReceive(m);
        assertEq(staking.getStake(VAL, DEST_SS58, 0), 1e9); // delivered, not booked
    }

    function test_outboundToUnallowedLaneReverts() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.LaneNotAllowed.selector, uint64(999)));
        gw.bridgeOut{value: 1 ether + FEE}(999, address(wtao), recipient, 1 ether, 0, 0);
    }

    // removing a lane stops honouring it, but in-flight arrivals stay recoverable (never trapped)
    function test_removeLane_inflightStillRecoverable() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        gw.setLane(BASE_SEL, false); // governance de-allows Base

        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data)); // must not revert

        assertEq(gw.claimableToken(address(wtao), user), amt); // booked to the user, recoverable
        assertEq(staking.getStake(VAL, DEST_SS58, 0), 0); // no longer honoured as a delivery
    }

    // a delivery from an unexpected source lane is booked (not processed) — to the USER's own
    // fallback when the payload carries one, so a lane misconfiguration costs them no custody.
    function test_ccipReceive_foreignLane_booksToUserFallback() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        Client.Any2EVMMessage memory m = _msg(address(wtao), amt, data);
        m.sourceChainSelector = BASE_SEL + 1; // not our lane
        vm.prank(address(router));
        gw.ccipReceive(m); // must not revert (source tokens already burned)

        assertEq(gw.claimableToken(address(wtao), user), amt); // user's own fallback
        assertEq(gw.claimableToken(address(wtao), rescuer), 0);
        assertEq(staking.getStake(VAL, DEST_SS58, 0), 0); // payload NOT honoured, no delivery
    }

    // ...but an undecodable payload on a foreign lane has nobody to credit -> rescuer
    function test_ccipReceive_foreignLane_malformedGoesToRescuer() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        Client.Any2EVMMessage memory m = _msg(address(wtao), amt, hex"00");
        m.sourceChainSelector = BASE_SEL + 1;
        vm.prank(address(router));
        gw.ccipReceive(m);
        assertEq(gw.claimableToken(address(wtao), rescuer), amt);
    }

    // a staked exit that fails INSIDE the vault (the position is short of the redemption) books to
    // the user's OWN fallback — not the rescuer — like every other recoverable delivery failure.
    function test_handleExit_stakeShort_booksToFallback() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        staking.shrink(VAL, staking.ck(address(vault)), 0, 1e9); // position now 0: exit must fail

        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0})); // valid coldkey, staked exit
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data)); // must NOT revert

        assertEq(gw.claimableToken(address(wtao), user), amt); // user's fallback, not rescuer
        assertEq(gw.claimableToken(address(wtao), rescuer), 0);
        assertEq(wtao.balanceOf(address(gw)), amt); // nothing burned (vault call reverted whole)
    }

    // a return-leg delivery while the vault is halted books the user's own claimable wSN — NOT the
    // rescuer's — so a governance pause never funnels in-flight user funds into rescuer custody.
    function test_handleExit_duringHalt_booksClaimableToUser() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.guardianPause(1 days); // full halt: withdrawals would revert

        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data)); // must not revert

        assertEq(gw.claimableToken(address(wtao), user), amt); // user's fallback, redeemable later
        assertEq(gw.claimableToken(address(wtao), rescuer), 0); // NOT the rescuer
        assertEq(wtao.balanceOf(address(gw)), amt); // wSN retained, nothing burned while halted
    }

    // during a halt, a return leg with no EVM fallback (evmFallback==0) must not strand funds at
    // address(0) — it falls back to the recoverable rescuer balance.
    function test_handleExit_duringHalt_zeroFallbackGoesToRescuer() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.guardianPause(1 days);

        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: address(0), wantLiquid: false, minTaoOut: 0})); // no EVM fallback
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));

        assertEq(gw.claimableToken(address(wtao), rescuer), amt); // recoverable, not stranded
        assertEq(gw.claimableToken(address(wtao), address(0)), 0);
    }

    // -------------------------------------------------- claims (as the unwrapped position)

    // a user with a stuck (halt-stranded) claimable balance can pull it as unwrapped STAKE, straight
    // to their coldkey, once the halt lifts — never having to touch wSN.
    function test_claimStaked_deliversUnwrappedToColdkey() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        vault.grantRole(vault.GUARDIAN_ROLE(), owner);
        vault.grantRole(vault.OPERATOR_ROLE(), owner); // to unpause later
        vault.guardianPause(1 days); // strand an inbound leg as claimable to `user`
        bytes memory data = ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}));
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data));
        assertEq(gw.claimableToken(address(wtao), user), amt);

        // still halted -> the unwrap claim reverts (safe, rolls back); user waits
        vm.prank(user);
        vm.expectRevert(); // AlphaVault.IsHalted via withdrawStaked
        gw.claimStaked(address(wtao), DEST_SS58, user);
        assertEq(gw.claimableToken(address(wtao), user), amt); // untouched by the reverted claim

        vault.unpause();
        vm.prank(user);
        gw.claimStaked(address(wtao), DEST_SS58, user); // now unwraps to staked alpha at the coldkey
        assertEq(gw.claimableToken(address(wtao), user), 0);
        assertEq(wtao.balanceOf(address(gw)), 0); // gateway's wSN burned
        assertEq(staking.getStake(VAL, DEST_SS58, 0), 1e9); // delivered as stake, zero slippage
    }

    // same, but claimed as native TAO to the caller
    function test_claimLiquid_deliversNative() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        _bookToUser(amt);

        uint256 before = user.balance;
        vm.prank(user);
        gw.claimLiquid(address(wtao), 0.99e18, user); // unwrap to native
        assertEq(gw.claimableToken(address(wtao), user), 0);
        assertEq(user.balance - before, 1 ether); // 1 wSN -> 1 TAO (root 1:1)
        assertEq(wtao.totalSupply(), 0);
    }

    function test_claimWSN() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        _bookToUser(amt);

        vm.prank(user);
        gw.claimToken(address(wtao), user);
        assertEq(wtao.balanceOf(user), amt);
        assertEq(gw.claimableToken(address(wtao), user), 0);
    }

    // ---- guards added from the TODO review ----

    // a liquid return leg now carries a slippage bound; missing it books claimable, never executes
    // the unwrap at a bad price (previously withdrawLiquid was called with minTaoOut = 0)
    function test_handleExit_liquidRespectsMinTaoOut() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        staking.setFee(100); // 1% -> ~0.99 TAO out, below the bound below
        bytes memory data = ExitPayload.encode(
            ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: true, minTaoOut: 1 ether})
        );
        vm.prank(address(router));
        gw.ccipReceive(_msg(address(wtao), amt, data)); // must not revert

        assertEq(gw.claimableToken(address(wtao), user), amt); // booked, not unwrapped at a bad price
        assertEq(MockExit(EXIT).lastValue(), 0); // nothing exited to substrate
    }

    // quoting must fail wherever execution would
    function test_quote_matchesExecution() public {
        AlphaToken t = new AlphaToken(address(vault), "x", "x"); // unlisted
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.UnsupportedToken.selector, address(t)));
        gw.quoteBridgeOut(BASE_SEL, address(t), recipient, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.LaneNotAllowed.selector, uint64(999)));
        gw.quoteBridgeOut(999, address(wtao), recipient, 1 ether);
        vm.expectRevert(AlphaGateway.ZeroRecipient.selector);
        gw.quoteBridgeOut(BASE_SEL, address(wtao), address(0), 1 ether);
        // getFee would happily price a zero-amount send that ccipSend rejects
        vm.expectRevert(AlphaGateway.ZeroAmount.selector);
        gw.quoteBridgeOut(BASE_SEL, address(wtao), recipient, 0);
        assertEq(gw.quoteBridgeOut(BASE_SEL, address(wtao), recipient, 1 ether), FEE); // valid route
    }

    // bridgeOut rejects unlisted tokens up front, before any value moves
    function test_bridgeOut_rejectsUnlistedToken() public {
        AlphaToken t = new AlphaToken(address(vault), "x", "x");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.UnsupportedToken.selector, address(t)));
        gw.bridgeOut{value: 1 ether + FEE}(BASE_SEL, address(t), recipient, 1 ether, 0, 0);
        // ...on the zero-amount path too, rather than falling through to ZeroAmount
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.UnsupportedToken.selector, address(t)));
        gw.bridgeOut{value: FEE}(BASE_SEL, address(t), recipient, 0, 0, 0);
    }

    // bridgeTokenOut pulls an arbitrary ERC20 by address — it must refuse unlisted tokens
    function test_bridgeTokenOut_rejectsUnlistedToken() public {
        AlphaToken t = new AlphaToken(address(vault), "x", "x");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AlphaGateway.UnsupportedToken.selector, address(t)));
        gw.bridgeTokenOut{value: FEE}(BASE_SEL, address(t), recipient, 1 ether);
    }

    // constructor arguments are validated with errors that describe what was actually wrong
    function test_constructorRejectsBadArgs() public {
        // a zero router is caught by the CCIPReceiver base before our body runs
        vm.expectRevert();
        new AlphaGateway(address(0), address(vault), BASE_SEL, rescuer, bytes32(uint256(1)));
        vm.expectRevert(AlphaGateway.ZeroAddress.selector);
        new AlphaGateway(address(router), address(0), BASE_SEL, rescuer, bytes32(uint256(1)));        // vault
        vm.expectRevert(AlphaGateway.ZeroAddress.selector);
        new AlphaGateway(address(router), address(vault), BASE_SEL, address(0), bytes32(uint256(1))); // rescuer
        vm.expectRevert(AlphaGateway.ZeroSelector.selector);
        new AlphaGateway(address(router), address(vault), 0, rescuer, bytes32(uint256(1)));           // not ZeroAddress
    }

    // claimStaked delivers to a coldkey — a zero one is rejected before the balance is touched
    function test_claimStaked_rejectsZeroColdkey() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        _bookToUser(amt);

        vm.prank(user);
        vm.expectRevert(AlphaGateway.ZeroColdkey.selector);
        gw.claimStaked(address(wtao), bytes32(0), user);
        assertEq(gw.claimableToken(address(wtao), user), amt); // balance untouched by the revert
    }

    // a claim can be directed elsewhere, so a booking to a contract that cannot receive is not stuck
    function test_claim_toAnotherReceiver() public {
        uint256 amt = _fundGatewayWithWSN(1 ether);
        _bookToUser(amt);

        address helper = makeAddr("helper");
        vm.prank(user);
        gw.claimToken(address(wtao), helper); // user owns the balance, helper receives it
        assertEq(wtao.balanceOf(helper), amt);
        assertEq(wtao.balanceOf(user), 0);

        vm.prank(user);
        vm.expectRevert(AlphaGateway.ZeroRecipient.selector);
        gw.claimToken(address(wtao), address(0));
    }

    function test_onlyRouterCanDeliver() public {
        vm.expectRevert();
        gw.ccipReceive(_msg(address(wtao), 1 ether, ExitPayload.encode(ExitPayload.Params({ss58: DEST_SS58, evmFallback: user, wantLiquid: false, minTaoOut: 0}))));
    }
}
