// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwarmlerActivity} from "./SwarmlerActivity.sol";
import {SwarmlerConstants} from "./SwarmlerConstants.sol";
import {SwarmlerArt} from "./SwarmlerArt.sol";

/// @notice 2,500 NFTs and a fully collateralized IMD holding-time reward ledger.
/// @dev Earned and unclaimed rewards belong to the NFT, including across transfers.
contract Swarmlers is ERC721, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SUPPLY = 2500;
    uint256 public constant CREATOR_SUPPLY = 25;
    uint256 public constant MINT_PRICE = 0.25 ether;
    uint256 public constant LIFETIME_CAP = 1 ether;
    IERC20 public constant imd = IERC20(SwarmlerConstants.IMD);
    address public constant creator = SwarmlerConstants.CREATOR;
    SwarmlerActivity public immutable activity;

    uint256 public totalMinted;
    bool public publicMintOpen;
    uint256 public rewardDuration;
    uint256 public rewardRate;
    uint256 public rewardIndex;
    uint256 public lastRewardTime;
    uint256 public firstActiveId = 1;
    uint256 public rewardReserve;
    uint256 public totalAllocated;
    uint256 public totalClaimed;
    uint256 public creatorCredit;
    uint256 public totalProceeds;
    uint256 public totalCreatorPaid;
    mapping(uint256 => uint256) public birthIndex;
    mapping(uint256 => uint256) public claimed;
    mapping(uint256 => bool) public identityClaimed;
    mapping(address => bool) public walletClaimed;
    mapping(uint256 => uint256) public pairedIdentity;
    mapping(uint256 => bool) public isPaired;

    error InvalidConfiguration();
    error RewardsNotConfigured();
    error MintClosed();
    error SoldOut();
    error NotEligible();
    error AlreadyClaimed();
    error NotHolder();
    error ZeroAmount();
    error InexactPayment();
    error NoRewards();
    error InvalidBatch();

    event RewardDurationConfigured(uint256 duration, uint256 rate);
    event PublicMintOpened();
    event Minted(address indexed holder, uint256 indexed tokenId, bool freeClaim);
    event Paired(uint256 indexed tokenId, uint256 indexed identityId);
    event ProceedsDeposited(address indexed sender, uint256 gross, uint256 rewards, uint256 creatorShare);
    event RewardsCheckpointed(uint256 index, uint256 allocated, uint256 firstActiveId);
    event RewardClaimed(address indexed holder, uint256 indexed tokenId, uint256 amount);
    event CreatorPaid(uint256 amount);
    event MetadataUpdate(uint256 tokenId);

    constructor(address initialOwner, address activityRegistry)
        ERC721("Swarmlers Agents", "SWARMLER-NFT")
        Ownable(initialOwner)
    {
        if (activityRegistry == address(0)) {
            revert InvalidConfiguration();
        }
        activity = SwarmlerActivity(activityRegistry);
        lastRewardTime = block.timestamp;
        // Deliberately no receiver callbacks or external calls in launch constructors.
        for (uint256 i = 1; i <= CREATOR_SUPPLY; ++i) {
            _mint(creator, i);
        }
        totalMinted = CREATOR_SUPPLY;
    }

    /// @notice One-time choice of funded seconds to earn one IMD, made before public minting.
    function setRewardDuration(uint256 duration) external onlyOwner {
        if (rewardDuration != 0 || duration < 1 days || duration > 3650 days) revert InvalidConfiguration();
        rewardDuration = duration;
        rewardRate = LIFETIME_CAP / duration;
        lastRewardTime = block.timestamp;
        emit RewardDurationConfigured(duration, rewardRate);
    }

    function openPublicMint() external onlyOwner {
        if (publicMintOpen) revert InvalidConfiguration();
        if (rewardRate == 0) revert RewardsNotConfigured();
        if (activity.reporter() == address(0)) revert SwarmlerActivity.ReporterNotConfigured();
        publicMintOpen = true;
        emit PublicMintOpened();
    }

    function mint() external nonReentrant returns (uint256 tokenId) {
        _checkMint();
        _checkpoint();
        _pullProceeds(msg.sender, MINT_PRICE);
        tokenId = _mintNext(msg.sender);
        emit Minted(msg.sender, tokenId, false);
    }

    function freeClaim(uint256 identityId) external nonReentrant returns (uint256 tokenId) {
        _checkMint();
        if (walletClaimed[msg.sender] || identityClaimed[identityId]) revert AlreadyClaimed();
        _requireActiveIdentity(identityId, msg.sender);
        _checkpoint();
        walletClaimed[msg.sender] = true;
        identityClaimed[identityId] = true;
        // Pair before the receiver callback so no partial state is observable.
        tokenId = totalMinted + 1;
        isPaired[tokenId] = true;
        pairedIdentity[tokenId] = identityId;
        _mintNext(msg.sender);
        emit Paired(tokenId, identityId);
        emit Minted(msg.sender, tokenId, true);
    }

    function eligible(address holder, uint256 identityId) external view returns (bool) {
        if (
            !publicMintOpen || totalMinted == MAX_SUPPLY || walletClaimed[holder]
                || identityClaimed[identityId]
        ) return false;
        try activity.status(identityId, holder) returns (bool active, uint64, uint64) {
            return active;
        } catch {
            return false;
        }
    }

    function pair(uint256 tokenId, uint256 identityId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotHolder();
        _requireActiveIdentity(identityId, msg.sender);
        pairedIdentity[tokenId] = identityId;
        isPaired[tokenId] = true;
        emit Paired(tokenId, identityId);
        emit MetadataUpdate(tokenId);
    }

    /// @notice Anyone may supply actual mint/trading proceeds or donations. All use the same 90/10 split.
    function depositProceeds(uint256 amount) external nonReentrant {
        if (rewardRate == 0) revert RewardsNotConfigured();
        if (amount == 0) revert ZeroAmount();
        _checkpoint();
        _pullProceeds(msg.sender, amount);
    }

    /// @notice Direct IMD transfers can be recognized without ever counting liabilities twice.
    function syncProceeds() external nonReentrant {
        if (rewardRate == 0) revert RewardsNotConfigured();
        _checkpoint();
        uint256 amount = imd.balanceOf(address(this)) - accountedBalance();
        if (amount == 0) revert ZeroAmount();
        _accountProceeds(amount);
    }

    function accountedBalance() public view returns (uint256) {
        return rewardReserve + totalAllocated - totalClaimed + creatorCredit;
    }

    /// @notice Reward funding the ledger can still absorb: the lifetime cap of every possible NFT minus
    ///         what is already allocated or reserved. Checkpoints move reserve to allocation, so this
    ///         is exact without one. Zero means every further deposit is credited to the creator.
    function remainingRewardCapacity() public view returns (uint256) {
        return MAX_SUPPLY * LIFETIME_CAP - totalAllocated - rewardReserve;
    }

    function checkpoint() external {
        _checkpoint();
    }

    /// @dev Each active NFT earns the same amount per funded second. Expiries are ordered by mint index.
    ///      Capped NFTs are removed automatically, independent of transfers or claims.
    function previewRewardState() public view returns (uint256 index, uint256 reserve, uint256 first) {
        index = rewardIndex;
        reserve = rewardReserve;
        first = firstActiveId;
        uint256 target = index + (block.timestamp - lastRewardTime) * rewardRate;
        while (first <= totalMinted && index < target) {
            uint256 activeCount = totalMinted - first + 1;
            uint256 nextCap = birthIndex[first] + LIFETIME_CAP;
            uint256 increment = target - index;
            if (increment > nextCap - index) increment = nextCap - index;
            if (increment > reserve / activeCount) increment = reserve / activeCount;
            index += increment;
            reserve -= increment * activeCount;
            if (index == nextCap) {
                do {
                    ++first;
                } while (first <= totalMinted && birthIndex[first] + LIFETIME_CAP == index);
            } else {
                break;
            }
        }
    }

    function earned(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        (uint256 index,,) = previewRewardState();
        uint256 amount = index - birthIndex[tokenId];
        return amount > LIFETIME_CAP ? LIFETIME_CAP : amount;
    }

    function claimable(uint256 tokenId) external view returns (uint256) {
        return earned(tokenId) - claimed[tokenId];
    }

    function claimReward(uint256 tokenId) external nonReentrant returns (uint256 amount) {
        _checkpoint();
        amount = _claim(tokenId);
        imd.safeTransfer(msg.sender, amount);
    }

    function claimRewards(uint256[] calldata tokenIds) external nonReentrant returns (uint256 amount) {
        if (tokenIds.length == 0 || tokenIds.length > 100) revert InvalidBatch();
        _checkpoint();
        for (uint256 i; i < tokenIds.length; ++i) {
            amount += _claim(tokenIds[i]);
        }
        imd.safeTransfer(msg.sender, amount);
    }

    /// @notice Permissionless trigger; the destination is permanently the brief's creator wallet.
    function withdrawCreator() external nonReentrant {
        uint256 amount = creatorCredit;
        if (amount == 0) revert ZeroAmount();
        creatorCredit = 0;
        totalCreatorPaid += amount;
        imd.safeTransfer(creator, amount);
        emit CreatorPaid(amount);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address holder = _requireOwned(tokenId);
        bool active;
        uint64 lastActive;
        uint64 score;
        if (isPaired[tokenId]) {
            try activity.status(pairedIdentity[tokenId], holder) returns (bool a, uint64 last, uint64 s) {
                active = a;
                lastActive = last;
                score = s;
            } catch {} // Metadata remains readable during a dependency outage.
        }
        return SwarmlerArt.uri(tokenId, active, lastActive, score, pairedIdentity[tokenId], isPaired[tokenId]);
    }

    function rarity(uint256 tokenId) external view returns (string memory) {
        _requireOwned(tokenId);
        return SwarmlerArt.rarity(tokenId);
    }

    /// @notice Refresh marketplace caches after reporter updates or natural activity expiry.
    function refreshMetadata(uint256 tokenId) external {
        _requireOwned(tokenId);
        emit MetadataUpdate(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }

    function renounceOwnership() public view override onlyOwner {
        revert InvalidConfiguration();
    }

    function _checkMint() private view {
        if (!publicMintOpen) revert MintClosed();
        if (totalMinted == MAX_SUPPLY) revert SoldOut();
    }

    function _requireActiveIdentity(uint256 identityId, address holder) private view {
        (bool active,,) = activity.status(identityId, holder);
        if (!active || IERC721(SwarmlerConstants.IDENTITY).ownerOf(identityId) != holder) {
            revert NotEligible();
        }
    }

    function _mintNext(address holder) private returns (uint256 tokenId) {
        tokenId = ++totalMinted;
        birthIndex[tokenId] = rewardIndex;
        _safeMint(holder, tokenId);
    }

    function _pullProceeds(address from, uint256 amount) private {
        uint256 beforeBalance = imd.balanceOf(address(this));
        imd.safeTransferFrom(from, address(this), amount);
        if (imd.balanceOf(address(this)) - beforeBalance != amount) revert InexactPayment();
        _accountProceeds(amount);
    }

    /// @dev Called after a checkpoint. Reward funding beyond the collection's lifetime capacity has no
    ///      holder who could ever claim it, so that part is credited to the creator instead of a dead reserve.
    function _accountProceeds(uint256 amount) private {
        // Floor the creator's share; sub-10-wei rounding belongs to rewards.
        uint256 creatorShare = amount / 10;
        uint256 rewardShare = amount - creatorShare;
        uint256 capacity = remainingRewardCapacity();
        if (rewardShare > capacity) {
            creatorShare += rewardShare - capacity;
            rewardShare = capacity;
        }
        creatorCredit += creatorShare;
        rewardReserve += rewardShare;
        totalProceeds += amount;
        emit ProceedsDeposited(msg.sender, amount, rewardShare, creatorShare);
    }

    function _checkpoint() private {
        (uint256 index, uint256 reserve, uint256 first) = previewRewardState();
        uint256 allocated = rewardReserve - reserve;
        totalAllocated += allocated;
        rewardIndex = index;
        rewardReserve = reserve;
        firstActiveId = first;
        lastRewardTime = block.timestamp;
        if (allocated != 0) emit RewardsCheckpointed(index, allocated, first);
    }

    function _claim(uint256 tokenId) private returns (uint256 amount) {
        if (ownerOf(tokenId) != msg.sender) revert NotHolder();
        uint256 lifetimeEarned = rewardIndex - birthIndex[tokenId];
        if (lifetimeEarned > LIFETIME_CAP) lifetimeEarned = LIFETIME_CAP;
        amount = lifetimeEarned - claimed[tokenId];
        if (amount == 0) revert NoRewards();
        claimed[tokenId] = lifetimeEarned;
        totalClaimed += amount;
        emit RewardClaimed(msg.sender, tokenId, amount);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0)) emit MetadataUpdate(tokenId);
    }
}
