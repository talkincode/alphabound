# Gate 3 验收清单（Demo Trading）

> 目标：Risk Kernel + Execution 在 **demo 授权场所** 全链路可跑，故障可降级。  
> 授权场所 = OKX 模拟盘（`OKX_SIMULATED=1`）**或** 小额实盘子账号 + 显式开关（`OKX_REAL_MONEY_OK=1`）。  
> 当前采用后者：≈100 USDT 子账号，风险边界即子账号余额。`mode=live` 仍锁死（Gate 4）。  
> 退出条件见 [ROADMAP.md](ROADMAP.md) Phase 3。滚动任务见 [NEXT.md](NEXT.md)。

## 已具备（代码）

- [x] `mode=demo` 启动闸：必须 `OKX_*` + （`OKX_SIMULATED=1` 或显式 `OKX_REAL_MONEY_OK=1`）；`mode=live` 仍直接拒绝；实盘授权时 boot 打印醒目 banner，且真实 key 绝不发送模拟盘 header
- [x] Demo 对账：私有 REST 余额写入引擎（非 shadow 模拟本金）
- [x] 提案 → `admission.admit` → planner → 市价单（`tgtCcy=base_ccy`）
- [x] 幂等 `client_order_id`（`ab` + hash）+ `orders` 表投影
- [x] 下单 HTTP 失败 → `UNKNOWN` + 查询后再处置（禁止盲重发）
- [x] Admin `cancel-all`：拉取 pending 并逐笔 cancel（仅 demo + 授权场所）
- [x] Admin `flatten`：风险态 `FLATTENING`
- [x] 事件：`ORDER_ACK` / `ORDER_REJECTED` / `ORDER_UNKNOWN` / `ORDER_QUERY` / `ORDER_CANCEL_SENT`
- [x] Dashboard：`/api/v1/orders`（orders+fills 投影）+ 订单标签页
- [x] 部分成交再规划：resolve=`partial`/`filled` 后 REST 刷新仓位 → 残差 plan → 新 `clOrdId`(seq++)；最多 3 腿；`EXEC_REPLAN`
- [x] Fault 矩阵单测骨架：`src/fault/matrix.zig`（FD1–5/9）
- [x] Dashboard 决策详情关联 orders/fills（decision_id）
- [x] Limit 挂单：`formatPlaceLimitBody` + `limitPriceFromMark`；demo `LIMIT_ONLY` 下 limit 腿
- [x] LIMIT_ONLY：`max_wait_ms` 内轮询，超时/部分成交撤余量（`ORDER_CANCEL_SENT`）
- [x] FD6–8 策略单测：`src/storage/policy.zig`（busy / disk / corrupt）
- [x] LLM 传输：禁用 keep-alive + 一次 HTTP 客户端 reset 重试  
- [x] LLM 墙钟超时：`decision_timeout_ms`（默认 ≥120s）→ `Timeout` → HOLD；不阻塞主环  
- [x] OKX REST：keep-alive off + transport reset 重试  
- [x] FD7：DB 卷 `statvfs` 周期探测 → `disk_ok` / EXIT_ONLY / critical→HALTED + system `disk`  
- [x] FD8：已存在 DB 打开失败拒绝启动（不静默空库）
- [x] FD6：关键写 `Stmt.stepCritical` busy 重试；gate2-report / check-remote 展示 disk+llm

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
export OKX_SIMULATED=1        # 模拟盘 key
# 或：小额实盘子账号（显式二次确认，绝不默认）
# export OKX_REAL_MONEY_OK=1
# 可选 LLM
export LLM_API_KEY=...
```

## 联调清单（人工 / soak）

| # | 项 | 状态 |
|---|---|---|
| 1 | 执行场所就绪（实盘子账号 ≈100 USDT + `OKX_REAL_MONEY_OK=1`，代替模拟盘） | ☑ 2026-08-12 |
| 2 | 私有余额对账 ok（`[reconcile] demo balance applied usdt=… btc=…`） | ☑ 2026-08-12（含 excess-decimal 修复后对账） |
| 3 | 一轮决策出现 `exec=filled`（非 shadow `not_executed`） | ☑ 2026-08-12 operator `target-weight=0.05` → FILLED；agent HOLD 现为 `exec=hold` no-op |
| 4 | Dashboard/events 可见 `ORDER_*` + orders/fills 投影 | ☑ 2026-08-12（多笔 buy/sell FILLED；exchange_order_id 保留修复随后） |
| 5 | `--control cancel-all` 清空 pending | ☐ |
| 6 | `--control flatten` 后不再增仓（admission REJECT） | ☐ |
| 7 | 滚动 24h 窗口 0 次非预期退出（`soak-report.sh 24` PASS；向 168h 窗口迈进） | ☐ 滚动观察中（持续部署豁免） |
| 8 | 断线恢复演练 | ◐（kill -9 恢复 + 重启对账×3 + LLM 断连均 PASS；OKX WS 断线注入待 demo） |
| 9 | 版本回滚演练 | ☑ 2026-08-12（`scripts/rollback-remote.sh` 双向 PASS；health 门禁自动回滚已真实触发过一次） |
| 10 | 故障矩阵 AC-FD1..10 逐项 | ☐ |
| 11 | HOLD 不交易 / 仅 REBALANCE 改仓 | ☑ 2026-08-12（曾误把 HOLD weight=0 当清仓，已修） |
| 12 | 残差 replan 不在余额滞后时连买 | ☑ 2026-08-12 |

## 安全提醒

- **永远不要**在未过 Gate 3 时把 `mode` 设为 `live`
- Demo 密钥也不得提交仓库；日志已脱敏，仍勿打印完整响应中的敏感头
