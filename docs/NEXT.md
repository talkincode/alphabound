# 下一步执行计划（滚动）

> 与 [ROADMAP.md](ROADMAP.md)、[GATE2_CHECKLIST.md](GATE2_CHECKLIST.md)、[GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 对齐。

**当前焦点（2026-08-13）**: 小额实盘已是主路径；**`mode=live` + `OKX_REAL_MONEY_OK=1` 已解锁**。  
`mode=demo` 仅保留给 OKX 模拟盘（`OKX_SIMULATED=1`）；`demo+REAL_MONEY` 仍兼容但 boot 告警，请迁 live。  
**已合并**: PR #1–#8 链（实盘解锁、ops/auth、equity buffer、favicon 等）+ live 模式正式化。  

---

## 模式约定（2026-08-12 起）

| mode | 场所 | 必填 env |
|---|---|---|
| `shadow` | 模拟引擎现金，不下单 | 无 |
| `demo` | OKX 模拟盘 | `OKX_*` + `OKX_SIMULATED=1` |
| `live` | 小额实盘子账号 | `OKX_*` + `OKX_REAL_MONEY_OK=1`（禁 SIMULATED） |

---

## 现在做什么（按序）

### P0 — 稳盘（滚动）

1. ✅ 生产 `mode = "live"` + `OKX_REAL_MONEY_OK=1`（2026-08-12）  
2. ✅ 运维脚本带 Dashboard token：`check-remote` / `soak-report` / `gate2-report`  
3. ✅ Dashboard 鉴权 + 只读 Analytics MCP（PR #6 链）  
4. **滚动 soak**：继续 `HOST=<host> ./scripts/soak-report.sh 24`（24h PASS；向 7 日窗口滚）  
5. **控制面演练**：`cancel-all` → `flatten` → 拒增仓 → `target-weight=0.05` 恢复（flatten 已验；cancel-all 有挂单时再验）  
6. ✅ 对账：live balance applied；新单 `exchange_order_id` 非空（历史 FILLED 空 id 为修前数据）  

### P1 — Gate3 收口

1. ✅ Fault 矩阵单测 FD1–10 齐（含 FD10 restart fail-closed）；实网 WS/超时注入仍可选  
2. 7 日滚动 soak 窗口继续积累（AC-GO8）  
3. ✅ Dashboard/API：orders `exchange_order_id` 抽查（新单 8/8）  

### P1.5 — Agent 决策质量（实盘证据，2026-08-19）

1. Context 给出权威 `btc_weight`，以及 HOLD 连胜次数 / 距上次成交 / vs 买持有 `alpha_return` 事实（不给建议）
2. Prompt：HOLD = 维持当前权重；thesis 有方向就必须 REBALANCE；连胜不是正确性证据
3. **不做**：放松风险内核、强制加仓、抬高仓位上限
4. Agent K 线：1D×45 / 4H×42 / 1H×48 / 30m×48 / 15m×48（紧凑数组）+ 本地计算的 1D/4H structure（SMA/range/前高突破）

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
