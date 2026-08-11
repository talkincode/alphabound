# 下一步执行计划（滚动）

> 与 [ROADMAP.md](ROADMAP.md)、[GATE2_CHECKLIST.md](GATE2_CHECKLIST.md)、[GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 对齐。

**当前焦点（2026-08）**: Gate 2 24h soak + Gate 3 Demo 联调；**live 仍禁用**。  
**已合并**: PR #1（orders API / scheduler / fills / partial replan）。  
**本迭代**:
- ✅ Gate3 **故障矩阵单测** `src/fault/matrix.zig`（AC-FD1..5/9 + replan cap）
- ✅ 决策详情 **关联订单/成交**（decision_id → orders/fills）

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
| B4 | APPROVE/REDUCE → planner → 幂等市价单 | ✅ `mode=demo` + `OKX_SIMULATED=1` |
| B5 | Demo 余额写入引擎 | ✅ |
| B6 | 故障注入全矩阵 | ☐ 随后 |

---

## 现在做什么（按序）

1. **运维 Gate 2**（若 shadow 尚未 24h 绿）  
   `gate2-report.sh` + `check-remote.sh`
2. **准备模拟盘密钥**（`OKX_SIMULATED=1`，IP 白名单）  
3. **本机 Demo 冒烟**  
   ```bash
   # config: mode = "demo"
   set -a && source ./secrets.env && set +a
   ./zig-out/bin/alphabound --config config/local.toml --self-check
   ./zig-out/bin/alphabound --config config/local.toml --agent-once --ticks 8
   # 日志应含 admit=… exec=filled|acked|…（非 not_executed）
   ```
4. **按 [GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 勾选联调项**
5. **下一代码迭代**  
   - ✅ Dashboard 订单视图 API + 决策详情关联订单  
   - ✅ 部分成交再规划 + fills 投影  
   - ✅ Fault 矩阵单测骨架（AC-FD1..5/9）；FD6–8/10 仍需注入/演练  
   - 挂单 limit  
   - Demo ≥7 天 soak

---

## 明确不做

- `mode=live` / 真金白银  
- 私有 WS 长连作为主路径（REST 对账为主）  
- Phase 5 扩展数据源  

---

## 验证命令

```bash
zig build test --summary all
./scripts/gate2-report.sh
# Demo（需密钥）
./zig-out/bin/alphabound --config config/local.toml --control cancel-all
./zig-out/bin/alphabound --config config/local.toml --control flatten
```
