import { ed25519 } from "@noble/curves/ed25519";
import { base58, base16 } from "@scure/base";

/**
 * did:key derivation for Ed25519 public keys, per the W3C did-key spec
 * (https://w3c-ccg.github.io/did-method-key/). Multicodec prefix for
 * Ed25519 public key is 0xed 0x01.
 *
 * We keep the surface tiny: derive a did:key string from a private key,
 * verify a key matches a did, that's it. Forum-api uses the same scheme.
 */

const ED25519_PUB_MULTICODEC = new Uint8Array([0xed, 0x01]);

export interface DidKey {
  /** `did:key:z...` — the agent's public identifier. */
  did: string;
  /** 32-byte Ed25519 public key */
  publicKey: Uint8Array;
  /** 32-byte Ed25519 private key (held only in process memory) */
  privateKey: Uint8Array;
}

/** Strip optional 0x prefix and decode hex bytes. */
function hexToBytes(hex: string): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (clean.length % 2 !== 0) throw new Error("hex string must have even length");
  return base16.decode(clean.toUpperCase());
}

export function bytesToHex(bytes: Uint8Array): string {
  return `0x${base16.encode(bytes).toLowerCase()}`;
}

/** Concatenate two Uint8Arrays into a fresh buffer. */
function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/** Derive the did:key form of an Ed25519 public key. */
export function publicKeyToDid(publicKey: Uint8Array): string {
  if (publicKey.length !== 32) throw new Error("ed25519 public key must be 32 bytes");
  const multicodec = concat(ED25519_PUB_MULTICODEC, publicKey);
  // did:key multibase: `z` prefix => base58btc
  return `did:key:z${base58.encode(multicodec)}`;
}

/**
 * Parse a private key hex string (with or without `0x`) into a full DidKey
 * record. Caller is responsible for keeping the buffer in memory only.
 */
export function didFromPrivateKeyHex(hex: string): DidKey {
  const privateKey = hexToBytes(hex);
  if (privateKey.length !== 32) {
    throw new Error(`ed25519 private key must be 32 bytes, got ${privateKey.length}`);
  }
  const publicKey = ed25519.getPublicKey(privateKey);
  const did = publicKeyToDid(publicKey);
  return { did, publicKey, privateKey };
}

/** Decode the public key bytes out of a `did:key:z...` string. */
export function publicKeyFromDid(did: string): Uint8Array {
  const prefix = "did:key:z";
  if (!did.startsWith(prefix)) throw new Error(`not a did:key: ${did}`);
  const decoded = base58.decode(did.slice(prefix.length));
  if (decoded.length < 3) throw new Error("did:key payload too short");
  if (decoded[0] !== ED25519_PUB_MULTICODEC[0] || decoded[1] !== ED25519_PUB_MULTICODEC[1]) {
    throw new Error("did:key is not Ed25519");
  }
  return decoded.slice(2);
}
