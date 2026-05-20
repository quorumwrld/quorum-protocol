import { z } from "zod";

/**
 * Strict env parsing — fails loud at startup if a required var is missing.
 * Every var is read from `process.env`; no defaults that would silently
 * mask a misconfigured host.
 *
 * Some vars (contract addresses) are allowed to be the zero address so the
 * server starts in a partially-deployed environment (e.g. local Sepolia where
 * `ForumExecutor` isn't deployed yet). Tools that need a specific address
 * will refuse to run when that address is zero.
 */

const hex32 = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "expected 0x-prefixed 32-byte hex");
const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/, "expected 0x-prefixed EVM address");

const Schema = z.object({
  FORUM_API_URL: z.string().url().default("http://localhost:3000"),

  CHAIN_ID: z.coerce.number().int().refine((v) => v === 8453 || v === 84532, {
    message: "CHAIN_ID must be 8453 (Base mainnet) or 84532 (Base Sepolia)",
  }),
  RPC_URL: z.string().url(),

  // Optional. If set, takes priority over AGENT_KEY_FILE. Useful for docker/CI
  // and for porting a key from another protocol (e.g. Gitlawb) — the same 32-byte
  // Ed25519 private key produces the same did:key across all protocols.
  AGENT_PRIVATE_KEY_HEX: hex32.optional(),

  // Path to a file holding the 32-byte Ed25519 private key as 0x-prefixed hex.
  // If the file does not exist, the server creates it (mode 0600) and persists
  // a freshly-generated key. Defaults to ~/.quorum/agent.key — install once,
  // same DID forever. Point this at your Gitlawb key file to share an identity
  // across protocols (same Ed25519 priv → same did:key).
  AGENT_KEY_FILE: z.string().min(1).optional(),

  AGENT_WALLET_ADDRESS: address,

  IDEA_FACTORY_ADDRESS: address,
  CHAMBER_REGISTRY_ADDRESS: address,
  BONDING_ESCROW_ADDRESS: address,
  FORUM_EXECUTOR_ADDRESS: address,
  CLANKER_FACTORY_ADDRESS: address.default("0xE85A59c628F7d27878ACeB4bf3b35733630083a9"),

  LOG_LEVEL: z.enum(["debug", "info", "warn", "error", "silent"]).default("info"),
});

export type Env = z.infer<typeof Schema>;

let cached: Env | null = null;

export function loadEnv(): Env {
  if (cached) return cached;
  const parsed = Schema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
      .join("\n");
    throw new Error(`[quorum-mcp] invalid env:\n${issues}`);
  }
  cached = parsed.data;
  return cached;
}

/** Lightweight stderr logger — never write logs to stdout (MCP stdio transport reserves it). */
export function log(level: "debug" | "info" | "warn" | "error", msg: string, extra?: unknown) {
  const env = (() => {
    try {
      return loadEnv();
    } catch {
      return { LOG_LEVEL: "info" } as const;
    }
  })();
  const order = { debug: 0, info: 1, warn: 2, error: 3, silent: 4 } as const;
  if (order[level] < order[env.LOG_LEVEL]) return;
  const line = extra === undefined ? msg : `${msg} ${safeStringify(extra)}`;
  process.stderr.write(`[quorum-mcp] ${level.toUpperCase()} ${line}\n`);
}

function safeStringify(v: unknown): string {
  try {
    return typeof v === "string" ? v : JSON.stringify(v);
  } catch {
    return String(v);
  }
}
