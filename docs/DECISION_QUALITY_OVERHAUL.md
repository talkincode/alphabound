# Decision-quality overhaul (2026-09)

A production review of six weeks of live decisions found one behaviour pattern
and several broken feedback loops. This note records what was wrong, what
changed, and how each change is verified. It intentionally contains no account
figures.

## What went wrong

**Pattern: sell-low / buy-high laddering inside a range.** With price in a
~10%-wide range, the agent trimmed exposure in ~10% steps over several days,
each step justified by the same sentence ("price below 1D and 4H SMA20 →
downtrend intact"), often while its own thesis noted "4H RSI < 35, at range
low, poor place to sell". It reached 0% at the range low, then held flat for
~25 consecutive decisions with the invalidation "1D close back above SMA20",
and re-entered in three steps after a +6% move. The same shape occurred twice
before on a smaller scale.

**Mechanisms (all confirmed in code):**

| # | Mechanism | Where |
|---|---|---|
| 1 | `structure` exposed only SMA20 / Donchian-20 / RSI and the prompt called it "first-party math … do not ignore a daily breakout". The model became a 20-bar trend filter with no notion of regime. | `prompts/system.md`, `src/tools/indicators.zig` |
| 2 | Only one hard self-check existed: `position_tension` (weight ≥ 0.85 & long HOLD streak → must write `reduce_eval`). Nothing symmetric forced a flat book to justify staying out. | `src/agent/context.zig`, `src/agent/proposal.zig` |
| 3 | `hold_streak` was `E_hold_streak.evidence_count`, a lifetime counter no rebalance ever reset. | `src/main.zig` |
| 4 | Event `thesis` strings were byte-sliced at 180 bytes, cutting UTF-8 characters in half. The periodic review embedded those bytes in its prompt; the provider rejected the request (HTTP 400 "invalid unicode code point"). **Every periodic review failed for ~2.5 weeks**, so the loop meant to notice "same mistake repeated" was dark. | `src/main.zig`, `src/agent/openai.zig` |
| 5 | HOLD reflection was deterministic and wrote the identical lesson hundreds of times; the strategy memory layer held zero active entries. | `src/main.zig` |
| 6 | `price_move` re-anchored on every decision and its cooldown doubled per no-op; a slow grind never woke the agent while `review_after` deferred the regular cadence up to 4h. | `src/core/scheduler.zig` |
| 7 | `LIMIT_OR_MARKET` executes as a plain market order (documented; left as is — see below). | `src/execution/demo_runner.zig` |
| 8 | Only the market-tick path journaled `RISK_MODE_CHANGED`; other engine messages flipped the mode silently, leaving orphan EXIT_ONLY→NORMAL events at decision time. | `src/core/state.zig`, `src/main.zig` |
| 9 | Twice, the first decision after a restart (`first_run`, bare context) produced an immediate trim. | `src/main.zig` |

## What changed

- **Regime-aware structure.** `structure.{1D,4H}` now carries `sma20_slope_pct`,
  `regime` (`range` / `trend_up` / `trend_down`, a documented rule on SMA20
  slope + side), `range20_width_pct`, `atr14_pct`, `prior_completed_low`,
  `broke_prior_low`. The prompt states that inside `range` SMA20 crossings are
  noise, that 1D sets the exposure budget and 4H the timing, and that the
  breakout bar at RSI > 75 is the worst add entry.
- **Symmetric tension.** `cash_tension` (weight ≤ 0.15, streak ≥ 4, cash covers a
  legal buy) mirrors `position_tension`; a HOLD under it must carry
  `add_eval {stay|add}` and `add` is only valid on a REBALANCE upward.
- **Real streak.** `hold_streak` = no-op proposals since the last executed one,
  derived from the audit log.
- **Prompt rules:** one view / one move (no laddering on an unchanged thesis);
  exit and re-entry are one plan (re-entry level written at the cut, bar never
  raised); a thesis cannot contradict its direction (oversold is not a sell
  reason); scheduled macro events are not a thesis; compare recent fills with
  the current price and say which thesis was wrong.
- **Feedback loops.** UTF-8-safe truncation (limits raised to 400/240 bytes)
  and UTF-8 repair in the LLM request writer; LLM reflection on every Nth
  consecutive no-op (`llm_reflection_hold_every`, default 6) and whenever
  either tension is set; reflection and periodic-review prompts ask for the
  symmetric findings.
- **Scheduler.** `price_drift` (default 2%) measures from the last traded
  price, accumulates across HOLDs and bypasses the no-op backoff. Recommended
  `event_noop_backoff_max_ms` lowered to 30 min.
- **Execution — deliberately unchanged.** `LIMIT_OR_MARKET` still executes as
  market. A passive-limit-first variant was written and reverted in review:
  the single-threaded limit wait has no ticker refresh, so venue reconcile is
  refused after `market_ttl_ms` and partial fills fall back to a synthetic
  full-quantity local fill; cancel confirmation is also weak. Fixing that is
  an execution-layer task (follow-up), and taker fees were never a material
  part of the underperformance.
- **Observability.** The engine records every mode transition (from, to,
  cause, folded bounces); `main` journals it from one place.
- **Restart guard.** A `first_run` REBALANCE is deferred (`exec=restart_guard`)
  when the previous decision is < 2h old.

## Verification

- `zig build` and `zig build test` (unit tests for regime classification,
  UTF-8-safe prefix, request-body repair, `cash_tension`, `add_eval` parsing
  and enforcement, `price_drift`, engine transition record).
- Local shadow run against a fresh DB (`--agent-once`): proposals parse, the
  model cites `regime`/slope figures, thesis stored untruncated, LLM reflection
  fires on the configured HOLD cadence and records a flat-book opportunity-cost
  memory.
- Local shadow run against a copy of the production database whose events
  contain the broken bytes: a manually triggered periodic review returns
  `status=ok` (previously `degraded` on every attempt).
- Staging deploy in shadow mode before any live deploy.
