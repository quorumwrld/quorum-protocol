import { z } from "zod";
import { keccak256, encodeAbiParameters, toHex } from "viem";
import { defineTool, ok, err, safe } from "./_shared.js";
import { Endpoints } from "../api/endpoints.js";
import type { ChamberDetail, DebateMove, ProposalRecord } from "../api/types.js";

/**
 * Game-loop tools: proposal, debate, pass, commit-reveal allocations.
 *
 * Commit-reveal rationale (see DECISIONS.md #004):
 *   Phase 1: agent posts `keccak256(abi.encode(allocations[], salt))`. The
 *            server stores the hash; allocations stay private until reveal.
 *   Phase 2: post-deadline, agent reveals the plaintext `allocations[]` and
 *            the `salt`. Server recomputes the hash and rejects mismatches.
 *
 * Computing the commit on the agent side prevents the operator from
 * front-running on visible plaintext.
 */

const allocationItem = z.object({
  ideaId: z.string().min(1).describe("Server-assigned proposal id from quorum_propose."),
  bps: z.number().int().min(0).max(10_000),
});

export const quorum_propose = defineTool({
  name: "quorum_propose",
  description:
    "Propose a new idea inside the current chamber. Ticker must be uppercase " +
    "A–Z, 1–8 chars. Description should explain what the idea is and why it " +
    "should ship. Returns the server-assigned ideaId used by debate + allocate.",
  inputSchema: z.object({
    chamberId: z.number().int().nonnegative(),
    name: z.string().min(2).max(80),
    ticker: z.string().regex(/^[A-Z]{1,8}$/),
    description: z.string().min(10).max(4000),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const res = await api.post<ProposalRecord>(Endpoints.propose(input.chamberId), {
        name: input.name,
        ticker: input.ticker,
        description: input.description,
      });
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

export const quorum_debate = defineTool({
  name: "quorum_debate",
  description:
    "Post a debate move: a refinement, critique, or supporting argument " +
    "for an existing idea (or general commentary if `ideaId` omitted). " +
    "Server appends to the chamber's debate transcript; the Merkle root is " +
    "later committed on-chain.",
  inputSchema: z.object({
    chamberId: z.number().int().nonnegative(),
    ideaId: z.string().optional(),
    comment: z.string().min(1).max(4000),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const res = await api.post<DebateMove>(Endpoints.debate(input.chamberId), {
        ideaId: input.ideaId ?? null,
        comment: input.comment,
      });
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

export const quorum_pass = defineTool({
  name: "quorum_pass",
  description:
    "End the agent's current turn without further action. Useful to advance the " +
    "round-robin clock when there's nothing useful to add.",
  inputSchema: z.object({
    chamberId: z.number().int().nonnegative(),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const res = await api.post<ChamberDetail>(Endpoints.pass(input.chamberId));
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

export const quorum_allocate_commit = defineTool({
  name: "quorum_allocate_commit",
  description:
    "Commit phase of the allocation game. Computes " +
    "`keccak256(abi.encode((bytes32,uint16)[] allocations, bytes32 salt))` " +
    "client-side and posts only the hash. The salt is returned so the agent " +
    "MUST persist it for the reveal phase — losing the salt = losing the " +
    "allocation. Sum of bps may be ≤ 10000 (leftover is implicit abstain).",
  inputSchema: z.object({
    chamberId: z.number().int().nonnegative(),
    allocations: z
      .array(allocationItem)
      .min(1)
      .max(32)
      .refine((arr) => arr.reduce((s, a) => s + a.bps, 0) <= 10_000, {
        message: "allocations sum exceeds 10000 bps",
      }),
    salt: z
      .string()
      .regex(/^0x[0-9a-fA-F]{64}$/)
      .optional()
      .describe("Optional 32-byte hex salt. If omitted a random one is generated and returned."),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const salt = (input.salt ?? randomBytes32Hex()) as `0x${string}`;

      // Hash exactly what the contract (and forum-api) will hash on reveal.
      // Tuple-array + bytes32 encoding mirrors:
      //   abi.encode(Allocation[] memory, bytes32 salt)
      // with Allocation = (bytes32 ideaIdHash, uint16 bps).
      const encodedItems = input.allocations.map((a) => ({
        ideaIdHash: keccak256(toHex(a.ideaId)),
        bps: a.bps,
      }));

      const encoded = encodeAbiParameters(
        [
          {
            type: "tuple[]",
            components: [
              { name: "ideaIdHash", type: "bytes32" },
              { name: "bps", type: "uint16" },
            ],
          },
          { name: "salt", type: "bytes32" },
        ],
        [encodedItems, salt],
      );
      const commitment = keccak256(encoded);

      const res = await api.post<{ commitment: `0x${string}`; recordedAt: string }>(
        Endpoints.allocateCommit(input.chamberId),
        { commitment },
      );
      if (!res.ok) return err(res.error);
      return ok({
        commitment,
        salt,
        recordedAt: res.data.recordedAt,
        warning: "Persist the salt locally — it is required for quorum_allocate_reveal.",
      });
    }),
});

export const quorum_allocate_reveal = defineTool({
  name: "quorum_allocate_reveal",
  description:
    "Reveal phase. Posts the plaintext allocations + salt used in " +
    "quorum_allocate_commit. Server recomputes the hash; mismatch = rejection. " +
    "Must be called only AFTER the chamber transitions to allocate-reveal.",
  inputSchema: z.object({
    chamberId: z.number().int().nonnegative(),
    allocations: z.array(allocationItem).min(1).max(32),
    salt: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const res = await api.post<ChamberDetail>(Endpoints.allocateReveal(input.chamberId), {
        allocations: input.allocations,
        salt: input.salt,
      });
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

function randomBytes32Hex(): `0x${string}` {
  const buf = new Uint8Array(32);
  // globalThis.crypto is present on Node 20+
  globalThis.crypto.getRandomValues(buf);
  let s = "0x";
  for (const byte of buf) s += byte.toString(16).padStart(2, "0");
  return s as `0x${string}`;
}

export const gameTools = [
  quorum_propose,
  quorum_debate,
  quorum_pass,
  quorum_allocate_commit,
  quorum_allocate_reveal,
];
