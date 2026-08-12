# Phase 5 — 数据工具扩展：审计结论与开工计划

> 状态：L1 开工（2026-08-12）  
> 对齐：`docs/ROADMAP.md` Phase 5、`docs/NEXT.md`、生产 `tool_calls` 实证

---

### 审计结论 (Audit Verdict)

- **ACCEPT**（窄范围开工；拒绝一次上齐 news/macro/onchain）
- **核心价值：** Agent 已有执行闭环，但决策证据几乎全是「风险态 + K 线」；缺结构化持仓/情绪面，thesis 无法被证伪，策略只能停在 5%–15% 惯性仓。
- **核心病灶（若做错）：** 把「基本面」理解成堆新闻 API = 锤子找钉子；在 **evidence 引用率未度量** 前加外部源，只会加噪声与密钥面，不提高可验证 alpha。

### 逻辑解剖

| 问题 | 事实 |
|------|------|
| 痛点 | 慢决策 Agent 缺「市场状态向量」：资金费率、OI、多空比、主动买卖、基差 |
| 不做会怎样 | 系统不崩；但 thesis 同质化、无法做工具价值评估、Gate3 之后策略迭代无抓手 |
| 现有为何不够 | `market.derivatives` 已上（funding+OI），但生产引用极低：近 80 条 `AGENT_PROPOSAL_OK` 仅 ~4 条 thesis 提到 funding/OI；`tool_calls` 中 derivatives 25 vs ticker/candles 283 |
| 外部依赖 | 新闻/宏观/链上需新供应商与密钥 → **延后**；OKX 公共 rubik/mark/index **零新依赖** → **先做** |

**Agent 成本轴**

- 验证面：解析单测 + 现场 `tool_calls` 计数 + thesis 关键词命中率脚本  
- 可逆性：工具失败 → null 字段，不阻断 ticker/candles；可回退只保留 funding+OI  
- 爆炸半径：只扩观察上下文与 prompt；不改 risk kernel / 下单路径  
- 熵增：禁止并行造 `news.*` 空壳；一个信封扩字段优于工具爆炸  

### 理想版本 (North Star)

1. **分层观察信封**（可信度：venue 数值 > 聚合指标 > 文本新闻）  
2. **提案 `evidence[]`** 强制绑定 tool 名 + as_of（schema 校验）  
3. **价值闭环**：上线 4 周 → 使用率 / 引用率 / 非 HOLD 贡献 → 低价值降级  
4. 按缺口接入 onchain / macro / news（带成本预算与注入隔离）

### 降级实现路径

| 级 | 内容 | 砍掉什么 | 升级信号 |
|----|------|----------|----------|
| **L0** | 全源 + evidence schema + 成本闸 + Dashboard 观察面板 | — | — |
| **L1（本迭代）** | 扩 `market.derivatives`：funding/OI + **多空比 + taker 主买主卖 + mark/index 基差**；prompt 要求引用；`tool-value-report` | 外部新闻/宏观/链上；强制 evidence schema | 引用率仍 <10% 且决策无分化 → 先改 prompt/schema 再加源 |
| **L2** | 仅加固现有 funding/OI + 引用度量（不加字段） | 多空/taker/基差 | L1 字段在 thesis 中被稳定引用 |
| **L3** | 等到 2026-09 再评估 | 一切新字段 | 仅运维，不推荐（阻塞策略迭代） |

**明确不做（本迭代）**

- `mode=live`、主账户  
- `news.*` / `macro.*` / `onchain.*` / `wallet.*` 真实适配（无供应商决策）  
- 用 LLM 网页搜索充当基本面  

### 机器验收面

- [ ] `zig build test`：OKX 新解析器 + `formatDerivativesData` 扩字段  
- [ ] 生产 `tool_calls`：`market.derivatives` 与 ticker 同频（每个 agent run）  
- [ ] `scripts/tool-value-report.sh`：输出 citation_rate（funding|oi|long_short|taker|basis）  
- [ ] 人工：Dashboard 决策 thesis 出现具体数字（费率/多空比/基差），非空话  

### 对照基线

- 只改 prompt「必须提 funding」而不加数据 → 模型会编数字 → **拒绝作为主路径**  
- 正确基线：数据进 `tool_observations` + 度量引用，而不是训模型背诵  

### 开工切片（L1 任务拆解）

1. `src/exchange/okx/rest.zig`：parse long-short ratio、taker volume、mark、index  
2. `src/tools/market.zig`：derivatives JSON 扩字段（缺省 null）  
3. `src/main.zig` `gatherObservations`：best-effort 追加请求  
4. `prompts/system.md`：REBALANCE 须引用至少一项 derivatives 数值字段  
5. `scripts/tool-value-report*.sh`：本地/远程统计  
6. 更新 `docs/NEXT.md` / `ROADMAP.md` 进展  

### 生产基线（开工前快照，2026-08-12）

```
tool_calls: market.ticker=283, market.candles=283, market.derivatives=25
AGENT_PROPOSAL_OK 近 80 条 thesis 含 funding/oi/deriv ≈ 4（~5%）
```

目标（L1 部署后滚动 7 日）：derivatives 调用 ≈ ticker；citation_rate ≥ 30%（REBALANCE 子集）。

---

### Agent 自我清洁声明

- 压下了「直接接 CryptoPanic/宏观 API」的冲动：无引用度量前加源不可验证。  
- 压下了「等满 4 周再动」的惰性：4 周评估需要 **先有可测字段与脚本**，不是干等。  
- 未用工期/人日论证；瓶颈是外部供应商与验证回路，不是写代码量。  
