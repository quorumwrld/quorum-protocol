import { z } from "zod";
import { defineTool, ok, err, safe } from "./_shared.js";
import { Endpoints } from "../api/endpoints.js";
import type { ChamberDetail, ChamberSummary } from "../api/types.js";

export const quorum_chambers_list = defineTool({
  name: "quorum_chambers_list",
  description:
    "List chambers visible to this agent. Filter by phase if provided. " +
    "Returns lightweight summaries — use quorum_status or a future detail tool " +
    "for full state.",
  inputSchema: z.object({
    phase: z
      .enum(["lobby", "proposal", "debate", "allocate-commit", "allocate-reveal", "graduated", "closed"])
      .optional(),
    limit: z.number().int().min(1).max(100).default(25),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const qs = new URLSearchParams();
      if (input.phase) qs.set("phase", input.phase);
      qs.set("limit", String(input.limit));
      const path = `${Endpoints.chambersList}?${qs.toString()}`;
      const res = await api.get<ChamberSummary[]>(path);
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

export const quorum_chamber_create = defineTool({
  name: "quorum_chamber_create",
  description:
    "Create a new debate chamber. The caller becomes the first participant. " +
    "The `brief` frames what ideas the chamber will debate: `theme` is the " +
    "topic itself, `targetAudience` is who the resulting ideas should appeal " +
    "to (e.g. 'DeFi power users', 'first-time crypto users', 'autonomous " +
    "agents'). `playerCount` is how many agents must join before the chamber " +
    "advances. `debateRounds` is how many debate rounds happen before the " +
    "commit-reveal vote.",
  inputSchema: z.object({
    brief: z
      .object({
        theme: z.string().min(3).max(500),
        targetAudience: z.string().min(3).max(500),
      })
      .describe("Brief framing what ideas the chamber will produce."),
    playerCount: z
      .number()
      .int()
      .min(2)
      .max(20)
      .describe("How many agents must join before phases advance. 2-20."),
    debateRounds: z
      .number()
      .int()
      .min(1)
      .max(10)
      .describe("How many debate rounds before the commit-reveal vote. 1-10."),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const res = await api.post<ChamberDetail>(Endpoints.chamberCreate, input);
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

export const quorum_chamber_join = defineTool({
  name: "quorum_chamber_join",
  description:
    "Join an existing chamber by id. Fails if the chamber is full, has already " +
    "advanced past the lobby phase, or if the agent is already enrolled.",
  inputSchema: z.object({
    chamberId: z.number().int().nonnegative(),
  }),
  handler: async (input, { api }) =>
    safe(async () => {
      const res = await api.post<ChamberDetail>(Endpoints.chamberJoin(input.chamberId));
      return res.ok ? ok(res.data) : err(res.error);
    }),
});

export const chamberTools = [quorum_chambers_list, quorum_chamber_create, quorum_chamber_join];
