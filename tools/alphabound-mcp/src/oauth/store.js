import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const ACCESS_TTL_MS = 60 * 60_000; // 1 h
export const REFRESH_TTL_MS = 30 * 24 * 60 * 60_000; // 30 d; every rotation grants a fresh window
export const CODE_TTL_MS = 5 * 60_000;
export const PENDING_TTL_MS = 10 * 60_000;

const MAX_CLIENTS = 100;
const MAX_CODES = 500;
const MAX_PENDING = 200;

const TOKEN = /^abmcp_(at|rt)_([A-Za-z0-9_-]{22})\.(\d{1,16})\.([A-Za-z0-9_-]{43})$/;

/**
 * State of the built-in authorization server.
 *
 *   clients  dynamically registered public clients                  persisted
 *   grants   one per operator approval: { id, client_id, gen, exp }  persisted
 *   codes    authorization codes (5 min), keyed by the code         memory only
 *   pending  consent forms awaiting the operator (10 min)           memory only
 *
 * Tokens prove themselves instead of being looked up:
 *
 *   access   abmcp_at_<grant id>.<expiry ms>.<mac>
 *   refresh  abmcp_rt_<grant id>.<generation>.<mac>
 *
 * `mac` is HMAC-SHA256 over the kind, the id and the number, keyed by a secret derived from
 * the operator secret and the audience (the MCP endpoint URL). A token is therefore useless
 * anywhere but at this endpoint, and rotating the operator secret orphans every issued token,
 * the same way it already invalidates the daemon's session cookies. Nothing token-like is
 * persisted, so a leaked state file is harmless.
 *
 * A token works while its grant exists. Each refresh bumps the grant's `gen`, so a refresh
 * token whose generation is behind the grant's is provably one that was already used, however
 * long ago: presenting it means it leaked, and the provider ends the whole grant. That is refresh
 * token rotation as RFC 9700 §4.14.2 asks for, including its implementation note (the grant is
 * encoded in the token, whose integrity the MAC protects).
 * (An access token is a function of its grant and expiry, so two minted in the same millisecond
 * coincide; they are the same credential, with the same lifetime and the same revocation.)
 */
export class OAuthStore {
  /**
   * @param file      JSON state file (0600). null = memory only; a restart then signs every
   *                  client out and forgets their registrations.
   * @param secret    operator secret (the AlphaBound API token)
   * @param audience  URL of the MCP endpoint the tokens are for
   */
  constructor({ file = null, secret, audience, now = Date.now, log = () => {} } = {}) {
    if (!secret || !audience) throw new Error("OAuthStore needs the operator secret and the audience");
    this.file = file;
    this.now = now;
    this.log = log;
    this.key = crypto.createHmac("sha256", secret).update(`alphabound-mcp/oauth/token/v1\n${audience}`).digest();
    this.clients = new Map();
    this.grants = new Map();
    this.codes = new Map();
    this.pending = new Map();
    this.failing = false; // the last write failed (log once per episode)
    this.lagging = false; // a revocation is applied in memory but not yet in the file
    if (file) this.#load();
  }

  // --- tokens ----------------------------------------------------------------

