# 事件与审计

「每笔订单可追溯到 decision、快照、风控与配置」是上线硬条件之一。事件日志是真相源，Dashboard 只是视图。

## 事件信封

顶层字段固定，避免消费者每次挖 `payload`：

| 字段 | 含义 |
|---|---|
| `seq` / `event_id` | 单调序号与全局 ID |
| `ts` | 时间戳 |
| `type` | 事件类型枚举名 |
| `source` | 产生模块 |
| `severity` | 严重级 |
| `correlation_id` | 通常为 `decision_id` / `run_id` |
| `state_version` | 当时快照版本 |
| `software_version` | 二进制版本 |
| `config_hash` | 配置摘要 |
| `payload` | 类型相关细节 JSON |

实现：`src/core/events.zig` + `storage` `EventsRepo`。

## 典型类型（示例）

| type | 何时 |
|---|---|
| `RECONCILE_COMPLETED` | 对账结束 |
| `STATE_READY` | 进入 READY |
| `RISK_MODE_CHANGED` | 状态机迁移 |
| `RISK_DECISION` | 准入批准/缩减/拒绝 |
| `ORDER_*` | 订单投影变化 |
| `SHUTDOWN_CLEAN` | 优雅退出 |
| `CONFIG_APPLIED` | 配置/Prompt 生效（规划） |

以代码与 migration 为准；新类型必须带齐信封字段。

## SQLite 表（migration 0001）

| 表 | 作用 |
|---|---|
| `events` | 只追加事件流 |
| `orders` / `fills` | 订单与成交投影 |
| `equity_samples` | 净值 / HWM / DD 采样 |
| `agent_runs` | 模型调用与提案摘要 |
| `tool_calls` | 工具调用审计 |
| `memories` | 记忆版本 |

路径见配置 `[storage].path`；WAL 模式，单 writer。

## 查询示例

```bash
DB=/var/lib/alphabound/trading.db

# 最近风险相关
sqlite3 "$DB" "SELECT ts,type,correlation_id FROM events
  WHERE type LIKE 'RISK%' ORDER BY seq DESC LIMIT 20;"

# 某决策全链路
sqlite3 "$DB" "SELECT seq,type,payload_json FROM events
  WHERE correlation_id = 'dec_01J...' ORDER BY seq;"

# 净值曲线尾部
sqlite3 "$DB" "SELECT ts,equity,hwm,drawdown FROM equity_samples
  ORDER BY ts DESC LIMIT 30;"
```

## 脱敏

`observability/redaction.zig` 在日志路径屏蔽密钥形态字符串。原则：

- 宁可不打，也不打半截 secret
- issue / 聊天贴日志前再人工扫一遍
- 备份加密与访问控制同生产库

## 回放

状态引擎支持同序消息 **逐位确定性** 回放（单测守护）。审计争议时：

1. 取 `config_hash` + `software_version` 对齐二进制与配置
2. 按 `seq` 重放相关输入消息
3. 比对 `state_version` 与订单投影

这是 Replay 测试与事故复盘的共同基础。
