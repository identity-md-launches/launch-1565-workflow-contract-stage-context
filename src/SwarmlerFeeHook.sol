// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Swarmlers} from "./Swarmlers.sol";
import {SwarmlerConstants} from "./SwarmlerConstants.sol";

/// @notice Routes realized LP fees from one compatible v4 pool, without adding a swap surcharge.
/// @dev Not attachable to the policy-created launch pool. LPs in this separate pool surrender their fees.
contract SwarmlerFeeHook is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint160 public constant PERMISSION_MASK = 0x2503;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    IPoolManager public immutable poolManager;
    Swarmlers public immutable collection;
    IERC20 public immutable launchToken;
    IERC20 public constant imd = IERC20(SwarmlerConstants.IMD);
    uint256 public feeTokenPrice;
    uint256 public totalImdForwarded;

    error InvalidConfiguration();
    error OnlyPoolManager();
    error WrongPool();
    error OnlyOwnerMayInitialize();
    error InvalidFeeDelta();
    error PriceNotConfigured();
    error SlippageExceeded();
    error ZeroAmount();
    error InexactPayment();
    error UnsupportedHook();

    event FeesCollected(uint256 imdAmount, uint256 launchTokenAmount);
    event FeeTokenPriceSet(uint256 imdPerToken);
    event FeeTokensSold(address indexed buyer, uint256 tokenAmount, uint256 imdAmount);
    event FeesForwarded(uint256 imdAmount);

    constructor(address initialOwner, address manager, address nftCollection, address token)
        Ownable(initialOwner)
    {
        if (
            manager == address(0) || nftCollection == address(0) || token == address(0)
                || token == address(imd) || uint160(address(this)) & 0x3fff != PERMISSION_MASK
        ) revert InvalidConfiguration();
        poolManager = IPoolManager(manager);
        collection = Swarmlers(nftCollection);
        launchToken = IERC20(token);
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.afterAddLiquidityReturnDelta = true;
        p.afterRemoveLiquidityReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory key) {
        (address a, address b) = address(launchToken) < address(imd)
            ? (address(launchToken), address(imd))
            : (address(imd), address(launchToken));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), POOL_FEE, TICK_SPACING, IHooks(address(this)));
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        if (sender != owner()) revert OnlyOwnerMayInitialize();
        return IHooks.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external onlyManager nonReentrant returns (bytes4, BalanceDelta) {
        _collect(key, feesAccrued);
        return (IHooks.afterAddLiquidity.selector, feesAccrued);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) external onlyManager nonReentrant returns (bytes4, BalanceDelta) {
        _collect(key, feesAccrued);
        return (IHooks.afterRemoveLiquidity.selector, feesAccrued);
    }

    /// @notice Configure an explicit ask in IMD per 1e18 launch-token units. No spot-price oracle is used.
    /// @dev Owner is trusted to quote fairly; buyers can enforce their maximum payment.
    function setFeeTokenPrice(uint256 imdPerToken) external onlyOwner {
        if (imdPerToken == 0) revert ZeroAmount();
        feeTokenPrice = imdPerToken;
        emit FeeTokenPriceSet(imdPerToken);
    }

    function quoteFeeTokens(uint256 amount) public view returns (uint256) {
        if (feeTokenPrice == 0) revert PriceNotConfigured();
        return Math.mulDiv(amount, feeTokenPrice, 1 ether, Math.Rounding.Ceil);
    }

    /// @notice Convert held token-side fees into actual IMD via a public fixed-price sale.
    function buyFeeTokens(uint256 amount, uint256 maxImd) external nonReentrant returns (uint256 cost) {
        if (amount == 0) revert ZeroAmount();
        cost = quoteFeeTokens(amount);
        if (cost > maxImd) revert SlippageExceeded();
        uint256 beforeBalance = imd.balanceOf(address(this));
        imd.safeTransferFrom(msg.sender, address(this), cost);
        if (imd.balanceOf(address(this)) - beforeBalance != cost) revert InexactPayment();
        launchToken.safeTransfer(msg.sender, amount);
        emit FeeTokensSold(msg.sender, amount, cost);
    }

    /// @notice Permissionless, outside PoolManager callbacks; collection splits actual IMD 90/10.
    function forwardFees() external nonReentrant returns (uint256 amount) {
        if (address(collection).code.length == 0) revert InvalidConfiguration();
        amount = imd.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        totalImdForwarded += amount;
        imd.forceApprove(address(collection), amount);
        collection.depositProceeds(amount);
        imd.forceApprove(address(collection), 0);
        emit FeesForwarded(amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert InvalidConfiguration();
    }

    function _collect(PoolKey calldata key, BalanceDelta feesAccrued) private {
        _checkPool(key);
        int128 a = feesAccrued.amount0();
        int128 b = feesAccrued.amount1();
        if (a < 0 || b < 0) revert InvalidFeeDelta();
        if (a > 0) poolManager.take(key.currency0, address(this), uint128(a));
        if (b > 0) poolManager.take(key.currency1, address(this), uint128(b));
        bool imdIs0 = Currency.unwrap(key.currency0) == address(imd);
        emit FeesCollected(uint128(imdIs0 ? a : b), uint128(imdIs0 ? b : a));
    }

    function _checkPool(PoolKey calldata key) private view {
        if (keccak256(abi.encode(key)) != keccak256(abi.encode(poolKey()))) revert WrongPool();
    }

    fallback() external {
        revert UnsupportedHook();
    }
}
