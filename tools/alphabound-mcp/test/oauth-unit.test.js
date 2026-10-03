import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { InvalidGrantError, InvalidTokenError } from "@modelcontextprotocol/sdk/server/auth/errors.js";
import { FailLimiter } from "../src/oauth/limiter.js";
import { OperatorOAuthProvider, isAllowedRedirectUri } from "../src/oauth/provider.js";
import { ACCESS_TTL_MS, CODE_TTL_MS, OAuthStore, PENDING_TTL_MS, REFRESH_TTL_MS } from "../src/oauth/store.js";
import { randomToken, safeEqual } from "../src/secret.js";

const SECRET = "unit-operator-secret-0123456789abcdef";
const RESOURCE = new URL("https://mcp.example.com/mcp");
const CB = "https://app.example/cb";
const DAY = 24 * 60 * 60_000;

/** Provider + store on a clock the test controls. */
function rig({ file = null, log = () => {} } = {}) {
  const clock = { t: 1_800_000_000_000 };
  const now = () => clock.t;
  const store = new OAuthStore({ file, secret: SECRET, audience: RESOURCE.href, now, log });
  const limiter = new FailLimiter({ now });
  const provider = new OperatorOAuthProvider({ store, resourceUrl: RESOURCE, operatorToken: SECRET, limiter });
  return { clock, store, limiter, provider };
}

function newClient(provider, n = 1) {
  return provider.clientsStore.registerClient({
    client_id: `client-${n}`,
    client_id_issued_at: 1,
    redirect_uris: [CB],
    client_name: `App ${n}`,
  });
}

/** The provider's code flow without HTTP: plant an approved code, then redeem it. */
async function grantFor({ store, provider }, client) {
  const code = randomToken("code_");
  store.putCode(code, {
    client_id: client.client_id,
    redirect_uri: CB,
    code_challenge: "c",
    state: "issued",
    exp: store.now() + CODE_TTL_MS,
  });
  await provider.challengeForAuthorizationCode(client, code);
  return provider.exchangeAuthorizationCode(client, code, undefined, CB);
}

function fakeRes() {
  return {
    headers: {},
    set(k, v) {
      if (typeof k === "object") Object.assign(this.headers, k);
      else this.headers[k] = v;
      return this;
    },
    status(code) {
      this.code = code;
      return this;
    },
    type() {
      return this;
    },
    send(body) {
      this.body = body;
      return this;
    },
    redirect(code, location) {
      this.code = code;
      this.location = location;
      return this;
    },
  };
}

describe("redirect URI policy", () => {
  it("allows https, loopback http, and private-use app schemes", () => {
    for (const uri of [
      "https://claude.ai/api/mcp/auth_callback",
      "http://localhost:3000/cb",
      "http://127.0.0.1/cb",
      "http://[::1]:5/cb",
      "cursor://anysphere.cursor-retrieval/oauth/x/callback",
      "vscode://vscode.github-authentication/did-authenticate",
      "com.example.app:/oauth2redirect",
    ]) {
      assert.equal(isAllowedRedirectUri(uri), true, uri);
    }
  });

  it("refuses everything that could hand a code to a stranger", () => {
    for (const uri of [
      "http://evil.example/cb",
      "http://127.0.0.1.evil.example/cb",
      "http://localhost.evil.example/cb",
      "javascript:alert(1)",
      "data:text/html,x",
      "file:///etc/passwd",
      "blob:https://a.example/b",
      "ftp://a.example/b",
      "ws://a.example/b",
      "wss://a.example/b",
      "https://a.example/cb#x",
      "https://a.example/cb#",
      "https://user:pw@a.example/cb",
      "//a.example/cb",
      "/relative",
      "",
    ]) {
      assert.equal(isAllowedRedirectUri(uri), false, uri);
    }
  });
});

