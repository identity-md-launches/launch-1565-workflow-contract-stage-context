// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {MockIMD} from "./helpers/Fixture.sol";
import {V4Actions} from "./helpers/V4Actions.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {SwarmlerFeeHook} from "src/SwarmlerFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract FeeCustodyHandler is Test {
    SwarmlerFeeHook public immutable hook;
    Swarmlers public immutable nft;
    LaunchToken public immutable token;
    MockIMD public immutable imd;
    V4Actions public immutable actions;
    PoolKey internal key;
    address[3] public buyers;
    bool internal immutable imdIs0;
    uint256 public liquidity;
    uint256 public harvestedImd;
    uint256 public harvestedToken;
    uint256 public giftedImd;
    uint256 public giftedToken;
    uint256 public soldToken;
    uint256 public salesImd;
    uint256 public forwarded;
    uint256 public creatorEntitlement;
    uint256 public rewardsPaid;
    uint256 public creatorPaid;
    uint256 public swaps;
    uint256 public sales;
    uint256 public forwards;

    constructor(SwarmlerFeeHook h, V4Actions a, MockIMD i, address[3] memory accounts) {
        hook = h;
        nft = h.collection();
        token = LaunchToken(address(h.launchToken()));
        imd = i;
        actions = a;
        key = h.poolKey();
        imdIs0 = Currency.unwrap(key.currency0) == address(i);
        buyers = accounts;
        token.approve(address(a), type(uint256).max);
        i.approve(address(a), type(uint256).max);
    }

    function swap(uint96 raw, bool zeroForOne, bool exactInput) public {
        uint256 amount = bound(raw, 1, 10 ether);
        uint256 beforeImd = imd.balanceOf(address(hook));
        uint256 beforeToken = token.balanceOf(address(hook));
        BalanceDelta delta = actions.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        assertLe(delta.amount0() * int256(delta.amount1()), 0, "swap debited both currencies");
        assertEq(imd.balanceOf(address(hook)), beforeImd, "swap unexpectedly changed hook IMD");
        assertEq(token.balanceOf(address(hook)), beforeToken, "swap unexpectedly changed fee inventory");
        ++swaps;
    }

    function changeLiquidity(uint96 raw) public {
        uint256 next = bound(raw, 10_000 ether, 200_000 ether);
        _modify(int256(next) - int256(liquidity));
        liquidity = next;
    }

    function harvest() public {
        BalanceDelta delta = _modify(0);
        assertEq(BalanceDelta.unwrap(delta), 0, "fee poke moved LP principal");
    }

    function donateToPool(uint96 raw0, uint96 raw1) public {
        actions.donate(key, bound(raw0, 1, 1 ether), bound(raw1, 1, 1 ether));
    }

    function giftInventory(uint96 raw) public {
        uint256 amount = bound(raw, 1, 5 ether);
        token.transfer(address(hook), amount);
        giftedToken += amount;
    }

    function giftImd(uint96 raw) public {
        uint256 amount = bound(raw, 1, 5 ether);
        imd.transfer(address(hook), amount);
        giftedImd += amount;
    }

    function setPrice(uint96 raw) public {
        hook.setFeeTokenPrice(bound(raw, 1, 10 ether));
    }

    function buy(uint256 buyerSeed, uint96 raw, bool all) public {
        uint256 inventory = token.balanceOf(address(hook));
        if (inventory == 0) return;
        uint256 amount = all ? inventory : bound(raw, 1, inventory);
        address buyer = buyers[buyerSeed % 3];
        uint256 beforeImd = imd.balanceOf(buyer);
        uint256 beforeToken = token.balanceOf(buyer);
        uint256 quote = hook.quoteFeeTokens(amount);
        vm.prank(buyer);
        assertEq(hook.buyFeeTokens(amount, quote), quote);
        assertEq(beforeImd - imd.balanceOf(buyer), quote);
        assertEq(token.balanceOf(buyer) - beforeToken, amount);
        assertGt(quote, 0, "fee inventory was given away for free");
        soldToken += amount;
        salesImd += quote;
        ++sales;
    }

    function forward() public {
        uint256 amount = imd.balanceOf(address(hook));
        if (amount == 0) {
            vm.expectRevert(SwarmlerFeeHook.ZeroAmount.selector);
            hook.forwardFees();
            return;
        }
        uint256 beforeBalance = imd.balanceOf(address(nft));
        assertEq(hook.forwardFees(), amount);
        assertEq(imd.balanceOf(address(nft)) - beforeBalance, amount);
        forwarded += amount;
        creatorEntitlement += amount / 10;
        ++forwards;
    }

    function releaseRewards(uint32 rawTime, uint256 rawId) public {
        vm.warp(vm.getBlockTimestamp() + bound(rawTime, 0, 40 days));
        uint256 id = bound(rawId, 1, 25);
        uint256 amount = nft.claimable(id);
        if (amount == 0) return;
        uint256 beforeBalance = imd.balanceOf(nft.creator());
        vm.prank(nft.creator());
        assertEq(nft.claimReward(id), amount);
        assertEq(imd.balanceOf(nft.creator()) - beforeBalance, amount);
        rewardsPaid += amount;
    }

    function payCreator() public {
        uint256 amount = creatorEntitlement - creatorPaid;
        if (amount == 0) return;
        uint256 beforeBalance = imd.balanceOf(nft.creator());
        nft.withdrawCreator();
        assertEq(imd.balanceOf(nft.creator()) - beforeBalance, amount);
        creatorPaid += amount;
    }

    // Test teardown only: all LP principal can exit after every random sequence.
    function closePositionAndForward() external {
        _modify(-int256(liquidity));
        liquidity = 0;
        if (imd.balanceOf(address(hook)) != 0) forward();
        payCreator();
    }

    function _modify(int256 deltaLiquidity) internal returns (BalanceDelta principal) {
        uint256 hookImdBefore = imd.balanceOf(address(hook));
        uint256 hookTokenBefore = token.balanceOf(address(hook));
        uint256 lpImdBefore = imd.balanceOf(address(this));
        uint256 lpTokenBefore = token.balanceOf(address(this));
        BalanceDelta fees;
        (principal, fees) = actions.modify(key, deltaLiquidity);
        assertGe(fees.amount0(), 0);
        assertGe(fees.amount1(), 0);
        uint256 imdFee = uint128(imdIs0 ? fees.amount0() : fees.amount1());
        uint256 tokenFee = uint128(imdIs0 ? fees.amount1() : fees.amount0());
        assertEq(imd.balanceOf(address(hook)) - hookImdBefore, imdFee);
        assertEq(token.balanceOf(address(hook)) - hookTokenBefore, tokenFee);
        assertEq(
            int256(imd.balanceOf(address(this))) - int256(lpImdBefore),
            imdIs0 ? int256(principal.amount0()) : int256(principal.amount1())
        );
        assertEq(
            int256(token.balanceOf(address(this))) - int256(lpTokenBefore),
            imdIs0 ? int256(principal.amount1()) : int256(principal.amount0())
        );
        harvestedImd += imdFee;
        harvestedToken += tokenFee;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HookStatefulTest is HookFixture {
    FeeCustodyHandler internal handler;
    address[3] internal buyers;
    uint256 internal initialImdSupply;

    function setUp() public override {
        super.setUp();
        buyers = [alice, bob, makeAddr("fee buyer C")];
        for (uint256 i; i < 3; ++i) {
            _fund(buyers[i], 1_000_000 ether);
            vm.prank(buyers[i]);
            imd.approve(address(hook), type(uint256).max);
        }
        handler = new FeeCustodyHandler(hook, actions, imd, buyers);
        token.transfer(address(handler), 1_000_000 ether);
        imd.mint(address(handler), 1_000_000 ether);
        initialImdSupply = imd.totalSupply();
        hook.transferOwnership(address(handler));
        vm.prank(address(handler));
        hook.acceptOwnership();
        handler.setPrice(uint96(0.4 ether));
        handler.changeLiquidity(uint96(100_000 ether));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.changeLiquidity.selector;
        selectors[2] = handler.harvest.selector;
        selectors[3] = handler.donateToPool.selector;
        selectors[4] = handler.giftInventory.selector;
        selectors[5] = handler.giftImd.selector;
        selectors[6] = handler.setPrice.selector;
        selectors[7] = handler.buy.selector;
        selectors[8] = handler.forward.selector;
        selectors[9] = handler.releaseRewards.selector;
        selectors[10] = handler.payCreator.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeInventoryAndConvertedProceedsAreConserved() public view {
        assertEq(
            token.balanceOf(address(hook)) + handler.soldToken(),
            handler.harvestedToken() + handler.giftedToken()
        );
        assertEq(
            imd.balanceOf(address(hook)) + handler.forwarded(),
            handler.harvestedImd() + handler.giftedImd() + handler.salesImd()
        );
        assertEq(hook.totalImdForwarded(), handler.forwarded());
        assertEq(nft.totalProceeds(), handler.forwarded());
        assertEq(nft.creatorCredit() + handler.creatorPaid(), handler.creatorEntitlement());
        assertEq(nft.totalClaimed(), handler.rewardsPaid());
        assertEq(nft.totalCreatorPaid(), handler.creatorPaid());
        assertEq(imd.allowance(address(hook), address(nft)), 0, "forward left a live allowance");
        assertEq(imd.balanceOf(CREATOR), handler.rewardsPaid() + handler.creatorPaid());
        _assertSolvent();
    }

    function invariant_bothTokenSuppliesRemainInTrackedCustody() public view {
        address[9] memory accounts = [
            address(this),
            address(handler),
            address(hook),
            address(manager),
            address(nft),
            CREATOR,
            buyers[0],
            buyers[1],
            buyers[2]
        ];
        uint256 tokenSum;
        uint256 imdSum;
        for (uint256 i; i < accounts.length; ++i) {
            tokenSum += token.balanceOf(accounts[i]);
            imdSum += imd.balanceOf(accounts[i]);
        }
        assertEq(tokenSum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(imdSum, initialImdSupply);
        assertEq(imd.totalSupply(), initialImdSupply);
        assertEq(imd.balanceOf(address(actions)), 0);
        assertEq(token.balanceOf(address(actions)), 0);
    }

    function afterInvariant() public {
        handler.closePositionAndForward();
        invariant_feeInventoryAndConvertedProceedsAreConserved();
        invariant_bothTokenSuppliesRemainInTrackedCustody();
        assertEq(handler.liquidity(), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_handlerReachesBothFeeAssetsSalesForwardingAndPayouts() public {
        handler.swap(uint96(10 ether), true, true);
        handler.swap(uint96(10 ether), false, false);
        handler.donateToPool(uint96(1 ether), uint96(1 ether));
        handler.harvest();
        assertGt(handler.harvestedImd(), 0);
        assertGt(handler.harvestedToken(), 0);
        handler.giftInventory(11);
        handler.giftImd(11);
        handler.setPrice(uint96(0.5 ether));
        handler.buy(1, 0, true);
        handler.forward();
        handler.releaseRewards(31 days, 1);
        handler.payCreator();
        assertGt(handler.sales(), 0);
        assertGt(handler.forwards(), 0);
        assertGt(handler.rewardsPaid(), 0);
        afterInvariant();
    }
}
