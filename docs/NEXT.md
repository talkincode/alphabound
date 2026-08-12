# 下一步执行计划（滚动）

> 与 [ROADMAP.md](ROADMAP.md)、[GATE2_CHECKLIST.md](GATE2_CHECKLIST.md)、[GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 对齐。

**当前焦点（2026-08-12）**: 小额实盘已是主路径；**`mode=live` + `OKX_REAL_MONEY_OK=1` 已解锁**。  
`mode=demo` 仅保留给 OKX 模拟盘（`OKX_SIMULATED=1`）；`demo+REAL_MONEY` 仍兼容但 boot 告警，请迁 live。  
**已合并**: PR #1–#3 + 实盘解锁链 + live 模式正式化。  

---

## 模式约定（2026-08-12 起）

| mode | 场所 | 必填 env |
|---|---|---|
| `shadow` | 模拟引擎现金，不下单 | 无 |
| `demo` | OKX 模拟盘 | `OKX_*` + `OKX_SIMULATED=1` |
| `live` | 小额实盘子账号 | `OKX_*` + `OKX_REAL_MONEY_OK=1`（禁 SIMULATED） |

---

## 现在做什么（按序）

### P0 — 迁 live + 稳盘（本周）

1. 生产配置改为 `mode = "live"`，保留 `OKX_REAL_MONEY_OK=1`，去掉误导性的 demo 命名  
2. **滚动 soak**：`HOST=<host> ./scripts/soak-report.sh 24` + `check-remote.sh`  
3. **控制面演练**：`cancel-all` → `flatten` → 拒增仓 → `target-weight=0.05` 恢复  
4. **对账抽查**：cash/btc 与 OKX 一致；新单 `exchange_order_id` 非空  

### P1 — Gate3 收口

1. Fault 矩阵 FD3/9/10 实网或注入补强（清单 #10）  
2. 7 日滚动 soak 窗口继续积累（AC-GO8）  
3. Dashboard：exchange_id 列非空验证  

### P2 — Phase 5 L1 观察

1. 部署后 7 日：derivatives≈ticker；REBALANCE citation≥30%（`tool-value-report.sh`）  
2. **不做** 外部 news/macro/onchain，直到 L1 引用闭环成立  

### P3 — 不做

- 主账户 / 大资金扩容（仍属 Phase 4 运维判定，不是再开代码锁）  
- 私有 WS 作主路径  
- 盲目加仓 / 高频 target-weight  

---

## 明确不做

- 主账户大资金、无 opt-in 的隐式实盘  
- 私有 WS 长连作为主路径（REST 对账为主）  
- 无引用度量前接入 news/macro/onchain 供应商  

---

## 验证命令

```bash
zig build test --summary all
./scripts/gate2-report.sh
# Live（需密钥 + OKX_REAL_MONEY_OK=1，mode=live）
./zig-out/bin/alphabound --config config/local.toml --control cancel-all
./zig-out/bin/alphabound --config config/local.toml --control flatten
```