  #mac(kind, id, n) {
    return crypto.createHmac("sha256", this.key).update(`${kind}\n${id}\n${n}`).digest("base64url");
  }

  mintAccess(grantId, expiresAtMs) {
    return `abmcp_at_${grantId}.${expiresAtMs}.${this.#mac("at", grantId, expiresAtMs)}`;
  }

  mintRefresh(grantId, gen) {
    return `abmcp_rt_${grantId}.${gen}.${this.#mac("rt", grantId, gen)}`;
  }

  /**
   * Check a token's kind ("at" | "rt") and MAC. Returns { id, n } — the grant id and the expiry
   * (access) or generation (refresh) — or undefined. Whether the grant still exists, and
   * whether n is current, is for the caller to decide.
   */
  open(kind, token) {
    const m = TOKEN.exec(String(token));
    if (!m || m[1] !== kind) return undefined;
    const [, , id, n, mac] = m;
    const want = Buffer.from(this.#mac(kind, id, n));
    const got = Buffer.from(mac);
    if (want.length !== got.length || !crypto.timingSafeEqual(want, got)) return undefined;
    return { id, n: Number(n) };
  }

  // --- clients ---------------------------------------------------------------

  /**
   * Registration counts as use. At the cap the least recently used client that holds no grant
   * goes; a client with a live grant is never evicted to admit an anonymous registration, so when
   * every client has one the registration is refused (returns false).
   */
  addClient(client) {
    const clients = new Map(this.clients);
    const grants = new Map([...this.grants].filter(([, g]) => g.exp > this.now()));
    while (clients.size >= MAX_CLIENTS) {
      const doomed = evictionCandidate(clients, grants);
      if (doomed === undefined) return false;
      clients.delete(doomed);
    }
    clients.set(client.client_id, { ...client, last_seen: this.now() });
    this.#commit(clients, grants);
    return true;
  }

  touchClient(id) {
    const c = this.clients.get(id);
    if (c) c.last_seen = this.now();
  }

  removeClient(id) {
    this.clients.delete(id);
    for (const [gid, g] of this.grants) if (g.client_id === id) this.grants.delete(gid);
    this.save();
  }

  // --- short-lived, memory-only records --------------------------------------

  putCode(code, rec) {
    putBounded(this.codes, code, rec, MAX_CODES, this.now());
  }

  putPending(id, rec) {
    putBounded(this.pending, id, rec, MAX_PENDING, this.now());
  }

  // --- grants ----------------------------------------------------------------

  newGrant(clientId) {
    return { id: crypto.randomBytes(16).toString("base64url"), client_id: clientId, gen: 0, exp: 0 };
  }

  /** Make a new or updated grant live, sliding its refresh window forward from now. Returns it. */
  saveGrant(grant) {
    const live = { ...grant, exp: this.now() + REFRESH_TTL_MS };
    this.touchClient(live.client_id);
    this.#commit(this.clients, new Map(this.grants).set(live.id, live));
    return live;
  }

  /** Takes effect at once; throws if the file could not be updated (see "state changes" below). */
  revokeGrant(id) {
    if (this.grants.delete(id)) this.save();
  }

  // --- state changes and persistence -------------------------------------------
  //
  // What grants access (a client, a grant, a new refresh generation) is written to the state
  // file first and becomes live only if that worked, so a failed write changes nothing and the
  // caller gets the error. Revocation goes the other way: it applies in memory at once (the
  // safe direction) and the write follows; if that fails the caller still gets the error and
  // the file lags. A lagging file is retried by sync() and by the next successful write, but
  // a restart before then would bring the revoked sign-ins back, so it is logged loudly.

  /** Persist the current state (revocations are already applied to it). Throws on failure. */
  save() {
    try {
      this.#commit(this.clients, this.grants);
    } catch (e) {
      this.lagging = true;
      throw e;
    }
  }

  /** Retry a write that failed earlier; a no-op unless the file lags. */
  sync() {
    if (!this.lagging) return;
    try {
      this.save();
    } catch {
      // still failing, and already logged
    }
  }

  #commit(clients, grants) {
    const live = new Map([...grants].filter(([, g]) => g.exp > this.now())); // closed refresh windows
    try {
      this.#write(clients, live);
    } catch (e) {
      if (!this.failing) {
        this.log(
          `oauth: cannot persist state (${e.code || e.message}); new sign-ins are refused and revocations ` +
            "live in memory only (a restart before the file is writable again would undo them)",
        );
      }
      this.failing = true;
      throw e;
    }
    this.failing = false;
    this.lagging = false;
    this.clients = clients;
    this.grants = live;
  }

  /**
   * Atomic replace via a temp file that is created exclusively (O_EXCL: never follows a symlink
   * or reuses a planted file) with an unpredictable name and mode 0600, then renamed over the state.
   */
  #write(clients, grants) {
    if (!this.file) return;
    const doc = { version: 1, clients: [...clients.values()], grants: [...grants.values()] };
    fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const tmp = `${this.file}.${crypto.randomBytes(6).toString("hex")}.tmp`;
    const fd = fs.openSync(tmp, "wx", 0o600);
    try {
      fs.writeFileSync(fd, JSON.stringify(doc));
    } catch (e) {
      fs.closeSync(fd);
      fs.rmSync(tmp, { force: true });
      throw e;
    }
    fs.closeSync(fd);
    try {
      fs.renameSync(tmp, this.file);
    } catch (e) {
      fs.rmSync(tmp, { force: true });
      throw e;
    }
  }

  /** Strict at startup so a bad path or corrupt file is noticed immediately. */
  #load() {
    let raw = null;
    try {
      raw = fs.readFileSync(this.file, "utf8");
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
    if (raw !== null) {
      let doc;
      try {
        doc = JSON.parse(raw);
      } catch {
        throw new Error(`OAuth state file is not valid JSON: ${this.file}`);
      }
      if (doc?.version !== 1) throw new Error(`unsupported OAuth state file version: ${this.file}`);
      const clients = doc.clients ?? [];
      const grants = doc.grants ?? [];
      const wellFormed =
        clients.every((c) => typeof c?.client_id === "string" && Array.isArray(c.redirect_uris)) &&
        grants.every(
          (g) =>
            typeof g?.id === "string" &&
            typeof g.client_id === "string" &&
            Number.isInteger(g.gen) &&
            Number.isFinite(g.exp),
        );
      if (!wellFormed) throw new Error(`OAuth state file is malformed: ${this.file}`);
      for (const c of clients) this.clients.set(c.client_id, c);
      for (const g of grants) this.grants.set(g.id, g);
    }
    this.#commit(this.clients, this.grants); // drops expired grants and proves the path is writable
  }
}

/** The least recently used client that holds no grant, if there is one. */
function evictionCandidate(clients, grants) {
  const approved = new Set([...grants.values()].map((g) => g.client_id));
  let pick;
  for (const c of clients.values()) {
    if (!approved.has(c.client_id) && (!pick || c.last_seen < pick.last_seen)) pick = c;
  }
  return pick?.client_id;
}

/** Insert with a hard cap: sweep expired records first, then drop the oldest insertions. */
function putBounded(map, key, value, cap, now) {
  if (map.size >= cap) for (const [k, v] of map) if (v.exp <= now) map.delete(k);
  while (map.size >= cap) map.delete(map.keys().next().value);
  map.set(key, value);
}
