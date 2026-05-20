import { z } from "zod";
import type { Address } from "viem";
import { defineTool, ok, err, safe, toBigInt } from "./_shared.js";
import { assertNonZero } from "../chain/client.js";
import { BondingEscrowAbi, Erc20Abi } from "../chain/abis.js";
import { prepBondAgainst, prepBondFor, prepErc20Approve } from "../chain/txprep.js";

/**
 * BondingEscrow tools.
 *
 * Each bond requires the agent's wallet to have approved the BondingEscrow
 * for `amount` of the idea token. We surface this gracefully:
 *   - read current allowance
 *   - if allowance < amount, the response includes BOTH the approve envelope
 *     and the bond envelope (host wallet should submit in order)
 *   - otherwise only the bond envelope is returned
 *
 * This keeps the agent's "I want to bond X" intent expressible in a single
 * tool call without leaking ERC-20 plumbing into the agent prompt.
 */

const sharedSchema = z.object({
  bountyId: z
    .union([z.string(), z.number()])
    .describe("Bounty id returned by ForumExecutor.createBounty (uint256)."),
  amount: z
    .union([z.string(), z.number()])
    .describe("Amount to bond, decimal string in the idea token's smallest unit."),
});

async function buildBondPayload(args: {
  chainId: number;
  bondingEscrow: Address;
  bonder: Address;
  bountyId: bigint;
  amount: bigint;
  side: "for" | "against";
  readBountyToken: (id: bigint) => Promise<Address>;
  readAllowance: (token: Address, owner: Address, spender: Address) => Promise<bigint>;
}) {
  const ideaToken = await args.readBountyToken(args.bountyId);
  if (ideaToken === "0x0000000000000000000000000000000000000000") {
    return err(`bounty #${args.bountyId.toString()} not registered with BondingEscrow`);
  }

  const allowance = await args.readAllowance(ideaToken, args.bonder, args.bondingEscrow);
  const transactions = [];
  if (allowance < args.amount) {
    transactions.push(
      prepErc20Approve({
        chainId: args.chainId,
        token: ideaToken,
        spender: args.bondingEscrow,
        amount: args.amount,
      }),
    );
  }
  transactions.push(
    args.side === "for"
      ? prepBondFor({
          chainId: args.chainId,
          bondingEscrow: args.bondingEscrow,
          bountyId: args.bountyId,
          amount: args.amount,
        })
      : prepBondAgainst({
          chainId: args.chainId,
          bondingEscrow: args.bondingEscrow,
          bountyId: args.bountyId,
          amount: args.amount,
        }),
  );

  return ok({
    side: args.side,
    bountyId: args.bountyId.toString(),
    amountWei: args.amount.toString(),
    ideaToken,
    transactions,
  });
}

export const quorum_bond_for = defineTool({
  name: "quorum_bond_for",
  description:
    "Prepare a FOR-bond on a ForumExecutor bounty. Returns one or two tx-prep " +
    "envelopes: ERC-20 approve (if allowance < amount) then BondingEscrow.bondFor. " +
    "MCP host signs and submits in order.",
  inputSchema: sharedSchema,
  handler: async (input, { chain, signer }) =>
    safe(async () => {
      assertNonZero(chain.addresses.bondingEscrow, "BondingEscrow");
      const bountyId = toBigInt(input.bountyId);
      const amount = toBigInt(input.amount);
      if (amount <= 0n) return err("amount must be > 0");

      return buildBondPayload({
        chainId: chain.chainId,
        bondingEscrow: chain.addresses.bondingEscrow,
        bonder: signer.walletAddress as Address,
        bountyId,
        amount,
        side: "for",
        readBountyToken: async (id) => {
          const bs = (await chain.publicClient.readContract({
            address: chain.addresses.bondingEscrow,
            abi: BondingEscrowAbi,
            functionName: "getBounty",
            args: [id],
          })) as { ideaToken: Address };
          return bs.ideaToken;
        },
        readAllowance: async (token, owner, spender) =>
          (await chain.publicClient.readContract({
            address: token,
            abi: Erc20Abi,
            functionName: "allowance",
            args: [owner, spender],
          })) as bigint,
      });
    }),
});

export const quorum_bond_against = defineTool({
  name: "quorum_bond_against",
  description:
    "Prepare an AGAINST-bond on a ForumExecutor bounty. Same shape as " +
    "quorum_bond_for but stakes on the rejection side.",
  inputSchema: sharedSchema,
  handler: async (input, { chain, signer }) =>
    safe(async () => {
      assertNonZero(chain.addresses.bondingEscrow, "BondingEscrow");
      const bountyId = toBigInt(input.bountyId);
      const amount = toBigInt(input.amount);
      if (amount <= 0n) return err("amount must be > 0");

      return buildBondPayload({
        chainId: chain.chainId,
        bondingEscrow: chain.addresses.bondingEscrow,
        bonder: signer.walletAddress as Address,
        bountyId,
        amount,
        side: "against",
        readBountyToken: async (id) => {
          const bs = (await chain.publicClient.readContract({
            address: chain.addresses.bondingEscrow,
            abi: BondingEscrowAbi,
            functionName: "getBounty",
            args: [id],
          })) as { ideaToken: Address };
          return bs.ideaToken;
        },
        readAllowance: async (token, owner, spender) =>
          (await chain.publicClient.readContract({
            address: token,
            abi: Erc20Abi,
            functionName: "allowance",
            args: [owner, spender],
          })) as bigint,
      });
    }),
});

export const bondingTools = [quorum_bond_for, quorum_bond_against];
