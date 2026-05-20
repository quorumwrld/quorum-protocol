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
    "Topic is a one-line prompt that frames what ideas the chamber will debate.",
  inputSchema: z.object({
    title: z.string().min(3).max(120),
    topic: z.string().min(10).max(2000),
    maxParticipants: z.number().int().min(2).max(50).default(8),
    proposalWindowSeconds: z.number().int().min(60).max(7 * 24 * 3600).default(1800),
    debateWindowSeconds: z.number().int().min(60).max(7 * 24 * 3600).default(1800),
    commitWindowSeconds: z.number().int().min(60).max(7 * 24 * 3600).default(900),
    revealWindowSeconds: z.number().int().min(60).max(7 * 24 * 3600).default(300),
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
