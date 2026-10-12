-- Dynamic strategy parameters (phase 1). Applied by src/storage/db.zig.
--
-- Filter-layer knobs only. max_drawdown is intentionally absent: it stays a
-- compiled risk-kernel constant and is not stored here.
--
-- param_versions is the version chain. Exactly one row may be `active`.
-- param_audit is append-only (triggers reject UPDATE and DELETE).
-- This phase writes a single bootstrap row from the config file. There is
-- no trading write path and no parameter-mutation API.

CREATE TABLE IF NOT EXISTS param_versions (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    params_json       TEXT NOT NULL,
    source            TEXT NOT NULL CHECK (source IN ('bootstrap','manual','mcp','review')),
    parent_id         INTEGER REFERENCES param_versions(id),
    created_ts        TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN ('active','superseded','rolled_back')),
    backtest_summary  TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_param_versions_one_active
    ON param_versions(status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_param_versions_created ON param_versions(created_ts);

CREATE TABLE IF NOT EXISTS param_audit (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           TEXT NOT NULL,
    version_id   INTEGER NOT NULL,
    action       TEXT NOT NULL,
    source       TEXT NOT NULL,
    detail_json  TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_param_audit_version ON param_audit(version_id);

CREATE TRIGGER IF NOT EXISTS param_audit_no_update
BEFORE UPDATE ON param_audit
BEGIN
    SELECT RAISE(ABORT, 'param_audit is append-only');
END;

CREATE TRIGGER IF NOT EXISTS param_audit_no_delete
BEFORE DELETE ON param_audit
BEGIN
    SELECT RAISE(ABORT, 'param_audit is append-only');
END;
