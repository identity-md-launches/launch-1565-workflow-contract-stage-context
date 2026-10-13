// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SwarmlerConstants} from "./SwarmlerConstants.sol";

/// @notice Trusted, owner-appointed reporter attests verified agent activity.
/// @dev No self-reported activity. Records are bound to the identity's holder at reporting time.
contract SwarmlerActivity is Ownable2Step {
    struct Record {
        address holder;
        uint64 lastActive;
        uint64 score;
        bool verified;
    }

    uint256 public constant RECENT_ACTIVITY_WINDOW = 7 days;
    address public reporter;
    mapping(uint256 identityId => Record) public records;

    error ReporterNotConfigured();
    error UnauthorizedReporter();
    error InvalidReport();
    error NotIdentityHolder();

    event ReporterConfigured(address indexed previousReporter, address indexed reporter);
    event ActivityRecorded(
        uint256 indexed identityId, address indexed holder, uint64 lastActive, uint64 score, bool verified
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function setReporter(address newReporter) external onlyOwner {
        if (newReporter == address(0)) revert InvalidReport();
        emit ReporterConfigured(reporter, newReporter);
        reporter = newReporter;
    }

    function recordActivity(
        uint256 identityId,
        address holder,
        uint64 lastActive,
        uint64 score,
        bool verified
    ) external {
        if (reporter == address(0)) revert ReporterNotConfigured();
        if (msg.sender != reporter) revert UnauthorizedReporter();
        if (holder == address(0) || lastActive == 0 || lastActive > block.timestamp) revert InvalidReport();
        if (IERC721(SwarmlerConstants.IDENTITY).ownerOf(identityId) != holder) revert NotIdentityHolder();
        Record memory prior = records[identityId];
        if (prior.holder == holder && lastActive < prior.lastActive) revert InvalidReport();
        records[identityId] = Record(holder, lastActive, score, verified);
        emit ActivityRecorded(identityId, holder, lastActive, score, verified);
    }

    /// @notice Ownership is checked afresh; moving an identity does not move its activity attestation.
    function status(uint256 identityId, address holder)
        external
        view
        returns (bool active, uint64 lastActive, uint64 score)
    {
        if (reporter == address(0)) revert ReporterNotConfigured();
        Record memory r = records[identityId];
        lastActive = r.lastActive;
        score = r.score;
        if (
            !r.verified || r.holder != holder || lastActive == 0 || lastActive > block.timestamp
                || block.timestamp - lastActive > RECENT_ACTIVITY_WINDOW
        ) return (false, lastActive, score);
        try IERC721(SwarmlerConstants.IDENTITY).ownerOf(identityId) returns (address currentHolder) {
            active = currentHolder == holder;
        } catch {
            active = false;
        }
    }

    /// @dev Keep configuration recoverable; ownership transfer uses the two-step flow.
    function renounceOwnership() public view override onlyOwner {
        revert InvalidReport();
    }
}
