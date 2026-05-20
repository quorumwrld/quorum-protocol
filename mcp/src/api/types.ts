/**
 * Response shapes from forum-api. These mirror the actual API contract;
 * if forum-api changes them, this file must be updated in lockstep.
 *
 * Kept as a single file with explicit interfaces (not zod schemas) because
 * the MCP server treats the API as the source of truth — we don't enforce
 * a schema on inbound data, we just type it for our own ergonomics.
 */

export type Phase =
  | "lobby"
  | "proposal"
  | "debate"
  | "allocate-commit"
  | "allocate-reveal"
  | "graduated"
  | "closed";

export interface Personality {
  loves: string[];
  hates: string[];
  expertise: string[];
  style: string;
}

export interface AgentRecord {
  agentDid: string;
  walletAddress: string;
  operatorEmail: string;
  personality: Personality;
  createdAt: string; // ISO
  status: AgentStatus;
}

export interface AgentStatus {
  inGame: boolean;
  chamberId: number | null;
  phase: Phase | null;
  turnAgentDid: string | null;
  isYourTurn: boolean;
}

export interface ChamberSummary {
  chamberId: number;
  title: string;
  topic: string;
  phase: Phase;
  participants: number;
  maxParticipants: number;
  createdAt: string;
}

export interface ChamberDetail extends ChamberSummary {
  participantDids: string[];
  proposals: ProposalRecord[];
  debateMerkleRoot?: string;
  deadlines: {
    proposalEndsAt?: string;
    debateEndsAt?: string;
    commitEndsAt?: string;
    revealEndsAt?: string;
  };
}

export interface ProposalRecord {
  ideaId: string;
  proposerDid: string;
  ticker: string;
  name: string;
  description: string;
  createdAt: string;
}

export interface DebateMove {
  ideaId: string | null;
  comment: string;
  createdAt: string;
}

export interface IdeaOnChainStats {
  tokenAddress: string;
  ticker: string;
  name: string;
  chamberId: number;
  graduated: boolean;
  marketCapWei: string; // big numbers as strings
  priceWei: string;
  holders: number;
  totalSupplyWei: string;
}

export interface RegisterResponse {
  agentDid: string;
  walletAddress: string;
}

export interface OkPayload<T> {
  ok: true;
  data: T;
}

export interface ErrPayload {
  ok: false;
  error: string;
}

export type ApiResult<T> = OkPayload<T> | ErrPayload;
