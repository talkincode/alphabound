# 运维部署

目标形态：**单文件二进制 + systemd + SQLite 本地盘**。生产 VM **不**装 Docker / 运行时 Node / Python 业务依赖。  
公开通用步骤见仓库 [`deploy/README.md`](https://github.com/talkincode/alphabound/blob/main/deploy/README.md)；**真实主机名 / IP / URL 只写本机 `DEPLOY.local.md`（gitignore）**。

## 目录约定

| 路径 | 用途 |
|---|---|
| `/opt/alphabound/releases/<sha>-<ts>/` | 不可变发布目录（二进制） |
| `/opt/alphabound/current` | symlink → 当前版本（原子切换） |
| `/etc/alphabound/alphabound.toml` | 主配置 |
| `/etc/alphabound/secrets.env` | 密钥，`0600` |
| `/etc/alphabound/prompts/` | Prompt 树 |
| `/var/lib/alphabound/trading.db` | SQLite（WAL 同目录） |
| `/var/lib/alphabound/deploys.log` | 部署记录（soak 可识别计划重启） |

## 系统用户

```bash
sudo useradd --system --home /var/lib/alphabound --shell /usr/sbin/nologin alphabound
sudo mkdir -p /var/lib/alphabound /etc/alphabound/prompts
sudo chown -R alphabound:alphabound /var/lib/alphabound
sudo chown -R root:alphabound /etc/alphabound
sudo chmod 750 /etc/alphabound
sudo chmod 640 /etc/alphabound/alphabound.toml
sudo chmod 600 /etc/alphabound/secrets.env
```

## systemd

仓库模板：[`deploy/alphabound.service`](https://github.com/talkincode/alphabound/blob/main/deploy/alphabound.service)

```bash
sudo cp deploy/alphabound.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now alphabound
sudo systemctl status alphabound
journalctl -u alphabound -f
```

单元要点：

- `EnvironmentFile=/etc/alphabound/secrets.env`
- `ProtectSystem=strict` + `ReadWritePaths=/var/lib/alphabound`
- `NoNewPrivileges` / `PrivateTmp`
- `Restart=always` + `RestartSec=5`（崩溃后重新对账，不假设旧内存状态）

## 远端助手脚本

需本机 `sshx` 与 `HOST=`（主机名以 `DEPLOY.local.md` 为准，**勿**写回 public 文档）：

```bash
HOST=<sshx-name> ./scripts/deploy-remote.sh
HOST=<sshx-name> ./scripts/check-remote.sh
HOST=<sshx-name> ./scripts/soak-report.sh 24
HOST=<sshx-name> ./scripts/restore-drill.sh
HOST=<sshx-name> ./scripts/rollback-remote.sh
HOST=<sshx-name> ./scripts/kill9-drill.sh
HOST=<sshx-name> ./scripts/restart-drill.sh 3
./scripts/llm-outage-drill.sh
```

`check-remote` / `soak-report` / `gate2-report` 在开启 API token 时会带鉴权头。

## 发布与回滚（原子 symlink）

推荐走 `deploy-remote.sh` / `install-remote.sh`：每次安装暂存

`/opt/alphabound/releases/<sha>-<ts>/`，原子翻转 `current`；`/health/ready` 失败则**自动回滚**上一版本；默认保留最近 5 个 release。

手动等价流程：

```bash
# 构建目标 OS/arch 后
sudo mkdir -p /opt/alphabound/releases/manual-$(date +%s)
sudo cp zig-out/bin/alphabound /opt/alphabound/releases/manual-.../
sudo ln -sfn /opt/alphabound/releases/manual-... /opt/alphabound/current
sudo systemctl restart alphabound
curl -fsS --retry 30 --retry-delay 1 http://127.0.0.1:8080/health/ready
```

## 备份

进程内约每小时 SQLite Backup API → `<db_path>.bak`。额外离线备份：

```bash
stamp=$(date -u +%Y%m%dT%H%M%SZ)
sqlite3 /var/lib/alphabound/trading.db \
  ".backup '/var/lib/alphabound/trading-$stamp.db'"
```

**恢复演练**（建议每周）：`HOST=... ./scripts/restore-drill.sh`

## Dashboard 访问

**默认**：SSH 本地转发，防火墙不对 Dashboard 端口放行公网。

```bash
ssh -N -L 8080:127.0.0.1:8080 ops@YOUR_HOST
```

**公网 edge（可选）**：daemon 仍绑 loopback，nginx 终止 TLS；见 `deploy/nginx-alphabound.conf.example`。

必需环境变量（secrets）：

- `ALPHABOUND_API_TOKEN` — 长随机串
- `ALPHABOUND_TRUST_PROXY=1` + `ALPHABOUND_TRUSTED_PROXY_HOPS=1`（**仅**受信任反代后）
- `ALPHABOUND_WEBAUTHN_RP_ID` / `ALPHABOUND_WEBAUTHN_ORIGIN` 与公网 hostname 一致

详见 [鉴权与 MCP](auth-mcp.md)。

## Admin on the box

```bash
sudo -u alphabound /opt/alphabound/current/alphabound \
  --config /etc/alphabound/alphabound.toml --control status
```

## 资源与告警（建议）

| 信号 | 为何重要 |
|---|---|
| RSS / fd 数量 | 长稳泄漏 |
| 磁盘可用 & DB 目录 | 满盘 → 停新交易 / HALTED |
| WAL 文件大小 | checkpoint 是否健康 |
| `health/ready` 连续失败 | 对账或依赖故障 |
| 风险模式 ≠ NORMAL 持续时长 | 边界或数据问题 |
| `journal` 落库失败日志 | 审计断裂 |
| soak-report 窗口 | 计划部署 vs 意外退出 |

## OKX / 网络

- API Key **Read+Trade，禁止 Withdraw**；出口公网 IP 加入白名单
- 出站：OKX、LLM、必要工具域名；**无**通用网页爬取权限给 Agent 进程
- NTP 可靠；日志统一 UTC
- `mode=live` 须 `OKX_REAL_MONEY_OK=1`，且**不得** `OKX_SIMULATED=1`

## 安全检查清单

- [ ] `secrets.env` 0600，不进 git
- [ ] 服务用户无 shell、无 sudo
- [ ] web 为 127.0.0.1，或仅经受信任 TLS 反代
- [ ] 对外暴露时已设 `ALPHABOUND_API_TOKEN`；`TRUST_PROXY` 仅反代后开启
- [ ] `mode` 与资金环境一致（live 有变更单 + 子账号）
- [ ] 上一 release 可回滚；备份恢复演练未过期

容器分发与 GHCR 发布见 [Docker 与 GHCR](docker.md)。
