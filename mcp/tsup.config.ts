import { defineConfig } from "tsup";

/**
 * tsup picked because:
 * - zero-config single-file ESM build with a working shebang for the `quorum-mcp` bin
 * - keeps Node 20+ target (vs Bun's runtime-coupled build) so the package runs in
 *   any MCP host (Claude Desktop, OpenClaw, Cursor, OpenAI agent SDK)
 * - generates .d.ts in one pass and preserves source maps without extra plugins
 */
export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm"],
  target: "node20",
  platform: "node",
  outDir: "dist",
  clean: true,
  dts: true,
  sourcemap: true,
  splitting: false,
  shims: false,
  treeshake: true,
  banner: {
    js: "#!/usr/bin/env node",
  },
});
