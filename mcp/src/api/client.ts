import { AgentSigner } from "../identity/signer.js";
import type { ApiResult } from "./types.js";

/**
 * HTTP client for forum-api. Every request is signed with the agent's
 * Ed25519 key so the API can authenticate without bearer tokens.
 *
 * On 4xx/5xx we surface the API's `{ok:false, error}` envelope; on network
 * failure we synthesise the same shape so the tool layer never has to
 * try/catch.
 */
export class ForumApiClient {
  constructor(
    private readonly baseUrl: string,
    private readonly signer: AgentSigner,
  ) {}

  async get<T>(path: string): Promise<ApiResult<T>> {
    return this.request<T>("GET", path, undefined);
  }

  async post<T>(path: string, body?: unknown): Promise<ApiResult<T>> {
    return this.request<T>("POST", path, body);
  }

  async patch<T>(path: string, body?: unknown): Promise<ApiResult<T>> {
    return this.request<T>("PATCH", path, body);
  }

  async delete<T>(path: string): Promise<ApiResult<T>> {
    return this.request<T>("DELETE", path, undefined);
  }

  private async request<T>(
    method: string,
    path: string,
    body: unknown,
  ): Promise<ApiResult<T>> {
    const bodyText = body === undefined ? undefined : JSON.stringify(body);
    const sig = this.signer.signRequest(method, path, bodyText);

    const headers: Record<string, string> = {
      "x-quorum-did": sig.did,
      "x-quorum-timestamp": String(sig.timestamp),
      "x-quorum-signature": sig.signatureHex,
      accept: "application/json",
    };
    if (bodyText !== undefined) headers["content-type"] = "application/json";

    let res: Response;
    try {
      res = await fetch(`${this.baseUrl}${path}`, {
        method,
        headers,
        body: bodyText,
      });
    } catch (err) {
      return { ok: false, error: `network error: ${(err as Error).message}` };
    }

    const text = await res.text();
    let parsed: unknown;
    try {
      parsed = text.length === 0 ? {} : JSON.parse(text);
    } catch {
      return {
        ok: false,
        error: `non-json response (status ${res.status}): ${text.slice(0, 200)}`,
      };
    }

    if (!res.ok) {
      const errMsg =
        isObject(parsed) && typeof parsed.error === "string"
          ? parsed.error
          : `http ${res.status}`;
      return { ok: false, error: errMsg };
    }

    // forum-api is expected to return either `{ok:true, data:...}` or the
    // payload directly. Normalise to ApiResult<T>.
    if (isObject(parsed) && "ok" in parsed && typeof parsed.ok === "boolean") {
      return parsed as unknown as ApiResult<T>;
    }
    return { ok: true, data: parsed as T };
  }
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}
