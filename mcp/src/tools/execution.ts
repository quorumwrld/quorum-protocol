import { z } from "zod";
import type { Address } from "viem";
import { defineTool, ok, err, safe, toBigInt } from "./_shared.js";
import { assertNonZero } from "../chain/client.js";
import { Erc20Abi } from "../chain/abis.js";
import {
  prepClaimBounty,
  prepCreateBounty,
  prepErc20Approve,
  prepFinalize,
} from "../chain/txprep.js";

/**
 * ForumExecutor tools (creating, claiming, finalising bounties).
 *
 * PR-open / PR-review aren't implemented here — those delegate to the
 * gitlawb MCP server (the agent installs both). See DECISIONS.md #003.
 * The hand-off from gitlawb back to Quorum is: gitlawb merges → calls
 * `submitBounty` then anyone (any AGAINST-bonder) calls `vote`, then
 * `quorum_bounty_finalize` here tallies and pays out.
 */

export const quorum_bounty_create = defineTool({
  name: "quorum_bounty_create",
  description:
    "Prepare a ForumExecutor.createBounty tx. Returns an approve envelope (if " +
    "allowance is insufficient) and the createBounty envelope. The bounty token " +
    "is typically the idea's Clanker token, so creating a bounty pulls liquidity " +
    "out of circulation until the PR is approved/rejected.",
  inputSchema: z.object({
    token: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/)
      .describe("ERC-20 to escrow as the bounty (usually the idea token)."),
    amount: z.union([z.string(), z.number()]).describe("Bounty amount, smallest unit of `token`."),
    repoOwner: z.string().min(1).max(64),
    repoName: z.string().min(1).max(128),
    issueId: z.string().min(1).max(64),
    title: z.string().min(3).max(200),
  }),
  handler: async (input, { chain, signer }) =>
    safe(async () => {
      assertNonZero(chain.addresses.forumExecutor, "ForumExecutor");
      const amount = toBigInt(input.amount);
      if (amount <= 0n) return err("amount must be > 0");

      const allowance = (await chain.publicClient.readContract({
        address: input.token as Address,
        abi: Erc20Abi,
        functionName: "allowance",
        args: [signer.walletAddress as Address, chain.addresses.forumExecutor],
      })) as bigint;

      const txs = [];
      if (allowance < amount) {
        txs.push(
          prepErc20Approve({
            chainId: chain.chainId,
            token: input.token as Address,
            spender: chain.addresses.forumExecutor,
            amount,
          }),
        );
      }
      txs.push(
        prepCreateBounty({
          chainId: chain.chainId,
          forumExecutor: chain.addresses.forumExecutor,
          token: input.token as Address,
          amount,
          repoOwner: input.repoOwner,
          repoName: input.repoName,
          issueId: input.issueId,
          title: input.title,
        }),
      );

      return ok({
        kind: "bounty-create" as const,
        token: input.token,
        amountWei: amount.toString(),
        repo: `${input.repoOwner}/${input.repoName}`,
        issueId: input.issueId,
        transactions: txs,
      });
    }),
});

export const quorum_bounty_claim = defineTool({
  name: "quorum_bounty_claim",
  description:
    "Prepare a ForumExecutor.claimBounty tx. The caller is recorded as the " +
    "claimant; once the PR is submitted (via gitlawb) and reviewed, the bounty " +
    "settles in their favour.",
  inputSchema: z.object({
    bountyId: z.union([z.string(), z.number()]),
    agentDid: z
      .string()
      .startsWith("did:key:z")
      .optional()
      .describe("Defaults to the configured agent's did:key."),
  }),
  handler: async (input, { chain, signer }) =>
    safe(async () => {
      assertNonZero(chain.addresses.forumExecutor, "ForumExecutor");
      const bountyId = toBigInt(input.bountyId);
      const did = input.agentDid ?? signer.did;
      return ok({
        kind: "bounty-claim" as const,
        bountyId: bountyId.toString(),
        agentDid: did,
        transactions: [
          prepClaimBounty({
            chainId: chain.chainId,
            forumExecutor: chain.addresses.forumExecutor,
            bountyId,
            agentDid: did,
          }),
        ],
      });
    }),
});

export const quorum_bounty_finalize = defineTool({
  name: "quorum_bounty_finalize",
  description:
    "Prepare a ForumExecutor.finalize tx. Tallies AGAINST-bonder votes on the " +
    "submitted PR. Anyone can call after the review deadline OR once a strict " +
    "majority has voted one direction. On approve → payout + BondingEscrow.settle(true). " +
    "On reject → refund creator + BondingEscrow.settle(false).",
  inputSchema: z.object({
    bountyId: z.union([z.string(), z.number()]),
  }),
  handler: async (input, { chain }) =>
    safe(async () => {
      assertNonZero(chain.addresses.forumExecutor, "ForumExecutor");
      const bountyId = toBigInt(input.bountyId);
      return ok({
        kind: "bounty-finalize" as const,
        bountyId: bountyId.toString(),
        transactions: [
          prepFinalize({
            chainId: chain.chainId,
            forumExecutor: chain.addresses.forumExecutor,
            bountyId,
          }),
        ],
      });
    }),
});

export const executionTools = [quorum_bounty_create, quorum_bounty_claim, quorum_bounty_finalize];
