# Gate 3 验收清单（Demo Trading）

> 目标：Risk Kernel + Execution 在 **OKX 模拟盘** 全链路可跑，故障可降级。  
> 退出条件见 [ROADMAP.md](ROADMAP.md) Phase 3。滚动任务见 [NEXT.md](NEXT.md)。

## 已具备（代码）

- [x] `mode=demo` 启动闸：必须 `OKX_*` + `OKX_SIMULATED=1`；`mode=live` 仍直接拒绝
- [x] Demo 对账：私有 REST 余额写入引擎（非 shadow 模拟本金）
- [x] 提案 → `admission.admit` → planner → 市价单（`tgtCcy=base_ccy`）
- [x] 幂等 `client_order_id`（`ab` + hash）+ `orders` 表投影
- [x] 下单 HTTP 失败 → `UNKNOWN` + 查询后再处置（禁止盲重发）
- [x] Admin `cancel-all`：拉取 pending 并逐笔 cancel（仅 demo+simulated）
- [x] Admin `flatten`：风险态 `FLATTENING`
- [x] 事件：`ORDER_ACK` / `ORDER_REJECTED` / `ORDER_UNKNOWN` / `ORDER_QUERY` / `ORDER_CANCEL_SENT`

## 配置最小集

```toml
[exchange]
mode = "demo"
instrument = "BTC-USDT"
```

```bash
export OKX_API_KEY=...
export OKX_API_SECRET=...
export OKX_API_PASSPHRASE=...
export OKX_SIMULATED=1
# 可选 LLM
export LLM_API_KEY=...
```

## 联调清单（人工 / soak）

| # | 项 | 状态 |
|---|---|---|
| 1 | 模拟盘 API Key + IP 白名单 | ☐ |
| 2 | `--self-check` 私有余额 ok | ☐ |
| 3 | 一轮 agent 出现 `exec=filled\|acked\|...`（非 shadow `not_executed`） | ☐ |
| 4 | Dashboard/events 可见 `ORDER_*` | ☐ |
| 5 | `--control cancel-all` 清空 pending | ☐ |
| 6 | `--control flatten` 后不再增仓（admission REJECT） | ☐ |
| 7 | 连续运行 ≥24h 无非预期 crash（向 7 天 soak 迈进） | ☐ |
| 8 | 断线恢复演练 | ☐ |
| 9 | 版本回滚演练 | ☐ |
| 10 | 故障矩阵 AC-FD1..10 逐项 | ☐ |

## 安全提醒

- **永远不要**在未过 Gate 3 时把 `mode` 设为 `live`
- Demo 密钥也不得提交仓库；日志已脱敏，仍勿打印完整响应中的敏感头
