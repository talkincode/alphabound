# AlphaBound 路线图

> 依据系统设计 v0.1 §9.4「MVP 迭代阶段」展开,每阶段含范围、交付物、退出条件(闸门)。
> 阶段串行推进,**退出条件未满足不得进入下一阶段**;各条目与
> [验收矩阵](ACCEPTANCE_MATRIX.md) 的 AC 编号对应。

**当前进度(2026-08)**: Phase 0–3 离线组件 + shadow 在线路径已打通并通过单元测试。
**本机已验证**: OKX 公共行情 + 周期只读私有余额 REST 对账、`market.ticker`/`market.candles`
工具 → `tool_calls` 审计、OpenAI 兼容 LLM（Azure）shadow `proposal ok`、
`agent_runs` digests + `AGENT_*` payload、`--agent-stats`、GHCR 镜像、
Dashboard 提案/净值/BH/K 线/Memories/Events/System API、shadow buy-and-hold 基准、
记忆 boot 重建 + 决策环 retrieve/events + 提案 episode + **LLM reflection**（失败回退确定性）、小时 SQLite 备份。
私有 WS：**协议**单测 + TLS 握手/upgrade 实连；login 后 OKX close 4004 仍在排查，
默认跳过（`ALPHABOUND_PRIVATE_WS=1` 可启用探测），REST 对账仍为 Gate 1 主路径。
**尚未完成**: 私有 WS login 长连仍 opt-in 不稳、Gate2 长稳 soak、Demo/Live 下单闸门。
**本迭代已补**: shadow 准入审计、`flatten`/`cancel-all`、`gate2-report.sh`、shadow 账户心跳；**Demo 最小下单路径**（`mode=demo`+`OKX_SIMULATED=1` → admit → planner → 市价单/查单/撤单）。
**下一步**: Gate2 运维 soak + [GATE3_CHECKLIST.md](GATE3_CHECKLIST.md) 模拟盘联调；见 [NEXT.md](NEXT.md)。

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4 ──► Phase 5
可行性 Spike  只读市场     Shadow Mode   Demo Trading  100 USDT 实盘  数据工具扩展
(go/no-go)   + Dashboard  (不下单)      (模拟盘)      (真金白银)     (按需增强)
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
- Market K 线只读面 — ✅ `/api/v1/candles` + sparkline（TradingView 归因仍待完整 K 线组件）
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

## Phase 3 — Demo Trading(模拟盘)

**目标**: 打通 Risk Kernel + Execution 全链路,在 OKX Demo 环境经受故障注入。

**范围**
- Risk Kernel: 保守净值/压力净值/ExitReserve/风险预算、提案准入(APPROVE/REDUCE/REJECT)、
  风险状态机 NORMAL/EXIT_ONLY/FLATTENING/HALTED
  - ✅ admission 单测 + shadow/demo 决策环调用
- Execution Engine: 目标仓位→订单、幂等 client_order_id、部分成交、撤单、UNKNOWN 处置、最终对账
  - ✅ planner + client_order_id + demo 市价 place/query/cancel；部分成交再规划 / limit 仍待
- orders/fills 表、订单 8 状态投影(PLANNED..UNKNOWN)
  - ✅ orders 投影写入；fills 表已有、成交明细落库仍可增强
- 管理控制: pause / resume / reconcile / cancel-all / flatten / safe-shutdown(本机 CLI/Unix socket)
  - ✅ 控制文件 CLI 全套；cancel-all 在 demo 拉 pending 撤单
- 故障注入全组: 断网、DNS、时钟漂移、磁盘满、SQLite busy、LLM 超时、坏 JSON、工具污染
- 测试金字塔补全: property(Risk Kernel 不变量)、replay(状态确定性)、integration(OKX Demo)
- 发布流水线完整化: manifest + SHA256 + self-check + 自动回滚
- 清单: [GATE3_CHECKLIST.md](GATE3_CHECKLIST.md)

**退出条件(Gate 3)**
- [ ] Demo Trading 连续稳定运行 ≥ 7 天(soak)
- [ ] 至少一次断线恢复演练 + 一次版本回滚演练通过
- [ ] 故障降级矩阵(§7.2)10 项场景逐项验证
- [ ] Risk Kernel property test 全绿(边界/费用/滑点/部分成交覆盖)

---

## Phase 4 — 100 USDT Live(实盘)

**目标**: OKX 独立子账户真实资金运行,人工每日检查,自动 halt 兜底。

**范围**
- 子账户开设 + API Key(仅 Read+Trade,无 Withdraw)+ Azure 固定出口 IP 白名单
- 密钥安全落地: root 管理 0600、systemd 加固(NoNewPrivileges/PrivateTmp/ProtectSystem)
- 上线验收清单(§9.3 全部 8 条)逐项签署
- 每日人工检查流程 + 周度 restore drill
- 回撤边界实弹: FLATTENING → HALTED 全链路在真实市场验证(可用小幅人工触发演练)

**进入条件**: Gate 3 全过 + 验收矩阵 P4 列全绿(任何无法解释的状态不一致都阻止实盘)

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

**退出条件(滚动)**
- [ ] 每个新工具上线 4 周后完成使用率与增量价值评估,低价值工具降级或下线

---

## 横切工作流(贯穿所有阶段)

| 事项 | 节奏 |
|---|---|
| CI: unit + property + replay + integration + dashboard build | 每次 PR |
| 备份 + restore drill | 每小时快照 / 每周演练(Phase 1 起) |
| 依赖与 Zig 版本升级 | 冻结;升级须过回放 + 长稳 + 故障注入 |
| 未决项决议(§9.5) | LLM Provider(P2 前)、HTTP/WS 选型(P0)、数据商(P5)、压力参数(P3-4)、触发策略(P2-4)、Region(P0) |
| 文档: ADR 追加、验收矩阵状态更新 | 每阶段闸门评审时 |
