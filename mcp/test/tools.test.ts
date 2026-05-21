import { describe, it, expect, vi, beforeEach } from "vitest";
import { keccak256, encodeAbiParameters, toHex } from "viem";
import { AgentSigner } from "../src/identity/signer.js";
import { ForumApiClient } from "../src/api/client.js";
import type { ToolContext } from "../src/tools/_shared.js";
import { quorum_register, quorum_balance, quorum_status } from "../src/tools/account.js";
import {
  quorum_chambers_list,
  quorum_chamber_create,
  quorum_chamber_join,
} from "../src/tools/chambers.js";
import {
  quorum_propose,
  quorum_debate,
  quorum_pass,
  quorum_allocate_commit,
  quorum_allocate_reveal,
} from "../src/tools/game.js";
import { quorum_ideas, quorum_trade } from "../src/tools/trading.js";
import { quorum_bond_for, quorum_bond_against } from "../src/tools/bonding.js";
import {
  quorum_bounty_create,
  quorum_bounty_claim,
  quorum_bounty_finalize,
} from "../src/tools/execution.js";
import { allTools } from "../src/tools/index.js";

const TEST_KEY = "0x" + "22".repeat(32);
const TEST_WALLET = "0x000000000000000000000000000000000000beef";

function makeContext(overrides: Partial<ToolContext> = {}): ToolContext {
  const signer = new AgentSigner(TEST_KEY, TEST_WALLET);
  const fakeApi = new ForumApiClient("http://localhost:9999", signer);
  return {
    signer,
    api: fakeApi,
    chain: {
      chainId: 84532,
      // unused unless the tool reads the chain; concrete ones override
      chain: {} as never,
      publicClient: {} as never,
      addresses: {
        ideaFactory: "0xaa00000000000000000000000000000000000001",
        chamberRegistry: "0xaa00000000000000000000000000000000000002",
        bondingEscrow: "0xaa00000000000000000000000000000000000003",
        forumExecutor: "0xaa00000000000000000000000000000000000004",
        clankerFactory: "0xE85A59c628F7d27878ACeB4bf3b35733630083a9",
      },
    },
    ...overrides,
  };
}

describe("tool registry", () => {
  it("exposes exactly 19 tools", () => {
    expect(allTools).toHaveLength(19);
  });

  it("every tool name is unique and prefixed with quorum_", () => {
    const names = allTools.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
    for (const n of names) expect(n.startsWith("quorum_")).toBe(true);
  });

  it("the 19 tools cover account + chambers + game + trading + bonding + execution", () => {
    const expected = [
      // account
      "quorum_register",
      "quorum_balance",
      "quorum_personality",
      "quorum_status",
      // chambers
      "quorum_chambers_list",
      "quorum_chamber_create",
      "quorum_chamber_join",
      // game
      "quorum_propose",
      "quorum_debate",
      "quorum_pass",
      "quorum_allocate_commit",
      "quorum_allocate_reveal",
      // trading
      "quorum_ideas",
      "quorum_trade",
      // bonding
      "quorum_bond_for",
      "quorum_bond_against",
      // execution
      "quorum_bounty_create",
      "quorum_bounty_claim",
      "quorum_bounty_finalize",
    ];
    const got = allTools.map((t) => t.name).sort();
    expect(got).toEqual(expected.sort());
  });
});

describe("account tools (api-mocked)", () => {
  let ctx: ToolContext;
  beforeEach(() => {
    ctx = makeContext();
  });

  it("quorum_register forwards the agent did + wallet + email", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({ agentDid: ctx.signer.did, walletAddress: TEST_WALLET }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const res = await quorum_register.handler(
      {
        operatorEmail: "hello@quorumwrld.com",
        personality: { loves: ["base"], hates: ["mev"], expertise: ["defi"], style: "blunt" },
      },
      ctx,
    );
    expect(res.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0]!;
    const body = JSON.parse((init as RequestInit).body as string);
    expect(body.agentDid).toBe(ctx.signer.did);
    expect(body.walletAddress).toBe(TEST_WALLET);
    expect(body.operatorEmail).toBe("hello@quorumwrld.com");
    // Signature headers
    const headers = (init as RequestInit).headers as Record<string, string>;
    expect(headers["x-quorum-did"]).toBe(ctx.signer.did);
    expect(headers["x-quorum-signature"]).toMatch(/^[0-9a-f]{128}$/);
  });

  it("quorum_balance reads via viem", async () => {
    const fakeClient = { getBalance: vi.fn().mockResolvedValue(1234567890123456789n) };
    const c = makeContext({
      chain: {
        ...makeContext().chain,
        publicClient: fakeClient as never,
      },
    });
    const res = await quorum_balance.handler({}, c);
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.address).toBe(TEST_WALLET);
      expect(res.data.balanceWei).toBe("1234567890123456789");
      expect(res.data.balanceEth).toBe("1.234567890123456789");
    }
  });

  it("quorum_status maps api errors", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: "not enrolled" }), {
        status: 404,
        headers: { "content-type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const res = await quorum_status.handler({}, ctx);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.error).toContain("not enrolled");
  });
});

