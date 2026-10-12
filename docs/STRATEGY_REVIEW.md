# 策略参数复盘

每日一轮（可配置）的过滤层参数复盘。它和 LLM 定期复盘（`/api/v1/review/periodic`）是两条通道：这里不调用模型，不写记忆，也不新增下单入口。`max_drawdown` 仍是 `0.10`。

交易循环不调用这段代码。后台车道自己打开数据库，读一份已经发布的组合快照（回撤、风险模式），跑完再写报告。任何未捕获错误都记一条 `failed` 报告，不改 active 版本。

## 开关

`[review]`：

| 键 | 默认 | 含义 |
|---|---|---|
| `strategy_mode` | `auto` | `auto`：硬边界内自动生效。`propose_only`：只留下 pending 提案。`off`：本轮不搜索、不改参数 |
| `strategy_interval_ms` | `86400000` | 间隔。最小 `3600000`。`0` 表示不定时，HTTP/MCP 仍可手动触发 |

进程启动后，第一次定时运行要等满一个间隔。手动触发不等。示例配置里这两个键保持注释：更旧的二进制会拒绝未知键，回滚二进制时不应因此起不来。

观察窗口里的安全回滚不因 `off` 取消。窗口健康时，`off` 只记 `skipped`，参数不动。

## 一轮里做什么

1. **对账。** 用最近约 40 天的 1m bid 聚成 15m，从该窗口第一笔权益样本的现金和 BTC 起步重放已记录决策。实盘曲线先减去 `capital_flow`，两边都做成起点为 1 的增长指数。绝对偏差的最大值超过 `0.05` 时，本轮 `aborted`（`reconcile_deviation`），不搜索、不改参数。样本不够或起点现金和 BTC 都是 0，记 `failed` / `reconcile_unavailable`。
2. **行情。** 用收盘价划分趋势（涨跌超过 2% 为 up/down，否则 flat）和波动（bar 收益标准差 &lt; 0.004 为 low，&gt; 0.015 为 high）。相对 BTC 持有的落后记在 `lag_pp`（百分点）。落后至少 1 个百分点、趋势向上、平均仓位低于 0.55，并且未投资部分的现金拖累能解释落后的大部分时，`cause` 为 `low_position`。这只写进报告。`position_cap` 只能下调，自动搜索不会为了提高仓位去抬它。
3. **邻域。** 相对当前 active，按固定顺序对重放真正会碰到的字段各做一步向下、一步向上：`min_trade_equity_frac`、`daily_trade_cap`、`reverse_cooldown_ms`、`trend_ma_period`，步长是当前值的 1/5（截断），再经 `validate`（绝对边界、单参数 ≤20%）。最多 8 个，顺序固定。单向旋钮和调度旋钮不在自动邻域里。
4. **门槛。** 每个候选跑第 3 期回测门槛（70/30、至少 4 个窗口、窗口回撤 &lt; 8%）。取通过且样本外 alpha 改善超过噪声带（0.002）的最大者；并列留更早的下标。没有这样的候选则 `no_candidate`。
5. **生效。** 仅当 `strategy_mode=auto`、实盘回撤 **小于** 5%、风险模式 `NORMAL`、且 24 小时内没有成功的 apply。通过已有的 `apply_params`，`source=review`，操作者 `strategy_review`，并带上该候选的 `backtest_summary`。不满足时只 `propose`，报告里写原因（`drawdown` / `risk_mode` / `too_soon` / `switch_propose_only`）。apply 被拒绝则 active 不变，报告为 `proposed` / `apply_rejected`。
6. **观察 72 小时。** 与变更前基线和回测预期比较。回撤比基线或预期高出超过 2 个百分点，或满 1 小时后成交频率超过基线的 2 倍与「基线每天 +1 笔」中的较大者且达到每天 2 笔，则 `rollback_params` 回到变更前版本并清掉观察。观察期内不再应用新变更。窗口到期后清掉观察，下一轮可以再搜索。

## 报告

表 `strategy_reviews`，形状 `alphabound.strategy_review.v1`。字段包括数据范围、行情、每个候选的通过与否和回测引用、选中下标、是否应用或回滚及原因、`max_drawdown_locked`（`0.10`）。观察状态在 `strategy_review_watch`（单行）。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/review/strategy` | 最近 20 条摘要 |
| GET | `/api/v1/review/strategy?id=` | 一份完整报告 |
| POST | `/api/v1/review/strategy` | 只把原子标记置位，202。车道忙时 409。未配置管理令牌时 401 |

MCP：`list_reviews`、`get_review`、`run_strategy_review`。触发工具不代填参数，也不把 `source` 改成 `mcp`；真正改版本的仍是 daemon 内部的 `source=review`。

## 做不到的事

- 纸面重放和实盘曲线经常会差过 5%。这时中止是预期行为，不是把偏差修进参数。
- 门槛只重放已经记下的决策，不能说明模型在新参数下会提出什么。调度旋钮不改变这次重放，所以不参与自动搜索。
- 对账使用窗口内第一笔样本的现金和 BTC。没有这笔样本时安全失败。
- 变更之后如果报告没能落库，24 小时闸门仍会挡住下一次 apply。回滚写失败时观察行保留，下一轮再试。
