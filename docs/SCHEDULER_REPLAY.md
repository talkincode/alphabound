# Offline scheduler replay

Run with Zig 0.16:

```sh
zig build replay-scheduler -- public-marks.csv > comparison.csv
zig build test
```

This executable imports the real scheduler directly, without daemon startup,
network, LLM, database or trading operations. Use public market marks only.
Do not commit real production CSVs or account data.
For runtime configuration, freshness gates and audit fields, see
[高波动自适应决策调度](VOLATILITY_SCHEDULING.md).

## Input contract

CSV contains only `timestamp_ms,bid`, with that exact optional first-line header.
Unix timestamps are positive integer milliseconds, strictly increasing; prices
are positive plain decimals with at most eight fractional digits. LF and CRLF
are accepted. Empty internal lines, extra columns, whitespace, exponent notation,
duplicate/out-of-order timestamps and invalid prices are errors, not skipped rows.
The entire file is validated before any comparison is printed. Errors identify
the line without echoing its contents.

Limits: 64 MiB input, two million observations, 128 bytes per row, timestamps
through year 9999 and bids no greater than one billion. Memory is bounded by the
input buffer and scheduler state; observations are not accumulated separately.

## Fixed synthetic decision policy

Both scheduler instances see identical prices and timestamps, observe before
evaluating, start cold, and commit every fired verdict. Every decision is a
synthetic HOLD, records a no-op, and requests `review_after=4h` (cap also 4h).
There are no trades, capital flows, changing risk modes or drawdowns. Risk mode
stays `exit_only`, drawdown stays zero, and all UTC hours are active.

Shared parameters: base 15 minutes, minimum 3 minutes, price move 0.005,
price drift 0.02, no-op cooldown cap 30 minutes. The only difference is volatility
entry: old=0 (disabled), new=0.01. Both use exit=0.006, volatility cadence=3 minutes,
exit hold=15 minutes, and the scheduler's fixed 15-minute coverage window with
maximum 90-second observation gaps.
The oldest minute-extrema bucket is retained in full, so the window can extend
0–59,999 milliseconds beyond 15 minutes.

This is **policy-fixed scheduling replay, not a causal trading or PnL backtest**.
Actual decisions would alter future state. One-minute samples cannot establish
exact tick-level trigger timing or reconstruct intervening price extrema.

## Output

Stdout is aggregate CSV, with one row per reason/model/observed UTC day, plus
totals (`utc_epoch_day=-1`). UTC day is integer days since 1970-01-01. Zero-count
reasons are retained. No empty calendar days are manufactured across data gaps.
Decision gap extrema are for all decisions in the indicated model/day, not
only the row's reason; a cross-midnight gap belongs to the firing day.
Zero gap extrema mean no pair of decisions was available, never an actual
zero-length decision interval.

Stderr reports sample count, sample gap extrema and estimated ready/high-vol
minutes. Durations use the previous observation's state until the next sample,
only when the gap is at most 90 seconds; longer gaps are counted separately as
unknown, not extrapolated. High-vol time requires readiness. No duration is
assigned after the final sample. These are sampled estimates, not tick-exact
durations. The utility rejects any decision interval shorter than three minutes
after first run, including in optimized builds.

For reproducible comparisons preserve the input hash, repository revision,
Zig version and aggregate output outside the public repository as appropriate.
The automated flat-price fixture verifies identical old/new four-hour cadence;
an oscillating-price fixture exercises volatility under the cooldown invariant.
Parser fixtures exercise strict rejection without using account data.
