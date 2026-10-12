-- Dynamic strategy parameters (phase 3). Stored backtest gate reports.
--
-- A row is the alphabound.backtest_ref.v1 document apply_params looks up.
-- It records the candidate parameters, the baseline version they were scored
-- against, the data-range hash, and the pass/fail report. Nothing here is an
-- order. max_drawdown is not a column.

CREATE TABLE IF NOT EXISTS backtest_reports (
    id                  TEXT PRIMARY KEY,
    created_ts          TEXT NOT NULL,
    as_of_ms            INTEGER NOT NULL,
    passed              INTEGER NOT NULL CHECK (passed IN (0, 1)),
    params_json         TEXT NOT NULL,
    baseline_json       TEXT NOT NULL,
    baseline_version_id INTEGER NOT NULL,
    range_hash          TEXT NOT NULL,
    digest              TEXT NOT NULL,
    report_json         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_backtest_reports_as_of ON backtest_reports(as_of_ms);
