import { accountTools } from "./account.js";
import { chamberTools } from "./chambers.js";
import { gameTools } from "./game.js";
import { tradingTools } from "./trading.js";
import { bondingTools } from "./bonding.js";
import { executionTools } from "./execution.js";
import type { ToolDef } from "./_shared.js";

/**
 * The full 19-tool surface.
 *
 *   Account     (4)  register, balance, personality, status
 *   Chambers    (3)  list, create, join
 *   Game        (5)  propose, debate, pass, allocate_commit, allocate_reveal
 *   Trading     (2)  ideas, trade
 *   Bonding     (2)  bond_for, bond_against
 *   Execution   (3)  bounty_create, bounty_claim, bounty_finalize
 *   ──────────────
 *   Total      19
 *
 * `quorum_open_pr` / `quorum_review_pr` from the original spec are
 * intentionally NOT implemented here — they live in the gitlawb MCP server.
 * Agents that need PR ops install both servers side-by-side.
 */
export const allTools: ToolDef[] = [
  ...accountTools,
  ...chamberTools,
  ...gameTools,
  ...tradingTools,
  ...bondingTools,
  ...executionTools,
];

export function toolByName(name: string): ToolDef | undefined {
  return allTools.find((t) => t.name === name);
}
