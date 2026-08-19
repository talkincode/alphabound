-- Small runtime key/value store (持久化运行时基线). Applied by src/storage/db.zig.
-- First user: shadow buy-and-hold benchmark baseline, so alpha survives
-- daemon restarts instead of resetting to the current bid.

CREATE TABLE IF NOT EXISTS runtime_kv (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_ts TEXT NOT NULL
);
