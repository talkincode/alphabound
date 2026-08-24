-- Explicit external deposits/withdrawals and per-sample flow attribution.
-- Raw account equity remains unchanged; performance consumers remove these
-- flows instead of treating capital movement as strategy profit or loss.

CREATE TABLE IF NOT EXISTS capital_flows (
    flow_id       TEXT PRIMARY KEY,
    ts            TEXT NOT NULL,
    direction     TEXT NOT NULL CHECK (direction IN ('deposit','withdrawal')),
    cash_delta    TEXT NOT NULL,
    btc_delta     TEXT NOT NULL,
    quote_value   TEXT NOT NULL,
    equity_before TEXT NOT NULL,
    equity_after  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_capital_flows_ts ON capital_flows(ts);

ALTER TABLE equity_samples ADD COLUMN capital_flow TEXT NOT NULL DEFAULT '';
ALTER TABLE equity_samples ADD COLUMN capital_flow_moment TEXT NOT NULL DEFAULT '';
