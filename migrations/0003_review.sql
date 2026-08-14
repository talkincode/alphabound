-- Human review chat transcripts (复盘对话). Applied by src/storage/db.zig.
-- Review chat is analysis-only: it never feeds the trading loop directly.
-- Conversations may be explicitly summarized into a low-confidence memory.

CREATE TABLE IF NOT EXISTS review_chats (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    decision_id TEXT NOT NULL,
    anchor_ts   TEXT NOT NULL DEFAULT '',   -- decision timestamp (chart anchor)
    role        TEXT NOT NULL CHECK (role IN ('user','assistant','summary')),
    content     TEXT NOT NULL,
    model       TEXT NOT NULL DEFAULT '',
    created_ts  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_review_chats_decision ON review_chats(decision_id, id);
