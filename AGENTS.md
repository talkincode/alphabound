# AGENTS.md — 给编码 Agent / 协作者的硬约束

本仓库是 **public**。任何 Agent、脚本或协作者在改代码、写文档、提交、部署说明、Issue/PR、日志摘录时，都必须遵守下列规则。

## 最高优先级：隐私与敏感数据不得泄露

**禁止**把下列内容写入仓库、git 历史、公开文档、示例配置、commit message、PR 描述、Issue、截图说明或 CI 日志：

| 类别 | 示例（非穷尽） |
|------|----------------|
| 密钥与凭证 | OKX API key / secret / passphrase、LLM API key、Bearer token、私钥、`secrets.env` 全文 |
| 账户与资金 | 真实余额、持仓数量、子账户 ID、订单号与客户真实标识 |
| 基础设施私有信息 | 内网 IP、出口公网 IP、hostname（如生产机短名）、SSH 用户、未脱敏的部署路径中的个人目录 |
| 运维私密 | 仅内网可达的 Dashboard URL、真实 `EnvironmentFile` 路径中的机密旁注、keyring 口令、sudo 密码 |
| 个人身份 | 本机用户名路径（如 `/Users/<name>/`）、邮箱、未公开的组织内部主机表 |

### 必须做到

1. **Secrets 只走环境 / 本地忽略文件**：`secrets.env`、`*.env`（除 `*.env.example`）、`var/`、`*.db*` 已在 `.gitignore`；**永不** `git add` 它们。
2. **文档与脚本用占位符**：主机用 `REMOTE_HOST` / `your-host`，IP 用 `x.x.x.x` 或省略，密钥用 `YOUR_*` / `<redacted>`。
3. **提交前自检**：对 diff 搜索 `sk-`、`OKX_`、`api_key`、内网段、具体公网出口 IP、真实 hostname；命中则改掉再提交。
4. **日志与事件已脱敏**：持久化前走 `src/observability/redaction.zig`；新增日志字段默认假设会进 public 审计，勿原样写密钥。
5. **Dashboard / API 响应**：面向展示的接口不得回传完整密钥、DB 绝对路径中的敏感段、或未脱敏的账户明细到公开可复制的文档示例。
6. **不要“为了方便”把内网运维细节写进 README/ROADMAP/checklist**；运维细节只写在本机 **`DEPLOY.local.md`**（gitignore），仓库只保留通用步骤（见 `deploy/README.md`、`scripts/*-remote.sh`、`DEPLOY.local.example.md`）。
7. **历史不可当垃圾桶**：public 仓库 force-push 也不能保证旧 blob 立即从所有缓存消失。宁可一开始就不提交敏感内容。
8. **发现问题**：立刻从工作树移除、轮换已暴露凭证，并按 `SECURITY.md` 私下通知维护者——**不要**在公开 Issue 里贴密钥。

### 允许写进仓库的

- 架构、风险边界、验收矩阵、通用部署步骤
- `secrets.env.example` / `deploy/production.example.toml` / `DEPLOY.local.example.md` 中的**空占位**字段名
- 合成/虚构的测试数据与示例 JSON（明显非生产）

## 本地部署实情（Agent 必读，不提交）

为避免部署摸瞎，本机维护 **`DEPLOY.local.md`**（已 gitignore，**永远不要 `git add`**）：

| 文件 | 是否进 git | 用途 |
|------|------------|------|
| `DEPLOY.local.md` | **否** | 真实 sshx 主机名、内网 IP、出口 IP、Dashboard URL、远程路径、部署/巡检命令 |
| `DEPLOY.local.example.md` | 是 | 字段模板，无真实地址 |
| `secrets.env` | **否** | 密钥；本文件只写路径不写值 |
| `deploy/README.md` | 是 | 公开通用布局与步骤 |

**Agent 部署流程：**

1. 若存在 `DEPLOY.local.md`，**先读它**再执行 deploy/check；以其中 HOST/IP 为准。
2. 若不存在：复制 `DEPLOY.local.example.md` → `DEPLOY.local.md`，请维护者填实情；**不要**把猜的生产地址写进可提交文件。
3. 典型命令形态（主机名以 local 文件为准）：`HOST=<sshx-name> ./scripts/deploy-remote.sh`、`HOST=<sshx-name> ./scripts/check-remote.sh`。
4. 改 daemon / 嵌入式 Dashboard / API 后，按 local 文件 redeploy 并验证 health/system/decisions。
5. 更新 `DEPLOY.local.md` 中过时事实可以；**禁止**把同一内容同步进 README/docs/commit。

## 产品与工程约束（摘要）

- **Shadow 默认**：不得在未明确授权且风控放行前接通真实下单；live 路径保持拒绝或严格门禁。
- **宽信息入口 / 慢决策 / 快风险 / 窄出口**：工具输出不可信；风险内核确定性；Agent 只出结构化提案。
- **改 Dashboard 需重编嵌入二进制**后再部署。
- 细节见 `README.md`、`docs/`、`SECURITY.md`、本机 `DEPLOY.local.md`。

## 提交与 PR

- 信息性 commit message，**不含**主机名、IP、密钥片段。
- PR 描述可写验证步骤，用占位符代替真实 endpoint。
- 若任务涉及“部署到某台机器”：读 `DEPLOY.local.md` 操作；**不要**把该主机的寻址信息写回 public 树。
- `git status` 时若看到 `DEPLOY.local.md` 被 track，立即 `git rm --cached` 并检查 `.gitignore`。
