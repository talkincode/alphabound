# AlphaBound 验收矩阵

> 将系统设计 v0.1 的功能需求(FR)、非功能需求(NFR)、上线验收标准(§9.3)、安全边界(§7.3/7.4)
> 与故障降级矩阵(§7.2)映射为可执行、可勾选的验收条目。
>
> - **验证方法** 对应 §9.2 测试金字塔: Unit / Property / Replay / Integration / Fault / Soak / Shadow / Manual(人工演练或评审)
> - **阶段** 指该条目必须通过的最晚阶段闸门(见 [ROADMAP.md](ROADMAP.md));进入 Phase 4 实盘前,P0–P3 条目必须全绿
> - **状态**: ☐ 未开始 · ◐ 进行中 · ☑ 通过
>
> **状态快照(2026-08)**: 核心软件 + shadow 在线路径已验证(`zig build test` 全绿; Dashboard 提案/BH; 本机 OKX
> 公共行情、只读私有余额、Azure LLM 提案、market 工具落库)。下表 ◐ = 代码+单测/部分实网已落地,
> 但设计要求的完整 Integration/Fault/Soak/Manual 尚未全部执行(Demo/Live 与长稳仍缺)。

## A. 功能需求(FR)

| ID | 需求摘要 | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|---|
| AC-FR01 | 行情与账户接入 | 订阅 OKX 公共+私有 WS;启动与断线后 REST 快照对账一致;序列缺口触发 DEGRADED+reconcile | Integration(OKX Demo)+ Fault(断线注入) | P1 | ◐ REST ticker/余额实网 + 周期 REST 对账;公共 WS 帧编解码单测;私有 WS login/push 协议单测;TLS 私有流与断线注入待做 |
| AC-FR02 | 状态引擎 | 内存维护价格/余额/BTC/挂单/净值/HWM/DD;快照带版本;replay 同版本结果逐位一致 | Unit + Replay | P1 | ☑ `core/state.zig` 单写者引擎;replay 确定性逐位一致测试通过(`state engine: replay determinism`) |
| AC-FR03 | Agent 决策 | 决策基于一致性快照+检索记忆;可按需调用工具;全程可审计 | Shadow + Integration | P2 | ◐ Context+LLM + market 工具 + 记忆/events + **LLM reflection** + **Risk 准入审计**（不执行）+ 全审计; 长跑阈值评审仍待 |
| AC-FR04 | 交易提案 | Proposal 严格 Schema(target/order_policy/confidence/thesis/evidence/invalid_if);坏 JSON/缺字段即作废 | Unit(Schema)+ Fuzz | P2 | ◐ `agent/proposal.zig` 严格解析:坏 JSON/缺字段/越界置信度全部拒绝(单测);fuzz 待做 |
| AC-FR05 | 风险准入 | 校验 snapshot_version、数据新鲜度、压力净值≥HWM×90%+ExitReserve;能输出 APPROVE/REDUCE/REJECT | Property + Unit | P3 | ◐ 单测+property 基础; **shadow 路径已调用 admit 并落 `RISK_ADMISSION`**; Demo 执行联动仍待 |
| AC-FR06 | 订单执行 | client_order_id 幂等(decision_id+版本+序号);部分成交重算差额;超时→UNKNOWN→查询后处置 | Integration + Fault + Replay | P3 | ◐ 单测 + **demo 市价/limit** place/query/cancel + UNKNOWN 查询 + **partial 再规划(≤3腿)**; Fault/7d soak 待做 |
| AC-FR07 | 长期 Context | 五层记忆可写入/检索/版本化;Reflection 产出结构化 memory_ops 并生效 | Shadow + Unit | P2 | ◐ store+reflection 单测; **Shadow**: boot/retrieve/episode/**LLM+确定性 reflection ops** + Dashboard memories |
| AC-FR08 | 可选数据工具 | 工具注册含 Schema/时效/成本;返回统一 ToolResult;调用与结果全部落事件日志 | Unit + Integration | P2(市场类)/ P5(扩展类) | ◐ registry + `market.ticker`/`market.candles` OKX REST provider 实调落 `tool_calls`;扩展域 provider 待做 |
| AC-FR09 | Dashboard | Overview/Market/Trade Detail/Events/Memory/System 六视图;K 线+交易/风险标记;保留 TradingView attribution | Manual(UI 走查)+ Integration(API) | P1(基础)/ P2(全视图) | ◐ Overview+提案+BH+**Lightweight Charts K线/量/净值HWM**+Memories+Events+System+**订单/fills API+Tab**+TV 归因；提案链路完整 Trade Detail 回放仍待 |
| AC-FR10 | 管理控制 | pause/resume/reconcile/cancel-all/flatten/safe-shutdown 全部可用且只经本机 CLI/Unix socket | Integration + Manual 演练 | P3 | ◐ CLI 全套；demo `cancel-all` 会撤 pending；人工演练/长稳仍待 |

## B. 非功能需求(NFR)

| ID | 属性 | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|---|
| AC-NFR01 | 延迟 | 行情事件进程内风险计算 p99 < 10ms(不含公网);有持续测量与告警 | Soak(基准测量) | P3 | ☐ |
| AC-NFR02 | 可用性 | 断开 LLM/新闻/链上/Dashboard 后,风险监控、订单对账与退出能力仍工作 | Fault Injection | P3 | ☐ |
| AC-NFR03 | 一致性 | 提案未绑定当前 snapshot_version 即拒绝;状态变化后旧提案自动失效 | Property + Unit | P2 | ◐ admission 单测:`snapshot_version` 失配 → REJECT(stale_snapshot);property 广度待扩 |
| AC-NFR04 | 恢复 | 重启→恢复 DB→OKX 对账→READY;对账完成前不产生增仓提案 | Integration + Fault(kill -9 注入) | P3 | ◐ 生命周期 BOOTING→CONNECTING→RECONCILING→READY 已实现并实网验证;未对账时 fail-closed 起步 exit_only(单测);kill -9 注入待做 |
| AC-NFR05 | 部署发布 | 生产 VM 无 Python/Node/Docker;核心二进制与 Dashboard 均可原子回滚;health fail 自动回滚 | Manual(发布演练) | P3 | ☐ |
| AC-NFR06 | 审计资源 | 关键事件带 state_version/software_version/config_hash/correlation_id;资源(CPU/RSS/fd/WAL/磁盘)有告警 | Unit(信封)+ Soak | P3 | ◐ `core/events.zig` 事件信封四字段已单测;daemon 落库事件实测含全部戳;资源告警待做 |

## C. 上线验收标准(§9.3,Phase 4 实盘闸门)

| ID | 标准 | 验证方法 | 状态 |
|---|---|---|---|
| AC-GO1 | 重启后可从 OKX 对账出正确余额、BTC 数量、开放订单和 HWM | Integration(重启演练×3) | ☐ |
| AC-GO2 | Agent 无法直接访问交易凭证或绕过 Risk Kernel(代码层能力缺失,非 prompt 约束) | Manual(红队评审)+ Unit(接口不可达) | ◐ 架构落地:`agent/` 仅产出 Proposal 值类型,无凭证/网络/执行依赖;凭证只在 `exchange/okx/auth.zig`;红队评审待做 |
| AC-GO3 | Risk Kernel 核心性质过 property test,覆盖边界/费用/滑点/部分成交 | Property | ◐ admission 2000 次随机 + halted/flattening 模式 property；费用/部分成交广度仍可扩 |
| AC-GO4 | 断开 LLM、新闻、链上和 Dashboard 后,风险监控与订单对账仍工作 | Fault Injection | ☐ |
| AC-GO5 | 所有订单可追溯到 decision_id、snapshot_version、risk decision 和 config_hash | Replay(审计链抽查) | ☐ |
| AC-GO6 | 未知订单/陈旧数据/数据库异常进入安全状态,不默认继续增仓 | Fault Injection | ☐ |
| AC-GO7 | Dashboard 可完整回放一笔交易从观察到反思的链路 | Manual(UI 走查) | ◐ 决策展开含 admission/exec + **按 decision_id 关联订单/成交**; 完整链路 UI 走查待 Demo |
| AC-GO8 | Demo Trading 连续稳定 ≥7 天,完成 ≥1 次断线恢复和 ≥1 次版本回滚演练 | Soak + Manual | ☐ |

## D. 风险内核专项(§5)

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-RK1 | 保守净值 E_t 扣除退出费用/滑点/挂单风险;HWM 单调不减;DD 公式与设计一致 | Unit + Property | P3 | ☑ `risk/equity.zig`:保守估值扣费/滑点、HWM 单调、DD 公式、非负回撤全部单测通过 |
| AC-RK2 | 任意输入下 Risk Kernel 不批准使压力净值 < HWM×90%+ExitReserve 的提案 | Property / Fuzz | P3 | ◐ 压力净值地板检查已实现并单测(REDUCE/REJECT 路径);随机化 property/fuzz 待扩 |
| AC-RK3 | 风险状态机转换(NORMAL/EXIT_ONLY/FLATTENING/HALTED)与 §5.3 条件表一致;HALTED 不自动恢复交易 | Unit(状态机)+ Fault | P3 | ◐ `risk/state_machine.zig` 转换表全路径单测,HALTED 无自动出边;Fault 注入待做 |
| AC-RK4 | FLATTENING 先撤增险挂单,再退出,持续对账至 BTC 可用≈0 | Integration(Demo 演练) | P3 | ☐ |
| AC-RK5 | 边界穿透时如实记录实际穿透幅度与成交成本(不掩饰) | Fault(极端行情 replay) | P3 | ☐ |
| AC-RK6 | max_drawdown 与 Risk Kernel 参数不可热加载、Agent 不可修改 | Unit + Manual(配置评审) | P3 | ◐ config 仅启动时解析,`allow_runtime_override=false` 强制;Agent 模块无 config 写路径;评审待做 |

## E. 故障降级矩阵(§7.2,逐项注入验证)

| ID | 故障场景 | 期望自动动作 | 验证方法 | 状态 |
|---|---|---|---|---|
| AC-FD1 | LLM 超时/报错 | 本轮 HOLD,无订单;风险与对账继续 | Fault | ◐ shadow HOLD + `fault/matrix` 分类/坏 JSON 单测; 实网 Fault 注入待做 |
| AC-FD2 | 外部工具不可用 | ToolResult=UNAVAILABLE;不得把缺失数据编造成零值 | Fault + Unit | ◐ UNAVAILABLE/`null` data 单测（`fault/matrix`）+ market HTTP 路径 |
| AC-FD3 | 公共行情过期 | 进入 EXIT_ONLY;重连 + REST 校验;不增险 | Fault | ◐ stale→EXIT_ONLY + admission 拒增仓（`fault/matrix`）; 实网断线待做 |
| AC-FD4 | 私有账户 WS 断开 | EXIT_ONLY + REST 对账;未知期间不自主开仓 | Fault | ◐ unresolved/stale account 拒增仓单测; WS 断线注入待做 |
| AC-FD5 | 下单超时 | 订单 UNKNOWN→查询后处置;禁止直接重发 | Fault + Integration | ◐ UNKNOWN 禁止 submit 单测 + demo query 路径; 实网超时注入待做 |
| AC-FD6 | SQLite busy | 短暂重试+降采样遥测;关键事件优先落库 | Fault | ◐ `storage/policy.onBusy` + PRAGMA busy_timeout; 实盘注入待做 |
| AC-FD7 | 磁盘接近满 | 停新交易,清理可重建缓存;严重时 HALTED | Fault | ◐ `storage/disk` statvfs + `disk_ok` 进健康检查; low→EXIT_ONLY critical→HALTED; 缓存清理待做 |
| AC-FD8 | 数据库损坏 | 仅保留退出能力+应急文本日志;禁止静默新建空库继续交易 | Fault | ◐ boot：已存在文件 open 失败 → FATAL refuse recreate; 应急文本日志/只退能力待扩 |
| AC-FD9 | 回撤边界触发 | FLATTENING → HALTED;记录穿透与成本 | Fault + Replay | ◐ FLATTENING→HALTED + 无自动恢复（`fault/matrix`）;极端行情 replay 待做 |
| AC-FD10 | 进程崩溃 | systemd 重启→重新对账→READY;重启前状态不被假定正确 | Fault(kill -9) | ☐ |

## F. 安全边界(§7.3 / §7.4)

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-SEC1 | OKX API Key 仅 Read+Trade(无 Withdraw),绑定 Azure 固定出口 IP 白名单 | Manual(配置审查) | P4 | ☐ |
| AC-SEC2 | 密钥文件 root 管理 0600;服务进程只读;密钥不进备份 | Manual + 脚本检查 | P4 | ☐ |
| AC-SEC3 | LLM Context/日志/错误栈/Dashboard 响应中无 secret/passphrase/签名材料(redaction 生效) | Unit(redaction)+ Manual 抽查 | P2 | ◐ `redaction.redact` 单测 + journal `logEventPayload` 落库前 redact/looksLeaky 拦截; Dashboard 抽查仍待 |
| AC-SEC4 | systemd 加固: NoNewPrivileges/PrivateTmp/ProtectSystem/受限写目录 | Manual(unit 审查) | P1 | ◐ `deploy/alphabound.service` 已含加固项；生产装机演练仍待 |
| AC-SEC5 | 外部 HTTP 响应有大小/解压/超时/JSON 深度限制 | Unit + Fuzz | P2 | ☐ |
| AC-SEC6 | Agent 禁止项全部不可达: 读环境变量/密钥/DB 文件、执行 shell、任意 URL、直接获得 OKX client、修改风险配置/Prompt/二进制 | Manual(红队)+ Unit | P2 | ☐ |
| AC-SEC7 | 工具返回视为不可信数据,只进 data 字段;第三方文字不得成为系统指令(注入测试) | Fault(工具污染注入) | P2 | ☐ |
| AC-SEC8 | Dashboard 默认仅绑定 127.0.0.1;管理命令仅本机 CLI/Unix socket | Integration(端口扫描) | P1 | ◐ web 默认 127.0.0.1；管理为本地控制文件 CLI（无 socket 面）；端口扫描演练待做 |

## G. 数据与运维(§6 / §7.5 / §8)

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-OPS1 | SQLite WAL 位于本地磁盘(非网络 FS);Journal Writer 唯一写者;关键事件限时提交 | Unit + Soak | P1 | ◐ WAL+单写者已落地;小时 Backup API→`.bak`;Soak 待做 |
| AC-OPS2 | 事件信封顶层含 type/correlation_id/state_version/software_version/config_hash | Unit | P1 | ☐ |
| AC-OPS3 | 每小时备份快照(留 24)+ 每日(留 30);备份失败不影响交易关键路径 | Fault + Manual | P1 | ☐ |
| AC-OPS4 | 每周 restore drill: 备份启动只读实例,校验 schema/事件序列/HWM/订单投影 | Manual(演练记录) | P3 起 | ☐ |
| AC-OPS5 | 发布 8 步流程可执行;dashboard-only 更新不重启 daemon;核心更新 pause→checkpoint→切换→重启 | Manual(发布演练) | P3 | ☐ |
| AC-OPS6 | ready health check 失败自动回滚上一 symlink 并重新对账 | Fault(坏版本注入) | P3 | ☐ |
| AC-OPS7 | 配置热加载规则符合 §8.5 表(Prompt 可热载;max_drawdown 不可) | Unit + Manual | P2 | ☐ |
| AC-OPS8 | 模型调用成本、基础设施成本可见可统计(成本 vs 本金一级指标) | Manual(Dashboard 走查) | P2 | ☐ |
| AC-OPS9 | equity_samples 保留策略生效(1s 保 7 天,1min 永久);tool_calls 原始 30 天 | Unit(保留任务) | P3 | ☐ |

## H. 阶段闸门汇总

| 闸门 | 必须全绿的条目 |
|---|---|
| Gate 0(P0 退出) | 依赖决议 + 24h 长稳(见 ROADMAP,无正式 AC,产出决议记录) |
| Gate 1(P1 退出) | AC-FR01/02、AC-FR09(基础)、AC-SEC4/8、AC-OPS1/2/3 |
| Gate 2(P2 退出) | AC-FR03/04/07/08(市场类)、AC-NFR03、AC-SEC3/5/6/7、AC-OPS7/8 |
| Gate 3(P3 退出) | AC-FR05/06/10、AC-NFR01/02/04/05/06、AC-RK1..6、AC-FD1..10、AC-OPS4/5/6/9 |
| Gate 4(实盘进入) | AC-GO1..8 + AC-SEC1/2 + 以上全部 |

> 维护约定: 每次闸门评审更新状态列并附证据链接(CI run / 演练记录 / 评审纪要);
> 新增需求先补矩阵行再写代码。
