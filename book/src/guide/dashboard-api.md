# Dashboard 与 API

Web 面默认**只绑 127.0.0.1**。远程看盘用 SSH 本地转发，或经受信任的 TLS 反代（nginx）；不要把未鉴权端口裸奔到公网。

```bash
ssh -L 18180:127.0.0.1:18180 user@your-vm
# 本机浏览器打开 http://127.0.0.1:18180/
```

本地默认配置见 `config/local.toml`（端口 **18180**）。生产示例多为 `127.0.0.1:8080`。

## 鉴权（可选）

| 客户端 | 凭证 |
|---|---|
| 浏览器 Dashboard | Token 登录 → `ab_session` HttpOnly cookie；可选 Passkey |
| MCP / 脚本 | `Authorization: Bearer <token>` 或 `X-API-Token: <token>` |
| 健康探针 | 始终开放：`/health/live`、`/health/ready` |

- **`ALPHABOUND_API_TOKEN` 为空**：鉴权关闭（本机开发默认）。
- **已设置 token**：所有 `/api/v1/*` 数据路由无凭证返回 401；HTML 壳仍可访问并显示登录门。
- Passkey 注册需要已有 session（先用 token 登录一次）。
- 反代场景见 [鉴权与 MCP](auth-mcp.md)；**默认不要**开 `ALPHABOUND_TRUST_PROXY`。

```bash
# 登录拿 session（示例）
curl -sS -c cookies.txt -X POST http://127.0.0.1:18180/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"token":"YOUR_TOKEN"}'
curl -sS -b cookies.txt http://127.0.0.1:18180/api/v1/state | jq .
# 或
curl -sS -H "Authorization: Bearer YOUR_TOKEN" http://127.0.0.1:18180/api/v1/state | jq .
```

## Dashboard

| 项 | 现状 |
|---|---|
| 形态 | 单文件 HTML + favicon 集，**编译期嵌入**二进制（`dashboard/`） |
| 入口 | `GET /` 与 `GET /index.html` |
| 依赖 | 零 Node 运行时；浏览器直接 `fetch` API |
| 刷新 | 前端约 2s 轮询 state / shadow / agent-runs / equity / candles / memories / events / system / orders / decisions |
| 内容 | Overview + Shadow vs BH + **Lightweight Charts**（分时/多周期 K 线 + 成交量 + 净值/HWM）+ 提案/记忆/事件/订单 + System |

