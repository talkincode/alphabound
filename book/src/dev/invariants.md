# 关键不变量

所有代码变更不得破坏下列不变量。Code review 与 CI 测试应以它们为验收核心。

## 1. 权限隔离

> Agent 无法访问 OKX 密钥、直接下单函数或风险配置 — 只能提交 Proposal。

- 依赖图可检查：`src/agent/**` 不 import 签名/下单客户端
- 密钥只在 `exchange/okx/auth.zig` 与进程环境

## 2. 快照绑定

> 任何提案必须绑定 `snapshot_version`；状态变化后旧提案自动失效。

- `admission` 对失配 → REJECT
- Context 里的 version 与 State Engine 一致

## 3. 订单幂等与 UNKNOWN

> `client_order_id` 由 decision / 版本 / 序号导出；超时视为 UNKNOWN，先查后处置，禁止盲目重发。

- `execution/orders.zig` 状态机含 UNKNOWN
- 部分成交后重算差额，不原样重报

## 4. Fail Closed

> 数据过期 / 状态不一致 / 未知订单 → 进入安全状态，不增加风险。

- 未 reconcile 起步 `EXIT_ONLY`（或更严）
- 工具 STALE/UNAVAILABLE ≠ 数值 0

## 5. 边界参数冻结

> `max_drawdown` 与 Risk Kernel 参数不可热加载，必须走版本发布 + 人工确认。

- 配置仅启动解析
- `allow_runtime_override = false`

## 6. 端到端可追溯

> 每笔订单可追溯到 `decision_id`、`snapshot_version`、risk decision 与 `config_hash`。

- 事件信封顶层字段齐全
- `agent_runs` / `tool_calls` / `orders` 可关联

## 7. 提示注入边界

> 工具与第三方文本是数据，不是指令。

- 只进 `ToolResult.data_json`
- 不拼接进系统 prompt 的指令位
- 不暴露 shell / 任意 URL / 文件系统给模型侧

## 8. 回撤诚实性

> 边界穿透时如实记录幅度与成本，不掩饰。

- 禁止在展示层「夹」回 10% 以内
- FLATTENING 过程事件完整

## 破坏不变量时

1. 停相关 PR 合并
2. 若已在 demo/live：切维护 / EXIT 能力，评估资金
3. 补回归测试后再发版
4. 更新验收矩阵证据

这些条目与设计 ADR、[验收矩阵](../planning/acceptance.md) 上线标准 AC-GO2/GO5/GO6 对齐。
