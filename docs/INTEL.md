# alphabound.intel.v1

AlphaBound **does not collect** investment intel. External collector agents
push a signed envelope. The daemon stores it, lists it on Dashboard / MCP,
and may feed a ranked subset into the slow decision context. Intel never
enters the risk kernel, order planner, or admin control plane.

Payloads are **untrusted data**, not instructions.

## Envelope

```json
{
  "schema": "alphabound.intel.v1",
  "id": "intel_etf_flow_01",
  "source_id": "collector.macro",
  "kind": "macro",
  "instrument": "BTC-USDT",
  "headline": "US spot BTC ETF saw net inflows",
  "body": "Issuers reported a second consecutive session of net creations.",
  "claims": [{"text": "ETF creations continued", "polarity": "bull"}],
  "tags": ["etf", "flows"],
  "refs": [{"url": "https://example.com/note", "title": "issuer print"}],
  "confidence": 0.62,
  "as_of_ms": 1700000000000,
  "expires_ms": 1700604800000,
  "nonce": "0123456789abcdef0123456789abcdef",
  "signature": "<64 lowercase hex>"
}
```

| Field | Rule |
|---|---|
| `id` | `intel_` + `[A-Za-z0-9_-]`, 8–80 chars |
| `source_id` | 3–64, starts with a letter |
| `kind` | `macro` `news` `flow` `regulatory` `narrative` `onchain` |
| `instrument` | `BTC-USDT` or `*` |
| `headline` | 8–120 chars, UTF-8, no HTML / control chars |
| `body` | 1–800 chars |
| `claims` | 1–6 `{text, polarity}`; polarity `bull`/`bear`/`neutral` |
| `tags` | ≤8, `[A-Za-z0-9_-]` |
| `refs` | ≤3; `url` must be `https://` |
| `confidence` | 0.000–1.000 |
| `nonce` | 16–64 lowercase hex |
| `as_of_ms` | not more than 5 minutes in the future |

`expires_ms` is optional. Default / max TTL by kind:

| kind | default | max |
|---|---|---|
| news | 12h | 24h |
| onchain | 24h | 72h |
| flow / narrative | 48h | 72h |
| macro | 7d | 14d |
| regulatory | 7d | 30d |

Ingest is **append-only**. Duplicate `id` or same-day `dedup_key`
(`sha256(kind|instrument|normalized_headline|utc_day)`) is ignored.

## HMAC

Canonical UTF-8 string:

```
v1|{id}|{source_id}|{kind}|{instrument}|{headline}|{body}|{conf_3dp}|{as_of_ms}|{expires_ms}|{nonce}
```

`conf_3dp` is always three decimals (`0.620`). Signature is lowercase hex
`HMAC-SHA256(ALPHABOUND_INTEL_HMAC, canonical)`. Key length ≥ 16; set in
`secrets.env` (never in git). Empty key disables ingest; GET history still works.

```bash
# collector signs locally — AlphaBound / MCP never receive the key over the wire
printf '%s' "$CANONICAL" | openssl dgst -sha256 -hmac "$ALPHABOUND_INTEL_HMAC" -hex
```

Per-source rate limit: 30 accepted envelopes / hour. Queue depth 8.

## How AlphaBound uses it

Live score = `source_trust × confidence × freshness` (all 0–1, milles internally).
Default `source_trust` is 1.0.

| score | grade | context |
|---|---|---|
| ≥ 0.700 | A | yes |
| ≥ 0.450 | B | yes |
| ≥ 0.200 | C | yes |
| else / expired | D | **no** |

Up to 8 ranked live A/B/C items go into the agent `intel` array. The model may
cite an `id` in `thesis`. Intel cannot change risk limits or force a trade.

Dashboard **情报** tab and `GET /api/v1/intel` show history **without**
`signature` / `nonce`.

## Push paths

1. `POST /api/v1/intel` — same auth as other `/api/v1/*` (token / session).
2. MCP `submit_intel` — forwards that POST. The collector signs first.
3. MCP `list_intel` — `GET /api/v1/intel`.

MCP still cannot place orders, flatten, or read secrets.

## Storage

SQLite table `intel` (migration `0009_intel.sql`). Core loop is the only writer;
the web thread enqueues validated records.