概览图表使用 [Lightweight Charts](https://www.tradingview.com/lightweight-charts/)（CDN）。周期按钮：**分时**（1m 收盘面积图）、1分/5分/15分/1时/4时/1日。离线无 CDN 时其余 UI 仍可用。

### 本地打开

```bash
set -a && source ./secrets.env && set +a
./zig-out/bin/alphabound --config config/local.toml --ticks 0 &
open http://127.0.0.1:18180/
```

## HTTP API

数据面以 **GET** 为主；鉴权相关为 POST/GET。响应体在请求缓冲区内拷贝，避免与核心环竞态。

### 健康检查（始终开放）

#### `GET /health/live`

```json
{"status":"ok"}
```

#### `GET /health/ready`

| 状态 | HTTP | body |
|---|---|---|
| READY | 200 | `{"status":"ready"}` |
| 尚未对账 | 503 | `{"status":"not_ready"}` |

### 鉴权路由（公开入口）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/auth/status` | `auth_required` / `authenticated` / passkey 计数 |
| POST | `/api/v1/auth/login` | body `{"token":"..."}` → Set-Cookie |
| POST | `/api/v1/auth/logout` | 清 cookie |
| GET/POST | `/api/v1/auth/passkey/*` | WebAuthn 注册/登录（需 secure context） |

### 数据 API（token 开启后需鉴权）

| 路径 | 内容 |
|---|---|
| `GET /api/v1/state` | 组合快照：`risk_mode`、现金/BTC、bid、净值/HWM/DD、version、`config_hash`… |
| `GET /api/v1/events` | 最近事件 JSON 数组 |
| `GET /api/v1/agent-runs` | 最近 agent_runs（newest first） |
| `GET /api/v1/equity` | 最近 equity_samples |
| `GET /api/v1/shadow` | 实盘净值 vs 同起点 buy-and-hold |
| `GET /api/v1/candles` | 多周期 K 线缓存 `bars.{1m,5m,15m,1H,4H,1D}` |
| `GET /api/v1/memories` | 最新版本记忆 |
| `GET /api/v1/system` | 进程/agent/paused/disk/latency 等 |
| `GET /api/v1/decisions` | 提案/反思审计事件（含 thesis） |
| `GET /api/v1/orders` | `{"orders":[...],"fills":[...]}` 投影 |

### `GET /api/v1/shadow`

```json
{
  "shadow_equity": "400.12",
  "bh_equity": "399.80",
  "alpha": "0.32",
  "entry_bid": "64191",
  "bh_btc": "0.00622",
  "baseline_capital": "400.00",
  "shadow_return": "0.0003",
  "bh_return": "-0.0005",
  "alpha_return": "0.0008"
}
```

- 首次有效 bid + 已对账权益时，用**当时实盘净值**建 BH（全仓假想 BTC，扣 taker fee）。
- 权益相对基准跳变 ≥8% 且 ≥15 USDT（转入/转出）时 **自动重标定**（事件 `SHADOW_BH_REBASE`）。
- 主指标看 `alpha_return`；美元 `alpha` 仅作同本金参考。

### `GET /api/v1/system`

```json
{
  "software_version": "0.1.0",
  "mode": "shadow",
  "uptime_ms": 12000,
  "paused": false,
  "memories": 6,
  "private_keys": true,
  "private_ws_opt_in": false,
  "agent": {"total": 4, "ok": 3, "invalid": 0, "errors": 1, "valid_rate": 75.0, "tool_calls": 8}
}
```

### `GET /api/v1/candles`

多周期缓存（核心环周期性刷新；失败保留上一份）：

```json
{
  "instrument": "BTC-USDT",
  "bars": {
    "1H": [{"ts_ms": 1786237200000, "o": "64978.2", "h": "65011.4", "l": "64850", "c": "64871.3", "vol": "50.98"}]
  }
}
```

### `GET /api/v1/orders`

订单 8 状态投影 + 近期 fills；Dashboard「订单」标签与决策详情按 `decision_id` 关联。

### 规划中

| 接口 | 用途 | 状态 |
|---|---|---|
| `GET /api/v1/trades/{id}` | 单笔情节完整回放 | 待做 |
| `WS /ws/v1/events` | 增量推送 | 待做 |

### SQLite 备份

主环约每小时调用 SQLite Backup API，写入 `<db_path>.bak`，事件 `BACKUP_DONE` / `BACKUP_FAILED`。

## 安全边界

1. **无交易按钮暴露在公网** — 清仓 / 暂停 / target-weight 走本机 `--control`。
2. **响应中的密钥** — API 状态快照不含凭证。
3. **Agent 不读 HTTP** — Dashboard 是人的只读窗；MCP 同样只读。
4. **对外暴露** — 长随机 token + HTTPS 反代；详见 [鉴权与 MCP](auth-mcp.md)。

## curl 速查

```bash
HOST=http://127.0.0.1:18180
AUTH=(-H "Authorization: Bearer ${ALPHABOUND_API_TOKEN:-}")
curl -sS "$HOST/health/live"
curl -sS "$HOST/health/ready"
curl -sS "${AUTH[@]}" "$HOST/api/v1/state" | jq .
curl -sS "${AUTH[@]}" "$HOST/api/v1/shadow" | jq .
curl -sS "${AUTH[@]}" "$HOST/api/v1/orders" | jq .
curl -sS "${AUTH[@]}" "$HOST/api/v1/decisions" | jq '.[0:3]'
curl -sS "${AUTH[@]}" "$HOST/api/v1/system" | jq .
curl -sS -o /dev/null -w "%{http_code}\n" "$HOST/"
```

只读 IDE 接入见 [鉴权与 MCP](auth-mcp.md) 与仓库 `tools/alphabound-mcp/`。
