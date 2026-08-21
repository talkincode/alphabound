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
| 刷新 | 前端约 2s 轮询 state / shadow / agent-runs / equity / candles / memories / events / system / orders / decisions / review-chats / statistics |
| 内容 | Overview + Shadow vs BH + **Lightweight Charts**（分时/多周期 K 线 + 成交量 + 净值/HWM）+ **复盘**（K 线决策标记 + 指标 + AI 复盘对话 + 复盘记录）+ **统计**（资产/交易窗口账本 + 持久化 LLM Token/成本账本）+ 提案/记忆/事件/订单 + System |

概览图表使用 [Lightweight Charts](https://www.tradingview.com/lightweight-charts/)（CDN）。周期按钮：**分时**（1m 收盘面积图）、1分/5分/15分/1时/4时/1日。离线无 CDN 时其余 UI 仍可用。

### 复盘标签页

K 线图（1m–1D 周期，MA/EMA/BOLL 主图指标，VOL/RSI/MACD 副图）上把每次 Agent 提案画成标记：`●` 持有、`▲/▼` 调仓（按目标权重方向）、`▪` 失败或准入拒绝。点击标记（或用决策下拉）后，下方三个子页联动：

- **决策**：该提案的完整摘要（thesis、invalid_if、准入结论、关联订单/成交、原始 payload）。
- **事件流**：该时点 ±30 分钟的事件账本窗口（行情、余额、准入、执行、备份等），由核心循环按需从 SQLite 提取。
- **复盘记录**：定期复盘的报告列表（见下）。
- **AI 复盘**：与复盘助手就该时点对话。助手可发起**一轮有界工具请求**（≤6 个）：决策时点指标（SMA/EMA/RSI/ATR/VOL/BOLL/RANGE，`at:anchor` 在锚点截断计算）、K 线窗口、提案历史、净值轨迹、记忆检索——全部只读，接触不到交易路径。**克制边界**：助手只做归因分析，不给交易建议、无执行能力，人不能借它直接或间接改变决策；对话全部落库（`review_chats` 表）。点「沉淀为记忆」可将对话压缩成一条 **confidence 0.3 的 reflection 记忆**（`HR_<decision_id>`，每个决策一条、就地更新），作为人类观点进入主 Agent 上下文的唯一通道，由 Agent 自行取舍。

K 线下方另有 **AB 因子曲线图（实验性）**：仓位、净值收益、超额 α、回撤、波动、动量六个成分的 z-score 曲线与合成因子，时间轴与 K 线图双向联动，配 IC 表观测各成分对未来净值收益的预测力。仅用于复盘观测，不参与任何决策（详见下文 `GET /api/v1/review/analytics`）。

#### 复盘记录子页（定期复盘）

前三个子页是人主动挑一个决策去追问；「复盘记录」是系统**按固定节奏自己回看一整段窗口**，两者并存互补，因此放在同一个复盘标签页下。

- **小周期**（小时级，默认 8 小时，常用 4 小时）：这一班的决策是否兑现了自己的论据？HOLD 是不是被当成了胜利？
- **大周期**（默认 7 天）：策略在跨班次上是否还成立？基准跑赢了吗？该改的是仓位、节奏，还是记忆？

子页顶部是两个周期的间隔与下次运行倒计时、最近一次结果；下方按时间倒序列出报告卡片（可按周期筛选），展开可见摘要、窗口内确定性事实（提案/准入/执行/净值/最大回撤/基准超额/异常计数）、模型给出的发现·经验·风险，以及沉淀出的记忆 ID 与原始 JSON。两个「立即复盘」按钮走同一条邮箱链路，用于手动加跑一次。

**边界与既有复盘一致**：只读账本，不触碰引擎、订单与风控状态，也不产生交易建议。窗口内的每个数字都来自 SQLite（`equity_samples` / `events` / `agent_runs` / `fills` / `audit_reports`），模型只负责归纳；结论压缩成一条 **confidence 0.3 的 reflection 记忆**（`PR_short` / `PR_long`，每周期一条、就地更新），是它影响未来决策的唯一通道，由主 Agent 自行取舍。LLM 未配置或返回不合法 JSON 时，仍会落一份 `degraded` 报告（只含确定性事实）并照常推进调度，坏掉的模型不会把循环卡在重试上。

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
| `GET /api/v1/system` | 进程/agent/paused/disk/CPU/内存/网络/latency 等 |
| `GET /api/v1/statistics` | 资产/交易窗口账本 + 持久化 LLM 调用、Token、市场价成本、覆盖率与近期账本 |
| `GET /api/v1/decisions` | 提案/反思审计事件（含 thesis） |
| `GET /api/v1/orders` | `{"orders":[...],"fills":[...]}` 投影 |
| `GET /api/v1/review/chats` | 复盘对话最近轮次（newest first，客户端按 `id` 升序重排） |
| `GET /api/v1/review/context` | 最近一次请求的复盘事件窗口 `{decision_id, from, to, events}` |
| `GET /api/v1/review/analytics` | AB 因子复盘分析（实验性）：成分指标曲线 + IC 表，见下 |
| `GET /api/v1/review/periodic` | 定期复盘报告（newest first，含窗口事实与模型结论） |
| `GET /api/v1/audit` | 定时审计报告（newest first，含完整 findings 与 stats） |

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
  "agent": {"total": 4, "ok": 3, "invalid": 0, "errors": 1, "valid_rate": 75.0, "tool_calls": 8},
  "status": {
    "disk": "ok",
    "disk_free_bytes": 12884901888,
    "cpu_pct_x10": 8,
    "host_cpu_pct_x10": 41,
    "rss_bytes": 16000000,
    "mem_used_bytes": 800000000,
    "mem_total_bytes": 2000000000,
    "net_rx_bps": 12000,
    "net_tx_bps": 4000
  }
}
```

### `GET /api/v1/statistics`

Dashboard「统计」页的数据源，含两个子页：**资产与交易**、**模型用量**。核心循环从 SQLite 预渲染快照；HTTP 线程不直接查询 SQLite。响应按 **UTC** 聚合。

顶层仍保留 LLM 字段（`last_24h` / `last_7d` / `last_30d` / `all_time` / `ledger_from` / `daily_utc` / `recent` 等），并新增 `portfolio` 与 `trading`。`all_time` 是账本累计；`ledger_from` 是第一条入账时间，更早的调用不会补记：

```json
{
  "timezone": "UTC",
  "currency": "USD",
  "cost_unit": "nano_usd",
  "price_basis": "market_estimate",
  "last_24h": {
    "calls": 12,
    "ok_calls": 11,
    "usage_reported_calls": 10,
    "priced_calls": 10,
    "prompt_tokens": 120000,
    "cached_prompt_tokens": 30000,
    "completion_tokens": 8000,
    "input_cost_nano_usd": 25000000,
    "output_cost_nano_usd": 5300000
  },
  "daily_utc": [{"day": "2026-08-21", "totals": {"calls": 12}}],
  "by_kind_30d": [{"kind": "proposal", "totals": {"calls": 8}}],
  "by_model_30d": [{"model": "DeepSeek-V4-Flash-0731", "totals": {"calls": 12}}],
  "recent": [{"ts": "2026-08-21T00:00:00.000Z", "kind": "proposal", "outcome": "ok"}]
}
```

- **完整性优先**：每次模型调用（成功、业务输出无效、超时/HTTP/解析失败）都写一条账本。`usage_reported=false` 表示 Provider 没有给出 usage；`cost_known=false` 表示模型未识别、usage 缺失或调用失败。二者都不能当作零成本。
- **价格边界**：目前识别 DeepSeek V4 Flash 的版本化市场价档；按调用开始时的 UTC 峰/非峰段分别计算缓存命中输入、缓存未命中输入和输出成本，使用整数 nano USD 结算。它是**市场价估算，不是供应商、网关或代理商账单**；未知模型保持未定价。
- **隐私边界**：账本仅保存时间、调用类型、模型、关联 run/decision、延迟、Token、价格档、费用和短错误类别；不保存 Prompt、Completion、Provider URL、密钥或原始错误响应。
- **资产窗口**：`portfolio.last_24h/7d/30d` 来自 1 分钟 `equity_samples`。缺起点/终点或买入持有标记时对应字段为 `null`，不会把未知收益或超额写成 0。
- **交易窗口**：`trading.*` 按订单创建时间和成交时间计入。名义额与数量用 Decimal 累加；未关联订单的成交计入 `unlinked_fills`，非 USDT 费用计入 `fee_other_fills`，都不并入 USDT 费用合计。

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

### 复盘 API（`/api/v1/review/*`）

复盘请求走**邮箱模式**：web 线程只入队（立即返回 `202 {"ok":true,"queued":true}`），核心循环每 tick 出队一件、查库/调 LLM，把结果发布为预渲染 JSON——与「web 线程不碰 SQLite」的单写者架构一致。该通道只读交易状态，写入面仅限 `review_chats`、记忆与审计事件，**接触不到提案与下单路径**。

| 方法 | 路径 | Body | 说明 |
|---|---|---|---|
| POST | `/api/v1/review/context` | `{"decision_id","anchor_ts"}` | 提取该时点 ±30min 事件窗口 → `GET /api/v1/review/context` |
| POST | `/api/v1/review/chat` | `{"decision_id","anchor_ts","message"}` | 复盘提问（≤1500B）；回复落库后出现在 `GET /api/v1/review/chats` |
| POST | `/api/v1/review/summarize` | `{"decision_id"}` | 将对话压缩为一条低置信度 reflection 记忆（`HR_<decision_id>`） |
| POST | `/api/v1/review/periodic` | `{"cycle":"short"\|"long"}` | 手动加跑一次定期复盘；结果进 `GET /api/v1/review/periodic` |

限制：队列深度 4（满载 429）；同决策同类请求去重（409）；每决策对话上限 40 轮；每次提问至多一轮工具请求（≤6 个，均为只读）；LLM 未配置时提问仍会保存并得到降级答复。审计事件：`REVIEW_CHAT_OK/FAILED`（含 `tools` 计数）、`REVIEW_SUMMARY_OK`、`PERIODIC_REVIEW`。手动定期复盘同样会推进调度游标（下一次自动运行相应顺延）。

### `GET /api/v1/review/analytics`（AB 因子，实验性）

复盘标签页 K 线下方曲线图与 IC 表的数据源。核心循环每分钟基于**最近 48 小时的 1m equity 轨迹**重算（`src/analytics/ab_factor.zig`），5 分钟采样输出：

```json
{
  "factor_version": "v1",
  "experimental": true,
  "n_1m": 2880,
  "step_minutes": 5,
  "orientation": {"pos": 1, "ret": 1, "alpha": 1, "dd": -1, "vol": -1, "mom": 1},
  "points": [{"t": 1786237200, "pos": 0.9497, "ret": -0.0012, "alpha": 0.0034,
              "dd": 0.0137, "vol": 0.0008, "mom": 0.0021, "ab": -0.42}],
  "ic": [{"horizon_minutes": 60, "pos": {"r": 0.12, "n": 140}, "ab": {"r": 0.21, "n": 140}}]
}
```

- **成分（v1 等权，方向见 `orientation`）**：`pos` 仓位占比（btc_value/equity）、`ret` 30m 净值滚动收益、`alpha` 相对 buy-and-hold 的超额（迁移 0006 marks）、`dd` 回撤、`vol` 30m 已实现波动（1m bid 对数收益 std）、`mom` 30m BTC 动量。`ab` = 各成分 z-score 的定向等权均值（≥3 个成分可用才输出）。
- **IC 表**：各成分 z 值与 `ab` 对**未来 1h / 4h 净值收益**的皮尔逊相关，`n` 为配对样本数；样本不足（<30）时 `r` 为 `null`。这是"哪些指标与未来表现相关、该不该留在因子里"的观测依据。
- **数据诚实性**：迁移 0006 之前的行缺 `bid_price/btc_qty/bh_equity` 标记，依赖它们的成分输出 `null`（前端留白），不回填猜测；1m 轨迹出现 >2× 窗口的缺口时滚动窗口同样置 `null`。
- **边界**：纯研究视图。因子不进提案 prompt、不进准入/风控/下单路径（`src/agent`、`src/risk`、`src/execution` 禁止 import analytics 模块）；调整成分或权重必须升 `factor_version`。

### 定时审计（`/api/v1/audit` 与告警铃铛）

核心循环内置**确定性规则审计器**（`src/observability/auditor.zig`，判定路径无 LLM），默认每 4 小时（`[audit] interval_ms`，0 关闭，下限 10 分钟）对五个面自检：

| 检查面 | 内容 |
|---|---|
| llm | run 成功率、连续失败、僵尸检测（超 3× 决策周期无提案） |
| tools | 工具调用缺失、延迟、MARKET_STALE 频次 |
| data | 净值恒等式重算、HWM 单调、drawdown 自洽、样本新鲜度、SQLite quick_check |
| flow | 触发→提案→准入→反思事件链完整性、备份、严重事件（FAULT 等） |
| self | 审计自身按时、风险模式非 NORMAL 可见 |

结果：完整报告落库 `audit_reports`（`GET /api/v1/audit` 可回放）；事件流写 `AUDIT_OK/WARN/ALERT`；`/api/v1/system` 的 `audit` 块驱动 Dashboard **右上角告警铃铛**（黄=警告、红=告警，点开看发现明细与历史）。启动即跑一次，之后按间隔。

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
curl -sS "${AUTH[@]}" "$HOST/api/v1/statistics" | jq .
curl -sS -o /dev/null -w "%{http_code}\n" "$HOST/"
```

只读 IDE 接入见 [鉴权与 MCP](auth-mcp.md) 与仓库 `tools/alphabound-mcp/`。
