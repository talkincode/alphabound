-- Scheduled audit reports (定时审计). Applied by src/storage/db.zig.
-- Deterministic rule-engine output; full findings JSON for replay.

CREATE TABLE IF NOT EXISTS audit_reports (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    audit_id    TEXT NOT NULL UNIQUE,
    ts          TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('ok','warn','alert')),
    findings    INTEGER NOT NULL DEFAULT 0,
    report_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_reports_ts ON audit_reports(ts);
