# 运行模式

`[exchange] mode` 控制「钱是不是真的、单会不会发」。

| 模式 | 行情 | 账户 | 下单 | 适用阶段 |
|---|---|---|---|---|
| **shadow** | 实网公共行情 | 模拟（`initial_capital`） | **否** | 开发、CI、观察链路 |
| **demo** | OKX Demo | Demo 账户 | Demo 单 | Phase 3 闸门、7 日 soak |
| **live** | 实盘 | 实盘（小资金） | **真单** | Phase 4，验收矩阵全绿后 |

## shadow（默认）

- 连接 OKX 公共 REST（时间、ticker 等），**不需要** API Key。
- 启动时注入模拟账户（`initial_capital` USDT，BTC=0），`reconcile_result` 标记 clean。
- 风险内核、状态机、事件落库、Dashboard **全链路真实代码路径**。
- Agent 若接入，提案可算、可审计，但执行层不得对实盘发单。

适合：

```bash
./zig-out/bin/alphabound --config dev.toml --ticks 20
```

## demo

- 使用 OKX 模拟盘端点与 Demo 密钥（见 `secrets.env`）。
- 验证私有 WS、对账、下单幂等、部分成交、UNKNOWN 处置。
- **Gate 3 / AC-GO8**：连续稳定 ≥7 天 + 至少一次断线恢复与版本回滚演练。

切换前检查清单：

1. `mode = "demo"` 且 rest/ws 指向 Demo 主机
2. Demo 密钥权限最小化（仅交易需要的 scope）
3. `--self-check` 通过
4. ready 探针在对账后变绿

## live

- 真金白银。设计默认实验资金 **100 USDT**。
- 进入条件：路线图 Gate 3 + 验收矩阵 P0–P3 相关条目全绿；任何无法解释的状态不一致都阻止实盘。
- `max_drawdown`、费率、滑点等已按发版流程冻结。
- 建议：先 shadow 长跑 → demo 7 日 → live，**禁止**从开发配置直接改 `live`。

## 模式与风险状态机正交

无论哪种 mode，进程内风险模式仍是：

```text
NORMAL → EXIT_ONLY → FLATTENING → HALTED
```

- 数据陈旧 / 未对账 → fail-closed，常从 `EXIT_ONLY` 起步
- 回撤边界触发 → `FLATTENING` → 完成后可 `HALTED`
- `HALTED` **不**自动恢复交易，需人工与发版流程介入

shadow 下也会演练状态机（例如人工压测陈旧数据），只是不会碰到真实资金。

## 切换操作建议

```toml
# 1. 改配置（新文件或发版产物），不要热改内存
mode = "demo"   # 或 live
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
