-- Dynamic strategy parameters (phase 2). Widen the version status so a
-- proposal can sit as `pending` or `rejected` without becoming active.
-- SQLite cannot alter a CHECK in place, so the table is rebuilt.
-- max_drawdown is still not a column. Writes never touch orders.

CREATE TABLE param_versions_v2 (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    params_json       TEXT NOT NULL,
    source            TEXT NOT NULL CHECK (source IN ('bootstrap','manual','mcp','review')),
    parent_id         INTEGER REFERENCES param_versions_v2(id),
    created_ts        TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN ('active','superseded','rolled_back','pending','rejected')),
    backtest_summary  TEXT NOT NULL DEFAULT ''
);

INSERT INTO param_versions_v2 (id, params_json, source, parent_id, created_ts, status, backtest_summary)
SELECT id, params_json, source, parent_id, created_ts, status, backtest_summary
FROM param_versions
ORDER BY id;

-- foreign_keys stays ON for the whole migration transaction, and a self-FK
-- makes DROP TABLE's implicit DELETE fail while parent_id still points at a
-- row. The copy above already kept the chain. Null the old links, then drop.
UPDATE param_versions SET parent_id = NULL;

DROP TABLE param_versions;
ALTER TABLE param_versions_v2 RENAME TO param_versions;

-- RENAME does not retarget sqlite_sequence, so the next id would restart.
UPDATE sqlite_sequence SET name = 'param_versions' WHERE name = 'param_versions_v2';

CREATE UNIQUE INDEX IF NOT EXISTS idx_param_versions_one_active
    ON param_versions(status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_param_versions_created ON param_versions(created_ts);
