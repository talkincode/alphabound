# Gate 2 验收清单（Shadow Mode）

> 目标：完整决策闭环但**不执行订单**。退出条件见 [ROADMAP.md](ROADMAP.md) Phase 2。

## 已通过（代码 + 实网 shadow）

- [x] OpenAI 兼容 LLM shadow 提案
- [x] market.ticker / market.candles 工具 → `tool_calls` 审计
- [x] Context：快照 + 记忆 retrieve + recent events
- [x] Proposal 严格 Schema；坏 JSON → HOLD
- [x] LLM 失败 → HOLD，核心环继续
- [x] LLM reflection + 确定性回退
- [x] agent_runs digests / `AGENT_*` 事件
- [x] Dashboard：概览 + 决策历史 + 状态（含 Token）
- [x] 影子 vs 买入持有、K 线 sparkline、记忆/事件
- [x] 本机管理：`--control pause|resume|reconcile|shutdown|status`
- [x] SQLite 小时备份
- [x] systemd 部署路径 + 中文 Dashboard
- [x] 有效提案后 **Risk Kernel 准入审计**（`RISK_ADMISSION`，shadow 仍不执行）
- [x] Shadow 模拟账户新鲜度随行情心跳（避免误进 EXIT_ONLY）
- [x] Admin `flatten` / `cancel-all` 控制面（cancel 的交易所路径待 Demo）
- [x] `scripts/gate2-report.sh` 阈值报告

## 运维注意

- [ ] 将部署机**出口公网 IP** 加入 OKX API 白名单（否则私有余额对账失败）
- [ ] Dashboard / API / 日志抽查无 secret 泄漏（AC-SEC3）
- [ ] 勿将内网地址、主机名、真实密钥写入本仓库

## Gate 2 长稳门槛（建议）

| 指标 | 建议门槛 | 如何看 |
|---|---|---|
| 进程存活 | ≥24h 无非预期 crash | `systemctl status` |
| 有效提案率 | ≥80%（样本 ≥20） | `/api/v1/system` → `agent.valid_rate` 或 `gate2-report.sh` |
| invalid 率 | ≤10% | system.agent.invalid / `gate2-report.sh` |
| 准入审计 | 每条 ok 提案有 admit 结论 | journal `admit=` / 事件 `RISK_ADMISSION` |
| LLM 连续失败 | 无连续 ≥10 次 | journal `LLM failed` |
| 备份 | 每日至少 1 次 | journal `backup] ok` |
| 内存 | RSS 无明显泄漏 | `ps` 对比 |

```bash
# 本机短 soak
./scripts/soak-shadow.sh 20

# Gate2 阈值（需 daemon 在跑）
BASE_URL=http://127.0.0.1:8080 ./scripts/gate2-report.sh

# 远端健康检查（需设置 HOST=你的 sshx 主机名）
HOST=your-host ./scripts/check-remote.sh
```

## Gate 2 → Gate 3（Demo）入口

1. [ ] 私有余额 REST 对账稳定 ≥24h  
2. [ ] 上表长稳门槛达到  
3. [ ] 模拟盘 API Key 就绪（`OKX_SIMULATED=1` / mode=demo）  
4. [x] cancel-all / flatten **控制面**已落地；交易所撤单 + 订单状态机联调 → 见 [NEXT.md](NEXT.md) Phase 3 切片  

滚动执行计划：[NEXT.md](NEXT.md)
