# AlphaBound 手册

**有边界的自主投资 Agent** — 在明确风险边界内，通过持续网络研究、基本面分析、事件调查、市场情绪理解和长期记忆，自主管理 BTC 风险暴露。

> **宽信息入口，慢投资决策，快风险反应，窄交易出口。**

| | |
|---|---|
| 范围 | OKX BTC-USDT 现货 · 约 100 USDT 实验资金 |
| 硬边界 | 基于历史高水位 (HWM) 的 **10% 最大回撤** |
| 技术栈 | Zig 0.16.0 · SQLite WAL · systemd · 嵌入式 Dashboard |
| 仓库 | [talkincode/alphabound](https://github.com/talkincode/alphabound) |
| 当前 | Shadow 默认；**小额 `mode=live` 已解锁**（`OKX_REAL_MONEY_OK=1`）；Dashboard 鉴权 + 只读 MCP |

## 一句话理解

把「AI 自主交易」拆成两个正交问题：

- **策略自主性**交给 LLM Agent（观察、调查、假设、提案、反思）
- **资金安全**交给确定性代码（状态引擎、风险内核、幂等执行）

Agent 可以提出任何交易观点，但**不能**直接调用交易凭证，也**不能**修改最大回撤边界。通往交易所的唯一路径是：

```text
结构化 Proposal → Risk Kernel 准入 → Execution Engine 幂等下单
```

管理动作（pause / flatten / target-weight）只走**本机 CLI**；Dashboard 与 MCP 是**只读**观察面。

## 本手册怎么读

| 你是… | 从这里开始 |
|---|---|
| 想在本机先跑起来 | [快速开始](guide/quickstart.md) |
| 要改配置 / 接密钥 | [配置参考](guide/configuration.md) · [CLI 参考](guide/cli.md) |
| 要保护 Dashboard / 接 IDE | [鉴权与 MCP](guide/auth-mcp.md) |
| 要上 VM 常驻 | [运维部署](guide/operations.md) |
| 要理解安全边界 | [四支柱架构](concepts/pillars.md) · [风险模型](concepts/risk.md) |
| 要改代码 / 写测试 | [构建与测试](dev/build.md) · [关键不变量](dev/invariants.md) |
| 要对齐阶段闸门 | [路线图](planning/roadmap.md) · [下一步](planning/next.md) · [验收矩阵](planning/acceptance.md) |

## 风险说明

「最大回撤 10%」是**系统工程目标**，不是绝对保证。极端跳空、流动性消失、交易所故障、网络中断或成交延迟均可能造成边界穿透。系统尽力提前保留退出缓冲，并**如实记录**任何突破。

## 文档构建

本手册由 [mdBook](https://rust-lang.github.io/mdBook/) 维护，源文件在仓库 `book/src/`。

```bash
# 需要 mdbook ≥ 0.4（本机可用 Homebrew: brew install mdbook）
./scripts/build-docs.sh          # 构建到 book/book/
./scripts/build-docs.sh serve    # 本地预览 http://127.0.0.1:3000
```

CI 在每次 push / PR 会执行 `mdbook build`，保证链接与语法不过期。
