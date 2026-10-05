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

## 订单账本与未决状态

`unresolved_orders` 现在**镜像本进程账本**(`foreign_pending` 另行表示非本进程挂单,只拦新增风险):只要 `orders` 表有 PLANNED/SUBMITTED/ACKNOWLEDGED/PARTIAL/UNKNOWN 行,或账本不可读,就保持为真;只有终态(FILLED/CANCELED/REJECTED)才会放行。
`OrdersRepo.upsert` 不会把终态行改回非终态。`/api/v1/state` 暴露 `unresolved_orders`、`account_projected`、`ledger_ok`。

## 剩余限制(未做或有意取舍)

1. **未在真实 OKX 上验证。** 所有演练使用本地合成场馆(`src/testing/fake_okx.zig`、`tools/e2e/fake_services.py`)。业务码映射(51603 订单不存在、51400/51401/51402 撤单失败类、50011 限频等)依据 OKX v5 公开文档,上线前应在 demo(`OKX_SIMULATED=1`)环境用真实回包复核。
2. **退出需要权威账户。** 为满足“账户与订单可核验”,`admitExit` 在账户过期/仅有本地推算时拒绝卖出;私有 REST 长时间不可用且价格暴跌时,不会盲卖,需要运维介入(场馆侧手动或恢复连接)。
3. **非本进程的挂单**(无 `clOrdId` 或不在账本)使恢复保持“未完成”并关闭新增风险(`foreign_pending`),但**不阻断退出**。运维执行 `--control cancel-all` 可清除(无 clOrdId 者按 `ordId` 撤销,并以场馆重新列表核验)。恢复一次最多处理 64 条账本行/32 条场馆挂单;超出视为未完成。
4. **逐笔成交(私有 WS)尚未接入账本。** 现在累计成交以增量行入账;将来加入逐笔成交时必须以 `fill_id=tradeId` 入账并对照 `applyCumulative` 的累计量去重,不得并存两套求和。
5. **作废的提案最多重做一次**;再次作废则放弃本轮(下一调度周期重新决策)。风险模式变化(含启动初期 EXIT_ONLY→NORMAL)也会使提案作废。
6. **执行 lane 不拉行情**:它依赖风险循环的行情轮询;行情过期时准入拒绝,而不是自己拉取并写入引擎。
7. 看板 `/api/v1/orders` 等缓存由风险循环在 lane 标记“脏”后刷新,延迟 ≤ 一圈(≈40ms)+ 刷新耗时。
8. `HALTED` 后的恢复、`max_drawdown`、`exit_reserve` 等风控参数**未改动**;交易模式/凭据/资金均未触碰。

## 演练与复现

```bash
zig build test --summary all            # 单元/整链/跨线程
( cd tools/alphabound-mcp && npm test )  # MCP(只读)
zig build && python3 tools/e2e/run_e2e.py   # 真实二进制 × 合成 OKX 模拟盘/模型(无外部凭据)
# 对比基线:git worktree add /tmp/ab-base d0c2fe8 && (cd /tmp/ab-base && zig build) \
#   && python3 tools/e2e/run_e2e.py --bin /tmp/ab-base/zig-out/bin/alphabound
```
