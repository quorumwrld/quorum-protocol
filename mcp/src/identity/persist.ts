/**
 * Persistent agent-key resolver.
 *
 * Resolution order:
 *   1. AGENT_PRIVATE_KEY_HEX env var       (highest — useful for docker / CI)
 *   2. AGENT_KEY_FILE path (or default)    (read + use if present)
 *   3. Generate fresh, save to that path   (created with mode 0600)
 *
 * Why file persistence matters: the agent's did:key is derived deterministically
 * from this private key. Lose the key → new DID → all chamber memberships and
 * historical signatures are orphaned. The default location (~/.quorum/agent.key)
 * makes "install the skill once, keep the same identity forever" the path of
 * least resistance.
 *
 * Cross-protocol interop: did:key:z6Mk... is a vanilla Ed25519 multibase
 * encoding. Whatever Ed25519 private key you give Quorum produces the same DID
 * as Gitlawb (or any other did:key consumer) would. To share an identity:
 *   - Export the 32-byte private key from the other protocol's keystore
 *   - Write `0x<64 hex chars>` to ~/.quorum/agent.key (or point AGENT_KEY_FILE there)
 *
 * Format on disk: a single line of 0x-prefixed 64-character hex. Comments and
 * trailing whitespace are tolerated. We never write any non-key metadata so
 * the file remains drop-in compatible with any other tool that expects a
 * raw hex Ed25519 key.
 */

import { mkdirSync, existsSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { log } from "../env.js";

const DEFAULT_KEY_FILE = ".quorum/agent.key";
const HEX_RE = /^0x[0-9a-fA-F]{64}$/u;

export interface ResolvedKey {
  /** 0x-prefixed 32-byte hex Ed25519 private key. */
  hex: string;
  /** Where the key was resolved from — surfaced in logs to help users understand state. */
  source: "env" | "file" | "generated";
  /** Absolute path of the persisted key file, if any. */
  path?: string;
}

/**
 * Resolve the agent's Ed25519 private key from env, a key file, or freshly generate.
 *
 * Side effects:
 *   - May create the parent directory of the key file (mode 0700).
 *   - May write the key file (mode 0600) if generating.
 *
 * Never logs the key material. Logs the resolution source + (if applicable) path.
 */
export function resolveAgentKey(opts: {
  envHex?: string;
  envFile?: string;
}): ResolvedKey {
  // 1. Env hex wins.
  if (opts.envHex && opts.envHex.length > 0) {
    if (!HEX_RE.test(opts.envHex)) {
      throw new Error(
        "AGENT_PRIVATE_KEY_HEX must be 0x-prefixed 32-byte hex (64 hex chars)",
      );
    }
    log("info", "agent key sourced from AGENT_PRIVATE_KEY_HEX env var");
    return { hex: opts.envHex, source: "env" };
  }

  // 2. File.
  const path = resolveKeyFilePath(opts.envFile);

  if (existsSync(path)) {
    const raw = readFileSync(path, "utf8").trim();
    // Tolerate comments (any line starting with #) + trailing whitespace.
    const hex = raw
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.length > 0 && !l.startsWith("#"))[0];

    if (!hex || !HEX_RE.test(hex)) {
      throw new Error(
        `[quorum-mcp] key file at ${path} does not contain a valid 0x-prefixed 32-byte hex key. ` +
          `Delete the file to regenerate, or replace its contents with a valid key.`,
      );
    }
    log("info", `agent key loaded from ${path}`);
    return { hex, source: "file", path };
  }

  // 3. Generate + persist.
  const fresh = `0x${randomBytes(32).toString("hex")}`;
  ensureParentDir(path);
  writeFileSync(path, `${fresh}\n`, { mode: 0o600 });
  // Belt-and-suspenders: re-chmod in case the FS ignored mode on write.
  try {
    chmodSync(path, 0o600);
  } catch {
    /* non-fatal on filesystems that don't support chmod (e.g. some Windows) */
  }
  log(
    "info",
    `agent key generated and persisted to ${path}. ` +
      `Keep this file safe — it IS your agent's identity.`,
  );
  return { hex: fresh, source: "generated", path };
}

function resolveKeyFilePath(envFile?: string): string {
  if (envFile && envFile.length > 0) {
    // Expand a leading ~ to the user's home dir for ergonomic configs.
    if (envFile.startsWith("~/") || envFile === "~") {
      return resolve(homedir(), envFile.slice(2));
    }
    return resolve(envFile);
  }
  return resolve(homedir(), DEFAULT_KEY_FILE);
}

function ensureParentDir(filePath: string): void {
  const dir = dirname(filePath);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
}
