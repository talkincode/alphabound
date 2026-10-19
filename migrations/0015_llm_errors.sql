-- Independent operational history: no cascading foreign key to short-lived runs.
CREATE TABLE llm_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms INTEGER NOT NULL,
    run_id TEXT NOT NULL,
    cause TEXT NOT NULL CHECK (cause IN ('timeout','connect','empty','api_status','http_failed','malformed','breaker_open','budget_exhausted')),
    http_status INTEGER,
    model TEXT NOT NULL,
    attempt INTEGER NOT NULL,
    detail TEXT NOT NULL
);
CREATE INDEX llm_errors_recent ON llm_errors(ts_ms DESC, id DESC);
