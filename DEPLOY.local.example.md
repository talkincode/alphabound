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
| sshx 主机名 | `~/.sshx` 中的 name（当前生产倾向 edge 机，非内网 appserver） |
| 公网/出口 IP | OKX API 白名单；edge 机公网地址 |
| 公网域名 | 如 `alphabound.example.com`（WebAuthn rpId/origin） |
| Dashboard URL | `https://YOUR_DOMAIN/` |
| 远程路径 | 默认同 `deploy/README.md` |
| secrets 位置 | 本机 `secrets.env` 路径（不要贴密钥值） |
| bind | 公网 edge：**`127.0.0.1:8080`** + nginx；仅内网直连才用 `0.0.0.0:8080` |
| TRUST_PROXY | 反代后设 `ALPHABOUND_TRUST_PROXY=1`、`TRUSTED_PROXY_HOPS=1` |
| 退役主机 | 若从旧机迁出：旧 host 须 stop/disable，避免双开同密钥 |
| CF DNS | Zone.DNS Edit token 或 Dashboard 手动 A 记录；SSL mode Full |

完整结构示例见维护者私有的 `DEPLOY.local.md`；公开步骤见 `deploy/README.md`、
`deploy/nginx-alphabound.conf.example`、`scripts/cf-upsert-dns-a.sh`。
