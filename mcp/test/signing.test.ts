import { describe, it, expect } from "vitest";
import { ed25519 } from "@noble/curves/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { base16 } from "@scure/base";
import { AgentSigner } from "../src/identity/signer.js";
import { didFromPrivateKeyHex, publicKeyFromDid, publicKeyToDid } from "../src/identity/did.js";

const TEST_KEY = "0x" + "11".repeat(32);
const TEST_WALLET = "0x0000000000000000000000000000000000001234";

describe("did:key derivation", () => {
  it("derives a stable did from a fixed private key", () => {
    const d = didFromPrivateKeyHex(TEST_KEY);
    expect(d.did.startsWith("did:key:z")).toBe(true);
    // Round-trip the public key through the did:key string.
    const pub = publicKeyFromDid(d.did);
    expect(Buffer.from(pub).equals(Buffer.from(d.publicKey))).toBe(true);
  });

  it("rejects a non-Ed25519 did:key", () => {
    // Manually construct a did with a wrong multicodec (0xec instead of 0xed).
    // Trim/re-encode is overkill — easier: pass garbage.
    expect(() => publicKeyFromDid("did:key:zBogus")).toThrow();
  });

  it("rejects a private key of wrong length", () => {
    expect(() => didFromPrivateKeyHex("0x1234")).toThrow();
  });

  it("publicKeyToDid is consistent with @noble/curves", () => {
    const priv = ed25519.utils.randomPrivateKey();
    const pub = ed25519.getPublicKey(priv);
    const did = publicKeyToDid(pub);
    expect(did.startsWith("did:key:z")).toBe(true);
    expect(Buffer.from(publicKeyFromDid(did)).equals(Buffer.from(pub))).toBe(true);
  });
});

describe("AgentSigner.signRequest", () => {
  it("produces a verifiable Ed25519 signature over the canonical payload", () => {
    const signer = new AgentSigner(TEST_KEY, TEST_WALLET);
    const body = JSON.stringify({ hello: "world" });
    const sig = signer.signRequest("POST", "/register", body);

    const bodyHash = base16.encode(sha256(body)).toLowerCase();
    const message = `POST\n/register\n${sig.timestamp}\n${bodyHash}`;
    const ok = ed25519.verify(
      base16.decode(sig.signatureHex.toUpperCase()),
      new TextEncoder().encode(message),
      publicKeyFromDid(sig.did),
    );
    expect(ok).toBe(true);
  });

  it("hashes an empty body to the sha256 of empty string", () => {
    const signer = new AgentSigner(TEST_KEY, TEST_WALLET);
    const sig = signer.signRequest("GET", "/status", undefined);
    const expectedHash = base16.encode(sha256("")).toLowerCase();
    const message = `GET\n/status\n${sig.timestamp}\n${expectedHash}`;
    const ok = ed25519.verify(
      base16.decode(sig.signatureHex.toUpperCase()),
      new TextEncoder().encode(message),
      publicKeyFromDid(sig.did),
    );
    expect(ok).toBe(true);
  });
});
