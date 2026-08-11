# 风险模型

风险内核是确定性关键路径的核心：用**可清算净值**守住 HWM 回撤边界，并在准入时对提案做压力检查。

## 保守净值

不直接拿 mark price 当「你有多少钱」。估值扣除：

- 退出 taker 费用（`taker_fee_rate`）
- 退出滑点缓冲（`slippage_rate`）
- 挂单与未决风险（实现演进中）

相关代码：`src/risk/equity.zig`。

## HWM 与回撤

- **HWM（High Water Mark）**：保守净值的历史高点，单调不减（仅在已对账数据上推进）
- **Drawdown**：相对 HWM 的回撤比例，与设计公式一致，非负
- **边界**：`drawdown ≥ max_drawdown`（默认 10%）触发收敛流程

HWM 会持久化（equity 采样 / 启动恢复），避免重启「忘记」峰值。

## 风险状态机

```text
NORMAL ──(数据陈旧/不一致/…)──► EXIT_ONLY
NORMAL ──(触界)──► FLATTENING ──► HALTED
任何状态在硬故障下可进入更安全侧
HALTED ──✗──► （无自动回到可开仓）
```

| 模式 | 允许 |
|---|---|
| `NORMAL` | 在准入通过下可增险 / 减险 |
| `EXIT_ONLY` | 只减险或 HOLD，不新开增险 |
| `FLATTENING` | 撤增险挂单 → 退出 → 对账至 BTC 可用≈0 |
| `HALTED` | 停止自主交易；等人 |

实现：`src/risk/state_machine.zig`。启动未 reconcile 时 **fail-closed**，常以 `EXIT_ONLY` 起步。

## 准入（Admission）

提案进入执行前必须通过 Risk Kernel（`src/risk/admission.zig`），典型检查：

1. `snapshot_version` 仍是当前版本
2. 数据 freshness 足够
3. 无 order ambiguity / 未对账阻断
4. **压力净值** ≥ `HWM × (1 - max_drawdown) + ExitReserve`（地板）
5. 输出 `APPROVE` / `REDUCE` / `REJECT`（可降目标仓位）

坏 JSON、缺字段的提案在 Schema 层已作废，进不了准入。

## ExitReserve

边界不是贴着 10% 才跑——需要预留「刹车距离」。ExitReserve 校准依赖真实流动性与费用模型；设计承认极端行情仍可能穿透，系统职责是：

- 尽量提前动作
- **如实记录**穿透幅度与成交成本（不掩饰）

## 与 Agent 的关系

- Agent **看不见**也不配置风险参数
- 内核 **不解释** thesis 是否高明，只问「这笔若成交，压力下会不会穿界」
- LLM 挂了时，风险监控与退出能力必须继续工作（NFR / 故障矩阵）

## 配置注意

| 项 | 规则 |
|---|---|
| `max_drawdown` | 仅启动加载；发版变更 |
| `allow_runtime_override` | 保持 `false` |
| 费率 / 滑点 | 偏保守；过乐观 = 边界虚设 |

单测覆盖见验收矩阵 AC-RK1…RK3、AC-FR05 等条目。
