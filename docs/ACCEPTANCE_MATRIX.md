# AlphaBound 验收矩阵

> 将系统设计 v0.1 的功能需求(FR)、非功能需求(NFR)、上线验收标准(§9.3)、安全边界(§7.3/7.4)
> 与故障降级矩阵(§7.2)映射为可执行、可勾选的验收条目。
>
> - **验证方法** 对应 §9.2 测试金字塔: Unit / Property / Replay / Integration / Fault / Soak / Shadow / Manual(人工演练或评审)
> - **阶段** 指该条目必须通过的最晚阶段闸门(见 [ROADMAP.md](ROADMAP.md));进入 Phase 4 实盘前,P0–P3 条目必须全绿
> - **状态**: ☐ 未开始 · ◐ 进行中 · ☑ 通过
>
> **状态快照(2026-08-13)**: 核心软件 + shadow/demo/live 主路径已验证(`zig build test` 全绿; Dashboard 提案/BH/订单;
> 鉴权+MCP; 本机/生产 OKX 公共行情与私有余额、LLM 提案、market/derivatives 工具落库; 小额 live 下单与 flatten)。
> 下表 ◐ = 代码+单测/部分实网已落地, 完整 7 日 Soak 与部分实网 Fault 仍缺。

## A. 功能需求(FR)

