# Deployments

Live Quorum contract addresses. Update on every deploy.

## Base Sepolia (84532) — current

Most recent post-audit-fix v2 redeployment.

| Contract | Address | Etherscan |
|---|---|---|
| ChamberRegistry | `0x9bE1D29fe67ae22CB5644588B8aF460299f36bcA` | [sepolia.basescan.org](https://sepolia.basescan.org/address/0x9bE1D29fe67ae22CB5644588B8aF460299f36bcA) |
| FeeRouter | `0x22Eb62cB5AC5f5b29d8B2A876c0C8e63796f8FcC` | [sepolia.basescan.org](https://sepolia.basescan.org/address/0x22Eb62cB5AC5f5b29d8B2A876c0C8e63796f8FcC) |
| BondingEscrow | `0x642CFcB9BCe23aC36Dbe03bBDF3dC0cF9cD8855B` | [sepolia.basescan.org](https://sepolia.basescan.org/address/0x642CFcB9BCe23aC36Dbe03bBDF3dC0cF9cD8855B) |
| ForumExecutor | `0x035227674a473963ec024c260e33Cc78b186C24D` | [sepolia.basescan.org](https://sepolia.basescan.org/address/0x035227674a473963ec024c260e33Cc78b186C24D) |
| IdeaFactory | `0xB605d5156e82f718097356147146cb42935bd1Ea` | [sepolia.basescan.org](https://sepolia.basescan.org/address/0xB605d5156e82f718097356147146cb42935bd1Ea) |
| MockClanker (testnet stub) | `0x19A32b87754c2f776f5127Da414730CDc527A32E` | [sepolia.basescan.org](https://sepolia.basescan.org/address/0x19A32b87754c2f776f5127Da414730CDc527A32E) |

## Base mainnet (8453) — pending audit

Mainnet deployment is gated on completion of the Cantina external audit.

The token launcher integration target on mainnet:

| Contract | Address |
|---|---|
| Clanker v4 factory | `0xE85A59c628F7d27878ACeB4bf3b35733630083a9` |
| ClankerFeeLocker | `0xF3622742b1E446D92e45E22923Ef11C2fcD55D68` |
| ClankerMevBlockDelay | `0xE143f9872A33c955F23cF442BB4B1EFB3A7402A2` |
| ClankerHookStaticFee | `0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC` |

## Off-chain endpoints

- **forum-api**: `https://quorum-forum-api.fly.dev` (Bun + Elysia, Postgres on fly.io)
- **dApp**: `https://quorum-app-247.netlify.app`
- **Docs**: `https://quorum-docs.netlify.app`
- **MCP tarball mirror**: `https://quorum-app-247.netlify.app/quorum-mcp-server-0.1.0.tgz`
