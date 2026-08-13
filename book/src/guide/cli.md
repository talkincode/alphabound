# CLI 参考

二进制：`zig-out/bin/alphabound`（安装后常见路径 `/opt/alphabound/current/alphabound`）。

## 用法

```text
alphabound [--config PATH] [--self-check] [--version] [--ticks N]
           [--agent-once] [--agent-stats]
           [--control pause|resume|reconcile|cancel-all|flatten|target-weight=W|shutdown|status]
           [--verify-db PATH]
```

无参或非法参数时打印 usage 并以非零退出。

## 参数

| 参数 | 必填 | 说明 |
|---|---|---|
| `--config PATH` | 否 | TOML 配置路径。默认 `config/alphabound.toml`（相对 cwd） |
| `--self-check` | 否 | 只做启动前检查后退出 0/非 0；不进主循环、不连行情轮询 |
| `--version` | 否 | 打印 `alphabound <version>` 后退出 0 |
| `--ticks N` | 否 | 有界运行：完成 N 次成功行情 tick 后走优雅退出。冒烟 / CI / 演示用 |
| `--agent-once` | 否 | READY 后强制一轮 Agent（shadow 只审计，需 `LLM_*`） |
| `--agent-stats` | 否 | 打印 agent_runs 有效率与 tool_calls 计数后退出 |
| `--control CMD` | 否 | 本机管理（写控制文件后退出，不启 daemon）。见 [Admin control](admin-control.md) |
| `--verify-db PATH` | 否 | 离线审计链抽查（订单 → 决策锚点 / fills），不启 daemon |

## 退出码

| 码 | 含义 |
|---|---|
| `0` | 正常（含 self-check 通过、ticks 跑完、信号优雅退出） |
| 非 0 | 配置失败、DB 打不开、web listen 失败、连接阶段不可达等 |

## 生命周期日志锚点

便于 `journalctl -u alphabound -f` 过滤：

| 前缀 | 阶段 |
|---|---|
| `[boot]` | 加载配置、开库、恢复 HWM、起 web；live 醒目 banner |
| `[connect]` | 探测交易所 REST（时间同步） |
| `[ready]` | 对账完成，进入主循环 |
| `[reconcile]` | 私有余额只读探针 / live balance applied |
| `[agent]` | 慢环决策 / 工具 / 降级 HOLD |
| `[admin]` | 本机控制命令生效 |
| `[tick N]` | 单次行情处理摘要（bid / equity / dd / mode） |
| `[risk]` | 风险模式切换 |
| `[loop]` | 行情拉取失败等可恢复错误 |
| `[shutdown]` | 优雅退出开始 |
| `[journal]` | 事件/净值落库失败（应告警） |
| `[web]` | HTTP 服务异常停止 |
| `[agent-stats]` | `--agent-stats` 输出 |

## 常用配方

```bash
# 版本
./zig-out/bin/alphabound --version

# 配置与 DB 冒烟
./zig-out/bin/alphabound --config /etc/alphabound/alphabound.toml --self-check

# 本地有界验证
./zig-out/bin/alphabound --config config/local.toml --ticks 10

# Agent 一轮 + 统计（需 secrets.env）
set -a && source ./secrets.env && set +a
./zig-out/bin/alphabound --config config/local.toml --agent-once --ticks 5
./zig-out/bin/alphabound --config config/local.toml --agent-stats

# 审计链
./zig-out/bin/alphabound --verify-db var/trading.db

# 常驻（前台）；生产用 systemd，见运维章
./zig-out/bin/alphabound --config config/local.toml
```

## 信号处理

| 信号 | 行为 |
|---|---|
| `SIGTERM` / `SIGINT` | 置位停止标志 → 结束当前 tick → 落 `SHUTDOWN_CLEAN` → 关 DB / web |
| `SIGKILL` | 无法处理；依赖 systemd `Restart=` + 下次启动重新对账（fail-closed） |

## 管理命令

设计要求 pause / resume / reconcile / cancel-all / flatten / target-weight / safe-shutdown 走**本机 CLI**（控制文件），不走公网 HTTP。详见 [Admin control](admin-control.md)。

运维报告（daemon 已在跑时）：

```bash
./scripts/gate2-report.sh
HOST=<sshx-name> ./scripts/soak-report.sh 24
HOST=<sshx-name> ./scripts/check-remote.sh
```
