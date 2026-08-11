# AlphaBound — DEPLOY.local.md 模板（可提交）

复制为 **`DEPLOY.local.md`**（已被 gitignore），填入本机/内网实情，供开发 Agent 部署用。

```bash
cp DEPLOY.local.example.md DEPLOY.local.md
# 编辑 DEPLOY.local.md — 勿 git add
```

## 应填写的字段

| 项 | 说明 |
|----|------|
| 本机仓库路径 | 绝对路径 |
| sshx 主机名 | `~/.sshx` 中的 name |
| 内网 IP / Dashboard URL | 仅写在 local 文件 |
| 出口公网 IP | OKX API 白名单 |
| 远程路径 | 默认同 `deploy/README.md` |
| secrets 位置 | 本机 `secrets.env` 路径（不要贴密钥值） |
| bind | 如内网 `0.0.0.0:8080` 或 loopback |

完整结构示例见维护者私有的 `DEPLOY.local.md`；公开步骤见 `deploy/README.md`。
