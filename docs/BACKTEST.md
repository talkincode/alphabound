# 离线回测（`zig build backtest`）

确定性离线回测：**历史 K 线 + 决策序列 → Risk Kernel 准入 → 收紧型护栏 → 模拟成交**。
不起 daemon、不联网、不读时钟/随机数、不调 LLM；同一输入逐字节输出相同 JSON。
用于在不动实盘的前提下，对比「护栏前 / 后」的收益、回撤、交易数、手续费与反复买卖。

```sh
zig build backtest -- --candles candles.csv --decisions decisions.csv --initial-cash 1000
zig build backtest -- --candles candles.csv --agent rule        # 规则代理替代 LLM
zig build backtest -- --help
```

## 输入（全部是本地文件，**勿提交真实生产数据**）

| 参数 | 格式 | 说明 |
|---|---|---|
| `--candles` | `ts_ms,close` 或 `ts_ms,open,high,low,close,…`（升序） | 默认按 15m 理解；成交在**下一根 bar 开盘价** ± 滑点 |
| `--decisions` | `ts_ms,target_weight[,agent\|operator[,macro 0\|1]]` | 已记录的目标仓位；`operator` 行是人工通道，护栏不拦 |
| `--agent rule` | — | 内置 50D 均线规则代理，用于没有决策记录的区间 |
| `--daily` | `ts_ms,close` | 已收盘日线，用于 50D 趋势；缺省时由 K 线聚合 |
| `--flows` | `ts_ms,cash_delta,btc_delta` | 外部出入金；用于调整 HWM 与时间加权收益（TWR） |

成本口径：taker 0.1%、滑点 0.05%（均可用 `--fee` / `--slippage` 覆盖）。
准入使用生产同一份 `risk/admission.zig`（`admit` / `heldExposure` / 退出预留 / 价格冲击），
HWM×(1−`max_drawdown`) 回撤底线触发后按「平仓后 HALT」处理。

## 三种策略口径（`--policy recorded|baseline|guarded|all`）

- `recorded`：原样重放决策，仅过准入，不设最小交易额；
- `baseline`：生产当前口径（只有 `min_trade_notional`）；
- `guarded`：`baseline` + `risk/guardrails.zig` 的收紧型护栏（与 daemon 共用同一份代码）。

## 输出

JSON，每个口径一行：`twr_return`、`hold_return`、`alpha`、`max_drawdown`、
`trades/buys/sells`、`fees_usdt`、`turnover_usdt`、`churn_reversals`（窗口内方向反转，默认 2h）、
`blocked.{min_trade,daily_cap,reverse_cooldown,macro_sell}`、`admission_rejects`，
以及安全指标 `floor_breaches`、`stress_breach_bars`、`forced_exits`、`halted`。
**合并门槛**：`floor_breaches = 0`、`stress_breach_bars = 0`，且回撤不高于基线。

## 护栏（`risk/guardrails.zig`）：只收紧、不放宽

护栏是准入**之后**的否决层：被否决 = HOLD；永远不修改 Risk Kernel 裁决，
不触碰 HWM×0.9 回撤底线、退出预留与 fail-closed 检查。强制退出（风控模式非 normal、持仓已越界）
与人工 `operator` 通道**豁免**。

| 护栏 | 默认 | 行为 |
|---|---|---|
| 最小交易额 | 权益 5%（并保留绝对 `min_trade_notional`） | 小额来回买卖直接拒绝；清仓、以及账户已低于 HWM ≥1% 时的卖出只受绝对下限约束 |
| 日交易上限 | 6 笔 / 24h | 只数 agent 自主决策的成交（不含 operator / 强制退出）；回撤 ≥1% 的卖出豁免 |
| 反向交易冷却 | 4h | 刚买不立刻卖、刚卖不立刻买；回撤 ≥1%（`guard_sell_exempt_drawdown`）的卖出豁免——降风险不能被冷却拖住 |
| 宏观卖出需趋势破位 | **默认关**（`guard_macro_sell_trend_break`） | 论点命中宏观关键词的卖出，须最近一根已收盘日线低于 50D 均线；日线不足 50 根时 fail-closed 拒绝该类卖出；同样豁免回撤 ≥ `guard_sell_exempt_drawdown` 的卖出 |
| HOLD 压测实际持仓 | 开（仅告警，不改执行） | HOLD 的目标权重恒为 0，准入压测的是空仓。现在额外按**实际持仓**压测，裕度不足发 `HELD_EXPOSURE_ALERT`（thin / breach） |

