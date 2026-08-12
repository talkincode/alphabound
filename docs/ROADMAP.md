# AlphaBound 路线图

> 依据系统设计 v0.1 §9.4「MVP 迭代阶段」展开,每阶段含范围、交付物、退出条件(闸门)。
> 阶段串行推进,**退出条件未满足不得进入下一阶段**;各条目与
> [验收矩阵](ACCEPTANCE_MATRIX.md) 的 AC 编号对应。

**当前进度(2026-08)**: Phase 0–3 代码主路径已通；**小额 `mode=live` 已解锁**（`OKX_REAL_MONEY_OK=1`）。
**本机/生产已验证**: OKX 公共行情 + 私有余额 REST 对账、Agent 提案/反思、Dashboard、
小额实盘下单（operator + agent REBALANCE → FILLED）、flatten/cancel-all、部署回滚与 soak 脚本。
私有 WS 仍 opt-in；REST 对账为主路径。
**尚未完成**: Gate3 故障矩阵逐项 + ≥7 日滚动 soak（AC-GO8）、Phase 5 L1 引用率观察。
**下一步**: 配置迁 `mode=live`、稳盘证据、故障矩阵收口；见 [NEXT.md](NEXT.md)。

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5
可行性 Spike  只读市场     Shadow Mode   交易路径       MVP 运维判定   数据工具扩展
(go/no-go)   + Dashboard  (不下单)      (demo|live)   (长稳/验收)    (按需增强)
```

---

## Phase 0 — 技术可行性 Spike(go/no-go 闸门)

**目标**: 证明 Zig 0.16.0 技术栈能支撑生产级长时运行,任何一项不过关即触发选型回退预案。

**范围**
- Zig 0.16 `std.Io` 下的 TLS 客户端、WebSocket 客户端、HTTP 客户端验证(对 OKX 与 LLM 端点)
- SQLite amalgamation 集成(vendor sqlite3.c/h,WAL,单 writer)
- systemd 服务化 + ReleaseSafe 静态构建 + 原子发布/回滚脚本雏形
- 内存长稳测试(24h 连续运行,监控 RSS / fd / 句柄泄漏)
- Azure Region 延迟实测脚本(OKX REST / 公共 WS / 私有 WS / LLM 端点 p50/p95)

**交付物**
- 可运行的最小 daemon(连接 OKX 公共 WS,落 SQLite 事件)
- 《依赖决议记录》: TLS/WS/HTTP 每个组件的选型(标准库 or vendor)与验证证据
- CI 骨架: 固定 Zig 0.16.0 下载 + SHA256 校验 + build + test
- Azure Region 选型报告

**退出条件(Gate 0)**
- [ ] 所有关键库可固定版本并连续运行 24h 无泄漏、无崩溃(短时验证通过;24h 长稳待跑)
- [x] TLS/WS 对 OKX 实际端点稳定收发,断线可检测(REST over TLS 实网验证;WS 帧编解码单测)
- [x] SQLite WAL 读写并行验证通过(vendor 3.53.4,WAL 模式,存储层测试 + daemon 实测落库)

---

## Phase 1 — 只读市场与 Dashboard

**目标**: 无交易能力的完整「观察者」——行情、账户、状态引擎、事件日志、可视化。

**范围**
- Exchange Gateway: OKX 公共/私有 WS 订阅、REST 快照、心跳、重连、时间同步、instrument 配置加载
- State Engine: 单写者 mailbox、PortfolioState(版本化不可变快照)、HWM/DD 计算
- core/decimal: 定点金额运算(禁止二进制 float 结算)
- Storage: migrations、events/equity_samples 表、事件信封(顶层 type/correlation_id/state_version/config_hash)
- Journal Writer: 有界队列、关键事件强制提交
- 启动状态机: BOOTING → CONNECTING → RECONCILING → READY
- Dashboard v1: Overview + Market(K 线) + Events + System 视图,`/api/v1/state|candles|equity|events`,`/health/*`
- 备份: 每小时 SQLite Backup API 快照 + 保留策略

**交付物**: 在 Azure VM 上 systemd 常驻的只读实例 + 浏览器 Dashboard(SSH tunnel 访问)

**退出条件(Gate 1)**
- [x] 无交易也能对账与展示(基础): REST 只读余额周期探针 + HWM 持久化 + Dashboard state（shadow 引擎现金仍为模拟）
- [ ] WS 断线自动重连并触发 reconcile（TLS upgrade 已通；login/长连/重连待稳定；REST 周期对账兜底）
- [x] 净值/回撤样本在 Dashboard 呈现（`/api/v1/equity` + 表）；K 线 1H sparkline（`/api/v1/candles`）已交付

---

## Phase 2 — Agent Shadow Mode

**目标**: 完整决策闭环但**不执行订单**——验证 Context、工具、提案 Schema 与记忆的质量。

**范围**
- Agent Runtime: Context 构建(5 层记忆检索)、模型适配器、Decision Proposal Schema 校验
  - ✅ `agent/context.zig` 确定性 Context + input_digest;✅ Proposal 严格校验
  - ✅ `agent/openai.zig` OpenAI/Azure 兼容 chat completions;本机 Azure 实调 `proposal ok`
- Tool Registry: market.* / derivatives.* 工具、统一 ToolResult 信封、时效/成本/可信度记录
  - ✅ `tools/registry.zig` + ✅ `tools/market.zig` ticker/candles provider（OKX REST 实调）
- Memory & Reflection: episodes、假设(Strategy Memory)、结构化 Reflection 与 memory_ops
  - ✅ `memory/store.zig` + `agent/reflection.zig`(ops 确定性生效,坏 JSON 整体作废)
  - ✅ boot 从 SQLite 重建 + bootstrap seed；决策环 `retrieve` 注入 Context；提案 episode 落库
  - ✅ 决策后 **LLM reflection**（`prompts/reflection.md` → 严格 Schema → memory_ops；`ALPHABOUND_LLM_REFLECTION=0` 可关）
  - ✅ 失败回退确定性 shadow reflection（`R_*` + strategy touch）
  - ✅ 事件 `AGENT_REFLECTION_OK` / `_LLM_FAILED` / `_INVALID`
- agent_runs / tool_calls / memories 表与审计链路 — ✅ shadow 写 run + tool_calls + memories + `AGENT_*` payload
- Prompt 版本化(hash 进事件日志,SIGHUP 热加载) — ✅ prompt_hash 入 agent_runs;热加载待做
- Dashboard: Trade Detail(提案链路回放)+ Memory/System 视图 — ✅ 提案/Memories/Events/System + agent-runs/memories/events/system API
- 审计事件进 Context — ✅ `listCompactForContext` → agent recent_events
- SQLite 小时备份 — ✅ Backup API → `<db_path>.bak` + BACKUP_* 事件
- 提示注入防线: 工具返回一律进 data 字段;Agent worker 无 shell/文件/任意 URL 能力
  - ✅ ToolResult.data 不可信边界在类型层强制;LLM 凭证不进 Context
- 影子对比: 提案 vs 基准(如 buy-and-hold)的假设性表现记录 — ✅ `shadow_bench` + `/api/v1/shadow`
- Market K 线只读面 — ✅ `/api/v1/candles` + Dashboard **Lightweight Charts**（K 线/量/净值 + TradingView 归因）
- 统计: ✅ `--agent-stats` 有效提案率 / tool_calls 计数
- 短 soak 脚本: ✅ `scripts/soak-shadow.sh`
- 本机管理控制: ✅ `--control pause|resume|reconcile|cancel-all|flatten|shutdown|status`（控制文件，无网络面；cancel 交易所路径待 Demo）
- 提案准入审计: ✅ shadow 路径 `admission.admit` → `RISK_ADMISSION`（仍不执行订单）
- 工具 UNAVAILABLE: ✅ HTTP 失败不伪造零行情
- systemd unit + deploy 说明: ✅ `deploy/`

**退出条件(Gate 2)**
- [x] 提案可审计(基础): run_id + input/output digest + tool_calls + events.payload
- [x] invalid/ok 率可统计（`--agent-stats`）;阈值与长跑样本待 Gate 2 评审
- [x] LLM 超时/坏 JSON 均安全降级为 HOLD,不影响关键路径(本机失败路径已验证)

---

## Phase 3 — Trading path（demo | 小额 live）

**目标**: 打通 Risk Kernel + Execution 全链路；可在 OKX 模拟盘或**小额实盘子账号**经受故障注入与 soak。

**范围**
- Risk Kernel: 保守净值/压力净值/ExitReserve/风险预算、提案准入(APPROVE/REDUCE/REJECT)、
  风险状态机 NORMAL/EXIT_ONLY/FLATTENING/HALTED
  - ✅ admission 单测 + shadow/demo 决策环调用
- Execution Engine: 目标仓位→订单、幂等 client_order_id、部分成交、撤单、UNKNOWN 处置、最终对账
  - ✅ planner + client_order_id + demo 市价/limit place/query/cancel；✅ 部分成交再规划（≤3 腿 + REST 对账）
- orders/fills 表、订单 8 状态投影(PLANNED..UNKNOWN)
  - ✅ orders 投影写入；✅ `/api/v1/orders` + Dashboard 订单 Tab；✅ demo resolve 写 fills 聚合行（WS 多笔 fill 仍可增强）
- 管理控制: pause / resume / reconcile / cancel-all / flatten / safe-shutdown(本机 CLI/Unix socket)
  - ✅ 控制文件 CLI 全套；cancel-all 在 demo 拉 pending 撤单
- 故障注入全组: 断网、DNS、时钟漂移、磁盘满、SQLite busy、LLM 超时、坏 JSON、工具污染
- 测试金字塔补全: property(Risk Kernel 不变量)、replay(状态确定性)、integration(OKX Demo)
- 发布流水线完整化: manifest + SHA256 + self-check + 自动回滚
- 清单: [GATE3_CHECKLIST.md](GATE3_CHECKLIST.md)

**退出条件(Gate 3)**
- [ ] 交易模式（demo 或小额 live）连续稳定运行 ≥ 7 天(soak)
- [x] 至少一次断线恢复演练 + 一次版本回滚演练通过（2026-08-12）
- [ ] 故障降级矩阵(§7.2)10 项场景逐项验证
- [x] Risk Kernel property / 费用滑点部分成交相关验收项已落地（见 ACCEPTANCE_MATRIX）
- [x] **`mode=live` 小额路径解锁**（`OKX_REAL_MONEY_OK=1`，非主账户）

---

## Phase 4 — MVP 运维判定（非「再开 live 锁」）

**目标**: 小额 live 已可跑的前提下，用长稳与运营证据判定 MVP 成立；**不是**再解一把代码锁。

**范围**
- 子账户纪律: API Key 仅 Read+Trade、出口 IP 白名单、密钥 0600 + systemd 加固
- 上线验收清单(§9.3)逐项签署与滚动 soak 证据归档
- 每日人工检查流程 + 周度 restore drill
- 回撤边界实弹: FLATTENING → HALTED 在真实市场可重复

**进入条件**: Gate 3 故障矩阵与 7 日 soak 收口；任何无法解释的状态不一致都阻止扩容

**退出条件(Gate 4,判定 MVP 成立)**
- [ ] 无状态不一致事件;所有风险事件可解释、可追溯
- [ ] 运营成本(基础设施 + 模型调用)可见且未失控
- [ ] HALTED/EXIT_ONLY 触发行为与设计一致

---

## Phase 5 — 数据工具扩展(持续迭代)

**目标**: 按 Agent 的实际信息缺口逐个接入 onchain.* / wallet.* / macro.* / news.*,用数据说话。

**范围**
- 每个数据源作为独立工具适配器接入(Schema、时效、成本、可信度、缓存 TTL)
- 数据提供商评估: API 成本、标签质量、速率限制、许可
- 工具价值评估闭环: 使用率、引用进 evidence 的频率、对决策质量的增量贡献(Reflection 统计)
- 逐步校准: 风险压力参数、ExitReserve、Agent 触发策略(成本预算闸)

**进展**
- [x] `market.derivatives`(2026-08-12): SWAP 资金费率 + 未平仓量,OKX 公共端点、零新增外部依赖;Agent 上下文 tools=3
- [x] **L1 持仓/情绪包**(2026-08-12): 同工具扩 `long_short_ratio` / `taker_buy_vol`/`taker_sell_vol` / `mark_px`/`index_px`/`basis_bps`; prompt 强制 REBALANCE 引用数值; `scripts/tool-value-report.sh`
- [ ] 计划全文: [PHASE5_DATA_PLAN.md](PHASE5_DATA_PLAN.md)（L0 理想 → L1 本切片 → 外部 news/macro/onchain 延后）
- [ ] 滚动价值评估: 部署后 7 日 citation 门限 + 至 ~2026-09-09 四周评估

**退出条件(滚动)**
- [ ] 每个新工具/字段上线后完成使用率与 thesis 引用率评估,低价值降级或下线
- [ ] L1: `derivatives_vs_ticker_ratio≈1` 且 REBALANCE citation_rate≥30%（见 tool-value-report）

---

## 横切工作流(贯穿所有阶段)

| 事项 | 节奏 |
|---|---|
| CI: unit + property + replay + integration + dashboard build | 每次 PR |
| 备份 + restore drill | 每小时快照 / 每周演练(Phase 1 起) |
| 依赖与 Zig 版本升级 | 冻结;升级须过回放 + 长稳 + 故障注入 |
| 未决项决议(§9.5) | LLM Provider(P2 前)、HTTP/WS 选型(P0)、数据商(P5)、压力参数(P3-4)、触发策略(P2-4)、Region(P0) |
| 文档: ADR 追加、验收矩阵状态更新 | 每阶段闸门评审时 |
