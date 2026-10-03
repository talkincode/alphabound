/**
 * Built-in OAuth 2.1 authorization server for a single operator.
 *
 * AlphaBound has one human owner, so approving a client means proving possession of
 * the AlphaBound API token on a consent page — the same secret the Dashboard login
 * takes. The MCP gateway is both authorization server and resource server; its access
 * tokens are valid for exactly one audience (the gateway's own /mcp), so there is no
 * token passthrough: the upstream daemon is always called with the gateway's own token.
 *
 * The SDK's router supplies discovery metadata, dynamic client registration, PKCE S256
 * and client authentication; this class supplies storage, consent and token policy.
 */
import {
  InvalidClientMetadataError,
  InvalidGrantError,
  InvalidTargetError,
  InvalidTokenError,
  TemporarilyUnavailableError,
} from "@modelcontextprotocol/sdk/server/auth/errors.js";
import { randomToken, safeEqual } from "../secret.js";
import { PAGE_HEADERS, renderConsent, renderMessage } from "./consent.js";
import { ACCESS_TTL_MS, CODE_TTL_MS, PENDING_TTL_MS } from "./store.js";

const LOOPBACK = new Set(["localhost", "127.0.0.1", "[::1]"]);
const FORBIDDEN_SCHEMES = new Set([
  "javascript:",
  "data:",
  "vbscript:",
  "file:",
  "blob:",
  "about:",
  "ftp:",
  "ws:",
  "wss:",
]);

/**
 * Where an authorization code may be sent: https anywhere, http on loopback only, and
 * private-use schemes for native apps such as cursor:// (RFC 8252 §7.1). No fragments.
 * The consent page prints the URI verbatim so the operator can spot a stranger.
 */
export function isAllowedRedirectUri(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (raw.includes("#") || u.username || u.password) return false;
  if (u.protocol === "https:") return true;
  if (u.protocol === "http:") return LOOPBACK.has(u.hostname);
  return !FORBIDDEN_SCHEMES.has(u.protocol);
}

/** Self-reported and shown to the operator: drop control/format characters (bidi spoofing, log injection). */
const cleanName = (s) =>
  String(s ?? "")
    .replace(/[\p{Cc}\p{Cf}]/gu, " ")
    .trim()
    .slice(0, 80) || "Unnamed client";

const trimSlash = (s) => String(s).replace(/\/+$/, "");

function redirectWith(uri, params) {
  const u = new URL(uri);
  for (const [k, v] of Object.entries(params)) if (v !== undefined) u.searchParams.set(k, v);
  return u.href;
}

export class OperatorOAuthProvider {
  /**
   * @param store          OAuthStore
   * @param resourceUrl    URL of the MCP endpoint these tokens are for
   * @param operatorToken  the AlphaBound API token; approves clients on the consent page
   * @param limiter        FailLimiter guarding the consent form
   */
  constructor({ store, resourceUrl, operatorToken, limiter, log = () => {} }) {
    this.store = store;
    this.resourceUrl = resourceUrl;
    this.operatorToken = operatorToken;
    this.limiter = limiter;
    this.log = log;
    this.clientsStore = {
      getClient: (id) => this.store.clients.get(id),
      registerClient: (info) => this.#register(info),
    };
  }