配置键（`[risk]`，均可缺省；**不要为了“显式”而写进生产配置**——旧二进制拒绝未知键，会破坏回滚）：
`guard_min_trade_equity_frac`、`guard_daily_trade_cap`（0=关）、`guard_reverse_cooldown_ms`、
`guard_macro_sell_trend_break`、`guard_sell_exempt_drawdown`。

触发时 daemon 记 `EXEC_GUARDRAIL` 事件（含原因与当日统计），决策回到 HOLD 并按退避重新评估。

## 首轮对比（2026 年 8–10 月，BTC-USDT，仅百分比）

三个窗口：**W1** 早期来回买卖期、**W2** 主窗口（约 6 周）、**W3** FOMC 事件窗（W2 的子集）。数据来自生产 K 线与成交账本（本地私有，未入库）。
`baseline` → `guarded`，均为 0.1% taker + 0.05% 滑点：

| 窗口 | TWR | 最大回撤 | 交易数 | 手续费 |
|---|---|---|---|---|
| W1 | +1.69% → +1.50% | 0.77% → 0.53% | 17 → 6（−65%） | −35% |
| W2 | −1.60% → −1.48% | 5.24% → 5.14% | 29 → 26 | −4.5% |
| W3 | −1.43% → −1.44% | 2.77% → 2.77% | 15 → 14 | ±0% |

三个窗口 `floor_breaches = 0`、`stress_breach_bars = 0`、`forced_exits = 0`。结论：
**回撤不升、交易数与手续费下降、收益基本持平**（W1 少 0.19pp，W2 多 0.12pp，W3 持平，属路径依赖噪声）。
护栏的价值是减少无谓换手，**不是**提高收益。

### 宏观卖出趋势破位门（默认关，已实现并有单测）

按任务原意（卖出前须日线收于 50D 均线下、且不豁免 5% 以内的浮亏）在 W2/W3 回测：
W3 收益由 −1.4% 升到 +1.4%、交易数 15 → 2，但**最大回撤由 2.8% 升到 4.0%**；W2 收益与回撤均变差
（−1.70% / 5.56%）。它用更高的已实现回撤换收益，且只在**一个**重叠事件上成立，
不满足「安全不降低」的合并门槛，所以**不默认开启**。需要时在 `[risk]` 打开
`guard_macro_sell_trend_break = true` 并先用本工具在新数据上复核。

## 局限（务必如实看待）

- **决策是重放而非重新生成**：已记录的 LLM 决策没有见过「被否决后」的账户，
  否决一笔交易会让后续绝对目标作用在不同的持仓上；回放中的决策由成交账本**反推**，不是 LLM 原始输出。
- 成交 = 下一根 bar 开盘价 + 固定滑点 + 0.1% 费；无盘口、部分成交、排队、限价单与延迟。
- 15m 粒度：看不到 bar 内回撤与 bar 内压测越界。
- 风险状态机（EXIT_ONLY / FLATTENING 时序、人工复位）被简化为「下一根 bar 平仓后 HALT」。
- 宏观标记来自论点关键词（有记录论点时），规则代理没有宏观视角。
- 部分早期出入金没有记录，回测窗口刻意避开；初始状态取自当时的净值样本。
- **单一样本路径、单一行情（8–10 月）**：结果只是该区间的证据，不是预测。
  最小交易额 5% 是该区间里唯一让收益/回撤/交易数/手续费同时不变差的取值，证据强度有限，
  可能误拦个别合理的小额减仓，需持续观察 `EXEC_GUARDRAIL` 事件。

## 复现与测试

`src/backtest.zig` 内含 5 个单测（平盘只亏手续费且恰为 0.1%、确定性、护栏拦截来回买卖、硬回撤底线仍平仓、CSV 解析）；
`src/risk/guardrails.zig` 有护栏的纯函数单测；`zig build test` 一并运行。
