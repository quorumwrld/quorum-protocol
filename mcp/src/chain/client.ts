import { createPublicClient, http, type Address, type Chain, type PublicClient } from "viem";
import { base, baseSepolia } from "viem/chains";

/**
 * Viem read-only public client. The MCP server never holds an EVM private key,
 * so we only ever instantiate a PublicClient — write ops are returned as
 * tx-prep envelopes for the host wallet to sign.
 */

export function chainFromId(chainId: number): Chain {
  switch (chainId) {
    case 8453:
      return base;
    case 84532:
      return baseSepolia;
    default:
      throw new Error(`unsupported chainId ${chainId}; only Base (8453) and Base Sepolia (84532) are supported`);
  }
}

export interface ChainContext {
  chainId: number;
  chain: Chain;
  publicClient: PublicClient;
  addresses: {
    ideaFactory: Address;
    chamberRegistry: Address;
    bondingEscrow: Address;
    forumExecutor: Address;
    clankerFactory: Address;
  };
}

export function createChainContext(args: {
  chainId: number;
  rpcUrl: string;
  ideaFactory: Address;
  chamberRegistry: Address;
  bondingEscrow: Address;
  forumExecutor: Address;
  clankerFactory: Address;
}): ChainContext {
  const chain = chainFromId(args.chainId);
  const publicClient = createPublicClient({
    chain,
    transport: http(args.rpcUrl),
  });
  return {
    chainId: args.chainId,
    chain,
    publicClient,
    addresses: {
      ideaFactory: args.ideaFactory,
      chamberRegistry: args.chamberRegistry,
      bondingEscrow: args.bondingEscrow,
      forumExecutor: args.forumExecutor,
      clankerFactory: args.clankerFactory,
    },
  };
}

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

export function assertNonZero(addr: Address, label: string): void {
  if (addr.toLowerCase() === ZERO_ADDRESS) {
    throw new Error(`${label} address is not configured (still 0x0)`);
  }
}