describe("chamber tools", () => {
  it("quorum_chambers_list passes phase filter", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response(JSON.stringify([]), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const ctx = makeContext();
    await quorum_chambers_list.handler({ phase: "debate", limit: 10 }, ctx);
    const url = fetchMock.mock.calls[0]![0] as string;
    expect(url).toContain("phase=debate");
    expect(url).toContain("limit=10");
  });

  it("quorum_chamber_create posts the full config", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response(JSON.stringify({ chamberId: 7 }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const ctx = makeContext();
    const res = await quorum_chamber_create.handler(
      {
        title: "Lending on Base",
        topic: "Should we ship a curve-stETH-style stableswap?",
        maxParticipants: 8,
        proposalWindowSeconds: 1800,
        debateWindowSeconds: 1800,
        commitWindowSeconds: 900,
        revealWindowSeconds: 300,
      },
      ctx,
    );
    expect(res.ok).toBe(true);
  });

  it("quorum_chamber_join hits the right path", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await quorum_chamber_join.handler({ chamberId: 42 }, makeContext());
    expect((fetchMock.mock.calls[0]![0] as string).endsWith("/chambers/42/join")).toBe(true);
  });
});

describe("game tools — commit-reveal math", () => {
  it("quorum_allocate_commit computes the on-chain-compatible hash", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ commitment: "", recordedAt: "2026-05-18T00:00:00Z" }), {
        status: 200,
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const ctx = makeContext();
    const salt = ("0x" + "ab".repeat(32)) as `0x${string}`;
    const allocations = [
      { ideaId: "idea-1", bps: 4000 },
      { ideaId: "idea-2", bps: 6000 },
    ];

    const res = await quorum_allocate_commit.handler(
      { chamberId: 1, allocations, salt },
      ctx,
    );
    expect(res.ok).toBe(true);

    if (res.ok) {
      const expectedEncoded = encodeAbiParameters(
        [
          {
            type: "tuple[]",
            components: [
              { name: "ideaIdHash", type: "bytes32" },
              { name: "bps", type: "uint16" },
            ],
          },
          { name: "salt", type: "bytes32" },
        ],
        [
          allocations.map((a) => ({ ideaIdHash: keccak256(toHex(a.ideaId)), bps: a.bps })),
          salt,
        ],
      );
      expect(res.data.commitment).toBe(keccak256(expectedEncoded));
      expect(res.data.salt).toBe(salt);
    }
  });

  it("rejects allocations summing past 10000 bps", async () => {
    const ctx = makeContext();
    // The refine fires inside the schema, but the handler's own zod parse runs only at
    // registration. Validate by calling the schema directly.
    const result = quorum_allocate_commit.inputSchema.safeParse({
      chamberId: 1,
      allocations: [
        { ideaId: "x", bps: 7000 },
        { ideaId: "y", bps: 4000 },
      ],
    });
    expect(result.success).toBe(false);
  });

  it("quorum_propose validates ticker shape", () => {
    expect(
      quorum_propose.inputSchema.safeParse({
        chamberId: 1,
        name: "Idea",
        ticker: "lowercase",
        description: "long enough description",
      }).success,
    ).toBe(false);
    expect(
      quorum_propose.inputSchema.safeParse({
        chamberId: 1,
        name: "Idea",
        ticker: "ABC",
        description: "long enough description",
      }).success,
    ).toBe(true);
  });

  it("quorum_debate + quorum_pass + quorum_allocate_reveal accept their schemas", () => {
    expect(
      quorum_debate.inputSchema.safeParse({ chamberId: 1, comment: "hi" }).success,
    ).toBe(true);
    expect(quorum_pass.inputSchema.safeParse({ chamberId: 1 }).success).toBe(true);
    expect(
      quorum_allocate_reveal.inputSchema.safeParse({
        chamberId: 1,
        allocations: [{ ideaId: "x", bps: 100 }],
        salt: "0x" + "00".repeat(32),
      }).success,
    ).toBe(true);
  });
});

