# 代码结构

```text
alphabound/
├── build.zig / build.zig.zon
├── book.toml                 # mdBook 工程（输出 book/book/，已 gitignore）
├── book/src/                 # 本手册源码（guide / concepts / dev / planning）
├── scripts/build-docs.sh     # build | serve | clean
├── .github/workflows/docs.yml
├── src/
│   ├── main.zig              # daemon 生命周期
│   ├── root.zig              # 模块导出 + refAllDecls 测试
│   ├── config.zig
│   ├── core/                 # decimal, clock, events, state
│   ├── risk/                 # equity, state_machine, admission
│   ├── execution/            # orders, planner
│   ├── agent/                # proposal, context, reflection
│   ├── tools/                # registry
│   ├── memory/               # store + retrieval
│   ├── exchange/okx/         # auth, rest, ws
│   ├── storage/              # db + repos
│   ├── web/                  # HTTP 路由与 accept 循环
│   └── observability/        # redaction
├── migrations/               # SQL
├── dashboard/index.html      # 嵌入式 Overview
├── config/alphabound.toml
├── deploy/alphabound.service
├── docs/                     # 设计分析 / 路线图 / 验收（book 规划篇 include）
└── vendor/sqlite/
```

## 模块依赖方向（允许）

```text
main → config, storage, web, exchange, core/state, risk, …
agent → core/decimal, memory, tools   （禁止 → exchange 私钥路径）
risk  → core/decimal, state 类型
execution → core/decimal, orders 类型
tools / memory → 仅 core 与标准库
```

新增 `use` / `@import` 时保持：**慢路径依赖快路径类型可以，反向把密钥或 socket 塞进 agent 不行**。

## 关键入口

| 文件 | 职责 |
|---|---|
| `main.zig` | BOOTING→…→READY、shadow 循环、web 线程、信号 |
| `core/state.zig` | 单写者 mailbox / 快照 |
| `risk/admission.zig` | 提案最后一道门 |
| `web/server.zig` | 纯路由可单测 + serve 循环 |
| `storage/db.zig` | SQLite 与 Repo |

## 测试放置

- 与模块同文件的 `test "…"` 块（Zig 习惯）
- `root.zig` 的 `refAllDecls` 保证模块被链进测试二进制
- 未来沉重 integration 可放 `tests/integration/`（需凭证的勿默认跑）
