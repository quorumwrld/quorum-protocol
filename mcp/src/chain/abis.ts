import { parseAbi } from "viem";

/**
 * Minimal ABIs — only the functions we actually call from the MCP server.
 * Sourcing:
 *   - BondingEscrow: packages/contracts/src/BondingEscrow.sol
 *   - ForumExecutor: packages/contracts/src/ForumExecutor.sol
 *   - IdeaFactory / ChamberRegistry: read-only views only
 *   - Clanker: only the swap-via-router shape used by `quorum_trade`
 *
 * Kept as parseAbi string arrays so the source is human-auditable and diffs
 * cleanly against the Solidity. If a signature is wrong, viem throws at
 * encode time — we never silently send a malformed call.
 */

export const BondingEscrowAbi = parseAbi([
  "function bondFor(uint256 bountyId, uint256 amount)",
  "function bondAgainst(uint256 bountyId, uint256 amount)",
  "function claim(uint256 bountyId)",
  "function getBounty(uint256 bountyId) view returns ((address ideaToken, uint128 totalFor, uint128 totalAgainst, uint8 settlement, bool registered))",
  "function getPosition(uint256 bountyId, address bonder) view returns ((uint128 forStake, uint128 againstStake, bool claimed))",
]);

export const ForumExecutorAbi = parseAbi([
  "function createBounty(address token, uint256 amount, string repoOwner, string repoName, string issueId, string title) returns (uint256 bountyId)",
  "function claimBounty(uint256 bountyId, string agentDid)",
  "function submitBounty(uint256 bountyId, string prId)",
  "function vote(uint256 bountyId, bool approve)",
  "function finalize(uint256 bountyId)",
  "function cancelBounty(uint256 bountyId)",
  "function disputeBounty(uint256 bountyId)",
  "function getProtocolStats() view returns (uint256, uint256, uint256)",
]);

export const Erc20Abi = parseAbi([
  "function balanceOf(address account) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function totalSupply() view returns (uint256)",
]);

export const ChamberRegistryAbi = parseAbi([
  "function getIdea(address tokenAddress) view returns ((address tokenAddress, string name, string ticker, string description, address creator, uint256 chamberId, uint64 launchTimestamp, bool graduated, uint64 graduationTimestamp, bool exists))",
  "function getGraduatedIdeas() view returns (address[])",
  "function getIdeaCount() view returns (uint256)",
  "function isGraduated(address tokenAddress) view returns (bool)",
]);

/**
 * Clanker doesn't expose a swap function directly — trades go through the
 * Uniswap V4 router that Clanker's pool is wired into. The MCP server doesn't
 * try to encode V4 swaps itself (that's a moving target and would require
 * pulling in `@uniswap/v4-sdk`); instead `quorum_trade` returns a `quote`
 * envelope pointing at the idea token + paired token, and the MCP host's
 * wallet wires up the swap via its own router integration.
 *
 * We still include this minimal ABI so future iterations can encode direct
 * pool ops without another file diff.
 */
export const ClankerHelperAbi = parseAbi([
  "function tokenForPool(bytes32 poolId) view returns (address)",
]);
