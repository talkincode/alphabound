# Decision horizon and timing feedback (2026-10)

A review of the live decision log after the September overhaul found that
the sell-low / buy-high pattern had changed shape rather than disappeared,
and that the agent had no way to see it. This note records the evidence,
what changed, and how it was checked. It intentionally contains no account
figures.

## Evidence

**Timing attribution.** Split the book's price-only return into what the
window's *average* BTC weight would have earned held constant and the
remainder created by changing the weight (method in
`src/agent/attribution.zig`). Over every sub-window checked since late
August — before the overhaul, after it, and after the evidence-isolation
release — the timing term was negative, by roughly one to two percentage
points per window. The weight changes cost money relative to doing nothing.

**Mechanism.** After the overhaul the agent no longer laddered, but it built
every plan from 4H closes against the 4H 20-bar range and SMA20: "cut on a 4H
close below X, add on a 4H close above Y", with X and Y about one daily ATR
apart. In a multi-week consolidation, ordinary oscillation fires both levels
alternately, so the book bought range highs and sold range lows. Most trades
were taken right after a price-move or volatility wake-up.

**Exposure.** Through the same weeks the multi-month trend was up (price well
above rising 50/100-day means, strongly positive 90-day return), while the
average weight stayed well below half. The agent could not see this: its
longest view was 45 daily bars, all structure fields were 20-bar, and
`self_review` showed only the last few fills without any counterfactual.

## What changed

- **`structure.1D_long`** (`src/tools/indicators.zig`). The 1D candle
  request now fetches 200 bars in the same single call; the compact rows and
  20-bar structure still use the newest 45, so existing fields are
  byte-identical. From completed bars only: 50/100/200-day SMA and distance,
  `sma50_slope10_pct`, trailing 7/30/90/180-day returns, 90-day range and
  position, distance from the window high, 30-day realized volatility. Each
  field appears only when its full lookback exists.
- **`self_review.attribution`** (`src/agent/attribution.zig`,
  `collectAttribution` in `src/main.zig`). 7d and 30d windows from hourly
  equity marks, clipped to the decision-evidence cohort (`clipped: true`)
  and reported `available: false` below 12 marks: `btc_return`,
  `avg/min/max_btc_weight`, `book_return`, `static_return`,
  `timing_return`. Price-only, so fees and capital flows cannot leak in.
- **`vs_now_bps` on fills.** Each fill is marked at the current quote
  (positive = the trade helped versus not trading, before fees). Up to 10
  fills are shown instead of 6.
- **Prompt (`prompts/system.md`)**, new section *Horizon, noise and your own
  timing record*: size on the horizon the weight is held (1D / `1D_long`),
  treat a lone 4H range break as timing rather than a new target, keep
  exposure-changing levels outside daily-ATR noise with add and cut levels
  more than about one daily ATR apart, treat persistent low exposure in an
  up-regime (and high exposure in a down-regime) as a position needing
  evidence, and read `timing_return` / `vs_now_bps` as evidence about the
  agent's own process. The timeframe-disagreement rule was reworded so it
  does not contradict this; no label gained a veto.
- **Fixes found on the way.** The indicator tool's `schema_note` quoted JSON
  without escaping, so the rendered context was not valid JSON; it is now
  escaped. The second (indicator) round's context omitted `prior_plan` and
  `lot_size`; it now carries the same evidence as the first round.

Unchanged: risk kernel, admission, drawdown boundary, execution, scheduler
cadence, memory policy and decision epoch. No deterministic trading rule was
added; the agent still chooses the target.

## Verification

- `zig build`, `zig build test` (new tests: attribution sign/zero/insufficient
  data/rendering, `1D_long` completed-only fields and omissions, fill
  `vs_now_bps` sign, hourly-mark query, context escaping and attribution
  section).
- Local `--agent-once` shadow run against a copy of the production database
  with the cohort relabelled to shadow: the context renders all new sections
  from real data, and the proposal parses and is admitted.
- Prompt A/B on that captured context with the live book substituted, eight
  samples per arm on the production model. Both arms chose HOLD in every
  sample. With the previous prompt and context, every plan set its add/cut
  levels on 4H closes about one daily ATR apart. With the new prompt and
  context, every plan used completed 1D closes, usually 1.3–2 daily ATR away,
  cited `1D_long` and `timing_return`, and chose longer review intervals.
  One sample still placed narrow levels; the rule is guidance, not enforced.

This shows the agent now reasons at the intended horizon and sees its own
timing record. It does not show the change is profitable; judge that from
`timing_return` and the benchmark after a live or shadow observation period.

## Follow-ups not done here

- Periodic reviews could receive the same attribution facts for their window.
- If 1D-basis plans still show negative `timing_return` after a few weeks,
  consider a deterministic check that the add and cut levels of a REBALANCE's
  plan are at least one daily ATR apart, instead of relying on the prompt.