describe("token lifetimes", () => {
  it("expires an authorization code after 5 minutes", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const code = randomToken("code_");
    r.store.putCode(code, {
      client_id: client.client_id,
      redirect_uri: CB,
      code_challenge: "c",
      state: "issued",
      exp: r.clock.t + CODE_TTL_MS,
    });
    r.clock.t += CODE_TTL_MS;
    await assert.rejects(r.provider.challengeForAuthorizationCode(client, code), InvalidGrantError);
  });

  it("expires an access token after an hour and reports the expiry in seconds", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const tokens = await grantFor(r, client);
    const info = await r.provider.verifyAccessToken(tokens.access_token);
    assert.equal(info.expiresAt, Math.floor((r.clock.t + ACCESS_TTL_MS) / 1000));
    assert.equal(info.clientId, client.client_id);
    assert.equal(info.resource.href, RESOURCE.href);
    r.clock.t += ACCESS_TTL_MS - 1;
    await r.provider.verifyAccessToken(tokens.access_token);
    r.clock.t += 1;
    await assert.rejects(r.provider.verifyAccessToken(tokens.access_token), InvalidTokenError);
  });

  it("slides the refresh window on every rotation and ends it after 30 idle days", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const t1 = await grantFor(r, client);
    r.clock.t += 20 * DAY;
    const t2 = await r.provider.exchangeRefreshToken(client, t1.refresh_token);
    r.clock.t += 25 * DAY; // 45 days after login, 25 after the last use
    const t3 = await r.provider.exchangeRefreshToken(client, t2.refresh_token);
    r.clock.t += REFRESH_TTL_MS;
    await assert.rejects(r.provider.exchangeRefreshToken(client, t3.refresh_token), /expired/);
    assert.equal(r.store.grants.size, 0);
  });
});

describe("tokens", () => {
  const flip = (s) => s.slice(0, -1) + (s.endsWith("A") ? "B" : "A");

  it("prove themselves: kind, grant and number are all covered by the MAC", async () => {
    const r = rig();
    const { access_token: at, refresh_token: rt } = await grantFor(r, newClient(r.provider));
    const a = r.store.open("at", at);
    const b = r.store.open("rt", rt);
    assert.equal(a.id, b.id);
    assert.equal(a.n, r.clock.t + ACCESS_TTL_MS);
    assert.equal(b.n, 0);

    assert.equal(r.store.open("rt", at), undefined); // one kind is not the other
    assert.equal(r.store.open("at", rt), undefined);
    const [head, num, mac] = at.split(".");
    for (const forged of [
      `${head}.${Number(num) + 1}.${mac}`, // a longer life
      `${flip(head)}.${num}.${mac}`, // someone else's grant
      `${head}.${num}.${flip(mac)}`,
      `${head}.${num}.${mac}.more`,
      `${head}.${num}`,
      `${head}.${num}.`,
      "abmcp_at_",
      "garbage",
      "",
    ]) {
      assert.equal(r.store.open("at", forged), undefined, forged);
    }
    for (const junk of [undefined, null, 42, {}, []]) assert.equal(r.store.open("at", junk), undefined);
  });

  it("depend on the operator secret and on the audience", async () => {
    const r = rig();
    const { access_token, refresh_token } = await grantFor(r, newClient(r.provider));
    const other = (secret, audience) => new OAuthStore({ secret, audience });
    assert.ok(other(SECRET, RESOURCE.href).open("at", access_token)); // same inputs, same key
    assert.equal(other(`${SECRET}!`, RESOURCE.href).open("at", access_token), undefined);
    assert.equal(other(SECRET, "https://other.example/mcp").open("rt", refresh_token), undefined);
    assert.throws(() => new OAuthStore({ secret: "", audience: RESOURCE.href }), /operator secret/);
    assert.throws(() => new OAuthStore({ secret: SECRET }), /audience/);
  });

  it("are never the same twice: every rotation yields a new generation", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const t0 = await grantFor(r, client);
    const t1 = await r.provider.exchangeRefreshToken(client, t0.refresh_token);
    assert.notEqual(t1.refresh_token, t0.refresh_token);
    assert.equal(r.store.open("rt", t1.refresh_token).n, 1);
    assert.equal([...r.store.grants.values()][0].gen, 1);
  });

  it("end the grant when a refresh token from ANY earlier generation comes back", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const t0 = await grantFor(r, client);
    const t1 = await r.provider.exchangeRefreshToken(client, t0.refresh_token);
    const t2 = await r.provider.exchangeRefreshToken(client, t1.refresh_token);
    const t3 = await r.provider.exchangeRefreshToken(client, t2.refresh_token);
    assert.equal(r.store.grants.size, 1);

    // A thief who rotated several times before the owner returned cannot hide: t0 is three
    // generations behind, and still recognised.
    await assert.rejects(r.provider.exchangeRefreshToken(client, t0.refresh_token), /already used/);
    assert.equal(r.store.grants.size, 0);
    await assert.rejects(r.provider.exchangeRefreshToken(client, t3.refresh_token), InvalidGrantError);
    await assert.rejects(r.provider.verifyAccessToken(t3.access_token), InvalidTokenError);
  });

  it("are bound to their client", async () => {
    const r = rig();
    const owner = newClient(r.provider, 1);
    const stranger = newClient(r.provider, 2);
    const t = await grantFor(r, owner);
    await assert.rejects(r.provider.exchangeRefreshToken(stranger, t.refresh_token), InvalidGrantError);
    assert.equal(r.store.grants.size, 1); // a stranger's attempt does not end the owner's grant
    await r.provider.revokeToken(stranger, { token: t.refresh_token });
    assert.equal(r.store.grants.size, 1);
    await r.provider.revokeToken(owner, { token: t.access_token });
    assert.equal(r.store.grants.size, 0);
  });
});

