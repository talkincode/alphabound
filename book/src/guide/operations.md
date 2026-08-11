# 运维部署

目标形态：**单文件二进制 + systemd + SQLite 本地盘 + SSH tunnel 看盘**。生产 VM **不**装 Docker / 运行时 Node / Python 业务依赖。

## 目录约定

| 路径 | 用途 |
|---|---|
| `/opt/alphabound/releases/<ver>/` | 不可变发布目录（二进制 + 附带文件） |
| `/opt/alphabound/current` | symlink → 当前版本（原子切换） |
| `/opt/alphabound/previous` | symlink → 上一版本（一键回滚） |
| `/etc/alphabound/alphabound.toml` | 主配置 |
| `/etc/alphabound/secrets.env` | 密钥，`0600` |
| `/etc/alphabound/prompts/` | Prompt 树 |
| `/var/lib/alphabound/trading.db` | SQLite（WAL 同目录） |
| `/var/lib/alphabound/backups/` | 定时备份 |

## 系统用户

```bash
sudo useradd --system --home /var/lib/alphabound --shell /usr/sbin/nologin alphabound
sudo mkdir -p /var/lib/alphabound/backups /etc/alphabound/prompts
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
- `NoNewPrivileges` / `PrivateTmp` / 清空 Capability
- `Restart=always` + `RestartSec=5`（崩溃后重新对账，不假设旧内存状态）

## 发布与回滚（原子 symlink）

```bash
VER=0.1.0+git.$(git rev-parse --short HEAD)
REL=/opt/alphabound/releases/$VER
sudo mkdir -p "$REL"
sudo cp zig-out/bin/alphabound "$REL/"
sudo chmod 755 "$REL/alphabound"

# 记录 previous，切换 current
if [ -L /opt/alphabound/current ]; then
  sudo ln -sfn "$(readlink -f /opt/alphabound/current)" /opt/alphabound/previous
fi
sudo ln -sfn "$REL" /opt/alphabound/current

sudo systemctl restart alphabound

# ready 门禁：失败则回滚
if ! curl -fsS --retry 30 --retry-delay 1 http://127.0.0.1:8080/health/ready; then
  echo "ready failed — rolling back"
  sudo ln -sfn "$(readlink -f /opt/alphabound/previous)" /opt/alphabound/current
  sudo systemctl restart alphabound
  exit 1
fi
```

后续可用 `deploy/release.sh` 固化上述流程（脚本随仓库演进）。

## 备份

SQLite 在线备份优先用 **Backup API** 或安全的文件快照（注意 WAL）：

```bash
# 示例：sqlite3 .backup（进程可同时运行，注意 IO）
stamp=$(date -u +%Y%m%dT%H%M%SZ)
sqlite3 /var/lib/alphabound/trading.db \
  ".backup '/var/lib/alphabound/backups/trading-$stamp.db'"

# 保留策略示例：7 日
find /var/lib/alphabound/backups -name 'trading-*.db' -mtime +7 -delete
```

**恢复演练**（建议每周）：

1. 停服务或切只读副本
2. 恢复到临时路径，`PRAGMA integrity_check`
3. 用恢复库启动 shadow/`--self-check`，核对 HWM / 最近事件
4. 记录演练结果到变更日志

## 远程看盘

```bash
ssh -N -L 8080:127.0.0.1:8080 ops@azure-btc-01
```

防火墙：**不**对 `8080` 放行公网。管理动作不走 Dashboard。

## 资源与告警（建议）

| 信号 | 为何重要 |
|---|---|
| RSS / fd 数量 | 长稳泄漏 |
| 磁盘可用 & DB 目录 | 满盘 → 停新交易 / HALTED |
| WAL 文件大小 | checkpoint 是否健康 |
| `health/ready` 连续失败 | 对账或依赖故障 |
| 风险模式 ≠ NORMAL 持续时长 | 边界或数据问题 |
| `journal` 落库失败日志 | 审计断裂 |

## Azure / 网络

- 选型时测 OKX REST / WS 与 LLM 端点延迟（p50/p95）
- 出站白名单：OKX、LLM、必要工具域名；**无**通用网页爬取权限给 Agent 进程
- NTP 可靠；日志统一 UTC

## 安全检查清单

- [ ] `secrets.env` 0600，不进 git、不进备份的明文 tar 传到个人笔记本
- [ ] 服务用户无 shell、无 sudo
- [ ] web 仍为 127.0.0.1（容器场景：容器内可 `0.0.0.0`，**宿主机**只映射 127.0.0.1）
- [ ] `mode` 与资金环境一致（live 有变更单）
- [ ] 上一个 `previous` symlink 可回滚
- [ ] 备份恢复演练未过期

容器分发与 GHCR 发布见 [Docker 与 GHCR](docker.md)。
