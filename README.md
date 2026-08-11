# AlphaBound

**有边界的自主投资 Agent** — 在明确风险边界内,通过持续网络研究、基本面分析、事件调查、市场情绪理解和长期记忆,自主管理 BTC 风险暴露。

> **宽信息入口,慢投资决策,快风险反应,窄交易出口。**
> AI 可以提出任何交易观点,但不能直接调用交易凭证,也不能修改 10% 最大回撤边界。

| | |
|---|---|
| 状态 | MVP 设计基线 (v0.1, 2026-08-09) |
| 范围 | OKX BTC-USDT 现货 / 100 USDT 实验资金 |
| 硬边界 | 基于历史高水位 (HWM) 的 10% 最大回撤 |
| 技术栈 | Zig 0.16.0 · SQLite WAL · Azure Linux VM · systemd · 零依赖单文件 Dashboard |

**四支柱与代码的映射**

| 支柱 | 含义 | 模块 |
|---|---|---|
| 宽信息入口 | 工具只扩展观察,内容一律视为不可信数据 | `tools/registry.zig`(ToolResult、时效降级、审计摘要) |
| 慢投资决策 | 每轮组装稳定能力边界,可 HOLD,可反思 | `agent/context.zig` · `agent/proposal.zig` · `agent/reflection.zig` · `memory/store.zig` |
| 快风险反应 | 确定性关键路径,不等 LLM | `risk/equity.zig` · `risk/state_machine.zig` · `risk/admission.zig` · `core/state.zig` |
| 窄交易出口 | 唯一出口是结构化提案 + 风险准入 + 幂等订单 | `agent/proposal.zig` → `risk/admission.zig` → `execution/` |

## 核心设计命题

让 Agent 在**策略层面保持自主**;让**风险、状态一致性、订单幂等和权限边界保持确定**。

```
观察 → 工具调查 → 假设 → 交易提案 → 风险准入 → 执行
  ↑                                              ↓
长期记忆 ← 结果归因 ← 交易结算 ← 订单与成交事件 ←──┘
```

> ⚠️ **风险说明**:"最大回撤 10%" 是系统工程目标,不是绝对保证。极端跳空、流动性消失、
> 交易所故障、网络中断或成交延迟均可能造成边界穿透。系统尽力提前保留退出缓冲并如实记录任何突破。

## 架构总览

双通道运行模型 + 单写者状态:

- **关键路径**(确定性): Exchange Gateway → State Engine → Risk Kernel → Execution Engine。
  不调用 LLM,不等待外部数据源,行情事件进入进程后风险计算 p99 < 10ms。
- **Agent 路径**(可等待/可失败): Context 构建 → 工具调用 → LLM 推理 → Decision Proposal。
  超时或失败最多导致本轮不产生新交易,不阻塞风险计算。
- **State Engine 是唯一状态写入者**,所有输入转为消息顺序处理;Agent 和 Dashboard 只读不可变快照。
- **Agent 只输出结构化提案**(绑定 snapshot_version),Risk Kernel 在压力情景下决定批准 / 缩减 / 拒绝。
- **风险状态机**: `NORMAL → EXIT_ONLY → FLATTENING → HALTED`,Fail Closed。

详见 [docs/DESIGN_ANALYSIS.md](docs/DESIGN_ANALYSIS.md)(设计分析)与
[docs/design/AlphaBound_System_Design_v0.1.docx](docs/design/AlphaBound_System_Design_v0.1.docx)(完整设计文档)。

## 文档导航

**使用手册（mdBook）** 是面向操作与开发的主文档：

- 在线阅读：https://talkincode.github.io/alphabound/
- 本地预览：

```bash
./scripts/build-docs.sh          # 构建到 book/book/
./scripts/build-docs.sh serve    # http://127.0.0.1:3000
```

