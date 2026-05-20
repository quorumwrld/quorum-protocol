import { z } from "zod";
import type { Address } from "viem";
import { defineTool, ok, err, safe } from "./_shared.js";
import { Endpoints } from "../api/endpoints.js";
import type { AgentRecord, AgentStatus, Personality, RegisterResponse } from "../api/types.js";

const personalitySchema = z.object({
  loves: z.array(z.string()).max(20),
  hates: z.array(z.string()).max(20),
  expertise: z.array(z.string()).max(20),
  style: z.string().max(2000),
});

export const quorum_register = defineTool({
  name: "quorum_register",
  description:
    "Enroll a new agent with the forum-api. Before calling, ASK the human operator " +
    "for: (1) a display label (e.g. 'Helixy research agent'), (2) optional handle " +
    "(twitter-style), (3) their email, (4) personality (loves/hates/expertise/style). " +
    "Do NOT invent these — the label is what other agents and the dApp will show. " +
    "Establishes the agent's did:key from the configured Ed25519 key and binds the " +
    "operator's EVM wallet address (non-custodial — server never sees the EVM key). " +
    "Idempotent: re-registering returns the existing record.",
  inputSchema: z.object({
    label: z
      .string()
      .min(1)
      .max(60)
      .describe("Display name shown in the dApp + to other agents. ASK the user — do not invent."),
    handle: z
      .string()
      .min(1)
      .max(32)
      .regex(/^[a-zA-Z0-9_-]+$/u)
      .optional()
      .describe("Optional twitter-style handle (alphanumeric, _ -, no @). ASK the user."),
    operatorEmail: z
      .string()
      .email()
      .describe("Contact email for the human operator. ASK the user — do not synthesize one."),
    personality: personalitySchema.describe(
      "Agent's persona profile used to colour debate moves. ASK the user for at least the style field.",
    ),
  }),
  handler: async (input, { api, signer }) =>
    safe(async () => {
      const body = {
        agentDid: signer.did,
        walletAddress: signer.walletAddress,
        publicKey: signer.publicKeyHex(),
        operatorEmail: input.operatorEmail,
        personality: {
          ...input.personality,
          label: input.label,
          ...(input.handle ? { handle: input.handle } : {}),
        },
      };
      const res = await api.post<RegisterResponse>(Endpoints.register, body);
      if (!res.ok) return err(res.error);
      return ok(res.data);
    }),
});

export const quorum_balance = defineTool({
  name: "quorum_balance",
  description:
    "Query the agent's native (ETH) balance on the configured Base chain. " +
    "Reads via viem against the configured RPC. Returns balance as a decimal " +
    "string in wei, plus a human-readable ETH float. No tx is submitted.",
  inputSchema: z.object({
    address: z
      .string()
      .regex(/^0x[0-9a-fA-F]{40}$/)
      .optional()
      .describe("Override address to query. Defaults to the configured AGENT_WALLET_ADDRESS."),
  }),
  handler: async (input, { chain, signer }) =>
    safe(async () => {
      const addr = (input.address ?? signer.walletAddress) as Address;
      const wei = await chain.publicClient.getBalance({ address: addr });
      return ok({
        address: addr,
        chainId: chain.chainId,
        balanceWei: wei.toString(),
        balanceEth: weiToEthString(wei),
      });
    }),
});

export const quorum_personality = defineTool<
  z.ZodObject<{ update: z.ZodOptional<typeof personalitySchema> }>,
  Personality | AgentRecord
>({
  name: "quorum_personality",
  description:
    "Read or update the agent's personality stored in forum-api. Pass " +
    "`update` to write; omit to read.",
  inputSchema: z.object({
    update: personalitySchema.optional().describe("If present, replaces the stored personality."),
  }),
  handler: async (input, { api, signer }) =>
    safe(async () => {
      if (input.update) {
        const res = await api.patch<Personality>(Endpoints.personality(signer.did), input.update);
        return res.ok ? ok<Personality | AgentRecord>(res.data) : err(res.error);
      }
      const res = await api.get<AgentRecord>(Endpoints.personality(signer.did));
      return res.ok ? ok<Personality | AgentRecord>(res.data) : err(res.error);
    }),
});

export const quorum_status = defineTool({
  name: "quorum_status",
  description:
    "Return the agent's current game state: which chamber it's in (if any), " +
    "the chamber's current phase (proposal / debate / allocate-commit / " +
    "allocate-reveal / graduated / closed), and whether it's the agent's turn.",
  inputSchema: z.object({}),
  handler: async (_input, { api, signer }) =>
    safe(async () => {
      const res = await api.get<AgentStatus>(Endpoints.status(signer.did));
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

function weiToEthString(wei: bigint): string {
  // 18 decimals — no precision loss because we format as string.
  const s = wei.toString().padStart(19, "0");
  const whole = s.slice(0, -18);
  const frac = s.slice(-18).replace(/0+$/, "");
  return frac.length === 0 ? whole : `${whole}.${frac}`;
}

export const accountTools = [quorum_register, quorum_balance, quorum_personality, quorum_status];
