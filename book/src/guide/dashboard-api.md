# Dashboard 与 API

Web 面默认**只绑 127.0.0.1**。远程看盘用 SSH 本地转发，不要把端口暴露到公网。

```bash
ssh -L 18180:127.0.0.1:18180 user@your-vm
# 本机浏览器打开 http://127.0.0.1:18180/
```

本地默认配置见 `config/local.toml`（端口 **18180**，避免与其他桌面服务抢 18080）。

## Dashboard

| 项 | 现状 |
|---|---|
| 形态 | 单文件 HTML，**编译期嵌入**二进制（`dashboard/index.html`） |
| 入口 | `GET /` 与 `GET /index.html` |
| 依赖 | 零 Node 运行时；浏览器直接 `fetch` API |
| 刷新 | 前端约 2s 轮询 state / shadow / agent-runs / equity / candles / memories / events / system |
| 内容 | Overview + Shadow vs BH + **TradingView Lightweight Charts**（1H K 线 + 成交量 + 净值/HWM）+ 提案/记忆/事件 + System |

概览图表使用 [Lightweight Charts](https://www.tradingview.com/lightweight-charts/)（CDN 加载，页面内含 TradingView 归因）。离线无 CDN 时其余 UI 仍可用，图表区提示未加载。

### 本地打开

```bash
set -a && source ./secrets.env && set +a
./zig-out/bin/alphabound --config config/local.toml --ticks 0 &
open http://127.0.0.1:18180/
```

## HTTP API

全部为 **GET**；其它方法返回 `405`。响应体在请求缓冲区内拷贝，避免与核心环 seqlock 竞态。

### `GET /health/live`

```json
{"status":"ok"}
```

### `GET /health/ready`

| 状态 | HTTP | body |
|---|---|---|
| READY | 200 | `{"status":"ready"}` |
| 尚未对账 | 503 | `{"status":"not_ready"}` |

### `GET /api/v1/state`

组合快照：`risk_mode`、`cash_usdt`、`btc_total`、`bid_price`、`conservative_equity`、`high_watermark`、`drawdown`、`version`、`as_of_ms`、`software_version`、`config_hash`。

### `GET /api/v1/events`

最近事件 JSON 数组（由核心环从 SQLite 预渲染）。

### `GET /api/v1/agent-runs`

最近 `agent_runs` 行（newest first）：`run_id`、`status`、`model`、`snapshot_version`、digests、时间戳。

### `GET /api/v1/equity`

最近 `equity_samples`：`ts`、`equity`、`hwm`、`drawdown`、`cash`、`btc_value`。

### `GET /api/v1/shadow`

影子 vs buy-and-hold 对比：

```json
{
  "shadow_equity": "100",
  "bh_equity": "99.80",
  "alpha": "0.20",
  "entry_bid": "64600",
  "bh_btc": "0.00154"
}
```

BH 在首个有效 bid 按 `initial_capital` 与 taker fee 初始化；shadow 仍可 HOLD 全现金，故短期 alpha 常为正（未承担 BTC 风险）。

## 规划中的 API

| 接口 | 用途 | 状态 |
|---|---|---|
| `GET /api/v1/candles` | K 线缓存 | ✅ 已有（1H，供 Lightweight Charts） |
| `GET /api/v1/trades/{id}` | 单笔情节回放 | 待做 |
| `GET /api/v1/memories` | 假设与记忆版本 | 待做 |
| `WS /ws/v1/events` | 增量推送 | 待做 |

## 安全边界

1. **无交易按钮暴露在公网** — 清仓 / 暂停走本机管理通道。
2. **响应中的密钥** — API 状态快照不含凭证。
3. **Agent 不读 HTTP** — Dashboard 是人的只读窗，不是 Agent 工具。

## curl 速查

```bash
HOST=http://127.0.0.1:18180
curl -sS "$HOST/health/live"
curl -sS "$HOST/health/ready"
curl -sS "$HOST/api/v1/state" | jq .
curl -sS "$HOST/api/v1/shadow" | jq .
curl -sS "$HOST/api/v1/agent-runs" | jq .
curl -sS "$HOST/api/v1/equity" | jq .
curl -sS "$HOST/api/v1/events" | jq '.[0:3]'
curl -sS -o /dev/null -w "%{http_code}\n" "$HOST/"
```

### `GET /api/v1/candles`

OKX 公共 1H K 线缓存（最多 48 根，时间升序）：

```json
{
  "instrument": "BTC-USDT",
  "bar": "1H",
  "candles": [
    {"ts_ms": 1786237200000, "o": "64978.2", "h": "65011.4", "l": "64850", "c": "64871.3", "vol": "50.98"}
  ]
}
```

核心环约每 5s 刷新一次；失败时保留上一份缓存（或空数组）。

### `GET /api/v1/memories`

最新版本记忆（newest first）：`memory_id`、`version`、`kind`、`status`、`confidence`、`evidence_count`、`content`、`created_ts`。

Shadow 启动时若库空会 seed `W_shadow_policy` / `H_btc_spot_default`；每次有效提案写入 episodic `E_<run_id>` 并更新 `W_last_decision`。

### `GET /api/v1/system`

进程与 agent 统计（核心环刷新）：

```json
{
  "software_version": "0.1.0",
  "mode": "shadow",
  "uptime_ms": 12000,
  "memories": 6,
  "private_keys": true,
  "private_ws_opt_in": false,
  "agent": {"total": 4, "ok": 3, "invalid": 0, "errors": 1, "valid_rate": 75.0, "tool_calls": 8}
}
```

### SQLite 备份

主环约每小时调用 SQLite Backup API，写入 `<db_path>.bak`，事件 `BACKUP_DONE` / `BACKUP_FAILED`。

### `GET /api/v1/decisions`

Agent 相关审计事件（newest first，最多约 80 条）：`AGENT_PROPOSAL_OK` / `AGENT_INVALID_*` / `AGENT_LLM_FAILED` / `AGENT_REFLECTION_*`。  
Dashboard「决策历史」标签页消费此接口。
