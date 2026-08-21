-- Durable LLM metering ledger. Rows contain only accounting and health metadata:
-- never prompts, completions, endpoints, credentials, or provider error bodies.
--
-- Costs are market-price estimates in nano USD (1 USD = 1,000,000,000 nano USD).
-- A row remains useful even if the model omits usage or has no recognized
-- pricing profile: `usage_reported` / `cost_known` make that incompleteness
-- explicit instead of treating unknown spend as zero.

CREATE TABLE IF NOT EXISTS llm_usage (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    ts                    TEXT NOT NULL,
    call_kind             TEXT NOT NULL,
    run_id                TEXT NOT NULL DEFAULT '',
    decision_id           TEXT NOT NULL DEFAULT '',
    model                 TEXT NOT NULL,
    outcome               TEXT NOT NULL CHECK (outcome IN ('ok','error')),
    error_class           TEXT NOT NULL DEFAULT '',
    latency_ms            INTEGER NOT NULL DEFAULT 0,
    usage_reported        INTEGER NOT NULL DEFAULT 0 CHECK (usage_reported IN (0,1)),
    prompt_tokens         INTEGER NOT NULL DEFAULT 0,
    cached_prompt_tokens  INTEGER NOT NULL DEFAULT 0,
    completion_tokens     INTEGER NOT NULL DEFAULT 0,
    total_tokens          INTEGER NOT NULL DEFAULT 0,
    price_profile         TEXT NOT NULL DEFAULT '',
    input_cost_nano_usd   INTEGER NOT NULL DEFAULT 0,
    output_cost_nano_usd  INTEGER NOT NULL DEFAULT 0,
    cost_known            INTEGER NOT NULL DEFAULT 0 CHECK (cost_known IN (0,1))
);

CREATE INDEX IF NOT EXISTS idx_llm_usage_ts ON llm_usage(ts);
CREATE INDEX IF NOT EXISTS idx_llm_usage_kind_ts ON llm_usage(call_kind, ts);
CREATE INDEX IF NOT EXISTS idx_llm_usage_model_ts ON llm_usage(model, ts);
