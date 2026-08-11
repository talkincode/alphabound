# AlphaBound 系统设计分析

> 基于《AlphaBound System Design v0.1》(2026-08-09, MVP 设计基线)。
> 本文是工程视角的独立分析:评估关键决策、指出风险与薄弱点、列出实现阶段需要重点验证的事项。

## 1. 一句话理解

AlphaBound 把「AI 自主交易」拆成两个正交问题:**策略自主性交给 LLM Agent,资金安全交给确定性代码**。
Agent 拥有完整的观察、推理与提案自由,但唯一通往交易所的路径被 Risk Kernel + Execution Engine 把守;
10% 最大回撤是结果边界,不是方法约束。

## 2. 关键决策评估

| 决策 | 评价 | 分析 |
|---|---|---|
| Bounded Autonomy(提案-准入分离) | ✅ 核心亮点 | ADR-004 将模型不确定性与交易权限隔离。Agent 输出严格 Schema 的 Proposal 并绑定 `snapshot_version`,Risk Kernel 是唯一准入点。这是全系统最重要的安全设计,值得用 property test 重点守护。 |
| 双通道 + 单写者状态 | ✅ 正确 | 关键路径(风险/执行)不等待 LLM;State Engine 单写者消除并发写幽灵仓位。代价是所有状态变更都要走 mailbox 顺序化,吞吐受限于单核处理速度——对 1 标的 100 USDT 完全够用。 |
| 保守净值 + HWM 回撤定义 | ✅ 严谨 | 用「可清算净值」(扣退出费用/滑点/挂单风险) 而非 mark price 计净值;HWM 随盈利上移。ExitReserve 作为动态刹车距离是亮点。**注意**: E_t 公式中 Slippage_exit 与 PendingRisk 的估计模型是未决项,需要实盘订单簿数据校准(设计 9.5 已承认)。 |
| Zig 0.16.0 固定版本 | ⚠️ 最大技术风险 | pre-1.0 语言 + 官方承认 0.16.x 存在 miscompilation 风险。生态几乎没有久经考验的 TLS/WebSocket/HTTP 库,Phase 0 spike 是整个计划的**关键闸门**——若 TLS/WS 不达产线质量,应有 fallback 预案(vendor 轻量 C 库或降级语言选型)。ReleaseSafe + 回放测试可缓解但不能消除。 |
| SQLite WAL 单 writer | ✅ 合适 | 单机审计场景标准解。设计正确指出不可放网络文件系统。注意 WAL checkpoint 与备份 API 的交互要纳入 soak 测试(WAL size 是关键指标之一)。 |
| 无 Docker、systemd 直跑 | ✅ 务实 | 单文件二进制 + 原子 symlink 切换 + 快速回滚,发布路径短。代价是环境一致性靠 CI 固定 toolchain 保证。 |
| 分层长期记忆(5 层) | ⚠️ 价值待验证 | 结构合理(Current/Working/Episodic/Strategy/Reflection),但「按相关性检索」在无向量库前提下如何实现?MVP 大概率是标签 + 时间窗 + 市场环境特征匹配,检索质量是 Phase 2 shadow mode 需要实证的假设。 |
| 不保存 chain-of-thought | ✅ 合规友好 | 只存结构化 thesis/evidence/invalid_if/outcome,可审计且避免依赖模型隐藏状态。 |

## 3. 主要风险与薄弱点

### 3.1 边界穿透的物理极限(设计已声明,仍需强调)
10% DD 是工程目标。BTC 跳空、流动性瞬时消失时,FLATTENING 的实际成交价可能显著穿透边界。
设计的应对是 ExitReserve + 如实记录穿透,这是诚实的做法,但意味着:
- **ExitReserve 校准是安全性的实际决定因素**,参数错误 = 边界虚设;
- 验收必须包含「模拟极端行情下的穿透幅度测量」(fault injection + replay)。

### 3.2 Zig 生态缺口(Phase 0 必须回答)
- TLS 1.2/1.3 客户端(OKX + LLM API 均为 HTTPS/WSS): std.crypto 的 TLS 实现成熟度?
- WebSocket 客户端: 自研还是 vendor?断线重连、ping/pong、压缩支持。
- 建议 Phase 0 产出一份《依赖决议记录》,把每个网络组件的选型 + 验证结果写死。

### 3.3 LLM 结构化输出的可靠性
Proposal 是严格 JSON Schema,但模型偶发输出坏 JSON / 幻觉字段。设计的处理是校验失败即作废(HOLD),
安全但可能造成决策饥饿。指标 `invalid outputs` 已列入观测,建议在验收上加阈值(如 invalid rate < 5%)。

### 3.4 时间与时钟
签名依赖时钟同步(clock_skew 已监控),但回撤计算、evidence `as_of`、订单超时都依赖单调时钟与墙钟的正确区分。
Zig 层面需要明确 monotonic vs wall clock 的使用规范(core/clock 模块的职责)。

### 3.5 提示注入面
工具返回(news.*、wallet.* 标签)是不可信数据,设计已要求隔离在 `data` 字段。真正的执行保障在于:
Agent worker **没有** shell / 文件 / 任意 URL 能力——这必须是代码层面的能力缺失,而非 prompt 层约束。
验收矩阵中对应「Agent 无法绕过 Risk Kernel / 访问密钥」的红队测试。

### 3.6 成本可见性
100 USDT 本金 vs LLM 调用成本:一次决策若 $0.05–0.2,高频触发会让运营成本超过本金。
设计原则 Cheap to Operate 要求成本可见,建议 Dashboard System 视图把「模型累计成本 vs 本金」做成一级指标,
并在触发策略上设成本预算闸(9.5 未决项之一)。

## 4. 实现阶段的关注顺序(与路线图对应)

1. **Phase 0 是真正的 go/no-go**: Zig TLS/WS/SQLite/长稳,任何一项不过关都影响全盘。
2. **Decimal 与订单状态机先行**: 全部资金计算走定点;订单 8 状态机 + 幂等 client_order_id 是 replay 测试的基础。
3. **Risk Kernel 纯函数化**: 无网络/无 DB/无 LLM,输入快照输出决策——这是 property test 能压住它的前提。
4. **事件日志先于功能**: Event First 原则意味着 events 表 + 事件信封是所有模块的公共依赖,应最早稳定。
5. **Reconcile 是恢复正确性的核心**: 启动状态机 BOOTING→CONNECTING→RECONCILING→READY,
   未完成对账不得开仓,值得单独的 integration 测试组。

## 5. 与验收的衔接

设计 9.3 节给出 8 条上线验收标准,已在 [ACCEPTANCE_MATRIX.md](ACCEPTANCE_MATRIX.md) 中
展开为「需求 → 验收标准 → 验证方法 → 所属阶段」的完整矩阵,覆盖 FR-01..10、NFR-01..06、
安全边界(7.3/7.4)、故障降级矩阵(7.2)与运维演练(8.4/7.5)。

## 6. 结论

设计整体成熟度高:边界清晰、失效模式想在前面、诚实面对不可保证项。
两个决定成败的赌注是 **Zig 0.16 生态可行性**(技术)与 **ExitReserve 校准**(风险)。
建议严格按 Phase 0 → 5 推进,不跳过 shadow 与 demo 阶段,每阶段以验收矩阵对应条目作为退出闸门。
