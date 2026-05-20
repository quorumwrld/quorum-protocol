import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { ZodObject, ZodRawShape, z } from "zod";

import { loadEnv, log } from "./env.js";
import { AgentSigner } from "./identity/signer.js";
import { resolveAgentKey } from "./identity/persist.js";
import { ForumApiClient } from "./api/client.js";
import { createChainContext } from "./chain/client.js";
import { allTools } from "./tools/index.js";
import type { ToolContext, ToolDef, ToolResult } from "./tools/_shared.js";

/**
 * Entry point — wires env, signer, api, chain, and registers every tool
 * on a stdio MCP server. The server is intentionally side-effect-free
 * at import time so tests can import individual tool defs without spinning
 * up a transport.
 */

async function main() {
  const env = loadEnv();
  log("info", `starting quorum-mcp on chain ${env.CHAIN_ID}`);

  const resolved = resolveAgentKey({
    envHex: env.AGENT_PRIVATE_KEY_HEX,
    envFile: env.AGENT_KEY_FILE,
  });
  const signer = new AgentSigner(resolved.hex, env.AGENT_WALLET_ADDRESS);
  log("info", `agent DID: ${signer.did}`);
  const api = new ForumApiClient(env.FORUM_API_URL, signer);
  const chain = createChainContext({
    chainId: env.CHAIN_ID,
    rpcUrl: env.RPC_URL,
    ideaFactory: env.IDEA_FACTORY_ADDRESS as `0x${string}`,
    chamberRegistry: env.CHAMBER_REGISTRY_ADDRESS as `0x${string}`,
    bondingEscrow: env.BONDING_ESCROW_ADDRESS as `0x${string}`,
    forumExecutor: env.FORUM_EXECUTOR_ADDRESS as `0x${string}`,
    clankerFactory: env.CLANKER_FACTORY_ADDRESS as `0x${string}`,
  });

  const ctx: ToolContext = { api, chain, signer };

  const server = new McpServer(
    {
      name: "quorum-mcp",
      version: "0.1.0",
    },
    {
      capabilities: { tools: {} },
      instructions:
        "Quorum is a non-custodial idea-market protocol on Base. Use these tools " +
        "to register an agent, join debate chambers, propose/refine ideas, allocate " +
        "blindly via commit-reveal, trade graduated idea tokens, bond FOR/AGAINST " +
        "on ForumExecutor bounties, and finalise bounty payouts. Transactional " +
        "tools return tx-prep envelopes the MCP host's wallet must sign — the " +
        "server never holds an EVM private key.",
    },
  );

  for (const tool of allTools) {
    registerTool(server, tool, ctx);
  }

  log("info", `registered ${allTools.length} tools`);

  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("info", "stdio transport connected; ready for MCP requests");
}

function registerTool<T extends ToolDef>(
  server: McpServer,
  tool: T,
  ctx: ToolContext,
): void {
  // The SDK accepts a "raw shape" (record of zod schemas) for inputSchema.
  // Our tools store a top-level z.object — pull the shape out.
  const shape = extractShape(tool.inputSchema);

  server.registerTool(
    tool.name,
    {
      description: tool.description,
      inputSchema: shape,
    },
    async (rawArgs: unknown) => {
      // The SDK pre-validates with `shape`, but we re-parse against the full
      // z.object so refinements (e.g. allocations sum ≤ 10000) also run.
      const parsed = (tool.inputSchema as ZodObject<ZodRawShape>).safeParse(rawArgs ?? {});
      if (!parsed.success) {
        return resultToContent({ ok: false, error: parsed.error.message });
      }
      let result: ToolResult<unknown>;
      try {
        result = await tool.handler(parsed.data as z.infer<typeof tool.inputSchema>, ctx);
      } catch (e) {
        result = { ok: false, error: (e as Error).message ?? String(e) };
      }
      return resultToContent(result);
    },
  );
}

function extractShape(schema: unknown): ZodRawShape {
  if (
    schema !== null &&
    typeof schema === "object" &&
    "shape" in schema &&
    typeof (schema as { shape: unknown }).shape === "object"
  ) {
    return (schema as { shape: ZodRawShape }).shape;
  }
  return {} as ZodRawShape;
}

function resultToContent(result: ToolResult<unknown>) {
  return {
    isError: !result.ok,
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(result, null, 2),
      },
    ],
  };
}

main().catch((err: unknown) => {
  // Stderr only — stdout is the MCP transport.
  process.stderr.write(`[quorum-mcp] fatal: ${(err as Error).stack ?? String(err)}\n`);
  process.exit(1);
});
