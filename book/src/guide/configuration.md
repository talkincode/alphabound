# 配置参考

配置文件为 **TOML**。生产约定路径：

| 文件 | 权限建议 | 内容 |
|---|---|---|
| `/etc/alphabound/alphabound.toml` | `0640` root:alphabound | 非密钥运行参数 |
| `/etc/alphabound/secrets.env` | `0600` root:root | OKX / LLM 密钥（systemd `EnvironmentFile`） |
| `/etc/alphabound/prompts/` | `0640` | 版本化系统 Prompt |

> 密钥**绝不**写入 TOML，也**绝不**进入 Agent Context。

仓库示例：[`config/alphabound.toml`](https://github.com/talkincode/alphabound/blob/main/config/alphabound.toml)。

---

## 完整示例

```toml
[app]
environment = "production"       # development | production
instance_id = "azure-btc-01"     # 写入事件，便于多实例区分

[exchange]
provider = "okx"
instrument = "BTC-USDT"
mode = "shadow"                  # shadow | demo | live
# rest_url = "https://www.okx.com"
poll_interval_ms = 5000

[risk]
max_drawdown = 0.10              # 不可热加载；Agent 不可修改
valuation = "conservative_liquidation"
allow_runtime_override = false
taker_fee_rate = 0.001
slippage_rate = 0.0005
initial_capital = 100.0          # shadow 模拟起始资金 (USDT)

[agent]
provider = "configured-adapter"
model = "configured-model"
decision_timeout_ms = 180000
prompt_dir = "/etc/alphabound/prompts"

[storage]
path = "/var/lib/alphabound/trading.db"
wal = true

[web]
bind = "127.0.0.1:8080"
static_dir = "/opt/alphabound/ui/current"   # 预留；当前 Dashboard 已嵌入二进制
```

---

## 分段说明

### `[app]`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `environment` | string | — | 环境标签，进日志/事件 |
| `instance_id` | string | — | 实例标识 |

### `[exchange]`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `provider` | string | `okx` | 交易所适配器 |
| `instrument` | string | `BTC-USDT` | 交易标的 |
| `mode` | string | `shadow` | 见 [运行模式](modes.md) |
| `rest_url` | string | `https://www.okx.com` | REST 根地址 |
| `poll_interval_ms` | u32 | `2000` | shadow 轮询间隔；**下限 200ms**（防打爆公共 API） |

### `[risk]` — 硬边界区

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `max_drawdown` | decimal | `0.10` | HWM 相对最大回撤。**启动时加载，禁止热改** |
| `valuation` | string | `conservative_liquidation` | 净值口径 |
| `allow_runtime_override` | bool | `false` | 必须为 false；解析保留字段 |
| `taker_fee_rate` | decimal | `0.001` | 保守估值 taker 费率 |
| `slippage_rate` | decimal | `0.0005` | 退出滑点缓冲 |
| `initial_capital` | decimal | `100` | shadow 模拟账户起始 USDT；须 `> 0` |

> 改 `max_drawdown` / 费率类参数 = **版本发布 + 人工确认**，不是运行中调参。

### `[agent]`

详见专章 [Agent 配置（OpenAI）](agent.md)。

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `provider` | string | `openai` | 适配器名（当前仅 openai 兼容） |
| `model` | string | `gpt-4o-mini` | 可被 `LLM_MODEL` 覆盖 |
| `base_url` | string | `https://api.openai.com/v1` | 可被 `LLM_API_URL` 覆盖 |
| `decision_timeout_ms` | u32 | `120000` | 单次 LLM chat 墙钟超时（超时→HOLD，不阻塞 daemon） |
| `decision_interval_ms` | u32 | `600000` | 慢环基础间隔（活跃时段）；0 表示不按间隔调度 |
| `decision_interval_quiet_ms` | u32 | `0` | 静默时段间隔；0 = 同基础间隔 |
| `decision_min_interval_ms` | u32 | `120000` | 任意两次决策的硬性冷却下限（事件触发也受限） |
| `active_hours_utc` | string | `""` | UTC 活跃时段 `"start-end"`（end 不含，可跨 0 点如 `"22-4"`）；空 = 全天基础间隔 |
| `event_price_move` | decimal | `0.005` | 距上次决策价格偏离 ≥ 该比例提前触发；0 关闭 |
| `event_drawdown_step` | decimal | `0.01` | 回撤较上次决策加深 ≥ 该比例提前触发；0 关闭 |
| `prompt_dir` | path | `prompts` | Prompt 目录 |
| `enabled` | bool | `true` | false 时永不调 LLM |
| `llm_reflection` | bool | `true` | 有效提案后跑 LLM 结构化反思；失败回退确定性 |
| `llm_reflection_on_hold` | bool | `false` | HOLD 提案是否也跑 LLM 反思；false 时 HOLD 只用确定性反思 |

慢环调度是多因素的：活跃/静默时段各有基础节奏，价格突变、回撤加深、
风险模式切换会提前触发一次决策，且所有触发都受 `decision_min_interval_ms`
冷却下限约束。风险内核不受此影响——它始终在快环独立执行。
每次触发在事件流记录 `AGENT_TRIGGER`（含 reason），便于审计调用频率。

### `[storage]`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `path` | path | — | SQLite 文件路径；父目录须可写 |
| `wal` | bool | `true` | 强制 WAL 语义（单 writer） |

**不要**把 DB 放在网络文件系统上。

### `[web]`

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `bind` | string | `127.0.0.1:8080` | 仅 `127.0.0.1:port` 或容器 `0.0.0.0:port`；宿主机发布仍应绑 loopback |
| `static_dir` | path | — | 预留静态目录；当前 Overview 页面 `@embedFile` 进二进制 |

---

## 密钥环境变量（`secrets.env`）

密钥**只**经环境变量注入（systemd `EnvironmentFile=`、shell `source`、或 macOS 钥匙串导出）。**禁止**写入 TOML。

```bash
# secrets.env  (chmod 0600) — 见 secrets.env.example
OKX_API_KEY=...
OKX_API_SECRET=...
OKX_API_PASSPHRASE=...
# OKX_SIMULATED=1          # 仅演示盘密钥
LLM_API_KEY=
LLM_API_URL=https://api.openai.com/v1
LLM_MODEL=gpt-4o-mini
```

macOS 本地：

```bash
./scripts/load-okx-keychain.sh ./secrets.env   # Keychain → 0600 文件（值已 shell-quote）
set -a && source ./secrets.env && set +a
```

进程只记录 `key_len` / `secret_len` / `pass_len`，从不打印密钥。有密钥时 shadow 会 **只读** 调用 `GET /api/v5/account/balance`；引擎现金仍用 `initial_capital` 模拟，**不下单**。

| 私有探测结果 token | 含义 |
|---|---|
| （成功） | 余额可用；日志打印 usdt/btc 数量 |
| `ip_whitelist` | OKX `50110`：把本机公网 IP 加入 API Key 白名单 |
| `invalid_sign` / `invalid_key` / `invalid_passphrase` | 密钥或签名问题 |
| `http_failed` | 网络/TLS |

日志与事件经 `observability/redaction.zig` 脱敏；**不要**把 `secrets.env` 贴进 issue 或聊天。

---

## 校验与哈希

- `--self-check`：解析 TOML、打开 DB、migration、bind；若有 `OKX_*` 则做私有只读探测。
- 每次启动计算 `config_hash`（SHA-256），写入事件信封。
- `mode=live` 在 Gate 4 前启动即失败；`mode=demo` 无密钥失败。

## 热加载边界

| 可热加载（规划） | 不可热加载（必须发版） |
|---|---|
| Prompt 文本（SIGHUP，hash 变更进事件） | `max_drawdown`、费率、滑点、mode→live 切换 |
| 日志级别（若后续支持） | web bind、DB 路径、instrument |

Agent **没有**写配置的代码路径——这是能力缺失，不是 prompt 约定。
