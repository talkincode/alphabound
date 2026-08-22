-- External signed intelligence (alphabound.intel.v1).
-- Append-only ingest; AlphaBound does not collect. Signature/nonce stored
-- for audit but never returned on Dashboard/API list payloads.

CREATE TABLE IF NOT EXISTS intel (
    id            TEXT PRIMARY KEY,
    source_id     TEXT NOT NULL,
    kind          TEXT NOT NULL CHECK (kind IN ('macro','news','flow','regulatory','narrative','onchain')),
    instrument    TEXT NOT NULL,
    headline      TEXT NOT NULL,
    body          TEXT NOT NULL,
    claims_json   TEXT NOT NULL,
    tags_json     TEXT NOT NULL DEFAULT '[]',
    refs_json     TEXT NOT NULL DEFAULT '[]',
    conf_milles   INTEGER NOT NULL,
    as_of_ms      INTEGER NOT NULL,
    expires_ms    INTEGER NOT NULL,
    dedup_key     TEXT NOT NULL UNIQUE,
    nonce         TEXT NOT NULL,
    signature     TEXT NOT NULL,
    accepted_ms   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_intel_accepted ON intel(accepted_ms DESC);
CREATE INDEX IF NOT EXISTS idx_intel_expires ON intel(expires_ms);
CREATE INDEX IF NOT EXISTS idx_intel_kind ON intel(kind, accepted_ms DESC);
