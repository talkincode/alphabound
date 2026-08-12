-- WebAuthn credentials for dashboard passkey login (optional; file store is primary).
CREATE TABLE IF NOT EXISTS webauthn_credentials (
    credential_id TEXT PRIMARY KEY,
    public_key_sec1 BLOB NOT NULL,
    sign_count INTEGER NOT NULL DEFAULT 0,
    created_ts TEXT NOT NULL
);
