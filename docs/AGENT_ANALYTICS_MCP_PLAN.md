# Agent 分析面 / MCP 计划

> 状态：审计 ACCEPT；**L1 已实现**（`tools/alphabound-mcp` + Dashboard token/passkey auth）  
> 动机：其他编码 Agent 需要稳定查询决策/订单/状态，用于复盘与优化，而不是 ssh 抠库。

---

### 审计结论

- **ACCEPT**「为外部 Agent 提供只读分析查询面」
- **条件 ACCEPT**「用 MCP 作为传输」——MCP 是适配层，**不是**第二套业务真相源
- **REJECT**「MCP 可下单 / 改 risk / 读 secrets」——与有界自主硬边界冲突

**核心价值：** 把「人眼 Dashboard + 运维脚本」变成「Agent 可组合的结构化工具」，加速策略复盘与 Phase5 价值评估。  
**核心病灶（若做错）：** 为 MCP 而 MCP，复制一套绕过 API 的写库/控制通道 → 熵增 + 事故面。

### 逻辑解剖

| 问题 | 现实 |
|------|------|
| 痛点 | 外部 Agent 分析时只能 sshx + sqlite/python，脆弱、不可复用、易碰密钥路径 |
| 不做 | 系统不崩；但每次复盘成本高，工具价值评估难自动化 |
| 现有能否承载 | **大半数据已在** `GET /api/v1/{state,decisions,orders,events,equity,shadow,system,memories,agent-runs,candles}`；缺的是 **Agent 友好契约**（过滤、分页、聚合、鉴权、MCP 封装） |
| 生产绑定 | 示例配置倾向 `127.0.0.1`；公网 `0.0.0.0` 无鉴权时 **禁止** 直接暴露给任意 MCP 客户端 |

**成本轴**

- 验证面：MCP tool schema 单测 + 对 API 契约的 golden；禁止返回密钥字段的扫描（沿用 SEC3）
- 可逆性：MCP 进程独立；关掉即回退 curl/API
- 爆炸半径：**只读**；控制面仍走 `--control` / 本地 admin，不进 MCP
- 外部依赖：MCP SDK（建议 TypeScript 或 Python stdio server）；运行时需能访问 Dashboard URL 或只读 DB
- 熵增：禁止 MCP 内嵌第二套 SQL 业务逻辑与 daemon 分叉；查询应代理稳定 HTTP 或只读 SQL 视图

### 理想版本 (North Star)

```
[外部 Agent] --MCP tools--> [alphabound-analytics]
                                |  read-only
                                v
                     Dashboard HTTP API  (首选)
                     或  trading.db URI mode=ro（降级）
                                |
                                v
                     脱敏 JSON（无 secrets、无完整密钥、无本机路径泄露）
```

**工具集（概念）**

| Tool | 用途 |
|------|------|
| `get_system` | mode / ready / schedule / agent stats |
| `get_state` | risk_mode / equity / cash / btc / dd |
| `get_shadow` | BH / alpha_return |
| `list_decisions` | 过滤 action/time；含 thesis |
| `list_orders` / `list_fills` | 按 decision_id 关联 |
| `list_events` | type 前缀过滤 |
| `list_memories` | 假设/策略记忆 |
| `query_equity` | 时间窗净值序列 |
| `tool_value_summary` | 对齐 `tool-value-report` 指标 |
| `run_readonly_sql` | **可选、极危险**——默认关闭；若开则白名单视图 |

**硬规则**

1. 默认 **stdio MCP**（本机 Agent 连接）；远程仅经 SSH 隧道 + token  
2. **无** place_order / flatten / resume / target-weight  
3. 响应过 redaction；余额可给数量级/已有 API 字段，不给密钥  
4. 与 public 仓库：MCP 配置示例用占位符，真实 URL 只在 `DEPLOY.local.md`

### 降级路径

| 级 | 内容 | 砍掉 | 升级信号 |
|----|------|------|----------|
| **L0** | 完整 MCP + token + 聚合分析工具 + 可选只读 SQL 视图 + OpenAPI | — | — |
| **L1（推荐首切）** | `tools/alphabound-mcp`：stdio server，tools 薄封装现有 `/api/v1/*`；`ALPHABOUND_API_BASE` + 可选 `ALPHABOUND_API_TOKEN` | SQL 任意查询；写操作；远程裸暴露 | 外部 Agent 每周用 MCP 复盘 ≥N 次且 API 过滤不够 |
| **L2** | 不写 MCP：补齐 API 查询参数（since/limit/type）+ OpenAPI + `scripts/agent-query.sh` | MCP 协议互操作 | IDE/CLI 强制要 MCP 才接入 |
| **L3** | 维持 sshx + `tool-value-report` + curl（现状） | 一切新面 | 仅个人偶尔看 |

**本迭代建议：** 若要开工 → **L1**；若只想立刻给 Agent 用 → 先 **L2 半天契约** 再 L1 包一层 MCP（同一查询面）。

### 机器验收面

- [ ] MCP `tools/list` 快照稳定（golden JSON）
- [ ] 每个 tool：mock HTTP → 固定 fixture → 输出 schema 校验
- [ ] 集成：对 running daemon `get_state` 与 `curl /api/v1/state` 字段一致
- [ ] 负向：请求 `secrets` 路径 / POST control → 不存在或 405
- [ ] SEC3：响应扫描无 `OKX_` / `sk-` / 私钥头
- [ ] 人工：用 Cursor/Copilot MCP 拉最近 5 条 REBALANCE thesis 成功

### 对照基线

```bash
# 已有能力，零新架构
curl -sS "$API/api/v1/decisions" | jq .
curl -sS "$API/api/v1/orders" | jq .
HOST=appserver ./scripts/tool-value-report.sh
```

基线能回答「数据在哪」；MCP 回答的是「外部 Agent 如何 **标准地、反复地** 调用」。

### 与 Phase5 关系

- Phase5 L1 解决 **交易 Agent 输入**（市场观察）
- 本计划解决 **研发 Agent 输入**（系统自省）
- 二者互补；优先顺序：交易安全与 L1 引用闭环 > 研发 MCP，但 MCP **不碰** 下单路径，可并行

### 自我清洁

- 压下「在 Zig daemon 内嵌 MCP」：协议迭代快，独立进程更可逆  
- 压下「MCP 直接读写 trading.db 当主路径」：绕过 redaction 与 API 版本  
- 压下「先做很炫的分析 Agent」：没有稳定 query 面之前，分析 Agent 是空中楼阁  
