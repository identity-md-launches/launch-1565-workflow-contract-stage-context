// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MineHookSalt} from "../script/MineHookSalt.s.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {V4Actions} from "./helpers/V4Actions.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SwarmlerFeeHook} from "../src/SwarmlerFeeHook.sol";
import {SwarmlerHookDeployer} from "../src/SwarmlerHookDeployer.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HookTest is Fixture {
    LaunchToken internal token;
    PoolManager internal manager;
    V4Actions internal actions;
    SwarmlerHookDeployer internal deployer;
    SwarmlerFeeHook internal hook;
    PoolKey internal key;
    bytes32 internal salt;

    function setUp() public override {
        super.setUp();
        token = new LaunchToken();
        manager = new PoolManager(address(this));
        actions = new V4Actions(manager);
        deployer = new SwarmlerHookDeployer(address(this), address(nft), address(token));
        deployer.setPoolManager(address(manager));
        bytes memory code = type(SwarmlerFeeHook).creationCode;
        salt = _mine(address(deployer), deployer.initCodeHash(code));
        hook = SwarmlerFeeHook(deployer.deploy(code, salt));
        key = hook.poolKey();
        manager.initialize(key, 79228162514264337593543950336);
        imd.mint(address(this), 1_000_000 ether);
        token.approve(address(actions), 1_000_000 ether);
        imd.approve(address(actions), 1_000_000 ether);
        actions.modify(key, 100_000 ether);
    }

    function _mine(address d, bytes32 initHash) internal returns (bytes32 mined) {
        MineHookSalt miner = new MineHookSalt();
        (mined,) = miner.run(d, initHash, 0, 1_000_000);
    }

    function _swap(bool zeroForOne, bool exactInput) internal returns (BalanceDelta) {
        return actions.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                exactInput ? -int256(100 ether) : int256(100 ether),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    function test_realCreate2DeploymentPermissionsAndConstructorBindings() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x2503);
        assertEq(address(hook), deployer.predict(type(SwarmlerFeeHook).creationCode, salt));
        assertEq(hook.owner(), address(this));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.collection()), address(nft));
        assertEq(address(hook.launchToken()), address(token));
        assertEq(key.fee, 12500);
        assertEq(key.tickSpacing, 60);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterAddLiquidity && p.afterRemoveLiquidity);
        assertTrue(p.afterAddLiquidityReturnDelta && p.afterRemoveLiquidityReturnDelta);
        assertFalse(p.beforeSwap || p.afterSwap || p.beforeSwapReturnDelta || p.afterSwapReturnDelta);
    }

    function test_bothSwapDirectionsAndExactModesCollectActualFees() public {
        _swap(true, true);
        _swap(false, true);
        _swap(true, false);
        _swap(false, false);
        assertEq(imd.balanceOf(address(hook)), 0); // LP fees realize only when the position is touched.
        (BalanceDelta callerDelta, BalanceDelta fees) = actions.modify(key, 0);
        assertEq(BalanceDelta.unwrap(callerDelta), 0);
        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        uint256 expectedImd =
            uint128(Currency.unwrap(key.currency0) == address(imd) ? fees.amount0() : fees.amount1());
        uint256 expectedToken =
            uint128(Currency.unwrap(key.currency0) == address(token) ? fees.amount0() : fees.amount1());
        assertEq(imd.balanceOf(address(hook)), expectedImd);
        assertEq(token.balanceOf(address(hook)), expectedToken);
        uint256 proceedsBefore = nft.totalProceeds();
        vm.prank(alice);
        hook.forwardFees();
        assertEq(nft.totalProceeds() - proceedsBefore, expectedImd);
        assertEq(nft.creatorCredit(), expectedImd / 10);
        assertEq(nft.rewardReserve(), expectedImd - expectedImd / 10);
        assertEq(imd.allowance(address(hook), address(nft)), 0);
        _assertSolvent();
    }

    function test_addAndRemoveCaptureFeesButPreserveLPPrincipal() public {
        _swap(true, true);
        (, BalanceDelta firstFees) = actions.modify(key, 1 ether);
        assertGt(firstFees.amount0(), 0);
        _swap(false, true);
        uint256 imdBefore = imd.balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        (BalanceDelta principal, BalanceDelta secondFees) = actions.modify(key, -int256(100_001 ether));
        assertGt(secondFees.amount1(), 0);
        assertGt(principal.amount0(), 0);
        assertGt(principal.amount1(), 0);
        uint256 imdPrincipal = uint128(
            Currency.unwrap(key.currency0) == address(imd) ? principal.amount0() : principal.amount1()
        );
        uint256 tokenPrincipal = uint128(
            Currency.unwrap(key.currency0) == address(token) ? principal.amount0() : principal.amount1()
        );
        assertEq(imd.balanceOf(address(this)) - imdBefore, imdPrincipal);
        assertEq(token.balanceOf(address(this)) - tokenBefore, tokenPrincipal);
    }

    function test_donationsCannotCreateUnbackedRewards() public {
        actions.donate(key, 2 ether, 3 ether);
        (, BalanceDelta fees) = actions.modify(key, 0);
        assertApproxEqAbs(uint128(fees.amount0()), 2 ether, 1);
        assertApproxEqAbs(uint128(fees.amount1()), 3 ether, 1);
        hook.forwardFees();
        _assertSolvent();
    }

    function test_feesConvertForExactQuotedIMDAndSplitOnce() public {
        token.transfer(address(hook), 2 ether);
        vm.expectRevert(SwarmlerFeeHook.PriceNotConfigured.selector);
        hook.quoteFeeTokens(1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        hook.setFeeTokenPrice(1 ether);
        hook.setFeeTokenPrice(0.4 ether);
        vm.startPrank(alice);
        imd.approve(address(hook), 1 ether);
        vm.expectRevert(SwarmlerFeeHook.SlippageExceeded.selector);
        hook.buyFeeTokens(2 ether, 0.7 ether);
        uint256 balance = imd.balanceOf(alice);
        assertEq(hook.buyFeeTokens(2 ether, 0.8 ether), 0.8 ether);
        assertEq(balance - imd.balanceOf(alice), 0.8 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        hook.forwardFees();
        vm.stopPrank();
        assertEq(nft.rewardReserve(), 0.72 ether);
        assertEq(nft.creatorCredit(), 0.08 ether);
        vm.expectRevert(SwarmlerFeeHook.ZeroAmount.selector);
        hook.forwardFees();
        _assertSolvent();
    }

    function test_conversionRoundsUpAndRevertsAtomicallyOnInsufficientInventory() public {
        hook.setFeeTokenPrice(1);
        token.transfer(address(hook), 1);
        vm.startPrank(alice);
        imd.approve(address(hook), 2);
        assertEq(hook.buyFeeTokens(1, 1), 1);
        uint256 balance = imd.balanceOf(alice);
        vm.expectRevert();
        hook.buyFeeTokens(1, 1);
        assertEq(imd.balanceOf(alice), balance);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(hook)), 1);
    }

    function test_failedForwardKeepsFeesAndCanRetry() public {
        imd.transfer(address(hook), 1 ether);
        imd.setFailure(true);
        vm.expectRevert("IMD transfer failed");
        hook.forwardFees();
        assertEq(hook.totalImdForwarded(), 0);
        assertEq(imd.balanceOf(address(hook)), 1 ether);
        assertEq(imd.allowance(address(hook), address(nft)), 0);
        imd.setFailure(false);
        hook.forwardFees();
        assertEq(hook.totalImdForwarded(), 1 ether);
        _assertSolvent();
    }

    function test_forgedCallbacksWrongPoolsAndNegativeFeesRejected() public {
        IPoolManager.ModifyLiquidityParams memory params;
        vm.expectRevert(SwarmlerFeeHook.OnlyPoolManager.selector);
        hook.afterAddLiquidity(alice, key, params, BalanceDelta.wrap(0), toBalanceDelta(1, 1), "");
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert(SwarmlerFeeHook.WrongPool.selector);
        vm.prank(address(manager));
        hook.afterRemoveLiquidity(alice, wrong, params, BalanceDelta.wrap(0), toBalanceDelta(1, 1), "");
        vm.expectRevert(SwarmlerFeeHook.InvalidFeeDelta.selector);
        vm.prank(address(manager));
        hook.afterRemoveLiquidity(alice, key, params, BalanceDelta.wrap(0), toBalanceDelta(-1, 1), "");
        vm.expectRevert(SwarmlerFeeHook.OnlyOwnerMayInitialize.selector);
        vm.prank(address(manager));
        hook.beforeInitialize(alice, key, 79228162514264337593543950336);
        vm.expectRevert(SwarmlerFeeHook.UnsupportedHook.selector);
        IHooks(address(hook)).beforeDonate(alice, key, 1, 1, "");
    }

    function test_deployerUnconfiguredWrongCodeAndDuplicateDeployment() public {
        SwarmlerHookDeployer fresh = new SwarmlerHookDeployer(address(this), address(nft), address(token));
        vm.expectRevert(SwarmlerHookDeployer.PoolManagerNotConfigured.selector);
        fresh.deploy(type(SwarmlerFeeHook).creationCode, bytes32(0));
        vm.expectRevert(SwarmlerHookDeployer.InvalidConfiguration.selector);
        fresh.setPoolManager(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fresh.setPoolManager(address(manager));
        fresh.setPoolManager(address(manager));
        vm.expectRevert(SwarmlerHookDeployer.WrongCreationCode.selector);
        fresh.deploy(hex"1234", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fresh.deploy(type(SwarmlerFeeHook).creationCode, bytes32(0));
        vm.expectRevert(SwarmlerHookDeployer.AlreadyDeployed.selector);
        deployer.deploy(type(SwarmlerFeeHook).creationCode, salt);
        vm.expectRevert(SwarmlerHookDeployer.AlreadyDeployed.selector);
        deployer.setPoolManager(address(manager));
    }

    function test_wrongPermissionSaltFailsAndNoDeploymentIsRecorded() public {
        SwarmlerHookDeployer fresh = new SwarmlerHookDeployer(address(this), address(nft), address(token));
        fresh.setPoolManager(address(manager));
        bytes32 badSalt;
        if (uint160(fresh.predict(type(SwarmlerFeeHook).creationCode, badSalt)) & 0x3fff == 0x2503) {
            badSalt = bytes32(uint256(1));
        }
        vm.expectRevert(SwarmlerHookDeployer.DeploymentFailed.selector);
        fresh.deploy(type(SwarmlerFeeHook).creationCode, badSalt);
        assertEq(fresh.hook(), address(0));
    }
}
