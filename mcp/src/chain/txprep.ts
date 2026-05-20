import { encodeFunctionData, type Address, type Hex } from "viem";
import { BondingEscrowAbi, Erc20Abi, ForumExecutorAbi } from "./abis.js";

/**
 * tx-prep envelope — the canonical "ready to sign" payload returned to the
 * MCP host. The host's wallet adapter populates `from`, gas params, nonce,
 * and the user signs it.
 *
 * Why this shape (vs returning a raw RLP / EIP-1559 hex tx):
 *   - we never see the user's account, so we can't fill `from` or `nonce`
 *   - the host wallet knows how to bump gas / pick a fee, we don't
 *   - it remains transport-agnostic (any chain abstraction can adapt)
 */
export interface TxEnvelope {
  to: Address;
  data: Hex;
  value: string; // bigint serialised as a decimal string
  chainId: number;
  description: string;
}

function envelope(args: {
  to: Address;
  data: Hex;
  value?: bigint;
  chainId: number;
  description: string;
}): TxEnvelope {
  return {
    to: args.to,
    data: args.data,
    value: (args.value ?? 0n).toString(),
    chainId: args.chainId,
    description: args.description,
  };
}

// ── ERC-20 approvals ────────────────────────────────────────────────────────

export function prepErc20Approve(args: {
  chainId: number;
  token: Address;
  spender: Address;
  amount: bigint;
}): TxEnvelope {
  const data = encodeFunctionData({
    abi: Erc20Abi,
    functionName: "approve",
    args: [args.spender, args.amount],
  });
  return envelope({
    to: args.token,
    data,
    chainId: args.chainId,
    description: `Approve ${args.amount.toString()} of token ${args.token} to spender ${args.spender}`,
  });
}

// ── BondingEscrow ───────────────────────────────────────────────────────────

export function prepBondFor(args: {
  chainId: number;
  bondingEscrow: Address;
  bountyId: bigint;
  amount: bigint;
}): TxEnvelope {
  const data = encodeFunctionData({
    abi: BondingEscrowAbi,
    functionName: "bondFor",
    args: [args.bountyId, args.amount],
  });
  return envelope({
    to: args.bondingEscrow,
    data,
    chainId: args.chainId,
    description: `Bond FOR ${args.amount.toString()} on bounty #${args.bountyId.toString()}`,
  });
}

export function prepBondAgainst(args: {
  chainId: number;
  bondingEscrow: Address;
  bountyId: bigint;
  amount: bigint;
}): TxEnvelope {
  const data = encodeFunctionData({
    abi: BondingEscrowAbi,
    functionName: "bondAgainst",
    args: [args.bountyId, args.amount],
  });
  return envelope({
    to: args.bondingEscrow,
    data,
    chainId: args.chainId,
    description: `Bond AGAINST ${args.amount.toString()} on bounty #${args.bountyId.toString()}`,
  });
}

// ── ForumExecutor ──────────────────────────────────────────────────────────

export function prepCreateBounty(args: {
  chainId: number;
  forumExecutor: Address;
  token: Address;
  amount: bigint;
  repoOwner: string;
  repoName: string;
  issueId: string;
  title: string;
}): TxEnvelope {
  const data = encodeFunctionData({
    abi: ForumExecutorAbi,
    functionName: "createBounty",
    args: [args.token, args.amount, args.repoOwner, args.repoName, args.issueId, args.title],
  });
  return envelope({
    to: args.forumExecutor,
    data,
    chainId: args.chainId,
    description: `Create bounty ${args.amount.toString()} of ${args.token} for ${args.repoOwner}/${args.repoName}#${args.issueId} (${args.title})`,
  });
}

export function prepClaimBounty(args: {
  chainId: number;
  forumExecutor: Address;
  bountyId: bigint;
  agentDid: string;
}): TxEnvelope {
  const data = encodeFunctionData({
    abi: ForumExecutorAbi,
    functionName: "claimBounty",
    args: [args.bountyId, args.agentDid],
  });
  return envelope({
    to: args.forumExecutor,
    data,
    chainId: args.chainId,
    description: `Claim bounty #${args.bountyId.toString()} as ${args.agentDid}`,
  });
}

export function prepFinalize(args: {
  chainId: number;
  forumExecutor: Address;
  bountyId: bigint;
}): TxEnvelope {
  const data = encodeFunctionData({
    abi: ForumExecutorAbi,
    functionName: "finalize",
    args: [args.bountyId],
  });
  return envelope({
    to: args.forumExecutor,
    data,
    chainId: args.chainId,
    description: `Finalize bounty #${args.bountyId.toString()} (tallies AGAINST-bonder votes)`,
  });
}