describe("trading tools", () => {
  it("quorum_trade refuses zero amount", async () => {
    const ctx = makeContext();
    const res = await quorum_trade.handler(
      {
        ideaToken: "0x1111111111111111111111111111111111111111",
        side: "buy",
        amountInWei: "0",
        slippageBps: 100,
      },
      ctx,
    );
    expect(res.ok).toBe(false);
  });

  it("quorum_trade returns a trade-intent envelope", async () => {
    const fakeClient = { readContract: vi.fn().mockResolvedValue(18) };
    const ctx = makeContext({
      chain: { ...makeContext().chain, publicClient: fakeClient as never },
    });
    const res = await quorum_trade.handler(
      {
        ideaToken: "0x1111111111111111111111111111111111111111",
        side: "buy",
        amountInWei: "1000000000000000000",
        slippageBps: 100,
      },
      ctx,
    );
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.kind).toBe("trade-intent");
      expect(res.data.tokenIn.toLowerCase()).toBe("0x4200000000000000000000000000000000000006");
      expect(res.data.tokenOut.toLowerCase()).toBe("0x1111111111111111111111111111111111111111");
    }
  });

  it("quorum_ideas surfaces api error", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(
        new Response(JSON.stringify({ error: "boom" }), { status: 500 }),
      );
    vi.stubGlobal("fetch", fetchMock);
    const res = await quorum_ideas.handler({ onlyGraduated: true, limit: 25 }, makeContext());
    expect(res.ok).toBe(false);
  });
});

describe("bonding tools", () => {
  it("quorum_bond_for emits approve + bondFor when allowance is low", async () => {
    const ctx = makeContext({
      chain: {
        ...makeContext().chain,
        publicClient: {
          readContract: vi
            .fn()
            // first read: getBounty → returns ideaToken
            .mockResolvedValueOnce({ ideaToken: "0x2222222222222222222222222222222222222222" })
            // second read: allowance → 0
            .mockResolvedValueOnce(0n),
        } as never,
      },
    });
    const res = await quorum_bond_for.handler(
      { bountyId: "5", amount: "1000000000000000000" },
      ctx,
    );
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.transactions).toHaveLength(2);
      expect(res.data.transactions[0]!.description).toContain("Approve");
      expect(res.data.transactions[1]!.description).toContain("Bond FOR");
    }
  });

  it("quorum_bond_against skips approve when allowance is sufficient", async () => {
    const ctx = makeContext({
      chain: {
        ...makeContext().chain,
        publicClient: {
          readContract: vi
            .fn()
            .mockResolvedValueOnce({ ideaToken: "0x3333333333333333333333333333333333333333" })
            .mockResolvedValueOnce(10n ** 30n),
        } as never,
      },
    });
    const res = await quorum_bond_against.handler(
      { bountyId: 7, amount: 123n.toString() },
      ctx,
    );
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.transactions).toHaveLength(1);
      expect(res.data.transactions[0]!.description).toContain("Bond AGAINST");
    }
  });

  it("quorum_bond_for refuses zero address bondingEscrow", async () => {
    const ctx = makeContext({
      chain: {
        ...makeContext().chain,
        addresses: {
          ...makeContext().chain.addresses,
          bondingEscrow: "0x0000000000000000000000000000000000000000",
        },
      },
    });
    const res = await quorum_bond_for.handler({ bountyId: 1, amount: 1 }, ctx);
    expect(res.ok).toBe(false);
  });
});

describe("execution tools", () => {
  it("quorum_bounty_create emits approve + createBounty when allowance is low", async () => {
    const ctx = makeContext({
      chain: {
        ...makeContext().chain,
        publicClient: {
          readContract: vi.fn().mockResolvedValueOnce(0n),
        } as never,
      },
    });
    const res = await quorum_bounty_create.handler(
      {
        token: "0x4444444444444444444444444444444444444444",
        amount: "1000",
        repoOwner: "quorumwrld",
        repoName: "xlabs",
        issueId: "42",
        title: "Add MEV protection",
      },
      ctx,
    );
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.transactions).toHaveLength(2);
      expect(res.data.transactions[1]!.description).toContain("Create bounty");
    }
  });

  it("quorum_bounty_claim defaults to the agent's own did", async () => {
    const ctx = makeContext();
    const res = await quorum_bounty_claim.handler({ bountyId: 9 }, ctx);
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.agentDid).toBe(ctx.signer.did);
      expect(res.data.transactions[0]!.description).toContain("Claim bounty #9");
    }
  });

  it("quorum_bounty_finalize returns a finalize envelope", async () => {
    const ctx = makeContext();
    const res = await quorum_bounty_finalize.handler({ bountyId: 11 }, ctx);
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data.transactions[0]!.description).toContain("Finalize bounty #11");
    }
  });
});
