import { z } from "zod";
import type { Address } from "viem";
import { defineTool, ok, err, safe, toBigInt } from "./_shared.js";
import { Endpoints } from "../api/endpoints.js";
import { Erc20Abi } from "../chain/abis.js";
import type { IdeaOnChainStats } from "../api/types.js";

/**
 * Trading surface.
 *
 * `quorum_ideas` aggregates two reads: forum-api's graduated-idea list (which
 * knows about ticker / chamber lineage) and on-chain ERC-20 stats (supply,
 * caller balance). We don't try to compute a TWAP price here — surfaces that
 * need accurate pricing should call the Uniswap V4 quoter directly.
 *
 * `quorum_trade` returns a tx-prep envelope. We intentionally do NOT encode
 * the V4 swap call inside the MCP server: V4 routing parameters (hooks /
 * pool keys / sqrtPriceLimit) are a moving target, and Clanker tokens use
 * specific hooks that the host wallet's swap router is best-equipped to
 * handle. Instead we return a structured "trade intent" the host can route
 * via its own router (e.g. wagmi + @uniswap/v4-sdk, or 0x / 1inch quote).
 */

export const quorum_ideas = defineTool({
  name: "quorum_ideas",
  description:
    "List ideas (graduated and live). For each idea, returns the on-chain " +
    "token address, ticker, name, chamber lineage, and live ERC-20 stats " +
    "(total supply, caller balance). Pricing/marketCap come from forum-api " +
    "indexing (it watches Clanker pools).",
  inputSchema: z.object({
    onlyGraduated: z.boolean().default(true),
    limit: z.number().int().min(1).max(100).default(25),
    cursor: z.string().optional(),
  }),
  handler: async (input, { api, chain, signer }) =>
    safe(async () => {
      const qs = new URLSearchParams();
      qs.set("onlyGraduated", String(input.onlyGraduated));
      qs.set("limit", String(input.limit));
      if (input.cursor) qs.set("cursor", input.cursor);
      const res = await api.get<IdeaOnChainStats[]>(`${Endpoints.ideas}?${qs.toString()}`);
      if (!res.ok) return err(res.error);

      // Enrich with caller balance per token — keeps the agent UX one round-trip.
      const enriched = await Promise.all(
        res.data.map(async (idea) => {
          let balanceWei = "0";
          try {
            const bal = await chain.publicClient.readContract({
              address: idea.tokenAddress as Address,
              abi: Erc20Abi,
              functionName: "balanceOf",
              args: [signer.walletAddress as Address],
            });
            balanceWei = (bal as bigint).toString();
          } catch {
            // RPC may not have the token if it's not actually deployed — leave 0
          }
          return { ...idea, callerBalanceWei: balanceWei };
        }),
      );
      return ok(enriched);
    }),
});

export const quorum_trade = defineTool({
  name: "quorum_trade",
  description:
    "Prepare a trade of an idea token against its paired token (typically " +
    "WETH on Base). Returns a structured trade intent for the MCP host's " +
    "wallet/router to execute. The MCP server never signs the swap.",
  inputSchema: z.object({
    ideaToken: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/)
      .describe("ERC-20 address of the idea token to trade."),
    side: z.enum(["buy", "sell"]).describe("buy = pairedToken → idea; sell = idea → pairedToken"),
    amountInWei: z
      .union([z.string(), z.number()])
      .describe("Input amount, decimal string in the smallest unit of the input token."),
    pairedToken: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/)
      .optional()
      .describe("Paired token address (defaults to WETH per chain)."),
    slippageBps: z.number().int().min(0).max(2000).default(100),
    recipient: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/)
      .optional(),
  }),
  handler: async (input, { chain, signer }) =>
    safe(async () => {
      const amount = toBigInt(input.amountInWei);
      if (amount <= 0n) return err("amountInWei must be > 0");

      const paired =
        input.pairedToken ?? (chain.chainId === 8453 ? WETH_BASE_MAINNET : WETH_BASE_SEPOLIA);
      const recipient = (input.recipient ?? signer.walletAddress) as Address;

      // Sanity: idea token must exist on chain (best-effort — readContract throws if not)
      try {
        await chain.publicClient.readContract({
          address: input.ideaToken as Address,
          abi: Erc20Abi,
          functionName: "decimals",
        });
      } catch {
        return err(`idea token ${input.ideaToken} not found on chainId ${chain.chainId}`);
      }

      return ok({
        kind: "trade-intent" as const,
        chainId: chain.chainId,
        side: input.side,
        tokenIn: (input.side === "buy" ? paired : input.ideaToken) as Address,
        tokenOut: (input.side === "buy" ? input.ideaToken : paired) as Address,
        amountInWei: amount.toString(),
        recipient,
        slippageBps: input.slippageBps,
        note:
          "MCP host: route this trade via your V4-aware router (idea tokens live " +
          "on Uniswap V4 with a Clanker static-fee hook). The MCP server does not " +
          "encode the swap call to avoid pinning a hook version.",
      });
    }),
});

const WETH_BASE_MAINNET = "0x4200000000000000000000000000000000000006" as const;
const WETH_BASE_SEPOLIA = "0x4200000000000000000000000000000000000006" as const;

export const tradingTools = [quorum_ideas, quorum_trade];
