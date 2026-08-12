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

1. **滚动 soak**（部署重启 + 邻近 crash-loop 计 churn；稳定后 0 非预期退出）  
   `HOST=<host> ./scripts/soak-report.sh 24` + `check-remote.sh`
2. **控制面演练**：`cancel-all` → `flatten` → 拒增仓 → `target-weight=0.05` 恢复
3. ✅ **agent 自发 REBALANCE**（2026-08-12 `dec_…` w=0.08 `exec=filled`，exchange_id 非空）
4. **对账抽查**：cash/btc 与 OKX 一致；新单 `exchange_id` 非空

### P1 — Gate3 收口代码

1. ✅ orders upsert **保留** `exchange_order_id`
2. ✅ AC-GO5：`--verify-db` 认 `ADMIN_TARGET_WEIGHT` + `scripts/audit-go5.sh`
3. Fault 矩阵 FD3/9/10 实网或注入补强（清单 #10）
4. Dashboard：exchange_id 列非空验证（新单已通）

### P2 — Phase 5 L1（基本面/情绪薄切片，已开工）

1. ✅ 审计与计划: `docs/PHASE5_DATA_PLAN.md`（ACCEPT 窄范围；拒一次性 news/macro）
2. ✅ 扩 `market.derivatives`: 多空比 + taker 主买主卖 + mark/index 基差（仍 tools=3，零新密钥）
3. ✅ prompt: REBALANCE thesis 必须引用 derivatives 具体数值
4. ✅ `HOST=… ./scripts/tool-value-report.sh` 引用率快照
5. ☐ 部署后看 7 日: derivatives≈ticker 调用；REBALANCE citation≥30%
6. ☐ **不做** 外部 news/macro/onchain，直到 L1 引用闭环成立

### P3 — 不做

- `mode=live`（Gate 4）
- 私有 WS 作主路径
- 盲目加仓 / 高频 target-weight

---

## 明确不做

- `mode=live` / 主账户大资金  
- 私有 WS 长连作为主路径（REST 对账为主）  
- 无引用度量前接入 news/macro/onchain 供应商  


---

## 验证命令

```bash
zig build test --summary all
./scripts/gate2-report.sh
# Demo（需密钥）
./zig-out/bin/alphabound --config config/local.toml --control cancel-all
./zig-out/bin/alphabound --config config/local.toml --control flatten
```
