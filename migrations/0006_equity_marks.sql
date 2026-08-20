-- Make the 1m equity trail a self-contained joint series for 复盘 attribution.
--
-- Before this migration a sample only stored `btc_value = btc_total * bid_price`,
-- which multiplies price and quantity into one number. On the exact minutes that
-- matter for review (a fill lands) it is impossible to tell whether btc_value
-- moved because the market moved or because the agent rebalanced.
--
-- Adding the marks below lets AB-factor analytics separate 价格漂移 from 主动调仓,
-- and reconstruct the buy-and-hold baseline as a series instead of a single
-- point-in-time comparison.
--
-- Rows written before this migration keep '' (unknown) — analytics must treat
-- empty marks as "data not available" rather than backfilling a guess.

ALTER TABLE equity_samples ADD COLUMN bid_price TEXT NOT NULL DEFAULT '';
ALTER TABLE equity_samples ADD COLUMN btc_qty   TEXT NOT NULL DEFAULT '';
ALTER TABLE equity_samples ADD COLUMN bh_equity TEXT NOT NULL DEFAULT '';
