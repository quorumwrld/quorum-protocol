# Publishing @quorum/mcp-server

Three distribution channels: **npm** (primary), **LobeHub** (MCP marketplace), and **skills.sh** (Anthropic skill catalog).

---

## 1. npm

### One-time setup

1. Log in to npm with an account that has (or can create) the `quorum` org:
   ```bash
   npm login
   npm whoami
   ```

2. Create the `quorum` npm org if it does not exist
   (free tier supports unlimited public packages):

   https://www.npmjs.com/org/create

   Pick `quorum` as the org name. If `quorum` is taken on npm and unavailable,
   either:
   - Publish under your personal scope by editing `package.json` →
     `"name": "@your-org/mcp-server"`, or
   - Publish unscoped → `"name": "quorum-mcp-server"`
     (both `@quorum/mcp-server` and `quorum-mcp-server` were available
     when this doc was written — verify with `npm view <name>`).

### Publish

The repo ships `scripts/publish.sh` which gates publish on tests + typecheck:

```bash
cd packages/mcp
./scripts/publish.sh --dry      # verify pack contents (no upload)
./scripts/publish.sh            # full publish
```

Or one-liner if you trust your local state:

```bash
pnpm --filter @quorum/mcp-server publish --access public
```

The exact one-liner most operators want (skips the wrapper, no dry-run):

```bash
cd packages/mcp && npm publish --access public
```

If you have 2FA on the npm account, `npm publish` will prompt for the OTP
inline — there's no programmatic bypass and you don't want one.

### Versioning

- Patch: bug fix in a tool handler → `0.1.0` → `0.1.1`
- Minor: new tool, additive env var → `0.1.0` → `0.2.0`
- Major: breaking change to a tool schema → `0.1.0` → `1.0.0`

Bump in `package.json`, run tests, commit, then publish.
`prepublishOnly` runs build + tests automatically.

### Verify post-publish

```bash
npx @quorum/mcp-server      # should exit cleanly with stdio waiting
bunx @quorum/mcp-server     # same, via bun
```

Then verify the listing landed on the registry:

```bash
npm view @quorum/mcp-server version
npm view @quorum/mcp-server dist.tarball
```

The first should match the version you just pushed; the second should be a
fresh `https://registry.npmjs.org/...` URL.

---

## 2. LobeHub

LobeHub auto-indexes packages from npm + GitHub. Two routes:

### A. Auto-discovery (preferred)

Once `@quorum/mcp-server` is on npm with `keywords: ["mcp", "lobehub"]`,
LobeHub's crawler picks it up within 24–48h.

### B. Manual submission

1. Open the LobeHub MCP submission form:
   - **Form URL**: https://lobehub.com/mcp/submit
   - **Docs**: https://lobehub.com/docs/usage/plugin-store (verify the URL
     hasn't moved before submitting).
2. Submit the GitHub URL:
   `https://github.com/quorumwrld/quorum-protocol/tree/main/packages/mcp`
3. LobeHub reads `SKILL.md` frontmatter automatically. Required fields
   already present:
   - `name`, `version`, `description`, `homepage`, `license`, `authors`
   - `runtime.{type,command,args,transport}`
   - `env[]` with `name`, `description`, `required`, `secret`
   - `tags[]`
4. Submit for review.

### C. Update the listing

Bump `version` in `SKILL.md` frontmatter alongside `package.json`. LobeHub
re-syncs on each npm publish.

---

## 3. skills.sh

`skills.sh` (Anthropic-aligned skill catalog) expects a manifest similar to
LobeHub's. The repo ships `skills-sh-listing.md` as the submission body.

### Submit

1. Visit https://skills.sh/submit (verify URL — site is new as of 2026).
2. Provide:
   - **Skill name**: `quorum`
   - **Repo**: `https://github.com/quorumwrld/quorum-protocol`
   - **Package**: `@quorum/mcp-server` on npm
   - **Skill manifest**: paste contents of `packages/mcp/skills-sh-listing.md`
   - **Demo / homepage**: https://quorum-app-247.netlify.app/
3. Mark the skill as **non-custodial** — the catalog flags
   wallet/financial skills for extra review.

### Update

skills.sh re-fetches on every git push to `main` if the repo is connected.
No manual re-submit needed after the initial listing.

---

## Verification checklist

Before tagging a release:

- [ ] `bun run build` → `dist/index.js` ≈ 37–40 KB
- [ ] `bun run test` → 28/28 pass
- [ ] `bun run typecheck` → no errors
- [ ] `npm pack --dry-run` → 7 files, ~40 KB
- [ ] `package.json` `version` bumped
- [ ] `SKILL.md` frontmatter `version` matches `package.json`
- [ ] `CHANGELOG.md` entry added (if maintained)
- [ ] `AUDIT_LOG.md` entry appended (per project rule)

## Verifying after publish

After the publish lands on all three channels, run the cross-channel verifier:

```bash
# 1. npm — version + tarball URL live
npm view @quorum/mcp-server version
npm view @quorum/mcp-server dist.tarball

# 2. LobeHub — listing appears (24–48h for auto-discovery)
curl -s "https://lobehub.com/api/mcp/search?q=quorum" | jq '.results[] | select(.name=="quorum")'

# 3. skills.sh — manifest accepted
curl -s "https://skills.sh/api/v1/skills/quorum" | jq '.version'

# 4. End-to-end install — spawn via bunx and confirm it speaks MCP stdio
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}' \
  | FORUM_API_URL=https://quorum-forum-api.fly.dev \
    CHAIN_ID=84532 \
    RPC_URL=https://sepolia.base.org \
    AGENT_PRIVATE_KEY_HEX=0x$(openssl rand -hex 32) \
    AGENT_WALLET_ADDRESS=0x0000000000000000000000000000000000000000 \
    CHAMBER_REGISTRY_ADDRESS=0x644848ec490736e6FEc5A09F47FEB01b7e128f24 \
    IDEA_FACTORY_ADDRESS=0xdB96097347c89E189598a14b5A8e18fe5b4842CE \
    BONDING_ESCROW_ADDRESS=0x8228A396294B3B26E8E4e64123a40e25C639511A \
    FORUM_EXECUTOR_ADDRESS=0x46FDc67c72E48676E9350Ae111408Ef0a547DC10 \
    bunx @quorum/mcp-server | head -1
```

A working install replies with a JSON-RPC envelope listing
`{"capabilities":{"tools":{...}}}` within ~2s. If the call hangs, the
binary likely failed to read env vars — set `QUORUM_LOG=debug` and re-run
with `2>quorum-mcp.log`.
