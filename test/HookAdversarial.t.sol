// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {MineHookSalt} from "../script/MineHookSalt.s.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {SwarmlerFeeHook} from "src/SwarmlerFeeHook.sol";
import {SwarmlerHookDeployer} from "src/SwarmlerHookDeployer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {stdError} from "forge-std/StdError.sol";

contract HookAdversarialTest is HookFixture {
    function test_realPoolRoutesFeesWhenIMDIsCurrency0() public {
        _exerciseCurrencyOrder(true);
    }

    function test_realPoolRoutesFeesWhenIMDIsCurrency1() public {
        _exerciseCurrencyOrder(false);
    }

    function _exerciseCurrencyOrder(bool imdFirst) internal {
        // Deploy actual LaunchToken bytecode on the desired side of IMD. The
        // address is derived from CREATE2, never patched into a hook or pool.
        bytes memory code = type(LaunchToken).creationCode;
        bytes32 hash = keccak256(code);
        address selected;
        bytes32 salt;
        for (uint256 i; i < 1000; ++i) {
            salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
            if ((address(imd) < predicted) != imdFirst) continue;
            assembly ("memory-safe") { selected := create2(0, add(code, 32), mload(code), salt) }
            assertEq(selected, predicted);
            break;
        }
        assertNotEq(selected, address(0), "could not construct requested currency order");
        token = LaunchToken(selected);
        deployer = new SwarmlerHookDeployer(address(this), address(nft), selected, address(manager));
        hook = _deployHook(deployer);
        key = hook.poolKey();
        assertEq(Currency.unwrap(imdFirst ? key.currency0 : key.currency1), address(imd));
        manager.initialize(key, uint160(1 << 96));
        token.approve(address(actions), type(uint256).max);
        imd.approve(address(actions), type(uint256).max);
        actions.modify(key, 100_000 ether);
        actions.swap(key, IPoolManager.SwapParams(true, -int256(100 ether), TickMath.MIN_SQRT_PRICE + 1));
        actions.swap(key, IPoolManager.SwapParams(false, -int256(100 ether), TickMath.MAX_SQRT_PRICE - 1));
        (BalanceDelta principal,) = actions.modify(key, 0);
        assertEq(BalanceDelta.unwrap(principal), 0);
        uint256 imdFees = imd.balanceOf(address(hook));
        uint256 tokenFees = token.balanceOf(address(hook));
        assertApproxEqAbs(imdFees, 1.25 ether, 1);
        assertApproxEqAbs(tokenFees, 1.25 ether, 1);
        hook.setFeeTokenPrice(1 ether);
        vm.prank(alice);
        imd.approve(address(hook), tokenFees);
        vm.prank(alice);
        assertEq(hook.buyFeeTokens(tokenFees, tokenFees), tokenFees);
        assertEq(token.balanceOf(alice), tokenFees);
        assertEq(hook.forwardFees(), imdFees + tokenFees);
        assertEq(nft.creatorCredit(), (imdFees + tokenFees) / 10);
        _assertSolvent();
    }

    function _feeState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                imd.balanceOf(alice),
                imd.balanceOf(address(hook)),
                imd.balanceOf(address(nft)),
                token.balanceOf(alice),
                token.balanceOf(address(hook)),
                imd.allowance(alice, address(hook)),
                imd.allowance(address(hook), address(nft)),
                hook.totalImdForwarded(),
                nft.totalProceeds(),
                nft.rewardReserve(),
                nft.creatorCredit()
            )
        );
    }

    function _inventory() internal {
        token.transfer(address(hook), 2 ether);
        hook.setFeeTokenPrice(0.4 ether);
        vm.prank(alice);
        imd.approve(address(hook), 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteIsTheSmallestIntegerPaymentCoveringTheAsk(uint128 rawAmount, uint128 rawPrice)
        public
    {
        uint256 amount = bound(rawAmount, 1, type(uint128).max);
        uint256 price = bound(rawPrice, 1, type(uint128).max);
        hook.setFeeTokenPrice(price);
        uint256 quote = hook.quoteFeeTokens(amount);
        uint256 numerator = amount * price; // Both inputs are <= uint128.max.
        assertGt(quote, 0);
        assertGe(quote * 1 ether, numerator);
        assertLt((quote - 1) * 1 ether, numerator);
        assertLe(hook.quoteFeeTokens(amount - 1), quote);
    }

    function test_fullPrecisionQuoteAndUnrepresentableQuoteBoundary() public {
        hook.setFeeTokenPrice(type(uint256).max);
        assertEq(hook.quoteFeeTokens(1 ether), type(uint256).max);
        assertEq(hook.quoteFeeTokens(0), 0);
        vm.expectRevert(stdError.arithmeticError);
        hook.quoteFeeTokens(1 ether + 1);
        hook.setFeeTokenPrice(1);
        assertEq(hook.quoteFeeTokens(1), 1);
        assertEq(hook.quoteFeeTokens(1 ether - 1), 1);
        assertEq(hook.quoteFeeTokens(1 ether), 1);
        assertEq(hook.quoteFeeTokens(1 ether + 1), 2);
    }

    function test_zeroPriceZeroAmountAndUnsetPriceCannotSpendFunds() public {
        vm.expectRevert(SwarmlerFeeHook.ZeroAmount.selector);
        hook.setFeeTokenPrice(0);
        vm.expectRevert(SwarmlerFeeHook.ZeroAmount.selector);
        hook.buyFeeTokens(0, type(uint256).max);
        vm.expectRevert(SwarmlerFeeHook.PriceNotConfigured.selector);
        hook.buyFeeTokens(1, type(uint256).max);
        assertEq(hook.totalImdForwarded(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_priceChangeHonorsBuyersPreviouslyChosenMaximum() public {
        _inventory();
        uint256 maximum = hook.quoteFeeTokens(1 ether);
        hook.setFeeTokenPrice(0.8 ether);
        bytes32 beforeState = _feeState();
        vm.expectRevert(SwarmlerFeeHook.SlippageExceeded.selector);
        vm.prank(alice);
        hook.buyFeeTokens(1 ether, maximum);
        assertEq(_feeState(), beforeState);
        hook.setFeeTokenPrice(maximum);
        vm.prank(alice);
        assertEq(hook.buyFeeTokens(1 ether, maximum), maximum);
    }

    function test_insufficientAllowanceAndTaxedSaleAreAtomic() public {
        _inventory();
        vm.prank(alice);
        imd.approve(address(hook), 0.4 ether - 1);
        bytes32 beforeState = _feeState();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(hook), 0.4 ether - 1, 0.4 ether
            )
        );
        vm.prank(alice);
        hook.buyFeeTokens(1 ether, 0.4 ether);
        assertEq(_feeState(), beforeState);
        vm.prank(alice);
        imd.approve(address(hook), 0.4 ether);
        beforeState = _feeState();
        uint256 supply = imd.totalSupply();
        imd.setTax(true);
        vm.expectRevert(SwarmlerFeeHook.InexactPayment.selector);
        vm.prank(alice);
        hook.buyFeeTokens(1 ether, 0.4 ether);
        assertEq(_feeState(), beforeState);
        assertEq(imd.totalSupply(), supply);
        imd.setTax(false);
        vm.prank(alice);
        assertEq(hook.buyFeeTokens(1 ether, 0.4 ether), 0.4 ether);
    }

    function test_insufficientInventoryRestoresPaymentAndFiniteAllowance() public {
        _inventory();
        bytes32 beforeState = _feeState();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(hook), 2 ether, 2 ether + 1
            )
        );
        vm.prank(alice);
        hook.buyFeeTokens(2 ether + 1, 1 ether);
        assertEq(_feeState(), beforeState);
    }

    function test_crossFunctionReentrancyCannotForwardDuringSaleOrBuyDuringForward() public {
        _inventory();
        imd.setCallback(address(hook), abi.encodeCall(SwarmlerFeeHook.forwardFees, ()));
        vm.prank(alice);
        hook.buyFeeTokens(1 ether, 0.4 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(hook.totalImdForwarded(), 0);
        assertEq(imd.balanceOf(address(hook)), 0.4 ether);
        imd.setCallback(address(hook), abi.encodeCall(SwarmlerFeeHook.buyFeeTokens, (1, 1)));
        vm.prank(bob);
        assertEq(hook.forwardFees(), 0.4 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(token.balanceOf(address(hook)), 1 ether);
        assertEq(imd.allowance(address(hook), address(nft)), 0);
        assertEq(nft.totalProceeds(), 0.4 ether);
        _assertSolvent();
    }

    function test_taxedForwardRestoresCountersAllowancesAndFees() public {
        imd.transfer(address(hook), 1 ether);
        bytes32 beforeState = _feeState();
        imd.setTax(true);
        vm.expectRevert(Swarmlers.InexactPayment.selector);
        hook.forwardFees();
        assertEq(_feeState(), beforeState);
        imd.setTax(false);
        assertEq(hook.forwardFees(), 1 ether);
        _assertSolvent();
    }

    function test_missingCollectionCodeRejectsForwardWithoutApprovingIt() public {
        imd.transfer(address(hook), 1 ether);
        vm.etch(address(nft), hex"");
        vm.expectRevert(SwarmlerFeeHook.InvalidConfiguration.selector);
        hook.forwardFees();
        assertEq(imd.balanceOf(address(hook)), 1 ether);
        assertEq(hook.totalImdForwarded(), 0);
        assertEq(imd.allowance(address(hook), address(nft)), 0);
    }

    function test_collectionNotConfiguredLeavesForwardRetryable() public {
        Swarmlers fresh = new Swarmlers(address(this), address(activity));
        SwarmlerHookDeployer factory =
            new SwarmlerHookDeployer(address(this), address(fresh), address(token), address(manager));
        SwarmlerFeeHook freshHook = _deployHook(factory);
        imd.transfer(address(freshHook), 1 ether);
        vm.expectRevert(Swarmlers.RewardsNotConfigured.selector);
        freshHook.forwardFees();
        assertEq(freshHook.totalImdForwarded(), 0);
        assertEq(imd.balanceOf(address(freshHook)), 1 ether);
        assertEq(imd.allowance(address(freshHook), address(fresh)), 0);
        fresh.setRewardDuration(1 days);
        assertEq(freshHook.forwardFees(), 1 ether);
        assertEq(fresh.rewardReserve(), 0.9 ether);
        assertEq(fresh.creatorCredit(), 0.1 ether);
    }

    function test_allCallbacksRejectNonManagerEvenWithZeroFees() public {
        IPoolManager.ModifyLiquidityParams memory params;
        vm.expectRevert(SwarmlerFeeHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vm.expectRevert(SwarmlerFeeHook.OnlyPoolManager.selector);
        hook.afterAddLiquidity(alice, key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(SwarmlerFeeHook.OnlyPoolManager.selector);
        hook.afterRemoveLiquidity(alice, key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_everyPoolKeyFieldIsAuthenticatedByEveryCallback() public {
        IPoolManager.ModifyLiquidityParams memory params;
        for (uint256 field; field < 6; ++field) {
            PoolKey memory wrong = key;
            if (field == 0) wrong.currency0 = Currency.wrap(alice);
            if (field == 1) wrong.currency1 = Currency.wrap(bob);
            if (field == 2) wrong.fee = 3000;
            if (field == 3) wrong.tickSpacing = 1;
            if (field == 4) wrong.hooks = IHooks(alice);
            if (field == 5) (wrong.currency0, wrong.currency1) = (wrong.currency1, wrong.currency0);
            vm.startPrank(address(manager));
            vm.expectRevert(SwarmlerFeeHook.WrongPool.selector);
            hook.beforeInitialize(address(this), wrong, uint160(1 << 96));
            vm.expectRevert(SwarmlerFeeHook.WrongPool.selector);
            hook.afterAddLiquidity(alice, wrong, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
            vm.expectRevert(SwarmlerFeeHook.WrongPool.selector);
            hook.afterRemoveLiquidity(alice, wrong, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
            vm.stopPrank();
        }
    }

    function test_negativeFeeOnEitherSideIsRejectedBeforeTakingAnyTokens() public {
        IPoolManager.ModifyLiquidityParams memory params;
        BalanceDelta[3] memory deltas = [
            toBalanceDelta(-1, 0), toBalanceDelta(0, -1), toBalanceDelta(type(int128).min, type(int128).max)
        ];
        for (uint256 i; i < deltas.length; ++i) {
            vm.startPrank(address(manager));
            vm.expectRevert(SwarmlerFeeHook.InvalidFeeDelta.selector);
            hook.afterAddLiquidity(alice, key, params, BalanceDelta.wrap(0), deltas[i], "");
            vm.expectRevert(SwarmlerFeeHook.InvalidFeeDelta.selector);
            hook.afterRemoveLiquidity(alice, key, params, BalanceDelta.wrap(0), deltas[i], "");
            vm.stopPrank();
        }
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_deployerOwnerHandoffRebindsInitCodeAndChildOwnership() public {
        SwarmlerHookDeployer fresh =
            new SwarmlerHookDeployer(address(this), address(nft), address(token), address(manager));
        bytes memory code = type(SwarmlerFeeHook).creationCode;
        bytes32 priorHash = fresh.initCodeHash(code);
        fresh.transferOwnership(alice);
        assertEq(fresh.initCodeHash(code), priorHash);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fresh.deploy(code, bytes32(0));
        vm.prank(alice);
        fresh.acceptOwnership();
        bytes32 newHash = fresh.initCodeHash(code);
        assertNotEq(newHash, priorHash);
        assertEq(
            newHash,
            keccak256(
                abi.encodePacked(code, abi.encode(alice, address(manager), address(nft), address(token)))
            )
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.deploy(code, bytes32(0));
        (bytes32 salt, address expected) = new MineHookSalt().run(address(fresh), newHash, 0, 1_000_000);
        vm.prank(alice);
        address deployed = fresh.deploy(code, salt);
        assertEq(deployed, expected);
        assertEq(SwarmlerFeeHook(deployed).owner(), alice);
        assertEq(address(SwarmlerFeeHook(deployed).poolManager()), address(manager));
        // A later owner handoff cannot re-run the one-time deployment or rebind the child.
        vm.prank(alice);
        fresh.transferOwnership(bob);
        vm.prank(bob);
        fresh.acceptOwnership();
        vm.expectRevert(SwarmlerHookDeployer.AlreadyDeployed.selector);
        vm.prank(bob);
        fresh.deploy(code, salt);
        assertEq(fresh.hook(), deployed);
        assertEq(SwarmlerFeeHook(deployed).owner(), alice);
    }

    /// @dev The launch runs constructors on an empty chain, so the deployer must accept a PoolManager
    ///      address that has no code yet and bind to it immutably once code exists there. Both views and
    ///      the deployment refuse to run before that, and nothing can point the deployer elsewhere.
    function test_managerArgumentIsImmutableAndOnlyUsableOnceItHasCode() public {
        address futureManager = makeAddr("future pool manager");
        bytes memory code = type(SwarmlerFeeHook).creationCode;
        SwarmlerHookDeployer early =
            new SwarmlerHookDeployer(address(this), address(nft), address(token), futureManager);
        assertEq(early.poolManager(), futureManager);
        vm.expectRevert(SwarmlerHookDeployer.PoolManagerNotDeployed.selector);
        early.initCodeHash(code);
        vm.expectRevert(SwarmlerHookDeployer.PoolManagerNotDeployed.selector);
        early.predict(code, bytes32(0));
        vm.expectRevert(SwarmlerHookDeployer.PoolManagerNotDeployed.selector);
        early.deploy(code, bytes32(0));
        assertEq(early.hook(), address(0));
        // Ownership changes do not substitute for the missing manager.
        early.transferOwnership(alice);
        vm.prank(alice);
        early.acceptOwnership();
        vm.expectRevert(SwarmlerHookDeployer.PoolManagerNotDeployed.selector);
        vm.prank(alice);
        early.deploy(code, bytes32(0));
        // Once the chain has a manager at that address, the child binds to it and to nothing else.
        vm.etch(futureManager, address(manager).code);
        bytes32 hash = early.initCodeHash(code);
        assertEq(
            hash,
            keccak256(abi.encodePacked(code, abi.encode(alice, futureManager, address(nft), address(token))))
        );
        (bytes32 salt, address expected) = new MineHookSalt().run(address(early), hash, 0, 1_000_000);
        assertEq(early.predict(code, salt), expected);
        vm.prank(alice);
        SwarmlerFeeHook child = SwarmlerFeeHook(early.deploy(code, salt));
        assertEq(address(child), expected);
        assertEq(address(child.poolManager()), futureManager);
        assertEq(child.owner(), alice);
        PoolKey memory childKey = child.poolKey();
        assertEq(address(childKey.hooks), address(child));
        // The real manager in this test environment is a different contract and is refused by the child.
        vm.expectRevert(SwarmlerFeeHook.OnlyPoolManager.selector);
        vm.prank(address(manager));
        child.beforeInitialize(address(this), childKey, uint160(1 << 96));
        vm.prank(futureManager);
        child.beforeInitialize(alice, childKey, uint160(1 << 96));
    }

    /// @dev Different manager arguments must produce different child addresses: the manifest's manager
    ///      choice is attested through the init-code hash, not configurable afterwards.
    function test_managerArgumentChangesTheChildAddress() public {
        bytes memory code = type(SwarmlerFeeHook).creationCode;
        address other = makeAddr("other manager");
        vm.etch(other, address(manager).code);
        SwarmlerHookDeployer a =
            new SwarmlerHookDeployer(address(this), address(nft), address(token), address(manager));
        SwarmlerHookDeployer b = new SwarmlerHookDeployer(address(this), address(nft), address(token), other);
        assertNotEq(a.initCodeHash(code), b.initCodeHash(code));
        assertNotEq(a.predict(code, bytes32(0)), b.predict(code, bytes32(0)));
    }

    function test_hookAndDeployerCannotBeRenouncedAndOnlyOwnerChangesPrice() public {
        vm.expectRevert(SwarmlerFeeHook.InvalidConfiguration.selector);
        hook.renounceOwnership();
        vm.expectRevert(SwarmlerHookDeployer.InvalidConfiguration.selector);
        deployer.renounceOwnership();
        hook.transferOwnership(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        hook.setFeeTokenPrice(1);
        vm.prank(alice);
        hook.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setFeeTokenPrice(1);
        vm.prank(alice);
        hook.setFeeTokenPrice(1);
        assertEq(hook.feeTokenPrice(), 1);
    }
}
