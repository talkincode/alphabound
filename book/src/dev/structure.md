# 代码结构

```text
alphabound/
├── build.zig / build.zig.zon
├── book.toml                 # mdBook 工程（输出 book/book/，已 gitignore）
├── book/src/                 # 本手册源码（guide / concepts / dev / planning）
├── scripts/                  # build-docs、run-local、deploy/soak/drill 助手
├── .github/workflows/
├── src/
│   ├── main.zig              # daemon 生命周期 + CLI
│   ├── root.zig              # 模块导出 + refAllDecls 测试
│   ├── config.zig
│   ├── core/                 # decimal, clock, events, state
│   ├── risk/                 # equity, state_machine, admission
│   ├── execution/            # orders, planner, venue client
│   ├── agent/                # proposal, context, openai, reflection
│   ├── tools/                # registry, market (+ derivatives L1)
│   ├── memory/               # store + retrieval
│   ├── exchange/okx/         # auth, rest, ws
│   ├── storage/              # db, policy, disk
│   ├── admin/                # 本机控制文件
│   ├── security/             # isolation / limits 不变量
│   ├── fault/                # 故障矩阵单测 FD1–10
│   ├── intel/                # alphabound.intel.v1 协议 + ingest mailbox
│   ├── web/                  # server 路由 + auth（token/session/passkey）
│   └── observability/        # redaction, latency
├── migrations/               # SQL
├── dashboard/                # 嵌入式 Overview + favicon
├── tools/alphabound-mcp/     # Analytics MCP（只读观察 + 签名 intel ingest）
├── config/                   # alphabound.toml / local.toml / docker.toml
├── deploy/                   # systemd, nginx 示例, install 脚本
├── docs/                     # 设计分析 / 路线图 / 验收 / Gate / Auth
└── vendor/sqlite/
```

## 模块依赖方向（允许）

```text
main → config, storage, web, exchange, core/state, risk, execution, admin, …
agent → core/decimal, memory, tools   （禁止 → exchange 私钥路径）
risk  → core/decimal, state 类型
execution → core/decimal, orders 类型
tools / memory → 仅 core 与标准库
web/auth → 不持有交易所密钥；MCP 不碰交易控制面
```

新增 `use` / `@import` 时保持：**慢路径依赖快路径类型可以，反向把密钥或 socket 塞进 agent 不行**。

## 关键入口

| 文件 | 职责 |
|---|---|
| `main.zig` | BOOTING→…→READY、shadow/demo/live 循环、web 线程、信号、控制文件 |
| `core/state.zig` | 单写者 mailbox / 快照 |
| `risk/admission.zig` | 提案最后一道门 |
| `execution/` | 目标仓位 → 幂等订单 |
| `web/server.zig` + `web/auth.zig` | 纯路由可单测 + 鉴权 |
| `admin/control.zig` | pause/flatten/target-weight 控制文件 |
| `storage/db.zig` | SQLite 与 Repo |
| `fault/matrix.zig` | 故障降级矩阵单测 |

## 测试放置

- 与模块同文件的 `test "…"` 块（Zig 习惯）
- `root.zig` 的 `refAllDecls` 保证模块被链进测试二进制
- 故障场景：`src/fault/matrix.zig`
- 沉重 integration 可放 `tests/`（需凭证的勿默认跑）
