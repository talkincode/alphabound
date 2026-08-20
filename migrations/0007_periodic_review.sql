-- Periodic review reports (定期复盘). Applied by src/storage/db.zig.
--
-- Two cadences share this table: `short` (default every 8h) and `long`
-- (default weekly). Each row is one closed window: the deterministic facts
-- collected from the ledger plus, when an LLM is configured, the validated
-- review document (summary / findings / lessons / applied memory ops).
--
-- Analysis-only, like the human 复盘 channel: nothing here reaches the
-- trading path except through the memory it distills, which the agent may
-- retrieve and weigh like any other low-confidence memory.
--
-- status: ok        — model document parsed and applied
--         degraded  — facts recorded, no usable model document (no LLM /
--                     call failed / invalid JSON); memory untouched
--         failed    — the window could not be collected at all

CREATE TABLE IF NOT EXISTS periodic_reviews (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    review_id    TEXT NOT NULL UNIQUE,
    cycle        TEXT NOT NULL CHECK (cycle IN ('short','long')),
    ts           TEXT NOT NULL,
    window_from  TEXT NOT NULL DEFAULT '',
    window_to    TEXT NOT NULL DEFAULT '',
    status       TEXT NOT NULL CHECK (status IN ('ok','degraded','failed')),
    trigger      TEXT NOT NULL DEFAULT 'schedule',
    summary      TEXT NOT NULL DEFAULT '',
    memory_id    TEXT NOT NULL DEFAULT '',
    ops_applied  INTEGER NOT NULL DEFAULT 0,
    model        TEXT NOT NULL DEFAULT '',
    report_json  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_periodic_reviews_ts ON periodic_reviews(ts);
CREATE INDEX IF NOT EXISTS idx_periodic_reviews_cycle ON periodic_reviews(cycle, id);
