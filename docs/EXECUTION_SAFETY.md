# 执行链安全与快慢分离(2026-10 缺陷审计修复)

本文说明 2026-10-04 缺陷分析(基线 `d0c2fe8`)之后的执行链设计、各缺陷的修复位置/测试,以及**仍然存在的限制**。
验收条目见 [ACCEPTANCE_MATRIX.md](ACCEPTANCE_MATRIX.md) 的 §I(AC-EX1..12)。

## 线程与所有权

```
                ┌────────────────────────── 风险循环(主线程) ──────────────────────────┐
 本机 CLI ───▶  │ 行情/对账/clock_tick/管理指令/看板缓存;唯一的引擎(state.Engine)写者   │
                └──▲─────────────────────────▲──────────────────────────▲────────────────┘
        submit(消息) │ Service(对账)           │ Mailbox(作业)             │ 快照(只读)
                ┌────┴────────┐       ┌────────┴─────────┐       ┌────────┴────────┐
                │ 执行 lane    │◀─────▶│  思考 lane        │       │  Web 线程        │
                │ 全部订单工作 │ Reply │ 模型/工具/反思/复盘│       │  读缓存          │
                │ 独立 HTTP+DB │       │ 独立 HTTP+DB      │       └─────────────────┘
                └──────────────┘       └──────────────────┘
```

* **风险循环**(`main.zig`)每 ≈40ms 一圈:`drainInbox` → 对账 Service → 调度反馈 → lane 状态 → 管理指令;行情轮询/看板刷新仍按 `poll_interval_ms` 节奏。它从不等待模型,也从不等待订单。
* **`state.Engine`**:所有者线程直接 `apply`;其它线程只能 `submit`(有界收件箱,溢出时 fail-closed 置订单不确定)并读取加锁快照。非所有者调用 `apply` 不会就地修改:消息被转交给所有者排队应用。
* **执行 lane**(`execution/exec_lane.zig`):唯一接触交易端点的线程,串行处理 agent 再平衡、operator target-weight、flatten 驱动、cancel-all、重启恢复;有界队列(8),紧急作业插队;自有 HTTP 客户端与 SQLite 连接。需要权威账户时通过 `lanes.Service` 请求风险循环执行对账(带超时)。
* **思考 lane**(`main.zig` `ThinkLane`):模型调用、工具、反思、周期/手动复盘与记忆索引;结果以调度反馈(`ThinkFeedback`)和执行作业回到风险循环;自有 HTTP 客户端与 SQLite 连接。
* **取消**:风险循环每圈设置 `agent_blocked`(暂停 / FLATTENING / HALTED / 未完成恢复);执行中的 agent 作业撤掉并**确认**挂单后返回,排队的 agent 作业自行放弃;超过 60s 的排队作业被丢弃,不会迟到执行。
* **关闭**:先置 `agent_blocked`(在途挂单撤销并确认),再带超时地 join 两个 lane。

## 缺陷 → 修复位置 → 测试

