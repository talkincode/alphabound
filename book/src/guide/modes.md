# 运行模式

`[exchange] mode` 控制「钱是不是真的、单会不会发」。

| 模式 | 行情 | 账户 | 下单 | 适用阶段 |
|---|---|---|---|---|
| **shadow** | 实网公共行情 | 模拟（`initial_capital`） | **否** | 开发、CI、观察链路 |
| **demo** | OKX 模拟盘 | Demo 账户 | 模拟盘单 | 无实盘密钥时的联调 |
| **live** | 实盘 | 小额实盘子账号 | **真单** | 当前默认实盘路径（显式 opt-in） |

## shadow（默认）

- 连接 OKX 公共 REST（时间、ticker 等），**不需要** API Key。
- 启动时注入模拟账户（`initial_capital` USDT，BTC=0），`reconcile_result` 标记 clean。
- 风险内核、状态机、事件落库、Dashboard **全链路真实代码路径**。
- Agent 若接入，提案可算、可审计，但执行层不得对交易所发单。

适合：

```bash
./zig-out/bin/alphabound --config dev.toml --ticks 20
```

## demo（OKX 模拟盘）

- 使用 OKX **模拟盘密钥** + 请求头 `x-simulated-trading: 1`（环境变量 **`OKX_SIMULATED=1` 必填**）。
- 引擎现金/BTC 来自私有 REST 余额（不再用 shadow 的 `initial_capital`）。
- Agent 提案经 Risk 准入后：`APPROVE`/`REDUCE` → planner → **市价/限价单**；HTTP 失败 → `UNKNOWN` → 查询后处置。
- Admin：`cancel-all` / `flatten` / `target-weight` 走同一执行栈。

```bash
export OKX_API_KEY=...
export OKX_API_SECRET=...
export OKX_API_PASSPHRASE=...
export OKX_SIMULATED=1
# config: mode = "demo"
./zig-out/bin/alphabound --config config/local.toml --agent-once --ticks 8
```

> **兼容**：历史部署可用 `mode=demo` + `OKX_REAL_MONEY_OK=1` 跑小额真金；boot 会告警，**请改 `mode=live`**。

## live（小额实盘 — 当前路径）

- 真金白银，设计默认实验资金约 **100 USDT 子账号**。
- **已解锁**，但必须同时满足：
  1. `mode = "live"`
  2. `OKX_*` 密钥（**Read+Trade，禁止 Withdraw**）
  3. **`OKX_REAL_MONEY_OK=1`**（显式 opt-in，从不默认）
  4. **不得**设 `OKX_SIMULATED=1`（live 拒绝模拟盘 header）
- Boot 打印醒目 banner；启动时探测 key 权限，带 withdraw 的 key 直接 FATAL。
- 风险边界 = 子账号余额 + `max_drawdown`；主账户/大资金不在范围内。

```bash
export OKX_API_KEY=...
export OKX_API_SECRET=...
export OKX_API_PASSPHRASE=...
export OKX_REAL_MONEY_OK=1
# config: mode = "live"
./zig-out/bin/alphabound --config /etc/alphabound/alphabound.toml
# 日志: [boot] *** LIVE REAL-MONEY AUTHORIZED ...
#        [ready] mode=live ... exec=live
```

Gate / 运维清单见 [GATE3_CHECKLIST.md](../../docs/GATE3_CHECKLIST.md)。  
「更大资金 / MVP 成立判定」仍是路线图 Phase 4 的运维与验收问题，**不是**再开一把代码锁。

## 模式与风险状态机正交

无论哪种 mode，进程内风险模式仍是：

```text
NORMAL → EXIT_ONLY → FLATTENING → HALTED
```

- 数据陈旧 / 未对账 → fail-closed，常从 `EXIT_ONLY` 起步
- 回撤边界触发 → `FLATTENING` → 完成后可 `HALTED`
- `HALTED` **不**自动恢复交易，需人工 `resume`（含 operator_reset）

shadow 下也会演练状态机，只是不会碰到真实资金。

## 切换操作建议

```toml
# 1. 改配置（新文件或发版产物），不要热改内存
mode = "live"   # 或 demo / shadow
```

```bash
# 2. 自检
alphabound --config /etc/alphabound/alphabound.toml --self-check

# 3. 原子发布 / restart（见运维章）
sudo systemctl restart alphabound
curl -sS --retry 30 --retry-delay 1 --fail \
  http://127.0.0.1:8080/health/ready
```

切换到 live 时在变更单中记录：`config_hash`、软件版本、操作人、回滚版本路径。
