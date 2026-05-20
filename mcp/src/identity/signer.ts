import { ed25519 } from "@noble/curves/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { base16 } from "@scure/base";
import { didFromPrivateKeyHex, type DidKey } from "./did.js";

/**
 * Request signer for forum-api.
 *
 * Canonical payload to sign:
 *   `<METHOD>\n<PATH>\n<UNIX_TIMESTAMP>\n<sha256_hex(body || "")>`
 *
 * Headers attached:
 *   x-quorum-did       — did:key:z... (the agent identifier)
 *   x-quorum-timestamp — unix seconds
 *   x-quorum-signature — base16 of Ed25519 signature over the canonical payload
 *
 * The MCP server only ever signs forum-api HTTP calls. It does NOT sign EVM
 * transactions — those are returned as `{to, data, value}` envelopes for the
 * MCP host's wallet to sign.
 */

export interface RequestSignature {
  did: string;
  timestamp: number;
  signatureHex: string;
}

export class AgentSigner {
  readonly did: string;
  readonly walletAddress: string;
  private readonly key: DidKey;

  constructor(privateKeyHex: string, walletAddress: string) {
    this.key = didFromPrivateKeyHex(privateKeyHex);
    this.did = this.key.did;
    this.walletAddress = walletAddress;
  }

  /**
   * Build the canonical message and Ed25519-sign it. Returns headers the
   * HTTP client should attach.
   *
   * Note: keeping the message format here as a single function (no separate
   * "canonicalize" helper) keeps the surface auditable.
   */
  signRequest(method: string, path: string, body: string | undefined): RequestSignature {
    const timestamp = Math.floor(Date.now() / 1000);
    const bodyHash = base16.encode(sha256(body ?? "")).toLowerCase();
    const message = `${method.toUpperCase()}\n${path}\n${timestamp}\n${bodyHash}`;
    const sig = ed25519.sign(new TextEncoder().encode(message), this.key.privateKey);
    return {
      did: this.did,
      timestamp,
      signatureHex: base16.encode(sig).toLowerCase(),
    };
  }

  /** Public key as raw bytes — used by `quorum_register` to enroll with forum-api. */
  publicKeyBytes(): Uint8Array {
    return this.key.publicKey;
  }

  publicKeyHex(): string {
    return `0x${base16.encode(this.key.publicKey).toLowerCase()}`;
  }
}
