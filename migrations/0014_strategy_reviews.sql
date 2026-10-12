-- Dynamic strategy parameters (phase 4). Scheduled strategy reviews.
--
-- One row is one round: reconciliation, regime, candidate backtests, and
-- whether the round applied, proposed, rolled back, or stopped. The watch
-- row is the 72h observation window after an automatic apply. Nothing here
-- is an order. max_drawdown is not a column.

CREATE TABLE IF NOT EXISTS strategy_reviews (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    review_id   TEXT NOT NULL UNIQUE,
    ts          TEXT NOT NULL,
    as_of_ms    INTEGER NOT NULL,
    status      TEXT NOT NULL,
    trigger     TEXT NOT NULL,
    summary     TEXT NOT NULL,
    report_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_strategy_reviews_ts ON strategy_reviews(as_of_ms);

CREATE TABLE IF NOT EXISTS strategy_review_watch (
    id                      INTEGER PRIMARY KEY CHECK (id = 1),
    active                  INTEGER NOT NULL CHECK (active IN (0, 1)),
    started_ms              INTEGER NOT NULL,
    until_ms                INTEGER NOT NULL,
    previous_version_id     INTEGER NOT NULL,
    applied_version_id      INTEGER NOT NULL,
    baseline_drawdown       REAL NOT NULL,
    baseline_trades_per_day REAL NOT NULL,
    expected_max_drawdown   REAL NOT NULL
);
