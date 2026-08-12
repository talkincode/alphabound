# 本机管理控制

AlphaBound 管理命令**不走网络**：CLI 写入 DB 同目录控制文件，daemon 主环每 tick 消费一次。

## 命令

```bash
./zig-out/bin/alphabound --config config/local.toml --control pause
./zig-out/bin/alphabound --config config/local.toml --control resume
./zig-out/bin/alphabound --config config/local.toml --control reconcile
./zig-out/bin/alphabound --config config/local.toml --control cancel-all
./zig-out/bin/alphabound --config config/local.toml --control flatten
./zig-out/bin/alphabound --config config/local.toml --control shutdown
./zig-out/bin/alphabound --config config/local.toml --control status
```

| 命令 | 行为 |
|---|---|
| `pause` | 停止 agent 决策环；行情/风险/对账继续 |
| `resume` | 恢复 agent |
| `reconcile` | 立即触发一次私有 REST 余额对账 |
| `cancel-all` | 取消开放订单。Shadow：只记审计事件；**Demo**（`OKX_SIMULATED=1`）：拉 pending 并逐笔 `cancel-order` |
| `flatten` | 操作员退出：进入 `FLATTENING`，主环自动市价卖向 weight=0；BTC 低于 lot dust 后 `flatten_complete` → `HALTED` |
| `resume` | 恢复 agent；若风险态为 `HALTED`，同时 `operator_reset` → `EXIT_ONLY`（再经对账回到 NORMAL） |
| `shutdown` | 等价安全停机（与 SIGTERM 相同排空路径） |
| `status` | 读 `*.control.state`（daemon 写入） |

控制文件：`var/trading.control`（one-shot，消费后删除）  
状态文件：`var/trading.control.state`

Dashboard `/api/v1/system` 含 `"paused": true|false`。