| 文档 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | **Agent/协作者硬约束**：隐私与敏感数据不得泄露（public 仓库） |
| [SECURITY.md](SECURITY.md) | 安全基线：密钥、Dashboard 绑定、脱敏与漏洞报告 |
| [book/src/](book/src/) | **手册源码**：快速开始、配置/CLI、运维、概念、开发 |
| [docs/DESIGN_ANALYSIS.md](docs/DESIGN_ANALYSIS.md) | 系统设计分析:决策评估、风险点、实现关注项 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 路线图:Phase 0–5 里程碑、交付物与退出条件 |
| [docs/ACCEPTANCE_MATRIX.md](docs/ACCEPTANCE_MATRIX.md) | 验收矩阵:FR/NFR/上线标准 → 验证方法 → 所属阶段 |
| [docs/design/](docs/design/) | 原始系统设计文档 (v0.1) |

规划类 Markdown 经 mdBook `{{#include}}` 编入手册「工程规划」篇，修改 `docs/*.md` 即可同步。

## 代码结构

```
alphabound/
├── build.zig / build.zig.zon   # Zig 0.16.0 固定工具链
├── book.toml / book/src/       # mdBook 使用手册
├── scripts/build-docs.sh       # mdbook build | serve
├── Dockerfile / docker-compose.yml  # GHCR 发布与本地 shadow lab
├── src/
│   ├── main.zig
│   ├── core/          # messages, state engine, decimal, clock
│   ├── exchange/okx/  # REST, WS, auth, reconciliation
│   ├── risk/          # equity, drawdown, stress, admission
│   ├── execution/     # planner, orders, fills, idempotency
│   ├── agent/         # context, model adapter, proposal schema
│   ├── tools/         # registry and provider adapters
│   ├── memory/        # retrieval, episodes, reflection
│   ├── storage/       # SQLite, migrations, repositories
│   ├── web/           # HTTP, WebSocket, health, static assets
│   └── observability/ # events, metrics, redaction
├── dashboard/         # 单文件零依赖 HTML(嵌入二进制,无运行时 Node)
├── migrations/        # SQLite schema 迁移
├── config/            # alphabound.toml 示例
├── prompts/           # 系统 Prompt(版本化,hash 审计)
├── tests/             # unit / property / replay / integration
└── deploy/            # systemd unit, release.sh
```

## 构建与运行

```bash
zig version   # 必须是 0.16.0(固定版本,ReleaseSafe)
zig build     # 产出 zig-out/bin/alphabound(静态链接 vendor SQLite)
zig build test --summary all   # 单元/回放测试

# 配置自检(校验 TOML、DB 可写、web 绑定白名单)
./zig-out/bin/alphabound --config config/alphabound.toml --self-check

# shadow 模式运行(实网 OKX 公共行情 + 模拟账户,不下单)
./zig-out/bin/alphabound --config config/alphabound.toml
#   --ticks N     有界运行 N 个轮询后优雅退出(冒烟测试用)
#   --version     打印版本

# Web 端点(默认 127.0.0.1; 容器内可用 0.0.0.0,宿主机仍只映射 loopback)
curl http://127.0.0.1:8080/health/live
curl http://127.0.0.1:8080/health/ready
curl http://127.0.0.1:8080/api/v1/state
open http://127.0.0.1:8080/
```

### Docker / GHCR

镜像：`ghcr.io/talkincode/alphabound`（push `main` / tag `v*` 由 Actions 发布）

```bash
docker pull ghcr.io/talkincode/alphabound:latest
docker run --rm -p 127.0.0.1:8080:8080 \
  -v alphabound-data:/var/lib/alphabound \
  ghcr.io/talkincode/alphabound:latest

# 或本地 compose
docker compose up --build
```

说明见手册 [Docker 与 GHCR](https://talkincode.github.io/alphabound/guide/docker.html)。

## 关键不变量(所有代码变更不得违反)

1. Agent 无法访问 OKX 密钥、直接下单函数或风险配置 —— 只能提交 Proposal。
2. 任何提案必须绑定 `snapshot_version`,状态变化后旧提案自动失效。
3. 订单请求超时视为 `UNKNOWN`,先查询后处置,禁止盲目重发。
4. 数据过期 / 状态不一致 / 未知订单 → Fail Closed,进入安全状态,不增加风险。
5. `max_drawdown` 与 Risk Kernel 参数不可热加载,必须走版本发布 + 人工确认。
6. 每笔订单可追溯到 `decision_id`、`snapshot_version`、risk decision 和 `config_hash`。
