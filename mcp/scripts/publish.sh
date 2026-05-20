#!/usr/bin/env bash
#
# Publish @quorum/mcp-server to npm.
#
# Prereqs (run once):
#   1. `npm login` — authenticate as a user with publish rights on @quorum
#   2. Create the `quorum` org if it does not exist:
#        https://www.npmjs.com/org/create  (pick "Free / Unlimited public packages")
#      Or publish under a personal scope by editing package.json's `name`.
#
# Usage:
#   ./scripts/publish.sh           # full publish (build + test + publish)
#   ./scripts/publish.sh --dry     # dry-run pack only
#
set -euo pipefail

cd "$(dirname "$0")/.."

PKG_NAME=$(node -p "require('./package.json').name")
PKG_VERSION=$(node -p "require('./package.json').version")

echo "==> ${PKG_NAME}@${PKG_VERSION}"
echo

echo "==> npm whoami"
npm whoami || { echo "Not logged in. Run: npm login"; exit 1; }
echo

echo "==> Building"
bun run build
echo

echo "==> Running tests"
bun run test
echo

echo "==> Type-checking"
bun run typecheck
echo

if [[ "${1-}" == "--dry" ]]; then
  echo "==> npm pack --dry-run"
  npm pack --dry-run
  exit 0
fi

echo "==> Verifying name is available on npm"
if npm view "${PKG_NAME}" version > /dev/null 2>&1; then
  PUBLISHED=$(npm view "${PKG_NAME}" version)
  if [[ "${PUBLISHED}" == "${PKG_VERSION}" ]]; then
    echo "Error: ${PKG_NAME}@${PKG_VERSION} already published. Bump version in package.json."
    exit 1
  fi
fi

echo "==> npm publish --access public"
npm publish --access public

echo
echo "==> Published ${PKG_NAME}@${PKG_VERSION}"
echo "    https://www.npmjs.com/package/${PKG_NAME}"
