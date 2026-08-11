# 构建与测试

## 工具链

| 工具 | 版本 |
|---|---|
| Zig | **0.16.0**（与 CI `mlugg/setup-zig@v2` 固定一致） |
| mdBook | ≥ 0.4（文档；Homebrew: `mdbook`） |
| SQLite | 源码 vendor 进仓库，无需系统库 |

Zig 0.16 API 与 0.13/0.14 不兼容；不要用「手头最新」随意升级。

## 常用命令

```bash
zig build                     # Debug 默认，产出 zig-out/bin/alphabound
zig build -Doptimize=ReleaseSafe
zig build test --summary all  # 全量单元 / 回放测试
./zig-out/bin/alphabound --self-check --config config/alphabound.toml
```

### 文档

```bash
./scripts/build-docs.sh           # mdbook build → book/book/
./scripts/build-docs.sh serve     # 预览 :3000
./scripts/build-docs.sh check     # build + 失败即非零（CI 用）
```

## CI

工作流：

| 文件 | 职责 |
|---|---|
| `.github/workflows/ci.yml` | Zig build + test + self-check（`main` / PR） |
| `.github/workflows/docs.yml` | mdBook 构建（可选发布 Pages） |
| `.github/workflows/release-docker.yml` | GHCR 镜像（**仅** tag `v*` / 手动，不跟 `main`） |

本地应用同等门槛再推送。

## vendor SQLite

- 路径：`vendor/sqlite/`
- `build.zig` 编为静态库并 `link_libc`
- migration 经 `addAnonymousImport("migration_0001", …)` 嵌入
- Dashboard HTML 经 `addAnonymousImport("dashboard_index_html", …)` 嵌入 **exe** 模块

新增 migration：加 SQL 文件 + 改 `build.zig` import + `db.zig` migrations 数组。

## 测试层次（目标金字塔）

| 层 | 现状 |
|---|---|
| Unit | 主力量；`zig build test` |
| Replay | 状态引擎确定性 |
| Property | 风险不变量逐步加强 |
| Integration | 需 Demo 凭证 |
| Fault / Soak | 需环境与时间 |

不要用 mock 掉 Risk Kernel 的「假绿」集成代替内核 property。

## 调试技巧

- 有界运行：`--ticks N` 避免手动杀进程
- 临时 DB：`/tmp/...` + 跑完删除
- 单测：`zig build test --summary all` 后按失败测试名定位文件
- 注意 0.16：**顶层函数名不要与局部变量同名**（shadowing 是编译错误）
