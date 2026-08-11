# 故障排查

按「先安全、后功能」顺序：确保不会错误增仓，再修观察面。

## 启动失败

### `FATAL config`

| 可能原因 | 处理 |
|---|---|
| TOML 语法错误 | 用编辑器 / `taplo` 校验 |
| `web.bind` 不是 `127.0.0.1:port` | 改回 loopback |
| `poll_interval_ms < 200` | 提高间隔 |
| `initial_capital` ≤ 0 | 设正数 |
| 路径无读权限 | 检查用户与 SELinux/AppArmor |

```bash
alphabound --config /path/to.toml --self-check
```

### `FATAL db open`

- 父目录不存在或不可写 → `mkdir` + `chown alphabound`
- 磁盘满 → 腾挪 / 扩容；不要删 WAL 凑合
- 文件损坏 → **禁止**静默新建空库继续 live 交易；走备份恢复（见 [运维](operations.md)）

### `FATAL web listen` / `[web] server stopped: AddressInUse`

- 端口占用：`lsof -nP -iTCP:18180 -sTCP:LISTEN`（或配置里的 port）
- 本机 `18080` 常被其他桌面工具占用 → `config/local.toml` 默认改用 **18180**
- 改 `[web].bind = "127.0.0.1:<空闲端口>"` 后重启
- 权限或 bind 地址被改坏（只能 loopback / 容器 `0.0.0.0`）
- **注意**：web 线程 listen 失败时 shadow 行情环仍可继续；只是 Dashboard 不可用

## 连接与 READY

### `[connect] unreachable`

- 出网 / DNS / 代理
- OKX 地域限制 → 换 Region 或合规网络路径
- `rest_url` 配错

shadow 在连接失败时**不会**假装 READY 去交易。

### `private balance FAILED: ip_whitelist`

OKX 返回 `50110`：当前公网 IP 不在该 API Key 白名单。

```bash
curl -sS https://api.ipify.org; echo
# 在 OKX → API → 编辑 Key → IP 白名单中加入上述地址
# 建议：只读权限 Key，专用于 shadow/Gate1 对账
```

签名与 passphrase 已通过（否则会是 `invalid_sign` / `invalid_passphrase`）。shadow **仍会**用公共行情 + 模拟资金进入 READY；仅私有对账未通。

### `OKX credentials absent` 但已 source secrets

- passphrase 含 `&` 等字符时必须用 `./scripts/load-okx-keychain.sh` 生成的 **quoted** `secrets.env`，或 export 时加引号
- 变量名必须是 `OKX_API_KEY` / `OKX_API_SECRET` / `OKX_API_PASSPHRASE`（不是 `OKX_SECRET_KEY`）
- 确认子进程继承环境：`python3 -c 'import os; print(len(os.environ.get("OKX_API_KEY","")))'`

### `/health/ready` 一直 503

- 仍在 BOOTING/CONNECTING/RECONCILING
- 对账未 clean（demo/live 私有数据不一致）
- 看 journal：`journalctl -u alphabound -n 100 --no-pager`

### live 探针绿但模式是 EXIT_ONLY

常见于：行情 freshness 不足、`unresolved_orders`、启动 fail-closed。这是**保护**，不是单纯 bug。查：

```bash
curl -s http://127.0.0.1:8080/api/v1/state | jq '{risk_mode,reconciled,drawdown}'
```

## 数据与审计

### 事件不涨

- 进程是否真在跑
- `[journal] append failed` → 磁盘、权限、SQLite busy
- 直接查库：

```bash
sqlite3 /var/lib/alphabound/trading.db "SELECT seq,type,ts FROM events ORDER BY seq DESC LIMIT 20;"
```

### Dashboard 空白 / 不是 HTML

- 是否打到错误端口
- 旧二进制未嵌入 dashboard（升级后确认 `GET /` Content-Type 含 `text/html`）
- 浏览器控制台看 `/api/v1/state` 是否 CORS/连接失败（本机不应有 CORS 问题）

## 风险模式异常

| 现象 | 优先动作 |
|---|---|
| 突然 FLATTENING | 检查回撤是否触界；**不要**为了「救策略」改 max_drawdown 热重启乱调 |
| HALTED | 人工审查事件与持仓；恢复交易走发版/变更流程，无自动爬出 |
| 频繁 EXIT_ONLY | 网络抖动、时钟、WS 断线；修基础设施，而非放松 freshness |

## 性能

- CPU 打满：确认没有过密 `poll_interval_ms`；单写者状态机本就单线程热点
- RSS 爬升：抓 24h 曲线；怀疑泄漏时用固定 `--ticks` 对比重启基线
- 磁盘：WAL 过大时检查是否有长事务/备份锁

## 安全事件

若怀疑密钥泄漏：

1. **立刻**在 OKX 作废 API Key
2. 停 live / 切 EXIT 能力优先的维护窗口
3. 轮换 `secrets.env`，限制新 Key 权限与 IP
4. 审计 `events` / 交易所成交是否与 `decision_id` 可对上

## 收集诊断包（脱敏）

```bash
alphabound --version
cat /etc/alphabound/alphabound.toml          # 无密钥
curl -s localhost:8080/api/v1/state
curl -s localhost:8080/health/ready
journalctl -u alphabound -n 200 --no-pager
sqlite3 /var/lib/alphabound/trading.db "PRAGMA integrity_check;"
# 不要打包 secrets.env；日志已依赖 redaction，仍人工扫一眼
```

## 测试侧回归

改代码后：

```bash
zig build test --summary all
./scripts/build-docs.sh    # 若动了手册链接
```

CI 应保持绿：`zig build` + `zig build test` + `--self-check` + `mdbook build`。


## 私有 WebSocket 探测

默认**不**在启动时做 OKX private WS login 探测（避免慢 DNS/IPv6 与实验性传输路径拖慢 READY）。

- Gate 1 账户可见性依赖 **REST** `GET /api/v5/account/balance` 周期对账（已验证）。
- 需要尝试 private WS 时：`export ALPHABOUND_PRIVATE_WS=1` 后启动。
- 若日志出现 `login_read_failed` 且 detail 含 close `881a0fa4…`（OKX 4004 / No data received）：
  TLS upgrade(101) 已成功，但 login 帧在 `std.http.Client` 原始连接路径上仍不稳定；协议编解码单测仍有效，长连修复前请继续依赖 REST。
