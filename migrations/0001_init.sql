-- AlphaBound initial schema (§6.2). Applied by src/storage/db.zig.
-- Events are the source of truth; orders/fills/equity are projections.

CREATE TABLE IF NOT EXISTS events (
    seq              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id         TEXT NOT NULL UNIQUE,
    ts               TEXT NOT NULL,             -- RFC3339 ms UTC
    type             TEXT NOT NULL,
    source           TEXT NOT NULL,
    severity         TEXT NOT NULL,
    correlation_id   TEXT NOT NULL DEFAULT '',
    state_version    INTEGER NOT NULL DEFAULT 0,
    software_version TEXT NOT NULL DEFAULT '',
    config_hash      TEXT NOT NULL DEFAULT '',
    payload_json     TEXT NOT NULL DEFAULT '{}',
    content_hash     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_events_type_ts ON events(type, ts);
CREATE INDEX IF NOT EXISTS idx_events_correlation ON events(correlation_id);

CREATE TABLE IF NOT EXISTS orders (
    client_order_id   TEXT PRIMARY KEY,
    exchange_order_id TEXT NOT NULL DEFAULT '',
    decision_id       TEXT NOT NULL,
    side              TEXT NOT NULL CHECK (side IN ('buy','sell')),
    qty               TEXT NOT NULL,             -- Decimal string, never float
    price             TEXT NOT NULL,
    status            TEXT NOT NULL,
    created_ts        TEXT NOT NULL,
    updated_ts        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_orders_decision ON orders(decision_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

CREATE TABLE IF NOT EXISTS fills (
    fill_id   TEXT PRIMARY KEY,
    order_id  TEXT NOT NULL REFERENCES orders(client_order_id),
    price     TEXT NOT NULL,
    qty       TEXT NOT NULL,
    fee       TEXT NOT NULL,
    fee_ccy   TEXT NOT NULL DEFAULT 'USDT',
    ts        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fills_order ON fills(order_id);

CREATE TABLE IF NOT EXISTS equity_samples (
    ts        TEXT NOT NULL,
    interval  TEXT NOT NULL CHECK (interval IN ('1s','1m')),
    equity    TEXT NOT NULL,
    hwm       TEXT NOT NULL,
    drawdown  TEXT NOT NULL,
    cash      TEXT NOT NULL,
    btc_value TEXT NOT NULL,
    PRIMARY KEY (ts, interval)
);

CREATE TABLE IF NOT EXISTS agent_runs (
    run_id           TEXT PRIMARY KEY,
    snapshot_version INTEGER NOT NULL,
    model            TEXT NOT NULL,
    prompt_hash      TEXT NOT NULL,
    input_digest     TEXT NOT NULL DEFAULT '',
    output_digest    TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL,
    started_ts       TEXT NOT NULL,
    finished_ts      TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS tool_calls (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id        TEXT NOT NULL REFERENCES agent_runs(run_id),
    tool          TEXT NOT NULL,
    source        TEXT NOT NULL DEFAULT '',
    as_of         TEXT NOT NULL DEFAULT '',
    latency_ms    INTEGER NOT NULL DEFAULT 0,
    cost          TEXT NOT NULL DEFAULT '0',
    result_digest TEXT NOT NULL DEFAULT '',
    ts            TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tool_calls_run ON tool_calls(run_id);

CREATE TABLE IF NOT EXISTS memories (
    memory_id      TEXT NOT NULL,
    version        INTEGER NOT NULL,
    kind           TEXT NOT NULL,
    status         TEXT NOT NULL DEFAULT 'active',
    confidence     REAL NOT NULL DEFAULT 0,
    evidence_count INTEGER NOT NULL DEFAULT 0,
    content_json   TEXT NOT NULL,
    created_ts     TEXT NOT NULL,
    PRIMARY KEY (memory_id, version)
);
