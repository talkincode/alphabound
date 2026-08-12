# Agent 配置（OpenAI 兼容）

AlphaBound 慢决策环使用 **OpenAI Chat Completions 兼容 API**。  
shadow 下会生成并审计 Decision Proposal，**绝不下单**。

## 你需要准备

| 项 | 说明 |
|---|---|
| API URL | 根路径，如 `https://api.openai.com/v1` 或中转 `https://xxx/v1`（不要带 `/chat/completions`） |
| API Key | Bearer token |
| Model | 如 `gpt-4o-mini`、`deepseek-chat` 等 |

## 1. 写密钥（环境变量，不要写 TOML）

### 方式 A：手写 `secrets.env`

```bash
./scripts/load-okx-keychain.sh ./secrets.env   # 可选 OKX

cat >> secrets.env <<'EOF'
LLM_API_KEY='你的key'
LLM_API_URL='https://api.openai.com/v1'   # 或 Azure: https://xxx.openai.azure.com/openai/v1
LLM_MODEL='你的模型名或Azure部署名'
EOF
chmod 600 secrets.env
set -a && source ./secrets.env && set +a
```

### 方式 B：macOS 钥匙串

支持 service 名：

| 用途 | service |
|---|---|
| Key | `LLM_API_KEY` / `OPENAI_API_KEY` / `AZURE_OPENAI_API_KEY` |
| URL | `LLM_API_URL` / `OPENAI_BASE_URL` / `AZURE_OPENAI_API_URL` |
| Model | `LLM_MODEL` / `OPENAI_MODEL` / `AZURE_OPENAI_DEPLOYMENT` |

```bash
./scripts/load-llm-keychain.sh ./secrets.env
# 若钥匙串没有 model，默认 gpt-4o-mini —— Azure 上通常要改成真实 Deployment 名：
# 编辑 secrets.env 里 LLM_MODEL='你的deployment'
set -a && source ./secrets.env && set +a
```

Azure OpenAI：`LLM_MODEL` **必须是门户里的 Deployment 名称**（不是随便写的模型 id）。  
若日志出现 `deployment_not_found`，只改 `LLM_MODEL` 即可。

别名：`OPENAI_*` / `AZURE_OPENAI_*` 均可。

## 2. TOML `[agent]`（非密钥）

`config/local.toml`：

```toml
[agent]
provider = "openai"
model = "gpt-4o-mini"                 # 可被 LLM_MODEL 覆盖
base_url = "https://api.openai.com/v1" # 可被 LLM_API_URL 覆盖
decision_timeout_ms = 180000
decision_interval_ms = 60000          # 慢环间隔；0=不按间隔调度
prompt_dir = "prompts"
enabled = true                        # false 则永不调模型
```

系统提示词：仓库内 `prompts/system.md`（已嵌入二进制）。

## 3. 运行

```bash
mkdir -p var
zig build -Doptimize=ReleaseSafe

# 自检（打印 agent 配置是否读到密钥，不强制调模型）
./zig-out/bin/alphabound --config config/local.toml --self-check

# 就绪后立刻做 1 次决策 + 跑若干 tick
./zig-out/bin/alphabound --config config/local.toml --agent-once --ticks 5

# 常驻：按 decision_interval_ms 周期决策
./scripts/run-local.sh
```

成功日志示例：

```text
[boot] LLM credentials present (key_len=... base_url=https://... model=...)
[agent] calling https://... model=... snap=...
[agent] proposal ok id=dec_... action=HOLD ... (shadow: not executed)
```

失败（超时/坏 JSON/鉴权）→ **HOLD**，写 `agent_runs` 状态，不影响行情环。

## 4. 查审计

每次慢环会先拉 **market.ticker / market.candles**（OKX 公共 REST），写入 `tool_calls`，再把观察塞进 Context 的 `tool_observations`（data 不可信）。

```bash
# 汇总有效提案率
./zig-out/bin/alphabound --config config/local.toml --agent-stats

sqlite3 var/trading.db \
  "SELECT run_id,model,status,snapshot_version FROM agent_runs ORDER BY started_ts DESC LIMIT 5;"

sqlite3 var/trading.db \
  "SELECT tool,source,latency_ms,substr(result_digest,1,16) FROM tool_calls ORDER BY id DESC LIMIT 10;"

# 提案摘要在 events.payload_json（shadow 永不 executed）
sqlite3 var/trading.db \
  "SELECT type,severity,payload_json FROM events WHERE type LIKE 'AGENT_%' ORDER BY seq DESC LIMIT 5;"
```

成功日志形如：

```text
[agent] calling ... tools=2
[agent] proposal ok id=dec_... action=HOLD target_btc=0 conf=0.75 (shadow: not executed)
```

## 优先级

1. 环境变量 `LLM_*` / `OPENAI_*`  
2. TOML `[agent] model` / `base_url`  
3. 无 `LLM_API_KEY` → agent 关闭，仅行情 shadow

## 安全

- Key 不进 git、不进 Dashboard、不进 Agent Context  
- 提案在 shadow **不进执行层**  
- `mode=live` 需 `OKX_REAL_MONEY_OK=1`；shadow 默认仍不执行订单

## Reflection（决策后）

提案校验通过后会再跑一轮 **Reflection**：

1. 默认 `llm_reflection = true`：第二次 LLM 调用（`prompts/reflection.md`），产出严格 Schema 的 `memory_ops` 并写入记忆库。
2. LLM 失败 / 坏 JSON / Schema 拒绝 → **fail-closed**，回退确定性 shadow reflection（不改订单路径）。
3. 环境变量 `ALPHABOUND_LLM_REFLECTION=0` 可强制关闭 LLM reflection。

相关事件：`AGENT_REFLECTION_OK`、`AGENT_REFLECTION_LLM_FAILED`、`AGENT_REFLECTION_INVALID`。

## 短 soak

```bash
./scripts/soak-shadow.sh 20
```