| ID | 需求摘要 | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|---|
| AC-FR01 | 行情与账户接入 | 订阅 OKX 公共+私有 WS;启动与断线后 REST 快照对账一致;序列缺口触发 DEGRADED+reconcile | Integration(OKX Demo)+ Fault(断线注入) | P1 | ◐ REST ticker/余额实网 + 周期 REST 对账;公共 WS 帧编解码单测;私有 WS login/push 协议单测;TLS 私有流与断线注入待做 |
| AC-FR02 | 状态引擎 | 内存维护价格/余额/BTC/挂单/净值/HWM/DD;快照带版本;replay 同版本结果逐位一致 | Unit + Replay | P1 | ☑ `core/state.zig` 单写者引擎;replay 确定性逐位一致测试通过(`state engine: replay determinism`) |
| AC-FR03 | Agent 决策 | 决策基于一致性快照+检索记忆;可按需调用工具;全程可审计 | Shadow + Integration | P2 | ◐ Context+LLM + market 工具 + 记忆/events + **LLM reflection** + **Risk 准入审计**（不执行）+ 全审计; 长跑阈值评审仍待 |
| AC-FR04 | 交易提案 | Proposal 严格 Schema(target/order_policy/confidence/thesis/evidence/invalid_if);坏 JSON/缺字段即作废 | Unit(Schema)+ Fuzz | P2 | ☑ `agent/proposal.zig` 严格解析(单测)+fuzz:随机字节/全前缀截断/4000 轮字节翻转均不 crash,可解析变体保持全部不变量 |
| AC-FR05 | 风险准入 | 校验 snapshot_version、数据新鲜度、压力净值≥HWM×90%+ExitReserve;能输出 APPROVE/REDUCE/REJECT | Property + Unit | P3 | ◐ 单测+property 基础; **shadow 路径已调用 admit 并落 `RISK_ADMISSION`**; Demo 执行联动仍待 |
| AC-FR06 | 订单执行 | client_order_id 幂等(decision_id+版本+序号);部分成交重算差额;超时→UNKNOWN→查询后处置 | Integration + Fault + Replay | P3 | ◐ 单测 + **demo 市价/limit** place/query/cancel + UNKNOWN 查询 + **partial 再规划(≤3腿)**; Fault/7d soak 待做 |
| AC-FR07 | 长期 Context | 五层记忆可写入/检索/版本化;Reflection 产出结构化 memory_ops 并生效 | Shadow + Unit | P2 | ◐ store+reflection 单测; **Shadow**: boot/retrieve/episode/**LLM+确定性 reflection ops** + Dashboard memories |
| AC-FR08 | 可选数据工具 | 工具注册含 Schema/时效/成本;返回统一 ToolResult;调用与结果全部落事件日志 | Unit + Integration | P2(市场类)/ P5(扩展类) | ◐ registry + `market.ticker`/`market.candles` OKX REST provider 实调落 `tool_calls`;扩展域 provider 待做 |
| AC-FR09 | Dashboard | Overview/Market/Trade Detail/Events/Memory/System 六视图;K 线+交易/风险标记;保留 TradingView attribution | Manual(UI 走查)+ Integration(API) | P1(基础)/ P2(全视图) | ◐ Overview+提案+BH+**Lightweight Charts K线/量/净值HWM**+Memories+Events+System+**订单/fills API+Tab**+TV 归因；提案链路完整 Trade Detail 回放仍待 |
| AC-FR10 | 管理控制 | pause/resume/reconcile/cancel-all/flatten/safe-shutdown 全部可用且只经本机 CLI/Unix socket | Integration + Manual 演练 | P3 | ◐ CLI 全套；demo `cancel-all` 会撤 pending；人工演练/长稳仍待 |

## B. 非功能需求(NFR)

| ID | 属性 | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|---|
| AC-NFR01 | 延迟 | 行情事件进程内风险计算 p99 < 10ms(不含公网);有持续测量与告警 | Soak(基准测量) | P3 | ◐ `observability/latency.zig` Histogram(2048 环形窗口,nearest-rank 分位)+主循环 market_tick→engine.apply µs 测量,system JSON `latency_us{p50,p99,max,samples}` 持续可见;soak-report p99 门限告警已接(samples≥20 且 p99>P99_BUDGET_US 默认 10ms → SOAK FAIL);长窗口基准累积中 |
| AC-NFR02 | 可用性 | 断开 LLM/新闻/链上/Dashboard 后,风险监控、订单对账与退出能力仍工作 | Fault Injection | P3 | ◐ LLM 断连注入演练 PASS(2026-08-12,`scripts/llm-outage-drill.sh`:不可达端点→tick/风险循环继续、HOLD 兜底、干净退出、DB verify PASS);新闻/链上无外呼路径;Dashboard 断开注入待做 |
| AC-NFR03 | 一致性 | 提案未绑定当前 snapshot_version 即拒绝;状态变化后旧提案自动失效 | Property + Unit | P2 | ✅ admission 单测 + 随机化 property(1000 例:版本失配在任意快照状态组合下必 REJECT stale_snapshot) |
| AC-NFR04 | 恢复 | 重启→恢复 DB→OKX 对账→READY;对账完成前不产生增仓提案 | Integration + Fault(kill -9 注入) | P3 | ◐ 生命周期 BOOTING→CONNECTING→RECONCILING→READY 已实现并实网验证;未对账时 fail-closed 起步 exit_only(单测);kill -9 演练 PASS(2026-08-12 生产 SIGKILL→systemd 拉起→10s 恢复 READY,`scripts/kill9-drill.sh` 可重复执行,soak-report 入账不误报) |
| AC-NFR05 | 部署发布 | 生产 VM 无 Python/Node/Docker;核心二进制与 Dashboard 均可原子回滚;health fail 自动回滚 | Manual(发布演练) | P3 | ◐ 二进制 musl 静态链接(ldd "not a dynamic executable",daemon 零运行时依赖);releases+current symlink 原子回滚+health fail 自动回滚演练 PASS(2026-08-12);共享 VM 上存在他项目的 docker/python,daemon 不依赖 |
| AC-NFR06 | 审计资源 | 关键事件带 state_version/software_version/config_hash/correlation_id;资源(CPU/RSS/fd/WAL/磁盘)有告警 | Unit(信封)+ Soak | P3 | ◐ `core/events.zig` 事件信封四字段已单测;daemon 落库事件实测含全部戳;soak-report 资源门限已接(RSS>256MB/fd>256/WAL>64MB → SOAK FAIL;磁盘 statvfs 已在 daemon 内) |

## C. 上线验收标准(§9.3,Phase 4 实盘闸门)

| ID | 标准 | 验证方法 | 状态 |
|---|---|---|---|
| AC-GO1 | 重启后可从 OKX 对账出正确余额、BTC 数量、开放订单和 HWM | Integration(重启演练×3) | ◐ 重启演练×3 PASS(2026-08-12 生产,`scripts/restart-drill.sh`:每轮 HWM 恢复+461 memories 重载+OKX 私有余额对账 ok+READY≤9s);开放订单对账待 demo 挂单场景 |
| AC-GO2 | Agent 无法直接访问交易凭证或绕过 Risk Kernel(代码层能力缺失,非 prompt 约束) | Manual(红队评审)+ Unit(接口不可达) | ◐ 架构落地:`agent/` 仅产出 Proposal 值类型;凭证只在 `exchange/okx/auth.zig`;`security/isolation.zig` 源码扫描单测持续强制隔离;红队评审待做 |
| AC-GO3 | Risk Kernel 核心性质过 property test,覆盖边界/费用/滑点/部分成交 | Property | ☑ admission 2000 次随机 + halted/flattening 模式 + 费用/滑点/shock 单调性(stress equity 非增)+ max_drawdown 收紧单调 + planner 部分成交迭代收敛(qty 单调减不翻向) property 全过 |
| AC-GO4 | 断开 LLM、新闻、链上和 Dashboard 后,风险监控与订单对账仍工作 | Fault Injection | ◐ LLM 断连演练 PASS(同 AC-NFR02);新闻/链上无外呼路径;Dashboard 进程内无独立断开面 |
| AC-GO5 | 所有订单可追溯到 decision_id、snapshot_version、risk decision 和 config_hash | Replay(审计链抽查) | ◐ `--verify-db` 审计链:订单→AGENT_PROPOSAL_OK **或** ADMIN_TARGET_WEIGHT + ORDER_* + 无孤儿 fills;单测含 operator 锚点;`scripts/audit-go5.sh` 远端抽查;2026-08-12 真实 agent REBALANCE 样本已有 exchange_id |
| AC-GO6 | 未知订单/陈旧数据/数据库异常进入安全状态,不默认继续增仓 | Fault Injection | ◐ 未知订单→`order_ambiguity`→degraded(单测);陈旧数据→admission REJECT `stale_data`(property);DB 审计写失败→`journal_ok=false`→exit_only、写恢复自愈(2026-08-12 新增,state 单测锁定;行情新鲜不能单独清除降级);进程级 fault 注入演练待做 |
| AC-GO7 | Dashboard 可完整回放一笔交易从观察到反思的链路 | Manual(UI 走查) | ◐ 决策展开含 admission/exec + **按 decision_id 关联订单/成交**; 完整链路 UI 走查待 Demo |
| AC-GO8 | 交易模式连续稳定 ≥7 天,完成 ≥1 次断线恢复和 ≥1 次版本回滚演练 | Soak + Manual | ◐ 版本回滚演练 ≥1 次 PASS(2026-08-12 双向);kill -9/重启恢复演练 PASS;执行场所已就绪(`mode=live`+小额子账号+`OKX_REAL_MONEY_OK=1`);7 天滚动 soak 窗口积累中 |

## D. 风险内核专项(§5)

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-RK1 | 保守净值 E_t 扣除退出费用/滑点/挂单风险;HWM 单调不减;DD 公式与设计一致 | Unit + Property | P3 | ☑ `risk/equity.zig`:保守估值扣费/滑点、HWM 单调、DD 公式、非负回撤全部单测通过 |
| AC-RK2 | 任意输入下 Risk Kernel 不批准使压力净值 < HWM×90%+ExitReserve 的提案 | Property / Fuzz | P3 | ● 压力净值地板单测 + 随机化 property×2(2000+2000 例)+ decimal 极值 fuzz(4000 例:0/1/i64max/1e18 单位级 raw 组合,不 panic、Overflow fail-closed、APPROVE/REDUCE 压力净值 ≥ floor) |
| AC-RK3 | 风险状态机转换(NORMAL/EXIT_ONLY/FLATTENING/HALTED)与 §5.3 条件表一致;HALTED 不自动恢复交易 | Unit(状态机)+ Fault | P3 | ◐ 转换表全路径单测 + 随机序列 property(500 walk×64 步:HALTED 无 reset 不出、出边仅 EXIT_ONLY、FLATTENING 不被健康信号中止);进程级 Fault 注入待做 |
| AC-RK4 | FLATTENING 先撤增险挂单,再退出,持续对账至 BTC 可用≈0 | Integration(Demo 演练) | P3 | ◐ 进入 FLATTENING 即置 `agent_blocked`,执行 lane 对在途 agent 挂单撤单并确认;只减仓退出驱动 + 权威对账确认 BTC≈0 才 HALTED(见 AC-EX1/EX2;E2E `slow_model`);撤单优先于增险单的整链演练待扩 |
| AC-RK5 | 边界穿透时如实记录实际穿透幅度与成交成本(不掩饰) | Fault(极端行情 replay) | P3 | ☐ |
| AC-RK6 | max_drawdown 与 Risk Kernel 参数不可热加载、Agent 不可修改 | Unit + Manual(配置评审) | P3 | ◐ config 仅启动时解析,`allow_runtime_override=false` 强制;Agent 模块无 config 写路径;评审待做 |

## E. 故障降级矩阵(§7.2,逐项注入验证)

| ID | 故障场景 | 期望自动动作 | 验证方法 | 状态 |
|---|---|---|---|---|
| AC-FD1 | LLM 超时/报错 | 本轮 HOLD,无订单;风险与对账继续 | Fault | ◐ shadow HOLD + `fault/matrix` 分类/坏 JSON 单测;实网断连注入 PASS(`scripts/llm-outage-drill.sh`) |
| AC-FD2 | 外部工具不可用 | ToolResult=UNAVAILABLE;不得把缺失数据编造成零值 | Fault + Unit | ◐ UNAVAILABLE/`null` data 单测（`fault/matrix`）+ market HTTP 路径 |
| AC-FD3 | 公共行情过期 | 进入 EXIT_ONLY;重连 + REST 校验;不增险 | Fault | ◐ stale→EXIT_ONLY + admission 拒增仓（`fault/matrix`）; 实网断线待做 |
| AC-FD4 | 私有账户 WS 断开 | EXIT_ONLY + REST 对账;未知期间不自主开仓 | Fault | ◐ unresolved/stale account 拒增仓单测; WS 断线注入待做 |
| AC-FD5 | 下单超时 | 订单 UNKNOWN→查询后处置;禁止直接重发 | Fault + Integration | ◐ UNKNOWN 禁止 submit 单测 + demo query 路径; 实网超时注入待做;**整链**已由 AC-EX3/EX4 + E2E `lost_response` 覆盖 |
| AC-FD6 | SQLite busy | 短暂重试+降采样遥测;关键事件优先落库 | Fault | ◐ `stepCritical` 对 events/orders/fills/… 写路径重试 + busy_timeout; 订单意图写失败不放行(AC-EX7);多连接 BUSY_SNAPSHOT 已修(AC-EX12);busy 注入待做 |
| AC-FD7 | 磁盘接近满 | 停新交易,清理可重建缓存;严重时 HALTED | Fault | ◐ `storage/disk` statvfs + `disk_ok` 进健康检查; low→EXIT_ONLY critical→HALTED; 缓存清理待做 |
| AC-FD8 | 数据库损坏 | 仅保留退出能力+应急文本日志;禁止静默新建空库继续交易 | Fault | ◐ boot：已存在文件 open 失败 → FATAL refuse recreate; 应急文本日志/只退能力待扩 |
| AC-FD9 | 回撤边界触发 | FLATTENING → HALTED;记录穿透与成本 | Fault + Replay | ◐ FLATTENING→HALTED + 无自动恢复（`fault/matrix`）;极端行情 replay 待做 |
| AC-FD10 | 进程崩溃 | systemd 重启→重新对账→READY;重启前状态不被假定正确 | Fault(kill -9) | ☑ 生产 kill -9 演练 PASS(2026-08-12) + `fault/matrix` 单测：fresh engine EXIT_ONLY/未 reconcile 拒增仓，对账后才 NORMAL |

## F. 安全边界(§7.3 / §7.4)

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-SEC1 | OKX API Key 仅 Read+Trade(无 Withdraw),绑定 Azure 固定出口 IP 白名单 | Manual(配置审查) | P4 | ◐ boot 代码门禁:实盘授权时探测 /account/config,withdraw 权限直接拒绝启动;生产验证 read=true trade=true withdraw=false(2026-08-12);IP 白名单绑定为 OKX 侧人工配置 |
| AC-SEC2 | 密钥文件 root 管理 0600;服务进程只读;密钥不进备份 | Manual + 脚本检查 | P4 | ✅ check-remote.sh SEC2 段自动检查:600 root:alphabound + 数据目录无密钥泄漏 + DB/备份/WAL 字节级抽查真实密钥值不存在,生产 PASS(2026-08-12) |
| AC-SEC3 | LLM Context/日志/错误栈/Dashboard 响应中无 secret/passphrase/签名材料(redaction 生效) | Unit(redaction)+ Manual 抽查 | P2 | ◐ `redaction.redact` 单测 + `logEventPayload` 落库前 redact/looksLeaky 拦截;check-remote SEC3 段抽查全部 Dashboard API(system/state/events/decisions/orders/memories/shadow)不含真实密钥值,生产 PASS(2026-08-12);LLM context 出站抽查待做 |
| AC-SEC4 | systemd 加固: NoNewPrivileges/PrivateTmp/ProtectSystem/受限写目录 | Manual(unit 审查) | P1 | ✅ 生产核验(2026-08-12 `systemctl show`):NoNewPrivileges=yes PrivateTmp=yes ProtectSystem=strict ProtectHome=yes ReadWritePaths=/var/lib/alphabound User=alphabound |
| AC-SEC5 | 外部 HTTP 响应有大小/解压/超时/JSON 深度限制 | Unit + Fuzz | P2 | ◐ `security/limits.zig` 上限常量+`jsonStructureSane` 结构扫描(单测含深度炸弹/breakout/截断);OKX REST 512KB、LLM 1MB、egress 探针 4KB 固定容量 sink 接线,超限→记录并拒绝;解压炸弹面(gzip)待评审 |
| AC-SEC6 | Agent 禁止项全部不可达: 读环境变量/密钥/DB 文件、执行 shell、任意 URL、直接获得 OKX client、修改风险配置/Prompt/二进制 | Manual(红队)+ Unit | P2 | ◐ `security/isolation.zig` @embedFile 源码扫描测试:agent 纯逻辑禁 std.http/net/fs/process/getenv/Child/exchange/execution/storage/risk-admission/凭证 token,openai.zig 仅白名单 std.http;人工红队评审待做 |
| AC-SEC7 | 工具返回视为不可信数据,只进 data 字段;第三方文字不得成为系统指令(注入测试) | Fault(工具污染注入) | P2 | ☑ `formatObservation` 对 data_json 结构扫描,失败→null;`fault/matrix.zig` 注入测试:提示注入文本仅存于 data.note 字符串值内,risk_rules 不可变,breakout/深度炸弹 payload 全部中和 |
| AC-SEC8 | Dashboard 默认仅绑定 127.0.0.1;管理命令仅本机 CLI/Unix socket | Integration(端口扫描) | P1 | ◐ 默认 bind 127.0.0.1;生产为私网 VM 上 0.0.0.0(局域网 Dashboard),互联网侧探测出口 IP:8080 不可达(NAT 无端口映射,2026-08-12 实测);管理仅本地控制文件 CLI;完整端口扫描(nmap 全端口)待做 |

## G. 数据与运维(§6 / §7.5 / §8)

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-OPS1 | SQLite WAL 位于本地磁盘(非网络 FS);Journal Writer 唯一写者;关键事件限时提交 | Unit + Soak | P1 | ◐ WAL+单写者已落地;小时 Backup API→`.bak`;Soak 待做 |
| AC-OPS2 | 事件信封顶层含 type/correlation_id/state_version/software_version/config_hash | Unit | P1 | ☐ |
| AC-OPS3 | 每小时备份快照(留 24)+ 每日(留 30);备份失败不影响交易关键路径 | Fault + Manual | P1 | ◐ `storage/retention.zig` 命名/轮换/selectDoomed 纯函数(property 测试)+`rotateBackups` 接线:hourly(留24)/daily(留30)快照+latest `.bak`,全部 best-effort 只记日志不阻断主循环;生产恢复演练待做 |
| AC-OPS4 | 每周 restore drill: 备份启动只读实例,校验 schema/事件序列/HWM/订单投影 | Manual(演练记录) | P3 起 | ◐ `--verify-db PATH`(只读打开,integrity_check/user_version/7 表行数/seq 连续/HWM 可解析)+`scripts/restore-drill.sh`(最新快照→scratch→校验→新鲜度<2h);生产演练 PASS(2026-08-12,hourly 快照 9s 新);周期化排程待做 |
| AC-OPS5 | 发布 8 步流程可执行;dashboard-only 更新不重启 daemon;核心更新 pause→checkpoint→切换→重启 | Manual(发布演练) | P3 | ◐ 版本化部署上线:`/opt/alphabound/releases/<sha>-<ts>/`+`current` 原子 symlink 切换(ln+mv -T),保留 5 版;dashboard-only 免重启路径待做 |
| AC-OPS6 | ready health check 失败自动回滚上一 symlink 并重新对账 | Fault(坏版本注入) | P3 | ◐ install-remote.sh health 门禁(15×2s 探测 /health/ready)失败自动回滚上一 release+记录 deploys.log;`scripts/rollback-remote.sh` 手动回滚演练 PASS(2026-08-12,双向);真实坏版本注入已发生一次(health grep bug 触发 auto-rollback 路径) |
| AC-OPS7 | 配置热加载规则符合 §8.5 表(Prompt 可热载;max_drawdown 不可) | Unit + Manual | P2 | ☐ |
| AC-OPS8 | 模型调用成本、基础设施成本可见可统计(成本 vs 本金一级指标) | Manual(Dashboard 走查) | P2 | ◐ system JSON 暴露 `llm_calls/prompt_tokens/completion_tokens/total_tokens` 会话累计;USD 折算与基础设施成本项待做 |
| AC-OPS9 | equity_samples 保留策略生效(1s 保 7 天,1min 永久);tool_calls 原始 30 天 | Unit(保留任务) | P3 | ◐ `retention.zig` cutoff/prune SQL(单测)+每小时 `runRetentionSweep` 接线:tool_calls>30d、equity '1s'>7d 清理,'1m' 永久保留;长跑验证待做 |

## I. 执行链与快循环加固(2026-10 缺陷审计修复)

> 来源:2026-10-04 缺陷分析(基线 `d0c2fe8`)。每一行的回归测试都先在基线代码上**确实失败**再修复;
> 单测在 `zig build test`,整链故障注入见 `src/execution/exec_chain_tests.zig`、`src/execution/exec_lane_tests.zig`,
> 进程级演练见 `tools/e2e/run_e2e.py`(真实二进制 + 本地合成 OKX 模拟盘/模型,**不触碰任何真实交易所/密钥**)。
> 设计与剩余限制见 [EXECUTION_SAFETY.md](EXECUTION_SAFETY.md)。

| ID | 验收标准 | 验证方法 | 阶段 | 状态 |
|---|---|---|---|---|
| AC-EX1 (P0-1) | 穿透回撤边界后(FLATTENING / EXIT_ONLY),清仓走**严格只减仓**的 `admitExit`:不要求净值回到边界之上,但要求账户已对账且权威(非本地推算)、行情/账户新鲜、无未决订单、卖量 ≤ 可用 BTC;任何情况下不得增仓 | Unit + Property(3000 例) + Integration + E2E | P3 | ☑ `risk/admission.zig` `admitExit`;`execution/operator.zig` `driveFlatten`/`runExit`;测试 `P0-1 repro…`、`exit admission …`、`P0-1: …`(越界/跳空/退出成本>缓冲/未决订单/推算账本);E2E `slow_model` 在价格崩到 -30% 时仍卖出并 HALTED |
| AC-EX2 (P0-2) | LLM、工具、反思、复盘与订单等待**不阻塞**行情/账户/clock_tick/本机指令;状态仍是单写者;有界队列;可取消;过期结果丢弃 | Unit + Integration(跨线程) + E2E | P3 | ☑ `core/state.zig` 所有者线程 + `submit`/`drainInbox`(溢出 fail-closed);`core/lanes.zig`;`execution/exec_lane.zig`(执行 lane);`main.zig` `ThinkLane`(思考 lane,独立 HTTP/SQLite);测试 `exec_lane_tests.zig`、`state.zig` 并发测试;E2E `slow_model`:模型挂 40s 期间 5s 内行情轮询 9 次、`pause` 0.5s 内生效、边界穿透后 0.7s 触发并卖出完成;基线同一演练 0 次轮询 |
| AC-EX3 (P1-1) | 写类请求(下单/撤单)传输结果未知时**不自动重发**;转 UNKNOWN 后按同一 clOrdId 查询 | Integration + E2E | P3 | ☑ `exchange/okx/rest.zig` 仅 GET 自动重试;`P1-1: a lost placement response is queried, never re-sent`;E2E `lost_response`:场馆仅收到 1 次下单(基线 2 次) |
| AC-EX4 (P1-2) | 查询空列表/业务错误码/暂不可见**不得**解除 UNKNOWN;`absent` 仅在对账中经宽限期 + 挂单列表完整核对后才可判定 | Unit + Integration | P3 | ☑ `rest.lookupOrder`/`classifyPlaceResponse`;`P1-2: …`×3;`P1-6: an intent the venue never saw …` |
| AC-EX5 (P1-3) | 部分成交撤单必须经查询确认终态才可进入下一腿;每一腿在新鲜权威快照上**重新准入**;方向不得翻转 | Integration + E2E | P3 | ☑ `demo_runner.zig` `cancelAndConfirm`/`tryDemoExecute`;`P1-3: …`×2;E2E `cancel_rejected`:撤单被拒时仅 1 次下单(基线 3 次叠加),保持未决直到恢复核验 |
| AC-EX6 (P1-4) | 余额刷新失败/滞后时只按**已核验的实际成交增量**(数量/均价/币种手续费)做本地推算;推算不刷新账户新鲜度、不推进 HWM、不能作为准入/清仓完成依据 | Unit + Integration | P3 | ☑ `state.zig` `account_projection`;`demo_runner.zig` `projectFill`;`P1-4: …`、`projection moves the book …`、`P0-1: a flatten cannot sell on a projected book` |
| AC-EX7 (P1-5) | 下单意图(PLANNED)**先持久化成功**才可发送;ACK/进度写失败显式进入 `ledger_ok=false`+未决,不放行新增交易 | Fault(SQLite 触发器注入) | P3 | ☑ `P1-5: a failed intent write blocks the venue request`、`…acknowledgement write keeps the order unresolved`;`ledger_status` 消息 |
| AC-EX8 (P1-6) | 启动与周期对账覆盖**订单**:DB 非终态订单 + 场馆挂单 + 单笔查询对齐前关闭新增交易;孤儿挂单撤销并核验;非本进程挂单需运维 cancel-all | Integration + E2E(kill -9) | P3 | ☑ `demo_runner.zig` `recoverOrders`;`P1-6: …`×7;E2E `restart_recovery`:kill -9 后新进程取消孤儿单并确认,期间 0 笔新订单 |
| AC-EX9 (P1-7) | cancel-all 返回结构化结果;列表失败/撤单被拒/撤单期间成交都**保持**未决保护,直到场馆挂单与本地账本均核验为空 | Integration | P3 | ☑ `cancelAllVerified`;`P1-7: …`×4 |
| AC-EX10 (P1-8) | 累计成交以**增量行**入账(`applyCumulative`),重复/乱序查询不重复计入,partial→更大 partial→filled 总量/均价/手续费正确 | Unit + Integration | P3 | ☑ `storage/db.zig` `FillsRepo.applyCumulative`;`cumulative fill projection …`、`P1-8: …`。与未来逐笔 WS 的去重见 EXECUTION_SAFETY 剩余限制 |
| AC-EX11 | 提案时效:模型决策锚定快照(时间/价格/账户/风险模式/资金流),执行前超龄、价格漂移、账户/资金流/风险状态变化即**作废并重做一次决策**;原始与执行快照随决策落库;不再把旧版本自动换绑到新快照 | Unit + E2E | P3 | ☑ `agent/validity.zig`(`proposal_max_age_ms`/`proposal_max_price_drift`/`proposal_max_book_drift`);事件 `AGENT_PROPOSAL_STALE`;`AGENT_PROPOSAL_OK` 含 `decision_snapshot`/`execution_snapshot`;E2E 日志 `proposal … void (risk_mode_changed)` 后重做 |
| AC-EX12 | 多连接写库不得因遗留的读语句固定快照而 `SQLITE_BUSY`(E2E 发现并修复) | Integration | P3 | ☑ `KvRepo.getChecked` 与 `applyCumulative` 读后复位;`a connection that read the kv store can still write …` |
| AC-EX13 | 独立评审发现项:① 非本进程挂单(含无 clOrdId)只关闭**新增风险**(`foreign_pending`),**不得**阻断只减仓退出;cancel-all 对无 clOrdId 订单按 `ordId` 撤销并以场馆重新列表核验;② 下单回包中超时类/未识别 `sCode`(如 50004/50013/51149)视为 UNKNOWN 而非拒绝;③ 单次账本写失败导致的 `ledger_ok=false` 在后续成功写或恢复通过后自愈;④ cancel-all 之后执行 lane 重新对账,解除“恢复未完成”对 agent 的封锁 | Unit + Integration + E2E | P3 | ☑ `state.zig` `foreign_pending`;`risk/gate.zig` `exitView` 仅看本地账本;`rest.zig` `definitiveRejectionCode`/`parsePendingUnnamedOrdIds`;`demo_runner.zig` `recoverOrders`/`cancelAllVerified`;`exec_lane.zig` `runRecovery`;测试 `review: …`×5、`classifyPlaceResponse never turns a timeout-class sCode …`;E2E `foreign_order_exit` |

## H. 阶段闸门汇总

| 闸门 | 必须全绿的条目 |
|---|---|
| Gate 0(P0 退出) | 依赖决议 + 24h 长稳(见 ROADMAP,无正式 AC,产出决议记录) |
| Gate 1(P1 退出) | AC-FR01/02、AC-FR09(基础)、AC-SEC4/8、AC-OPS1/2/3 |
| Gate 2(P2 退出) | AC-FR03/04/07/08(市场类)、AC-NFR03、AC-SEC3/5/6/7、AC-OPS7/8 |
| Gate 3(P3 退出) | AC-EX1..12、AC-FR05/06/10、AC-NFR01/02/04/05/06、AC-RK1..6、AC-FD1..10、AC-OPS4/5/6/9 |
| Gate 4(MVP 运维判定) | AC-GO1..8 + AC-SEC1/2 + 以上全部；小额 live 已在 Gate3 解锁 |

> 维护约定: 每次闸门评审更新状态列并附证据链接(CI run / 演练记录 / 评审纪要);
> 新增需求先补矩阵行再写代码。
