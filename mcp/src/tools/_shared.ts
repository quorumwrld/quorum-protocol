import { z } from "zod";
import type { ForumApiClient } from "../api/client.js";
import type { ChainContext } from "../chain/client.js";
import type { AgentSigner } from "../identity/signer.js";

/**
 * Shared types + helpers for tool definitions.
 *
 * Every tool returns a uniform shape:
 *   { ok: true, data: ... } | { ok: false, error: string }
 *
 * The MCP host sees this in the `content[0].text` JSON. We never throw out
 * of a tool handler — failures are mapped into `{ok:false}` so the agent
 * can reason about them.
 */

export interface ToolContext {
  api: ForumApiClient;
  chain: ChainContext;
  signer: AgentSigner;
}

export interface ToolResultOk<T> {
  ok: true;
  data: T;
}
export interface ToolResultErr {
  ok: false;
  error: string;
}
export type ToolResult<T> = ToolResultOk<T> | ToolResultErr;

export function ok<T>(data: T): ToolResultOk<T> {
  return { ok: true, data };
}

export function err(message: string): ToolResultErr {
  return { ok: false, error: message };
}

/**
 * A tool definition mirrors the @modelcontextprotocol/sdk shape but keeps
 * the input schema as zod so we can derive types AND emit JSON Schema for
 * the MCP `tools/list` response.
 *
 * `inputSchema` is typed as the base `z.ZodTypeAny` rather than the precise
 * literal shape to keep the collected `allTools` array assignable. Per-tool
 * handlers still get a fully-typed input via `z.infer` when defined inline.
 */
export interface ToolDef<TInput extends z.ZodTypeAny = z.ZodTypeAny, TOutput = unknown> {
  name: string;
  description: string;
  inputSchema: TInput;
  handler: (input: z.infer<TInput>, ctx: ToolContext) => Promise<ToolResult<TOutput>>;
}

export function defineTool<TInput extends z.ZodTypeAny, TOutput>(
  def: ToolDef<TInput, TOutput>,
): ToolDef<z.ZodTypeAny, TOutput> {
  return def as unknown as ToolDef<z.ZodTypeAny, TOutput>;
}

/** Wrap a possibly-throwing handler so it surfaces as `{ok:false, error}`. */
export async function safe<T>(fn: () => Promise<ToolResult<T>>): Promise<ToolResult<T>> {
  try {
    return await fn();
  } catch (e) {
    return err((e as Error).message ?? String(e));
  }
}

/** Coerce a bigint-able input (string, number, bigint) to bigint. */
export function toBigInt(v: string | number | bigint): bigint {
  if (typeof v === "bigint") return v;
  if (typeof v === "number") return BigInt(v);
  return BigInt(v);
}