describe("consent requests", () => {
  async function open(r) {
    const client = newClient(r.provider);
    const page = fakeRes();
    await r.provider.authorize(client, { redirectUri: CB, codeChallenge: "c", state: "s" }, page);
    return { client, requestId: /name="request_id" value="([^"]+)"/.exec(page.body)[1] };
  }
  const approve = (r, requestId) => {
    const res = fakeRes();
    return r.provider.consent({ body: { request_id: requestId, token: SECRET, decision: "approve" }, ip: "203.0.113.9" }, res).then(() => res);
  };

  it("are good for 10 minutes", async () => {
    const r = rig();
    const { requestId } = await open(r);
    r.clock.t += PENDING_TTL_MS - 1;
    const res = await approve(r, requestId);
    assert.equal(res.code, 302);
    assert.ok(new URL(res.location).searchParams.get("code"));
  });

  it("are forgotten after that", async () => {
    const r = rig();
    const { requestId } = await open(r);
    r.clock.t += PENDING_TTL_MS;
    const res = await approve(r, requestId);
    assert.equal(res.code, 400);
    assert.equal(r.store.codes.size, 0);
  });

  it("die with the client they were opened for", async () => {
    const r = rig();
    const { client, requestId } = await open(r);
    r.store.removeClient(client.client_id);
    assert.equal((await approve(r, requestId)).code, 400);
  });

  it("are capped, dropping the oldest first", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const ids = [];
    for (let i = 0; i < 201; i += 1) {
      const page = fakeRes();
      await r.provider.authorize(client, { redirectUri: CB, codeChallenge: "c" }, page);
      ids.push(/name="request_id" value="([^"]+)"/.exec(page.body)[1]);
    }
    assert.equal(r.store.pending.size, 200);
    assert.equal(r.store.pending.has(ids[0]), false);
    assert.equal(r.store.pending.has(ids[200]), true);
  });
});

