# AlphaBound

**有边界的自主投资 Agent** —— 研究市场、形成观点、提出交易；真正能不能下、下多大，由确定性的风险内核说了算。

> **宽信息入口 · 慢投资决策 · 快风险反应 · 窄交易出口**
>
> AI 可以大胆想，但不能碰交易密钥，也不能改 10% 最大回撤边界。

| | |
|---|---|
| **现在能做什么** | **Shadow**（默认）：行情 + LLM 提案 + 风险准入 + Dashboard，**不下单**。**Demo**：OKX 模拟盘下单。**Live**：小额实盘子账号 + `OKX_REAL_MONEY_OK=1` 真单（显式 opt-in）。Dashboard 可选 Token/Session/Passkey；只读 **Analytics MCP** |
| **实验范围** | OKX `BTC-USDT` 现货 · 设计目标约 100 USDT 实验资金 |
| **硬边界** | 相对历史高水位（HWM）约 **10%** 最大回撤（工程目标，非绝对保证） |
| **技术栈** | Zig 0.16.0 · SQLite WAL · systemd · 单文件嵌入式 Dashboard |
| **文档** | [在线手册](https://talkincode.github.io/alphabound/) |

---

## 一分钟理解

多数「AI 交易机器人」让模型直接下单。AlphaBound 反过来：

1. **Agent** 看行情、调工具、写理由，只产出**结构化提案**（要买/卖/持有多少）。
2. **Risk Kernel** 用确定性规则做准入：批准、缩减或拒绝 —— **不调用 LLM**。
3. 行情变脏、状态对不上、订单状态不明 → **Fail Closed**（偏安全，不继续加仓）。
4. 每一笔意图都应能追到：快照版本、决策 ID、风险结论、配置哈希。

```
观察 → 工具 → 假设 → 提案 → 风险准入 → 执行
  ↑                                    ↓
记忆与反思 ← 结算与归因 ← 订单/成交 ←──┘
```

当前公开进度：**Shadow 闭环已通**；**小额 live 下单路径已解锁**（须显式 `OKX_REAL_MONEY_OK=1`）；Dashboard 鉴权与只读 MCP 已落地。见 [路线图](docs/ROADMAP.md) · [下一步](docs/NEXT.md) · [运行模式](https://talkincode.github.io/alphabound/guide/modes.html)。

> **风险说明**：「最大回撤 10%」是系统设计目标，不是承诺。跳空、流动性枯竭、交易所或网络故障都可能导致边界被穿透；系统会尽量留退出缓冲，并**如实记录**任何突破。

---

## 快速开始

需要 **Zig 0.16.0**（版本钉死，勿用其他 minor）。

```bash
git clone https://github.com/talkincode/alphabound.git
cd alphabound

zig version                    # 应为 0.16.0
zig build
zig build test --summary all

# 配置自检（TOML / DB 路径 / Web 绑定）
./zig-out/bin/alphabound --config config/alphabound.toml --self-check

# Shadow：公共行情 + 模拟账户，默认不下单
./zig-out/bin/alphabound --config config/alphabound.toml
# 冒烟：跑 N 个轮询后退出
# ./zig-out/bin/alphabound --config config/alphabound.toml --ticks 5
```

本机开发更常用 `config/local.toml`（DB=`var/trading.db`，Web=`127.0.0.1:18180`）：

```bash
mkdir -p var
./zig-out/bin/alphabound --config config/local.toml --ticks 5
open http://127.0.0.1:18180/
curl -sS http://127.0.0.1:18180/health/live
curl -sS http://127.0.0.1:18180/api/v1/state | head
```

| 你想… | 怎么做 |
|---|---|
| 只看行情与状态 | 示例配置直接启动（shadow） |
| 接真实 LLM 提案 | 配置 OpenAI 兼容端点与密钥（见手册；**勿**把密钥写进仓库） |
| 本机控制进程 | `--control pause\|resume\|reconcile\|cancel-all\|flatten\|target-weight=W\|shutdown\|status` |
| 保护 Dashboard API | 设 `ALPHABOUND_API_TOKEN`（见 [鉴权与 MCP](docs/DASHBOARD_AUTH_MCP.md)） |
| 给 IDE Agent 只读盘面 | `tools/alphabound-mcp`（stdio / 本机 HTTP） |
| 换数据目录 / 端口 | 复制 `config/local.toml` 或 `config/alphabound.toml` 改 `[storage]` / `[web]` |

更完整的配置、CLI、部署步骤：[使用手册](https://talkincode.github.io/alphabound/)。

### 用 Docker 跑 Shadow 实验室

生产设计仍偏向 **VM + systemd 裸二进制**。镜像适合本地试用与版本分发：

```bash
docker compose up --build
# 或（有发布 tag 后）
# docker pull ghcr.io/talkincode/alphabound:latest
# docker run --rm -p 127.0.0.1:8080:8080 -v alphabound-data:/var/lib/alphabound \
#   ghcr.io/talkincode/alphabound:latest
```

- 镜像：`ghcr.io/talkincode/alphabound`
- **仅** git tag `v*`（或手动 workflow）构建推送；推 `main` 不会发镜像
- 宿主机端口请只映射 `127.0.0.1`，不要把 Dashboard 裸奔到公网

详见 [Docker 与 GHCR](https://talkincode.github.io/alphabound/guide/docker.html)。

---

## 它如何工作（精简）

两条路径并行，状态只有一个写者：

| 路径 | 特点 | 做什么 |
|---|---|---|
| **关键路径** | 确定性、可失败关闭 | 行情/账户 → 状态机 → 风险 → 执行（demo/live） |
| **Agent 路径** | 可慢、可失败 | 组 Context → 工具 → LLM → 提案 / 反思 |
| **State Engine** | 单写者 | 所有变更排队处理；Agent / Dashboard **只读快照** |

四条产品原则对应到代码（方便读源码时定位）：

| 原则 | 人话 | 主要代码 |
|---|---|---|
| 宽信息入口 | 工具只多看世界；返回内容不可信 | `src/tools/` |
| 慢投资决策 | 可以 HOLD，可以反思，不抢跑 | `src/agent/` · `src/memory/` |
| 快风险反应 | 风控不等模型 | `src/risk/` · `src/core/` |
| 窄交易出口 | 只能提案 → 准入 → 幂等订单 | `src/agent/proposal.zig` → `src/risk/` → `src/execution/` |

设计长文：[设计分析](docs/DESIGN_ANALYSIS.md) · [系统设计 v0.1](docs/design/AlphaBound_System_Design_v0.1.docx)

---

## 安全与不可破的约定

本仓库是 **public**。协作时请先读 [AGENTS.md](AGENTS.md) 与 [SECURITY.md](SECURITY.md)。

**永远不要提交**：API key / secret / passphrase、真实余额与订单号、内网或出口 IP、生产主机名、本机绝对路径里的隐私信息。密钥只放本机忽略文件（如 `secrets.env`）或部署机受控环境。

改代码时默认遵守：

1. Agent **拿不到**交易所密钥，也**调不到**直接下单；只能交提案。
2. 提案必须绑定当前 `snapshot_version`；状态一变，旧提案作废。
3. 下单超时先标 `UNKNOWN`，**查清再处置**，禁止盲着重发。
4. 数据过期 / 不一致 / 未知订单 → 进入安全态，**不主动加仓**。
5. `max_drawdown` 与风险内核参数**不能**热改、**不能**被 Agent 改；要改走发布与人工确认。
6. 订单应能追溯到 `decision_id`、`snapshot_version`、风险结论与 `config_hash`。
7. 管理动作（pause / flatten / target-weight…）只走**本机 CLI 控制文件**，不走公网 HTTP；MCP **只读**。

Dashboard 默认 `127.0.0.1`。对外暴露前务必设置 `ALPHABOUND_API_TOKEN`，并在受信任反代后才开 `ALPHABOUND_TRUST_PROXY`。日志落库前走脱敏。漏洞请私下联系维护者，**不要**在公开 Issue 里贴密钥。

---

## 文档地图

按角色选入口，避免在仓库根目录迷路：

| 我想… | 去哪 |
|---|---|
| 安装、配置、日常操作 | [在线手册](https://talkincode.github.io/alphabound/)（源码在 `book/src/`） |
| 本地预览手册 | `./scripts/build-docs.sh serve` → http://127.0.0.1:3000 |
| 阶段进度与下一步 | [docs/ROADMAP.md](docs/ROADMAP.md) · [docs/NEXT.md](docs/NEXT.md) |
| Gate 清单 | [Gate 2](docs/GATE2_CHECKLIST.md) · [Gate 3](docs/GATE3_CHECKLIST.md) |
| 验收勾选（FR/NFR/故障） | [docs/ACCEPTANCE_MATRIX.md](docs/ACCEPTANCE_MATRIX.md) |
| Dashboard 鉴权 / MCP | [docs/DASHBOARD_AUTH_MCP.md](docs/DASHBOARD_AUTH_MCP.md) · [tools/alphabound-mcp](tools/alphabound-mcp/README.md) |
| 设计取舍与风险点 | [docs/DESIGN_ANALYSIS.md](docs/DESIGN_ANALYSIS.md) |
| 通用部署 | [deploy/README.md](deploy/README.md)（真实主机写本机 `DEPLOY.local.md`，勿提交） |
| 给 Agent / 协作者的硬约束 | [AGENTS.md](AGENTS.md) |
| 安全基线 | [SECURITY.md](SECURITY.md) |

规划类 Markdown 会编入手册「工程规划」篇；改 `docs/*.md` 即可同步进书。

---

## 仓库结构

```
alphabound/
├── src/                 # 守护进程与领域代码
│   ├── core/            # 状态机、事件、定点小数
│   ├── exchange/okx/    # 行情、鉴权、对账
│   ├── risk/            # 净值、回撤、准入、状态
│   ├── execution/       # 订单规划与幂等（demo/live）
│   ├── agent/           # Context、LLM、提案、反思
│   ├── tools/           # 工具注册与 market/derivatives
│   ├── memory/          # 情节与策略记忆
│   ├── storage/         # SQLite
│   ├── admin/           # 本机控制文件 CLI
│   ├── security/        # 隔离与限额不变量
│   ├── fault/           # 故障矩阵单测
│   ├── web/             # HTTP API、鉴权、健康检查
│   └── observability/   # 事件、指标、脱敏
├── dashboard/           # 零依赖 HTML + favicon（编译期嵌入）
├── tools/alphabound-mcp # 只读 Analytics MCP（stdio / HTTP）
├── config/              # 示例 TOML（local / 生产 / docker）
├── prompts/             # 系统 / 反思 Prompt（版本可审计）
├── migrations/          # SQLite 迁移
├── deploy/              # systemd、nginx 示例、发布脚本
├── scripts/             # 本地运行、远端部署、soak、演练
├── book/                # 使用手册（mdBook）
├── docs/                # 路线图、验收矩阵、设计、Gate 清单
└── Dockerfile           # GHCR / 本地 lab 镜像
```

---

## 当前阶段（诚实版）

```
Phase 0 可行性  →  1 只读观察  →  2 Shadow（不下单）  →  3 交易路径  →  4 MVP 运维判定  →  5 数据工具
                                               ▲ 小额 live 已可跑（显式 opt-in）
```

- **已有**：Shadow 闭环、风险准入、小额 `mode=live` 下单、flatten/cancel-all/target-weight、Dashboard（含鉴权）、只读 MCP、备份、原子发布/回滚、故障矩阵单测 FD1–10、L1 `market.derivatives` 持仓包  
- **还在做**：≥7 日滚动 soak、部分故障场景实网注入、Phase 5 L1 引用率观察  
- **不要指望**：默认 shadow 配置会下单；live 必须 `OKX_REAL_MONEY_OK=1` + 子账号；MCP/HTTP **不能**下单或改风控

细节与勾选：[ROADMAP](docs/ROADMAP.md) · [NEXT](docs/NEXT.md) · [GATE2](docs/GATE2_CHECKLIST.md) · [GATE3](docs/GATE3_CHECKLIST.md)

---

## 许可

源码与文档的使用条款以仓库声明为准；实验性软件，**使用风险自负**，不构成投资建议。
