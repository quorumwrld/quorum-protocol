// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IChamberRegistry} from "./interfaces/IChamberRegistry.sol";

/// @title ChamberRegistry
/// @notice Source of truth for chambers (debate rooms) and the ideas that graduated out
///         of them. Holds no funds. Receives Merkle-root commits of off-chain debate
///         transcripts from the dealer relayer, and idea registrations from `IdeaFactory`.
/// @dev `markGraduated` is callable ONLY by the idea token itself (`msg.sender ==
///      tokenAddress`) or by the factory. Any open-auth path would let an attacker
///      flip the flag and skew fee routing — keep this gated.
contract ChamberRegistry is IChamberRegistry, Ownable {
    address public factory;
    address public dealer; // server relayer that commits debate roots

    mapping(uint256 chamberId => ChamberMetadata) internal _chambers;
    uint256[] internal _chamberIds;

    mapping(address tokenAddress => IdeaMetadata) internal _ideas;
    address[] internal _ideaTokens;
    mapping(string ticker => address) internal _tickerToToken;
    mapping(uint256 chamberId => address[]) internal _chamberIdeas;

    event FactoryUpdated(address indexed previousFactory, address indexed newFactory);
    event DealerUpdated(address indexed previousDealer, address indexed newDealer);
    event ChamberCommitted(uint256 indexed chamberId, bytes32 debateMerkleRoot, address indexed dealer);
    event IdeaRegistered(
        address indexed tokenAddress, string name, string ticker, address indexed creator, uint256 indexed chamberId
    );
    event IdeaGraduated(address indexed tokenAddress, uint64 timestamp);

    error NotFactory();
    error NotDealer();
    error NotIdeaTokenOrFactory();
    error TickerTaken(string ticker);
    error IdeaExists(address tokenAddress);
    error IdeaNotFound(address tokenAddress);
    error ChamberAlreadyCommitted(uint256 chamberId);
    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyDealer() {
        if (msg.sender != dealer) revert NotDealer();
        _;
    }

    // ── Admin setters ────────────────────────────────────────────────────────

    function setFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress();
        emit FactoryUpdated(factory, newFactory);
        factory = newFactory;
    }

    function setDealer(address newDealer) external onlyOwner {
        if (newDealer == address(0)) revert ZeroAddress();
        emit DealerUpdated(dealer, newDealer);
        dealer = newDealer;
    }

    // ── Chamber commits ──────────────────────────────────────────────────────

    /// Dealer commits the Merkle root of the off-chain debate transcript. One commit per chamber.
    function commitChamber(uint256 chamberId, bytes32 debateMerkleRoot) external onlyDealer {
        ChamberMetadata storage c = _chambers[chamberId];
        if (c.chamberId != 0 || c.createdAt != 0) revert ChamberAlreadyCommitted(chamberId);

        c.chamberId = chamberId;
        c.debateMerkleRoot = debateMerkleRoot;
        c.dealer = msg.sender;
        c.createdAt = uint64(block.timestamp);
        c.settled = false;

        _chamberIds.push(chamberId);
        emit ChamberCommitted(chamberId, debateMerkleRoot, msg.sender);
    }

    // ── Idea registration ────────────────────────────────────────────────────

    function registerIdea(
        address tokenAddress,
        string calldata name,
        string calldata ticker,
        string calldata description,
        address creator,
        uint256 chamberId
    ) external onlyFactory {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (_ideas[tokenAddress].exists) revert IdeaExists(tokenAddress);
        if (_tickerToToken[ticker] != address(0)) revert TickerTaken(ticker);

        _ideas[tokenAddress] = IdeaMetadata({
            tokenAddress: tokenAddress,
            name: name,
            ticker: ticker,
            description: description,
            creator: creator,
            chamberId: chamberId,
            launchTimestamp: uint64(block.timestamp),
            graduated: false,
            graduationTimestamp: 0,
            exists: true
        });

        _ideaTokens.push(tokenAddress);
        _tickerToToken[ticker] = tokenAddress;
        _chamberIdeas[chamberId].push(tokenAddress);

        emit IdeaRegistered(tokenAddress, name, ticker, creator, chamberId);
    }

    /// Mark an idea as graduated. ONLY the idea token itself OR the factory can call.
    /// Keeping this gated is critical — an open-auth path would let an attacker
    /// flip the flag and skew fee routing.
    /// @dev Defense-in-depth: even if an adversary deploys a contract at some
    ///      address X and calls `markGraduated(X)` from X, the second guard
    ///      `!idea.exists` reverts with `IdeaNotFound` — only ideas previously
    ///      registered through `registerIdea` (which is `onlyFactory`) can ever
    ///      be marked graduated. Therefore the address-comparison check by
    ///      itself does NOT permit unregistered tokens to flip state.
    /// @dev Trust assumption: the `factory` address is set by the owner via
    ///      `setFactory`. We assume the owner only ever points it at a real
    ///      Quorum `IdeaFactory` deployment, whose `deployIdea` is gated by
    ///      `onlyDeployer` (the relayer). If the owner is compromised this
    ///      assumption breaks, but that's already a total-protocol-loss event.
    function markGraduated(address tokenAddress) external {
        if (msg.sender != tokenAddress && msg.sender != factory) revert NotIdeaTokenOrFactory();
        IdeaMetadata storage idea = _ideas[tokenAddress];
        if (!idea.exists) revert IdeaNotFound(tokenAddress);
        if (idea.graduated) return; // idempotent

        idea.graduated = true;
        idea.graduationTimestamp = uint64(block.timestamp);

        emit IdeaGraduated(tokenAddress, idea.graduationTimestamp);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function getChamber(uint256 chamberId) external view returns (ChamberMetadata memory) {
        return _chambers[chamberId];
    }

    function getIdea(address tokenAddress) external view returns (IdeaMetadata memory) {
        IdeaMetadata memory idea = _ideas[tokenAddress];
        if (!idea.exists) revert IdeaNotFound(tokenAddress);
        return idea;
    }

    function getIdeaByTicker(string calldata ticker) external view returns (address) {
        return _tickerToToken[ticker];
    }

    function getIdeasByChamber(uint256 chamberId) external view returns (address[] memory) {
        return _chamberIdeas[chamberId];
    }

    function getGraduatedIdeas() external view returns (address[] memory) {
        uint256 n = _ideaTokens.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (_ideas[_ideaTokens[i]].graduated) ++count;
        }
        address[] memory out = new address[](count);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            address t = _ideaTokens[i];
            if (_ideas[t].graduated) {
                out[j++] = t;
            }
        }
        return out;
    }

    function getIdeaCount() external view returns (uint256) {
        return _ideaTokens.length;
    }

    function isGraduated(address tokenAddress) external view returns (bool) {
        return _ideas[tokenAddress].graduated;
    }

    /// Non-reverting lookup used by `ForumExecutor.createBounty` (H-02 fix) to
    /// enforce that bounty currencies must be factory-deployed idea tokens.
    /// Returns `true` iff the token was registered through `registerIdea`.
    function isRegisteredIdea(address tokenAddress) external view returns (bool) {
        return _ideas[tokenAddress].exists;
    }
}