describe("OAuthStore", () => {
  it("at 100 clients evicts the least recently used one that holds no grant", async () => {
    const r = rig();
    for (let i = 0; i < 100; i += 1) {
      r.clock.t += 1000;
      newClient(r.provider, i);
    }
    r.clock.t += 1000;
    r.store.touchClient("client-0"); // use, not age, decides: client-1 is now the stalest
    r.clock.t += 1000;
    newClient(r.provider, 100);
    assert.equal(r.store.clients.size, 100);
    assert.equal(r.store.clients.has("client-0"), true);
    assert.equal(r.store.clients.has("client-1"), false);
    assert.equal(r.store.clients.has("client-100"), true);
  });

  it("never evicts an approved client to admit an anonymous registration", async () => {
    const r = rig();
    const approved = newClient(r.provider, 0); // the stalest client of all...
    const tokens = await grantFor(r, approved); // ...but it holds a live grant
    for (let i = 1; i < 100; i += 1) {
      r.clock.t += 1000;
      newClient(r.provider, i);
    }
    for (let i = 100; i < 300; i += 1) {
      r.clock.t += 1000;
      newClient(r.provider, i); // a flood of junk registrations
    }
    assert.equal(r.store.clients.size, 100);
    assert.equal(r.store.clients.has("client-0"), true);
    assert.equal(r.store.grants.size, 1);
    await r.provider.verifyAccessToken(tokens.access_token); // still signed in
  });

  it("refuses a registration when every slot holds an approved client", async () => {
    const r = rig();
    for (let i = 0; i < 100; i += 1) await grantFor(r, newClient(r.provider, i));
    assert.throws(() => newClient(r.provider, 100), /Too many registered clients/);
    assert.equal(r.store.clients.size, 100);
    assert.equal(r.store.grants.size, 100);
    // a grant whose refresh window has closed frees its client again
    r.clock.t += REFRESH_TTL_MS;
    newClient(r.provider, 100);
    assert.equal(r.store.clients.size, 100);
    assert.equal(r.store.grants.size, 0);
  });

  it("keeps an access token alive to its own expiry across rotations", async () => {
    const r = rig();
    const client = newClient(r.provider);
    const t0 = await grantFor(r, client);
    await r.provider.exchangeRefreshToken(client, t0.refresh_token);
    await r.provider.verifyAccessToken(t0.access_token); // rotation does not shorten it
    r.clock.t += ACCESS_TTL_MS;
    await assert.rejects(r.provider.verifyAccessToken(t0.access_token), InvalidTokenError);
  });

  describe("persistence", () => {
    const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "ab-store-"));

    it("creates the file (0600) and its directory at startup, and round-trips state", async () => {
      const dir = tmp();
      const file = path.join(dir, "nested", "oauth.json");
      const r = rig({ file });
      assert.ok(fs.existsSync(file));
      if (process.platform !== "win32") {
        assert.equal(fs.statSync(file).mode & 0o777, 0o600);
        assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
      }
      const client = newClient(r.provider);
      const tokens = await grantFor(r, client);

      const again = new OAuthStore({ file, secret: SECRET, audience: RESOURCE.href, now: r.store.now });
      assert.deepEqual(again.clients.get(client.client_id).redirect_uris, [CB]);
      const grantId = again.open("at", tokens.access_token).id; // the reloaded store still honours the token
      assert.equal(again.grants.get(grantId).client_id, client.client_id);
      assert.equal(again.grants.get(grantId).gen, 0);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("drops expired grants when it saves", async () => {
      const dir = tmp();
      const r = rig({ file: path.join(dir, "oauth.json") });
      await grantFor(r, newClient(r.provider));
      r.clock.t += REFRESH_TTL_MS;
      r.store.save();
      assert.equal(r.store.grants.size, 0);
      assert.deepEqual(JSON.parse(fs.readFileSync(r.store.file, "utf8")).grants, []);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    // Make the state file unwritable (its parent becomes a file); the returned function mends it.
    const breakFile = (r) => {
      const good = r.store.file;
      r.store.file = path.join(good, "cannot-be-a-directory.json");
      return () => {
        r.store.file = good;
      };
    };
    const failures = (logs) => logs.filter((l) => l.includes("cannot persist state")).length;

    it("refuses a registration it cannot persist and changes nothing, logging once per episode", () => {
      const dir = tmp();
      const logs = [];
      const r = rig({ file: path.join(dir, "oauth.json"), log: (s) => logs.push(s) });
      const mend = breakFile(r);
      assert.throws(() => newClient(r.provider, 1));
      assert.throws(() => newClient(r.provider, 2));
      assert.equal(r.store.clients.size, 0);
      assert.equal(failures(logs), 1);
      mend();
      newClient(r.provider, 3);
      assert.equal(r.store.clients.size, 1);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("refuses to sign in or rotate when it cannot persist; the same refresh token works once it can", async () => {
      const dir = tmp();
      const r = rig({ file: path.join(dir, "oauth.json") });
      const client = newClient(r.provider);
      const t0 = await grantFor(r, client);
      const mend = breakFile(r);
      await assert.rejects(r.provider.exchangeRefreshToken(client, t0.refresh_token));
      await assert.rejects(grantFor(r, client));
      assert.equal(r.store.grants.size, 1);
      assert.equal([...r.store.grants.values()][0].gen, 0); // nothing advanced, so nothing was lost
      mend();
      const t1 = await r.provider.exchangeRefreshToken(client, t0.refresh_token);
      assert.equal(r.store.open("rt", t1.refresh_token).n, 1);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("applies a revocation in memory even when it cannot persist it, says so, and catches up when it can", async () => {
      const dir = tmp();
      const file = path.join(dir, "oauth.json");
      const logs = [];
      const r = rig({ file, log: (s) => logs.push(s) });
      const client = newClient(r.provider);
      const t0 = await grantFor(r, client);
      const mend = breakFile(r);

      await assert.rejects(r.provider.revokeToken(client, { token: t0.access_token })); // the caller is told
      assert.equal(r.store.grants.size, 0); // yet the sign-in is dead already
      await assert.rejects(r.provider.verifyAccessToken(t0.access_token), InvalidTokenError);
      assert.equal(r.store.lagging, true);
      assert.equal(JSON.parse(fs.readFileSync(file, "utf8")).grants.length, 1); // the file still has it
      assert.equal(failures(logs), 1);

      mend();
      await assert.rejects(r.provider.verifyAccessToken("abmcp_at_none.1.none"), InvalidTokenError); // any request syncs
      assert.equal(r.store.lagging, false);
      assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).grants, []);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("ends a grant in memory when a replay is detected but the file cannot be written", async () => {
      const dir = tmp();
      const r = rig({ file: path.join(dir, "oauth.json") });
      const client = newClient(r.provider);
      const t0 = await grantFor(r, client);
      await r.provider.exchangeRefreshToken(client, t0.refresh_token);
      breakFile(r);
      await assert.rejects(r.provider.exchangeRefreshToken(client, t0.refresh_token)); // the replay
      assert.equal(r.store.grants.size, 0);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("writes the state 0600 over a looser file and never through a planted symlink", { skip: process.platform === "win32" }, () => {
      const dir = tmp();
      const file = path.join(dir, "oauth.json");
      const empty = JSON.stringify({ version: 1, clients: [], grants: [] });
      fs.writeFileSync(file, empty);
      fs.chmodSync(file, 0o666);
      const victim = path.join(dir, "victim");
      fs.writeFileSync(victim, "keep");
      const oldTemp = `${file}.${process.pid}.tmp`; // the name an earlier version used
      fs.symlinkSync(victim, oldTemp);

      const r = rig({ file });
      newClient(r.provider);
      assert.equal(fs.readFileSync(victim, "utf8"), "keep");
      assert.equal(fs.statSync(file).mode & 0o777, 0o600);
      assert.deepEqual(fs.readdirSync(dir).sort(), ["oauth.json", path.basename(oldTemp), "victim"]); // no stray temp

      // a symlink at the state path itself is replaced, not written through
      const real = path.join(dir, "real.json");
      fs.writeFileSync(real, empty);
      fs.rmSync(file);
      fs.symlinkSync(real, file);
      const again = rig({ file });
      newClient(again.provider);
      assert.equal(fs.lstatSync(file).isSymbolicLink(), false);
      assert.deepEqual(JSON.parse(fs.readFileSync(real, "utf8")).clients, []);
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("is strict at startup: an unwritable location is an error, not a silent memory-only mode", () => {
      const dir = tmp();
      const blocker = path.join(dir, "file");
      fs.writeFileSync(blocker, "x");
      assert.throws(() => rig({ file: path.join(blocker, "oauth.json") }));
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("refuses a state file that parses but is not ours", () => {
      const dir = tmp();
      const file = path.join(dir, "oauth.json");
      const grant = { id: "g", client_id: "c", gen: 0, exp: 1 };
      for (const doc of [
        { version: 1, clients: [{}], grants: [] },
        { version: 1, clients: [], grants: [{ ...grant, gen: "0" }] },
        { version: 1, clients: [], grants: [{ ...grant, exp: undefined }] },
        { version: 1, clients: [], grants: [{ ...grant, id: undefined }] },
        { version: 2, clients: [], grants: [] },
        null,
      ]) {
        fs.writeFileSync(file, JSON.stringify(doc));
        assert.throws(() => rig({ file }), /unsupported OAuth state file version|malformed/);
      }
      fs.rmSync(dir, { recursive: true, force: true });
    });

    it("holds no token material: grants are ids, a client, a generation and an expiry", async () => {
      const dir = tmp();
      const r = rig({ file: path.join(dir, "oauth.json") });
      const tokens = await grantFor(r, newClient(r.provider));
      const doc = JSON.parse(fs.readFileSync(r.store.file, "utf8"));
      assert.deepEqual(Object.keys(doc.grants[0]).sort(), ["client_id", "exp", "gen", "id"]);
      const text = JSON.stringify(doc);
      for (const t of [tokens.access_token, tokens.refresh_token]) assert.equal(text.includes(t.split(".").pop()), false);
      fs.rmSync(dir, { recursive: true, force: true });
    });
  });
});

describe("FailLimiter", () => {
  const mk = (opts) => {
    const clock = { t: 0 };
    return { clock, lim: new FailLimiter({ now: () => clock.t, ...opts }) };
  };

  it("locks a key after 8 failures for 15 minutes, and a success clears it", () => {
    const { clock, lim } = mk();
    for (let i = 0; i < 7; i += 1) {
      assert.equal(lim.gate("a"), 0);
      lim.fail("a");
    }
    assert.equal(lim.gate("a"), 0); // the 8th try is still allowed...
    lim.fail("a"); // ...and its failure locks
    assert.equal(lim.gate("a"), 15 * 60);
    clock.t += 14 * 60_000;
    assert.equal(lim.gate("a"), 60);
    clock.t += 60_000;
    assert.equal(lim.gate("a"), 0);

    const other = mk();
    for (let i = 0; i < 5; i += 1) other.lim.fail("b");
    other.lim.clear("b");
    for (let i = 0; i < 7; i += 1) other.lim.fail("b");
    assert.equal(other.lim.gate("b"), 0);
  });

  it("keys are independent, and failures age out of the 15 minute window", () => {
    const { clock, lim } = mk();
    for (let i = 0; i < 8; i += 1) lim.fail("a");
    assert.ok(lim.gate("a") > 0);
    assert.equal(lim.gate("b"), 0);
    for (let i = 0; i < 7; i += 1) lim.fail("c");
    clock.t += 15 * 60_000;
    lim.fail("c"); // window restarted: 1 failure, not 8
    assert.equal(lim.gate("c"), 0);
  });

  it("admits at most 60 attempts a minute across all keys", () => {
    const { clock, lim } = mk();
    for (let i = 0; i < 60; i += 1) assert.equal(lim.gate(`ip-${i}`), 0);
    assert.ok(lim.gate("ip-new") > 0);
    clock.t += 60_000;
    assert.equal(lim.gate("ip-new"), 0);
  });

  it("stays bounded under a flood of distinct keys", () => {
    const { lim } = mk({ maxKeys: 50 });
    for (let i = 0; i < 500; i += 1) lim.fail(`ip-${i}`);
    assert.equal(lim.slots.size, 50);
  });
});

describe("secret helpers", () => {
  it("safeEqual compares by value, whatever the lengths", () => {
    assert.equal(safeEqual("abc", "abc"), true);
    assert.equal(safeEqual("abc", "abd"), false);
    assert.equal(safeEqual("abc", "abcd"), false);
    assert.equal(safeEqual("", "abc"), false);
    assert.equal(safeEqual(undefined, "abc"), false);
  });

  it("randomToken is 256-bit, URL-safe, prefixed, and never repeats", () => {
    const a = randomToken("abmcp_at_");
    assert.match(a, /^abmcp_at_[A-Za-z0-9_-]{43}$/);
    assert.notEqual(a, randomToken("abmcp_at_"));
  });
});