| 缺陷 | 修复 | 回归测试(先红后绿) |
|---|---|---|
| P0-1 清仓被边界准入拒绝 | `admission.zig` `admitExit`(只减仓、卖量≤可用 BTC、要求权威已对账账户/新鲜/无未决订单);`operator.zig` `driveFlatten`/`runExit`;`planner.zig` `max_sell_qty` | `admission.zig`(复现用例 + property 3000 例)、`exec_chain_tests.zig` `P0-1: …`×5 |
| P0-2 慢模型/订单等待阻塞主循环 | 见上图;`exec_lane.zig`、`ThinkLane`、`lanes.zig`、`state.zig` 收件箱 | `exec_lane_tests.zig`(模型挂起时 flatten 完成、限价单挂单不阻塞且被阻断时撤销、过期作业丢弃、队列有界)、`state.zig` 并发测试;E2E `slow_model` |
| P1-1 POST 自动重试 | `rest.zig`:仅 GET 重试;`demo_runner.zig` 未知结果→UNKNOWN→查询 | `P1-1: …`;E2E `lost_response` |
| P1-2 空列表=已撤单 | `rest.lookupOrder`(found/absent/failed)与 `classifyPlaceResponse`;`absent` 只在恢复路径满足宽限期+挂单列表完整后才判定 | `P1-2: …`×3、`rest.zig` 解析测试 |
| P1-3 部分成交撤单未确认/不重新准入 | `cancelAndConfirm`;逐腿 `shadowAdmit`/`exitAdmit`、方向翻转拒绝、`openOrderCount` 阻断 | `P1-3: …`×2;E2E `cancel_rejected` |
| P1-4 本地成交按委托量且刷新新鲜度 | `projectFill`(实际成交量/均价/币种手续费)+ `Message.account_projection`(不刷新新鲜度、不推进 HWM、`account_projected` 使准入拒绝) | `P1-4: …`、`state.zig` 投影测试 |
| P1-5 意图落库失败仍下单 | `persistOrder` 失败→`intent_persist_failed`、`ledger_ok=false` | `P1-5: …`×2 |
| P1-6 重启不恢复订单 | `recoverOrders`;启动即置未决,恢复完成才放开;未决时每 10s 重试 | `P1-6: …`×7;E2E `restart_recovery` |
| P1-7 cancel-all 清除不确定性 | `cancelAllVerified`:列表→逐单撤销+查询确认→再次列表+账本核验,才清除 | `P1-7: …`×4 |
| P1-8 累计成交首写后冻结 | `FillsRepo.applyCumulative`(增量行,重复/乱序不重复计入) | `storage/db.zig`、`P1-8: …` |
| 旧提案自动换绑 | `agent/validity.zig` 锚点 + `main.zig` 作废/重做;落库 `decision_snapshot`/`execution_snapshot` | `validity.zig` 测试;`config.zig` 键测试 |
| (E2E 发现)多连接 BUSY_SNAPSHOT | `KvRepo.getChecked`/`applyCumulative` 读后复位 | `storage/db.zig` 两连接测试 |
| (评审)非本进程挂单阻断退出 | `foreign_pending` 独立于 `unresolved_orders`:只关闭新增风险,`exitView` 只看本地账本;cancel-all 对无 clOrdId 订单按 `ordId` 撤销并重新列表核验 | `review: …`×3、E2E `foreign_order_exit` |
| (评审)cancel-all 后 agent 永久被封 | cancel-all 之后执行 lane 重新跑一遍恢复;主循环在恢复未完成/账本不健康/存在外部挂单时周期性(10s/60s)重提恢复 | `exec_lane_tests.zig` `review: cancel-all after a blocked recovery …` |
| (评审)`ledger_ok` 不自愈 | 任一次成功落库或恢复中的写探针(`probeWritable`)即恢复 | `review: a transient ledger write failure heals …` |
| (评审)不确定 sCode 被当作拒绝 | `definitiveRejectionCode`:仅 51xxx 规则/余额类与网关预匹配拒绝为确定;50004/50013/51149/未识别码为 UNKNOWN | `classifyPlaceResponse never turns a timeout-class sCode …` |
| (#65)风险模式 NORMAL↔EXIT_ONLY 抖动 | 行情新鲜度改按**本地接收时钟**判定(`Message.market_tick.seen_ms`,由 poller/operator 打戳),TTL 由轮询间隔派生(`FreshnessState.marketTtlFor`,三次轮询、下限 10s);`/api/v1/state` 暴露 `market_last_ms`/`market_ttl_ms`/`market_age_ms` | `market freshness uses local receipt time, not the venue timestamp`、`market ttl derives from the poll interval with a floor` |

## 订单账本与未决状态

`unresolved_orders` 现在**镜像本进程账本**(`foreign_pending` 另行表示非本进程挂单,只拦新增风险):只要 `orders` 表有 PLANNED/SUBMITTED/ACKNOWLEDGED/PARTIAL/UNKNOWN 行,或账本不可读,就保持为真;只有终态(FILLED/CANCELED/REJECTED)才会放行。
`OrdersRepo.upsert` 不会把终态行改回非终态。`/api/v1/state` 暴露 `unresolved_orders`、`account_projected`、`ledger_ok`。

## 剩余限制(未做或有意取舍)

1. **未在真实 OKX 上验证。** 所有演练使用本地合成场馆(`src/testing/fake_okx.zig`、`tools/e2e/fake_services.py`)。业务码映射(51603 订单不存在、51400/51401/51402 撤单失败类、50011 限频等)依据 OKX v5 公开文档,上线前应在 demo(`OKX_SIMULATED=1`)环境用真实回包复核。
2. **退出需要权威账户。** 为满足“账户与订单可核验”,`admitExit` 在账户过期/仅有本地推算时拒绝卖出;私有 REST 长时间不可用且价格暴跌时,不会盲卖,需要运维介入(场馆侧手动或恢复连接)。
3. **非本进程的挂单**(无 `clOrdId` 或不在账本)使恢复保持“未完成”并关闭新增风险(`foreign_pending`),但**不阻断退出**。运维执行 `--control cancel-all` 可清除(无 clOrdId 者按 `ordId` 撤销,并以场馆重新列表核验)。恢复一次最多处理 64 条账本行/32 条场馆挂单;超出视为未完成。
4. **逐笔成交(私有 WS)尚未接入账本。** 现在累计成交以增量行入账;将来加入逐笔成交时必须以 `fill_id=tradeId` 入账并对照 `applyCumulative` 的累计量去重,不得并存两套求和。
5. **作废的提案最多重做一次**;再次作废则放弃本轮(下一调度周期重新决策)。风险模式变化(含启动初期 EXIT_ONLY→NORMAL)也会使提案作废。
6. **执行 lane 不拉行情**:它依赖独立网络采集 lane 和状态写者发布的快照；行情过期时准入拒绝，不自行换绑旧决策。
7. 看板 `/api/v1/orders` 等缓存由风险循环在 lane 标记“脏”后刷新,延迟 ≤ 一圈(≈40ms)+ 刷新耗时。
8. `max_drawdown`、`exit_reserve` 等风险参数未放宽。暂停/HALTED 的持久化见下节；交易模式、凭据和资金不由此次修复自动变更。

## 后续安全补强

- **持久化安全锁**：`admin/safety.zig` 将暂停、风险模式和干净退出标记存入 `runtime_kv`。在启动任何执行 worker 前置为非干净状态；管理指令的状态文件确认在安全锁落库后才写出。HALTED/FLATTENING 跨重启保留，正常健康信号不会解除它们。
- **非干净重启**：先恢复订单和风险监测，但暂停自主决策，必须由操作员核对后显式 `resume`。首次升级已有历史数据库、尚无安全检查点时同样暂停；从历史事件恢复显式的 halt/flatten 锁。**不能用重启代替风险解锁。** 这改变了旧版“重启后自动恢复自主决策”的行为。
- **权限验证**：真实交易必须证明具有 read+trade 且无 withdraw 权限；权限接口错误、无法解析或缺失必要权限时拒绝启动，不再仅打印警告后继续。
- **整值脱敏**：JSON 敏感字段（包含嵌套对象、转义键）整体替换；自由文本保留完整 Bearer/引号值边界。结构损坏、深度/内存/输出上限触发时丢弃内容，不输出部分遮罩的数据。
- **HTTP 有界并发**：最多 8 个在途连接，每个请求从读头到写响应具有 5 秒总期限；超过期限取消并等待请求工作退出。缓存回调和鉴权状态仍在独立路由锁下串行操作；等待客户端网络不持有此锁。
- **真实 CI**：构建、单元/执行链/并发测试、合成服务 daemon 故障演练和 MCP 测试实际执行，不再用输出提示文本充当通过状态。

- **网络采集隔离**：`exchange/poller.zig` 的行情、账户、展示三条有界任务分别持有 HTTP client，不持有数据库句柄、不修改引擎。状态写者每圈推进时钟、消费结果；账户请求以 ticket 回传给执行 lane。展示外部服务挂起不拖住行情。REST 每次请求有 5 秒取消式期限，GET 最多重试一次，POST 不重发；任务退出会取消并 join，不遗留超时线程。行情积压合并为最新样本。私有 WS 仍是启动时可选探针，不在关键循环周期性重探。
- **资金差异隔离**：`core/accounting.zig` 用已确认成交的数量、成交价、费用币种解释现金/BTC 变化，不用当前市场价格猜测转账。检查点与对账提交同事务；未解释差异不推进基线，重复轮询/重启不会自动消除。`accounting_ok=false` 阻止增仓和 HWM 上调，但保留满足账户/订单条件的紧急减险。自动路径不再生成资金流或修改历史 HWM/BH 基准。
- **原子准入审计**：首腿也重新计算准入，且不超过调用者已批准的目标上限。`ORDER_INTENT` 保存快照版本、仓位、价格、风险参数、准入地板/压力净值、方向/数量和配置戳，与 PLANNED 行同事务提交后才发请求。SQLite 使用 WAL + synchronous=FULL。事务内不等待状态写者；失败全部回滚并关闭执行出口。
- **退出不受策略交易下限阻挡**：保留原场馆最小交易额，紧急退出使用场馆限制而不是策略抬高的最小名义额。

新增 E2E：`safety_restart`、`slow_http`、`network_stall`（行情/账户 socket 同时挂起时控制与时钟仍推进）、`accounting_quarantine`（未解释损失不能改写 HWM）。整链测试还注入准入事件写入失败，证明意图回滚且零下单；验证准入证明先于 ACK 持久化。

### 资金流能力边界与部署

这不是自动识别转账的另一种启发式：**本版本不自动确认外部入金/出金**。真实外部资金变化必须依据交易所账单独立核验，再通过受审核的基准迁移/导入流程处理；当前没有自动清除隔离或自动重置 HWM 的入口。`resume` 也不能绕过 `accounting_ok`。未解释差异期间，原始余额可展示，但不得将收益/BH 对比当作已完成资金流调整的绩效结果。历史数据不在发布时回算或覆盖。

首次升级历史库、非干净重启以及发布/回滚均维持自主交易暂停；部署验证 health/system/state/decisions 后，由维护者核对账户、未决订单和账单再显式恢复。安装脚本会在切换前检查配置，并停止旧进程后排入 pause；回滚旧二进制也如此，不能借回滚绕过暂停。真实场馆验收的限制仍见本页“剩余限制”，合成测试不等于收益或实盘无故障保证。

## 演练与复现

```bash
zig build test --summary all            # 单元/整链/跨线程
( cd tools/alphabound-mcp && npm test )  # MCP(只读)
zig build && python3 tools/e2e/run_e2e.py   # 真实二进制 × 合成 OKX 模拟盘/模型(无外部凭据)
# 对比基线:git worktree add /tmp/ab-base d0c2fe8 && (cd /tmp/ab-base && zig build) \
#   && python3 tools/e2e/run_e2e.py --bin /tmp/ab-base/zig-out/bin/alphabound
```
