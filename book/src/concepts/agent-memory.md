# Agent、工具与记忆

慢循环负责「想清楚再建议」，从不直接碰下单接口。

## 决策闭环（设计 §5.4）

| 步 | 名称 | 要点 |
|---|---|---|
| 1 | Trigger | 定时 / 行情异常 / invalid_if / 人工 |
| 2 | Snapshot | 不可变快照 + `snapshot_version` |
| 3 | Context | 检索记忆与近期事件 |
| 4 | Investigate | 自主选工具；全审计 |
| 5 | Propose | Decision Proposal；Schema 校验 |
| 6 | Admit | Risk Kernel |
| 7 | Execute | 幂等订单（shadow 不下真单） |
| 8 | Reconcile | 账户与订单确认 |
| 9 | Evaluate | 多时间窗结果，不只看盈亏 |
| 10 | Reflect | 结构化反思 + `memory_ops` |

## Context（`agent/context.zig`）

每轮送给模型的是**稳定能力边界**，不是聊天流水账。固定五段 JSON：

1. `current_state` — 净值、仓位、HWM、回撤、模式、是否已对账
2. `recent_events` — 有界最近事件
3. `memories` — 检索命中的长期记忆
4. `tools` — 注册表中的可用工具与时效/成本元数据
5. `risk_rules` — 不可变边界说明（`immutable: true`）

渲染**字节级确定性**，便于 `agent_runs.input_digest` 回放比对。

## Proposal（`agent/proposal.zig`）

唯一合法「想交易」的形状。必填语义包括：

- `decision_id`（`dec_…`）
- `snapshot_version`
- `action`: `HOLD` | `REBALANCE`
- `target`（再平衡时 BTC 权重）
- `order_policy` / `confidence` / `thesis` / `invalid_if` / …

任何坏 JSON、缺字段、越界置信度 → **整单作废**（fail-closed HOLD）。

## 工具注册表（`tools/registry.zig`）

| 域前缀 | 例子 |
|---|---|
| `market.*` | K 线、成交、簿、波动 |
| `derivatives.*` | 资金费率、OI、基差 |
| `onchain.*` / `wallet.*` | 网络与地址活动 |
| `macro.*` / `news.*` | 宏观与新闻 |

统一 `ToolResult`：

```text
status: OK | UNAVAILABLE | STALE | ERROR
source, as_of, confidence?, latency_ms, cost_usd
data_json   ← 不可信
raw_ref?
```

- 超时/不可用 → `UNAVAILABLE`，**禁止**把缺失编成 0
- 超过 `max_age_ms` 或 `as_of` 不明 → 有效状态降为 `STALE`
- 每次调用写审计（digest），供「哪些数据真改善了决策」统计

## 五层记忆（`memory/store.zig`）

| 层 | 内容 | 检索 |
|---|---|---|
| Current State | 账户与风险（来自状态机，非本表） | 每轮必带 |
| Working | 近事件、开放情节 | 时间窗 + 重要度 |
| Episodic | 完整交易摘要 | 相似环境 |
| Strategy | 假设与证据 | 相关 + 证据数 |
| Reflection | 偏差与改进 | 近 + 高影响 |

版本化记录 `(memory_id, version)` 追加；结构化 `memory_ops`：

- `CREATE` / `UPDATE` / `INVALIDATE` / `MERGE`

置信度钳制在 \[0,1\]；非法 op 在 Reflection 解析期整篇作废。

## Reflection（`agent/reflection.zig`）

只产出可审计结构：预期 vs 多窗口实际结果、`error_type`、`lessons`、`memory_ops`。  
**不保存**隐藏 chain-of-thought。

## 当前实现边界

已落地（单测覆盖）：Schema、Context 渲染、Registry、Memory ops、Reflection 解析与 store 联动、DB 表与 Repo。

已本机验证：OpenAI 兼容 LLM 实调 + shadow 提案审计。仍待：具体 provider 工具、Dashboard 回放、Shadow 影子收益对比长跑。详见 [路线图 Phase 2](../planning/roadmap.md)。
