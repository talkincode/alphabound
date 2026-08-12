# 下一步执行计划（滚动）

> 与 [ROADMAP.md](ROADMAP.md)、[GATE2_CHECKLIST.md](GATE2_CHECKLIST.md)、[GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 对齐。

**当前焦点（2026-08）**: Gate 2 24h soak + Gate 3 Demo 联调；**live 仍禁用**。  
**已合并**: PR #1–#3（orders/scheduler/partial replan、fault matrix、limit、LLM timeout、FD7/8 disk）。  
**本迭代**:
- ✅ Gate3 **故障矩阵单测** `src/fault/matrix.zig`（AC-FD1..5/9 + replan cap）
- ✅ 决策详情 **关联订单/成交**（decision_id → orders/fills）
- ✅ FD6 关键写路径 `stepCritical` busy 重试
- ✅ **安全/验收纯代码收口**: AC-SEC5(响应上限)/SEC6(隔离扫描)/SEC7(注入中和)、AC-FR04(proposal fuzz)、AC-GO3(费用/滑点/部分成交 property)、AC-OPS3/9(备份轮换+保留清理)、AC-NFR01(延迟直方图)、AC-OPS8(token 计数已可见)
- ✅ **运维验收自动化**（2026-08-12 生产演练全 PASS）: 版本化部署 `releases/<sha>-<ts>` + `current` symlink + health 门禁自动回滚(AC-OPS5/6)、`--verify-db` + restore-drill(AC-OPS4)、kill -9 恢复演练 10s READY(AC-NFR04)、soak-report p99 门限告警(AC-NFR01)与演练入账

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

1. **滚动 soak 验收**（替代冻结 24h/7d：部署重启豁免，只有 crash 判负）  
   `HOST=<host> ./scripts/soak-report.sh 24` + `gate2-report.sh` + `check-remote.sh`
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
   - ✅ 挂单 limit（`LIMIT_ONLY` → tick-snapped limit；`LIMIT_OR_MARKET` 仍走市价）  
   - ✅ LIMIT_ONLY `max_wait_ms` 超时撤单 + partial 余量撤单  
   - ✅ FD6–8 存储策略纯函数（`storage/policy.zig`）+ fault matrix 单测  
   - ✅ LLM 空闲连接：keep-alive off + HttpFailed 时 reset 重试一次  
   - ✅ LLM **墙钟超时**（`decision_timeout_ms`，默认 120s；worker+detach，超时→HOLD 不堵 daemon）  
   - ✅ OKX REST / egress 探测：keep-alive off + 一次 reset 重试  
   - ✅ FD7 磁盘探测接入 daemon（statvfs → disk_ok / EXIT_ONLY / HALTED + `DISK_STATUS`）  
   - ✅ FD8 已有库文件 open 失败 → refuse empty recreate  
   - ✅ AC-SEC5 固定容量响应 sink（OKX 512KB / LLM 1MB / 探针 4KB）+ `security/limits.zig` 结构扫描  
   - ✅ AC-SEC6 `security/isolation.zig` agent 源码隔离扫描测试  
   - ✅ AC-SEC7 工具 data_json 注入中和（结构坏→null）+ fault 注入测试  
   - ✅ AC-FR04 proposal fuzz（截断/字节翻转不 crash、不变量保持）  
   - ✅ AC-GO3 property 扩展（成本单调性 + 部分成交收敛）  
   - ✅ AC-OPS3/9 hourly/daily 备份轮换（留 24/30）+ tool_calls/equity_1s 保留清理  
   - ✅ AC-NFR01 risk apply 延迟直方图 → system JSON `latency_us`  
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
