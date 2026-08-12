# 快速开始

本页带你在开发机上完成：**构建 →（可选）钥匙串密钥 → 自检 → shadow 冒烟 → Dashboard**。  
shadow **永不下单**：公共行情 + 模拟账户；有密钥时额外做**只读**私有余额探测（Gate 1 连通性）。

## 前置条件

| 依赖 | 版本 / 说明 |
|---|---|
| Zig | **必须 0.16.0**（固定工具链，CI 同款） |
| 网络 | 能访问 `https://www.okx.com`（公共 REST） |
| 可选 | macOS Keychain 中的 `OKX_API_*`、`sqlite3`、`curl` |

```bash
zig version   # 期望输出 0.16.0
```

## 1. 克隆与构建

```bash
git clone git@github.com:talkincode/alphabound.git
cd alphabound

zig build -Doptimize=ReleaseSafe   # 产出 zig-out/bin/alphabound
zig build test
```

## 2. 本地配置

仓库提供开箱配置 [`config/local.toml`](https://github.com/talkincode/alphabound/blob/main/config/local.toml)：

- DB：`var/trading.db`（先 `mkdir -p var`）
- Web：`127.0.0.1:18180`（`config/local.toml`；避开 8080 / 18080 常见占用）
- `mode = "shadow"`

```bash
mkdir -p var
```

> **硬约束**：`web.bind` 只能是 `127.0.0.1:port` 或容器用 `0.0.0.0:port`。远程访问走 SSH tunnel。

## 3. （可选）从 macOS 钥匙串加载 OKX 密钥

钥匙串 service 名约定：`OKX_API_KEY`、`OKX_API_SECRET`、`OKX_API_PASSPHRASE`  
（兼容旧名 `OKX_API_ Passphrase`）。

```bash
./scripts/load-okx-keychain.sh ./secrets.env   # 0600，已 gitignore
set -a && source ./secrets.env && set +a      # 值已 shell 转义，支持 passphrase 含 &

# 或一键：
./scripts/run-local.sh --self-check
./scripts/run-local.sh --ticks 5
```

| 环境变量 | 说明 |
|---|---|
| `OKX_API_KEY` / `OKX_API_SECRET` / `OKX_API_PASSPHRASE` | 仅环境注入，禁止写 TOML |
| `OKX_SIMULATED=1` | 演示盘密钥时加 `x-simulated-trading: 1` |

**私有只读前提**：OKX API Key 的 **IP 白名单**须包含本机公网 IP。未放行时日志为 `private balance FAILED: ip_whitelist`——签名已通，属运维策略，shadow 公共路径仍可跑。

```bash
curl -sS https://api.ipify.org; echo   # 把该 IP 加到 OKX API Key 白名单
```

## 4. 自检

```bash
./zig-out/bin/alphabound --config config/local.toml --self-check
```

成功打印 `config_hash`、mode、db、web、`okx_keys: present|absent`。若有密钥会尝试 `/api/v5/account/balance`（只读）。

## 5. 有界 shadow 运行

```bash
./zig-out/bin/alphabound --config config/local.toml --ticks 5
```

期望日志：

```text
[boot] OKX credentials present (key_len=... secret_len=... pass_len=... simulated=false)
[connect] okx server time ...
[reconcile] private balance ...   # ok 或 ip_whitelist
[ready] mode=shadow live BTC-USDT data, simulated engine cash 100 USDT, web 127.0.0.1:18180, private_keys=yes, agent=on
[tick 0] bid ... equity 100 dd 0 mode normal
[shutdown] draining after 5 ticks
```

`mode=live` 需要 `OKX_REAL_MONEY_OK=1` 与小额子账号密钥；详见 [运行模式](modes.md)。

## 6. 探活与 Dashboard

常驻或加长 `--ticks` 时：

```bash
curl -s http://127.0.0.1:18180/health/live
curl -s http://127.0.0.1:18180/health/ready
curl -s http://127.0.0.1:18180/api/v1/state
open http://127.0.0.1:18180/
```

| 端点 | 含义 |
|---|---|
| `GET /` | 嵌入式 Overview Dashboard |
| `GET /health/live` | 进程存活 |
| `GET /health/ready` | READY 后 200 |
| `GET /api/v1/state` | 版本化状态快照 |
| `GET /api/v1/events` | 最近事件 |

## 7. 查库

```bash
sqlite3 var/trading.db \
  "SELECT type, severity FROM events ORDER BY seq DESC LIMIT 10;"
```

常见事件：`RECONCILE_COMPLETED` / `STATE_READY` / `PRIVATE_BALANCE_OK|FAILED` / `SHUTDOWN_CLEAN`。

## 8. 优雅退出

```bash
# Ctrl-C 或
kill -TERM <pid>
```

## 9. 配置 LLM Agent（可选）

有 OpenAI 兼容 `apiurl` / `key` / `model` 时，写入 `secrets.env`：

```bash
# secrets.env 追加（chmod 600；值请自行替换）
LLM_API_KEY='你的key'
LLM_API_URL='https://你的兼容端点/v1'   # 不要带 /chat/completions
LLM_MODEL='你的模型名'
```

```bash
set -a && source ./secrets.env && set +a
./zig-out/bin/alphabound --config config/local.toml --agent-once --ticks 5
```

完整说明 → [Agent 配置（OpenAI）](agent.md)

## 下一步

- 配置项 → [配置参考](configuration.md)
- Agent → [Agent 配置（OpenAI）](agent.md)
- 模式差异 → [运行模式](modes.md)
- Docker/GHCR → [Docker 与 GHCR](docker.md)
- 运维 → [运维部署](operations.md)