  /**
   * RFC 8707: a `resource` naming anything but this server is refused. A missing one is
   * fine — every token issued here is bound to this server regardless.
   */
  #checkResource(resource) {
    if (!resource) return;
    const r = trimSlash(resource.href);
    if (r !== trimSlash(this.resourceUrl.href) && r !== trimSlash(this.resourceUrl.origin)) {
      throw new InvalidTargetError("resource does not identify this MCP server");
    }
  }

  // --- dynamic client registration (RFC 7591) --------------------------------

  /** Public, PKCE-only clients: no client secret is ever issued or stored. */
  #register(info) {
    const uris = info.redirect_uris;
    if (uris.length < 1 || uris.length > 10) {
      throw new InvalidClientMetadataError("redirect_uris: provide 1 to 10 URIs");
    }
    if (!uris.every(isAllowedRedirectUri)) {
      throw new InvalidClientMetadataError(
        "redirect_uris: use https, http on loopback, or a private-use app scheme, without fragments",
      );
    }
    const client = {
      client_id: info.client_id,
      client_id_issued_at: info.client_id_issued_at,
      client_name: cleanName(info.client_name),
      redirect_uris: uris,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
    };
    if (!this.store.addClient(client)) {
      // Every slot is held by an approved client; never push one of those out for an anonymous caller.
      throw new TemporarilyUnavailableError("Too many registered clients; try again later");
    }
    return client;
  }

  // --- authorization endpoint: consent page ----------------------------------

  async authorize(client, params, res) {
    this.#checkResource(params.resource);
    const requestId = randomToken();
    this.store.putPending(requestId, {
      client_id: client.client_id,
      redirect_uri: params.redirectUri,
      state: params.state,
      code_challenge: params.codeChallenge,
      exp: this.store.now() + PENDING_TTL_MS,
    });
    res
      .status(200)
      .set(PAGE_HEADERS)
      .type("html")
      .send(renderConsent({ requestId, clientName: client.client_name, redirectUri: params.redirectUri }));
  }

  /** POST target of the consent form (express.urlencoded already ran). */
  consent = async (req, res) => {
    res.set(PAGE_HEADERS);
    const html = (status, body) => res.status(status).type("html").send(body);
    const body = req.body ?? {};
    const id = body.request_id;
    const pending = typeof id === "string" ? this.store.pending.get(id) : undefined;
    const client = pending && this.store.clients.get(pending.client_id);
    if (!pending || !client || pending.exp <= this.store.now()) {
      return html(
        400,
        renderMessage("Request expired", "This authorization request is unknown or has expired. Start again from your MCP client."),
      );
    }

    if (body.decision === "deny") {
      this.store.pending.delete(id);
      return res.redirect(
        302,
        redirectWith(pending.redirect_uri, {
          error: "access_denied",
          error_description: "The operator denied the request",
          state: pending.state,
        }),
      );
    }
    if (body.decision !== "approve") return html(400, renderMessage("Bad request", "Choose Approve or Deny."));

    const key = req.ip || "unknown";
    const wait = this.limiter.gate(key);
    if (wait) {
      res.set("Retry-After", String(wait));
      return html(429, renderMessage("Too many attempts", `Try again in ${wait} seconds.`));
    }
    if (!safeEqual(body.token, this.operatorToken)) {
      this.limiter.fail(key);
      this.log("oauth: consent refused (wrong token)");
      return html(
        401,
        renderConsent({
          requestId: id,
          clientName: client.client_name,
          redirectUri: pending.redirect_uri,
          error: "That token was not accepted.",
        }),
      );
    }
    this.limiter.clear(key);
    this.store.pending.delete(id);

    const code = randomToken("abmcp_ac_");
    this.store.putCode(code, {
      client_id: client.client_id,
      redirect_uri: pending.redirect_uri,
      code_challenge: pending.code_challenge,
      state: "issued",
      exp: this.store.now() + CODE_TTL_MS,
    });
    this.log(`oauth: approved "${client.client_name}" (redirect host ${new URL(pending.redirect_uri).host || "app link"})`);
    return res.redirect(302, redirectWith(pending.redirect_uri, { code, state: pending.state }));
  };

  // --- token endpoint ---------------------------------------------------------

  /**
   * The SDK checks PKCE against this value. A code gets one attempt: whether the check
   * passes or not, presenting it again burns it (and revokes what it already produced).
   */
  async challengeForAuthorizationCode(client, code) {
    const rec = this.store.codes.get(code);
    if (!rec || rec.exp <= this.store.now() || rec.client_id !== client.client_id) {
      throw new InvalidGrantError("Invalid or expired authorization code");
    }
    if (rec.state !== "issued") {
      this.store.codes.delete(code);
      if (rec.grant_id) this.store.revokeGrant(rec.grant_id); // RFC 6749 §4.1.2
      throw new InvalidGrantError("Authorization code already used");
    }
    rec.state = "challenged";
    return rec.code_challenge;
  }

  async exchangeAuthorizationCode(client, code, _codeVerifier, redirectUri, resource) {
    const rec = this.store.codes.get(code);
    if (!rec || rec.state !== "challenged" || rec.client_id !== client.client_id || rec.exp <= this.store.now()) {
      throw new InvalidGrantError("Invalid or expired authorization code");
    }
    if (redirectUri !== undefined && redirectUri !== rec.redirect_uri) {
      throw new InvalidGrantError("redirect_uri does not match the authorization request");
    }
    this.#checkResource(resource);
    const grant = this.store.saveGrant(this.store.newGrant(client.client_id));
    const tokens = this.#tokens(grant);
    rec.state = "used";
    rec.grant_id = grant.id;
    return tokens;
  }

  async exchangeRefreshToken(client, refreshToken, _scopes, resource) {
    const token = this.store.open("rt", refreshToken);
    const grant = token && this.store.grants.get(token.id);
    if (!grant || grant.client_id !== client.client_id) throw new InvalidGrantError("Invalid refresh token");
    const replayed = token.n !== grant.gen;
    if (replayed || grant.exp <= this.store.now()) {
      // A generation behind the grant's is a token that was already used, however long ago:
      // it leaked (or the client is broken). End the grant, which also kills the newest
      // token whoever holds it, so the operator has to approve again (RFC 9700 §4.14.2).
      this.store.revokeGrant(grant.id);
      throw new InvalidGrantError(replayed ? "Refresh token already used" : "Refresh token expired");
    }
    this.#checkResource(resource);
    return this.#tokens(this.store.saveGrant({ ...grant, gen: grant.gen + 1 }));
  }

  #tokens(grant) {
    return {
      access_token: this.store.mintAccess(grant.id, this.store.now() + ACCESS_TTL_MS),
      token_type: "Bearer",
      expires_in: ACCESS_TTL_MS / 1000,
      refresh_token: this.store.mintRefresh(grant.id, grant.gen),
    };
  }

  /** RFC 7009: unknown or foreign tokens are a silent no-op. Either kind ends the whole grant. */
  async revokeToken(client, { token }) {
    const opened = this.store.open("at", token) ?? this.store.open("rt", token);
    const grant = opened && this.store.grants.get(opened.id);
    if (grant && grant.client_id === client.client_id) this.store.revokeGrant(grant.id);
  }

  // --- resource server side ---------------------------------------------------

  async verifyAccessToken(token) {
    this.store.sync(); // catch the state file up if a write failed earlier
    const opened = this.store.open("at", token);
    const grant = opened && this.store.grants.get(opened.id);
    if (!grant || opened.n <= this.store.now()) throw new InvalidTokenError("Invalid or expired access token");
    this.store.touchClient(grant.client_id);
    return {
      token,
      clientId: grant.client_id,
      scopes: [],
      expiresAt: Math.floor(opened.n / 1000),
      resource: this.resourceUrl,
    };
  }
}
