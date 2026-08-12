# 下一步执行计划（滚动）

> 与 [ROADMAP.md](ROADMAP.md)、[GATE2_CHECKLIST.md](GATE2_CHECKLIST.md)、[GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 对齐。

**当前焦点（2026-08-12）**: Gate 3 **小额实盘 demo** 已跑通订单路径；**`mode=live` 仍禁用**。  
**已合并**: PR #1–#3 + 实盘解锁链（pre-admit refresh、operator target-weight、balance parseLossy、HOLD no-op、residual 止损）。  
**本迭代**:
- ✅ Gate3 **故障矩阵单测** `src/fault/matrix.zig`（AC-FD1..5/9 + replan cap）
- ✅ 决策详情 **关联订单/成交**（decision_id → orders/fills）
- ✅ FD6 关键写路径 `stepCritical` busy 重试
- ✅ **安全/验收纯代码收口**: AC-SEC5(响应上限)/SEC6(隔离扫描)/SEC7(注入中和)、AC-FR04(proposal fuzz)、AC-GO3(费用/滑点/部分成交 property)、AC-OPS3/9(备份轮换+保留清理)、AC-NFR01(延迟直方图)、AC-OPS8(token 计数已可见)
- ✅ **运维验收自动化**（2026-08-12 生产演练全 PASS）: 版本化部署 `releases/<sha>-<ts>` + `current` symlink + health 门禁自动回滚(AC-OPS5/6)、`--verify-db` + restore-drill(AC-OPS4)、kill -9 恢复演练 10s READY(AC-NFR04)、soak-report p99 门限告警(AC-NFR01)与演练入账
- ✅ **故障与恢复演练扩展**（2026-08-12 全 PASS）: 重启对账×3(AC-GO1: HWM+memories+余额对账+READY≤9s)、LLM 断连注入(AC-NFR02/GO4/FD1)、SEC2 密钥卫生自动检查、soak-report 资源门限(AC-NFR06: RSS/fd/WAL)
- ✅ **首笔真实成交**（2026-08-12）: operator `target-weight=0.05` → market FILLED；余额对账 `btc≈0.000078`；HOLD 不再清仓

---

## 已完成

### Gate 2 代码收口

| # | 事项 | 状态 |
|---|---|---|
| A1 | Shadow 提案 Risk 准入审计 | ✅ |
| A2 | Shadow 账户新鲜度心跳 | ✅ |
| A3 | `scripts/gate2-report.sh` | ✅ |
| A4–A6 | 24h soak / IP 白名单 / 泄密抽查 | ☐ 运维 |

### Phase 3 最小下单切片

| # | 事项 | 状态 |
|---|---|---|
| B1–B2 | Admin flatten / cancel-all 控制面 | ✅ |
| B3 | Demo 订单 REST place/cancel/query 封装 | ✅ `execution/okx_trade.zig` |
| B4 | APPROVE/REDUCE → planner → 幂等市价单 | ✅ `mode=demo` + 授权场所 |
| B5 | Demo 余额写入引擎 | ✅ |
| B6 | 故障注入全矩阵 | ☐ 随后 |

---

## 现在做什么（按序）

### P0 — 稳盘 + 证据（本周）

1. **滚动 soak**（部署重启豁免，crash/对账失败才判负）  
   `HOST=<host> ./scripts/soak-report.sh 24` + `check-remote.sh`
2. **控制面演练**：`cancel-all`（无 pending 时 no-op）→ `flatten` → 确认 admission 拒增仓 → 再 `target-weight=0.05` 恢复小仓
3. **等 agent 自发 REBALANCE**（HOLD 已 no-op）。当前 `active_hours_utc=13-21`；窗外 quiet 间隔 1h。开发期可临时放宽 active hours（改 `/etc/alphabound/alphabound.toml`，**不提交**真实主机细节）
4. **对账抽查**：Dashboard 状态页 cash/btc 与 OKX 子账号一致；orders 有 `exchange_id`

### P1 — Gate3 收口代码

1. ✅ orders upsert **保留** `exchange_order_id`（query 回写不再抹掉 ACK 的 ordId）
2. AC-GO5 审计链脚本：orders.decision_id ↔ events；fills 无孤儿
3. Fault 矩阵 FD3/9/10 实网或注入补强（清单 #10）
4. Dashboard：卖出/买入并列、exchange_id 列非空验证

### P2 — 不做

- `mode=live`（Gate 4）
- 私有 WS 作主路径
- 盲目加仓 / 高频 target-weight

---

## 明确不做

- `mode=live` / 主账户大资金  
- 私有 WS 长连作为主路径（REST 对账为主）  
- Phase 5 扩展数据源（derivatives 价值评估待 2026-09） 

---

## 验证命令

```bash
zig build test --summary all
./scripts/gate2-report.sh
# Demo（需密钥）
./zig-out/bin/alphabound --config config/local.toml --control cancel-all
./zig-out/bin/alphabound --config config/local.toml --control flatten
```
