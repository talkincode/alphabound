//! AlphaBound daemon entrypoint (§7.1 lifecycle).
//!
//! BOOTING    — parse args, load config, open DB, restore HWM
//! CONNECTING — reach OKX REST (public endpoints)
//! RECONCILING — private balance probe when OKX_* env keys exist;
//!               engine cash stays simulated in shadow (no orders)
//! READY      — web API serving; shadow loop feeds the state engine
//!
//! Credentials (§8.1): OKX_* and LLM_* from environment only — never TOML.
//! Optional OKX_SIMULATED=1 for demo keys.

const std = @import("std");
const ab = @import("alphabound");

const version_string = "0.1.0";

const dashboard_html: []const u8 = @embedFile("dashboard_index_html");
const default_system_prompt: []const u8 = @embedFile("agent_system_prompt");
const default_reflection_prompt: []const u8 = @embedFile("agent_reflection_prompt");

fn nowMs() i64 {
    return ab.clock.SystemClock.clock().wallMs();
}

var shutdown_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

const OkxEnvCreds = struct {
    api_key: []const u8,
    secret_key: []const u8,
    passphrase: []const u8,
    simulated: bool,
    /// Explicit operator opt-in: real (small sub-account) keys may execute
    /// in demo mode. Never implied; OKX_REAL_MONEY_OK=1 only.
    real_money_ok: bool,

    fn load(map: *const std.process.Environ.Map) ?OkxEnvCreds {
        const key = map.get("OKX_API_KEY") orelse return null;
        const secret = map.get("OKX_API_SECRET") orelse return null;
        const pass = map.get("OKX_API_PASSPHRASE") orelse return null;
        if (key.len == 0 or secret.len == 0 or pass.len == 0) return null;
        const sim_raw = map.get("OKX_SIMULATED") orelse "";
        const simulated = std.mem.eql(u8, sim_raw, "1") or std.mem.eql(u8, sim_raw, "true");
        const real_raw = map.get("OKX_REAL_MONEY_OK") orelse "";
        const real_money_ok = std.mem.eql(u8, real_raw, "1") or std.mem.eql(u8, real_raw, "true");
        return .{
            .api_key = key,
            .secret_key = secret,
            .passphrase = pass,
            .simulated = simulated,
            .real_money_ok = real_money_ok,
        };
    }

    fn asAuth(self: OkxEnvCreds) ab.okx_auth.Credentials {
        return .{
            .api_key = self.api_key,
            .secret_key = self.secret_key,
            .passphrase = self.passphrase,
        };
    }
};

/// OpenAI-compatible LLM settings. Key never leaves this process layer.
const LlmEnv = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,

    fn load(map: *const std.process.Environ.Map, cfg: *const ab.config.Config) ?LlmEnv {
        const key = firstEnv(map, &.{
            "LLM_API_KEY",
            "OPENAI_API_KEY",
            "AZURE_OPENAI_API_KEY",
        }) orelse return null;
        if (key.len == 0) return null;
        const url = firstEnv(map, &.{
            "LLM_API_URL",
            "OPENAI_BASE_URL",
            "OPENAI_API_BASE",
            "AZURE_OPENAI_API_URL",
            "AZURE_OPENAI_ENDPOINT",
        }) orelse cfg.agent_base_url;
        const model = firstEnv(map, &.{
            "LLM_MODEL",
            "OPENAI_MODEL",
            "AZURE_OPENAI_DEPLOYMENT",
            "AZURE_OPENAI_MODEL",
        }) orelse cfg.agent_model;
        if (url.len == 0 or model.len == 0) return null;
        return .{ .api_key = key, .base_url = url, .model = model };
    }
};

fn firstEnv(map: *const std.process.Environ.Map, names: []const []const u8) ?[]const u8 {
    for (names) |n| {
        if (map.get(n)) |v| {
            if (v.len > 0) return v;
        }
    }
    return null;
}

fn envGetTruthy(map: *const std.process.Environ.Map, name: []const u8) bool {
    const v = map.get(name) orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
}

const CliArgs = struct {
    config_path: []const u8 = "config/alphabound.toml",
    self_check: bool = false,
    show_version: bool = false,
    /// Bounded run for CI/manual verification; 0 = run until signal.
    max_ticks: u64 = 0,
    /// Force one agent decision shortly after READY (shadow audit only).
    agent_once: bool = false,
    /// Print agent_runs / tool_calls validity stats and exit.
    agent_stats: bool = false,
    /// One-shot local admin command: pause|resume|reconcile|cancel-all|flatten|shutdown|status.
    control_cmd: ?[]const u8 = null,
    /// Read-only backup/DB verification for restore drills (AC-OPS4).
    verify_db_path: ?[]const u8 = null,
};

fn parseArgs(args: std.process.Args) !CliArgs {
    var out = CliArgs{};
    var it = std.process.Args.Iterator.init(args);
    defer it.deinit();
    _ = it.next(); // argv0
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            out.config_path = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--self-check")) {
            out.self_check = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            out.show_version = true;
        } else if (std.mem.eql(u8, arg, "--ticks")) {
            const v = it.next() orelse return error.MissingValue;
            out.max_ticks = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--agent-once")) {
            out.agent_once = true;
        } else if (std.mem.eql(u8, arg, "--agent-stats")) {
            out.agent_stats = true;
        } else if (std.mem.eql(u8, arg, "--control")) {
            out.control_cmd = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--verify-db")) {
            out.verify_db_path = it.next() orelse return error.MissingValue;
        } else {
            return error.UnknownFlag;
        }
    }
    return out;
}

const WebState = struct {
    /// Seqlock: odd = write in progress. Single writer (core loop), many
    /// readers (web connections) — no blocking, no Io dependency.
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    snapshot: ab.state.PortfolioState = .{},
    ready: bool = false,
    config_hash: [71]u8 = @splat(0),
    /// Pre-rendered JSON blobs (owned buffers inside WebState).
    agent_runs_buf: [24576]u8 = undefined,
    agent_runs_len: usize = 2,
    equity_buf: [8192]u8 = undefined,
    equity_len: usize = 2,
    events_buf: [12288]u8 = undefined,
    events_len: usize = 2,
    shadow_buf: [512]u8 = undefined,
    shadow_len: usize = 2,
    /// Multi-timeframe candles JSON (分时/1m…1D); sized for ~1k bars total.
    candles_buf: [131072]u8 = undefined,
    candles_len: usize = 2,
    memories_buf: [8192]u8 = undefined,
    memories_len: usize = 2,
    system_buf: [4096]u8 = undefined,
    system_len: usize = 2,
    decisions_buf: [49152]u8 = undefined,
    decisions_len: usize = 2,
    /// Bundle: {"orders":[...],"fills":[...]}.
    orders_buf: [24576]u8 = undefined,
    orders_len: usize = 2,

    fn initEmpty(self: *WebState) void {
        @memcpy(self.agent_runs_buf[0..2], "[]");
        self.agent_runs_len = 2;
        @memcpy(self.equity_buf[0..2], "[]");
        self.equity_len = 2;
        @memcpy(self.events_buf[0..2], "[]");
        self.events_len = 2;
        @memcpy(self.shadow_buf[0..2], "{}");
        self.shadow_len = 2;
        @memcpy(self.candles_buf[0..2], "[]");
        self.candles_len = 2;
        @memcpy(self.memories_buf[0..2], "[]");
        self.memories_len = 2;
        @memcpy(self.system_buf[0..2], "{}");
        self.system_len = 2;
        @memcpy(self.decisions_buf[0..2], "[]");
        self.decisions_len = 2;
        const empty_orders = "{\"orders\":[],\"fills\":[]}";
        @memcpy(self.orders_buf[0..empty_orders.len], empty_orders);
        self.orders_len = empty_orders.len;
    }

    fn contextFn(userdata: ?*anyopaque) ab.web.Context {
        // Process-static copies so returned Context slices stay stable across
        // handle()/copyBody even if the core loop mutates WebState mid-request.
        // Safe: web accept loop is single-threaded.
        const Tls = struct {
            var agent: [24576]u8 = undefined;
            var equity: [8192]u8 = undefined;
            var events: [12288]u8 = undefined;
            var shadow: [512]u8 = undefined;
            var candles: [131072]u8 = undefined;
            var memories: [8192]u8 = undefined;
            var system: [4096]u8 = undefined;
            var decisions: [49152]u8 = undefined;
            var orders: [24576]u8 = undefined;
            var config_hash: [71]u8 = undefined;
            var agent_len: usize = 2;
            var equity_len: usize = 2;
            var events_len: usize = 2;
            var shadow_len: usize = 2;
            var candles_len: usize = 2;
            var memories_len: usize = 2;
            var system_len: usize = 2;
            var decisions_len: usize = 2;
            var orders_len: usize = 2;
        };
        const self: *WebState = @ptrCast(@alignCast(userdata.?));
        while (true) {
            const s1 = self.seq.load(.acquire);
            if (s1 % 2 == 1) {
                std.atomic.spinLoopHint();
                continue;
            }
            const snap = self.snapshot;
            const ready = self.ready;
            const al = self.agent_runs_len;
            const el = self.equity_len;
            const vl = self.events_len;
            const sl = self.shadow_len;
            const cl = self.candles_len;
            const ml = self.memories_len;
            const yl = self.system_len;
            const dl = self.decisions_len;
            const ol = self.orders_len;
            if (al > Tls.agent.len or el > Tls.equity.len or vl > Tls.events.len or sl > Tls.shadow.len or cl > Tls.candles.len or ml > Tls.memories.len or yl > Tls.system.len or dl > Tls.decisions.len or ol > Tls.orders.len) {
                std.atomic.spinLoopHint();
                continue;
            }
            @memcpy(Tls.agent[0..al], self.agent_runs_buf[0..al]);
            @memcpy(Tls.equity[0..el], self.equity_buf[0..el]);
            @memcpy(Tls.events[0..vl], self.events_buf[0..vl]);
            @memcpy(Tls.shadow[0..sl], self.shadow_buf[0..sl]);
            @memcpy(Tls.candles[0..cl], self.candles_buf[0..cl]);
            @memcpy(Tls.memories[0..ml], self.memories_buf[0..ml]);
            @memcpy(Tls.system[0..yl], self.system_buf[0..yl]);
            @memcpy(Tls.decisions[0..dl], self.decisions_buf[0..dl]);
            @memcpy(Tls.orders[0..ol], self.orders_buf[0..ol]);
            @memcpy(Tls.config_hash[0..], self.config_hash[0..]);
            Tls.agent_len = al;
            Tls.equity_len = el;
            Tls.events_len = vl;
            Tls.shadow_len = sl;
            Tls.candles_len = cl;
            Tls.memories_len = ml;
            Tls.system_len = yl;
            Tls.decisions_len = dl;
            Tls.orders_len = ol;
            const s2 = self.seq.load(.acquire);
            if (s1 == s2) {
                return .{
                    .snapshot = snap,
                    .ready = ready,
                    .software_version = version_string,
                    .config_hash = Tls.config_hash[0..],
                    .agent_runs_json = Tls.agent[0..Tls.agent_len],
                    .equity_json = Tls.equity[0..Tls.equity_len],
                    .events_json = Tls.events[0..Tls.events_len],
                    .shadow_json = Tls.shadow[0..Tls.shadow_len],
                    .candles_json = Tls.candles[0..Tls.candles_len],
                    .memories_json = Tls.memories[0..Tls.memories_len],
                    .system_json = Tls.system[0..Tls.system_len],
                    .decisions_json = Tls.decisions[0..Tls.decisions_len],
                    .orders_json = Tls.orders[0..Tls.orders_len],
                    .index_html = dashboard_html,
                };
            }
        }
    }

    fn update(self: *WebState, snap: ab.state.PortfolioState, ready: bool) void {
        _ = self.seq.fetchAdd(1, .acq_rel); // odd: writing
        self.snapshot = snap;
        self.ready = ready;
        _ = self.seq.fetchAdd(1, .release); // even: stable
    }

    fn setJson(self: *WebState, comptime which: enum { agent, equity, events, shadow, candles, memories, system, decisions, orders }, src: []const u8) void {
        _ = self.seq.fetchAdd(1, .acq_rel);
        switch (which) {
            .agent => {
                const n = @min(src.len, self.agent_runs_buf.len);
                @memcpy(self.agent_runs_buf[0..n], src[0..n]);
                self.agent_runs_len = n;
            },
            .equity => {
                const n = @min(src.len, self.equity_buf.len);
                @memcpy(self.equity_buf[0..n], src[0..n]);
                self.equity_len = n;
            },
            .events => {
                const n = @min(src.len, self.events_buf.len);
                @memcpy(self.events_buf[0..n], src[0..n]);
                self.events_len = n;
            },
            .shadow => {
                const n = @min(src.len, self.shadow_buf.len);
                @memcpy(self.shadow_buf[0..n], src[0..n]);
                self.shadow_len = n;
            },
            .candles => {
                const n = @min(src.len, self.candles_buf.len);
                @memcpy(self.candles_buf[0..n], src[0..n]);
                self.candles_len = n;
            },
            .memories => {
                const n = @min(src.len, self.memories_buf.len);
                @memcpy(self.memories_buf[0..n], src[0..n]);
                self.memories_len = n;
            },
            .system => {
                const n = @min(src.len, self.system_buf.len);
                @memcpy(self.system_buf[0..n], src[0..n]);
                self.system_len = n;
            },
            .decisions => {
                const n = @min(src.len, self.decisions_buf.len);
                @memcpy(self.decisions_buf[0..n], src[0..n]);
                self.decisions_len = n;
            },
            .orders => {
                const n = @min(src.len, self.orders_buf.len);
                @memcpy(self.orders_buf[0..n], src[0..n]);
                self.orders_len = n;
            },
        }
        _ = self.seq.fetchAdd(1, .release);
    }
};

/// Live connectivity/status snapshot for Dashboard「状态」页.
const RuntimeStatus = struct {
    okx_public: []const u8 = "unknown",
    okx_public_ms: i64 = 0,
    okx_public_detail: []const u8 = "",
    okx_private: []const u8 = "unknown",
    okx_private_ms: i64 = 0,
    okx_private_detail: []const u8 = "",
    llm: []const u8 = "unknown",
    llm_ms: i64 = 0,
    llm_detail: []const u8 = "",
    last_bid: []const u8 = "",
    egress_ip: []const u8 = "",
    egress_ip_ms: i64 = 0,
    /// FD7 disk free-space band for DB volume: ok | low | critical | unknown
    disk: []const u8 = "unknown",
    disk_free_bytes: u64 = 0,
    disk_ms: i64 = 0,
    // LLM token totals since process start
    llm_calls: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    acct_usdt: []const u8 = "",
    acct_btc: []const u8 = "",
    acct_usdt_buf: [48]u8 = undefined,
    acct_btc_buf: [48]u8 = undefined,
    last_decision: []const u8 = "",
    last_decision_buf: [96]u8 = undefined,
    last_decision_ms: i64 = 0,
    // Owned scratch for mutable strings
    bid_buf: [48]u8 = undefined,
    bid_len: usize = 0,
    pub_detail_buf: [96]u8 = undefined,
    pub_detail_len: usize = 0,
    priv_detail_buf: [96]u8 = undefined,
    priv_detail_len: usize = 0,
    llm_detail_buf: [96]u8 = undefined,
    llm_detail_len: usize = 0,
    egress_buf: [64]u8 = undefined,
    egress_len: usize = 0,

    fn addUsage(self: *RuntimeStatus, u: ab.openai.Usage) void {
        self.llm_calls += 1;
        self.prompt_tokens += u.prompt_tokens;
        self.completion_tokens += u.completion_tokens;
        self.total_tokens += if (u.total_tokens > 0) u.total_tokens else u.prompt_tokens + u.completion_tokens;
    }
    fn setBid(self: *RuntimeStatus, bid_txt: []const u8) void {
        const n = @min(bid_txt.len, self.bid_buf.len);
        @memcpy(self.bid_buf[0..n], bid_txt[0..n]);
        self.bid_len = n;
        self.last_bid = self.bid_buf[0..self.bid_len];
    }
    fn setPub(self: *RuntimeStatus, status: []const u8, detail: []const u8) void {
        self.okx_public = status;
        self.okx_public_ms = nowMs();
        const n = @min(detail.len, self.pub_detail_buf.len);
        @memcpy(self.pub_detail_buf[0..n], detail[0..n]);
        self.pub_detail_len = n;
        self.okx_public_detail = self.pub_detail_buf[0..self.pub_detail_len];
    }
    fn setPriv(self: *RuntimeStatus, status: []const u8, detail: []const u8) void {
        self.okx_private = status;
        self.okx_private_ms = nowMs();
        const n = @min(detail.len, self.priv_detail_buf.len);
        @memcpy(self.priv_detail_buf[0..n], detail[0..n]);
        self.priv_detail_len = n;
        self.okx_private_detail = self.priv_detail_buf[0..self.priv_detail_len];
    }
    fn setLlm(self: *RuntimeStatus, status: []const u8, detail: []const u8) void {
        self.llm = status;
        self.llm_ms = nowMs();
        const n = @min(detail.len, self.llm_detail_buf.len);
        @memcpy(self.llm_detail_buf[0..n], detail[0..n]);
        self.llm_detail_len = n;
        self.llm_detail = self.llm_detail_buf[0..self.llm_detail_len];
    }
    fn setAccount(self: *RuntimeStatus, usdt: []const u8, btc: []const u8) void {
        var n = @min(usdt.len, self.acct_usdt_buf.len);
        @memcpy(self.acct_usdt_buf[0..n], usdt[0..n]);
        self.acct_usdt = self.acct_usdt_buf[0..n];
        n = @min(btc.len, self.acct_btc_buf.len);
        @memcpy(self.acct_btc_buf[0..n], btc[0..n]);
        self.acct_btc = self.acct_btc_buf[0..n];
    }
    fn setLastDecision(self: *RuntimeStatus, text: []const u8) void {
        const n = @min(text.len, self.last_decision_buf.len);
        @memcpy(self.last_decision_buf[0..n], text[0..n]);
        self.last_decision = self.last_decision_buf[0..n];
        self.last_decision_ms = nowMs();
    }
    fn setEgress(self: *RuntimeStatus, ip: []const u8) void {
        const n = @min(ip.len, self.egress_buf.len);
        @memcpy(self.egress_buf[0..n], ip[0..n]);
        self.egress_len = n;
        self.egress_ip = self.egress_buf[0..self.egress_len];
        self.egress_ip_ms = nowMs();
    }
    fn setDisk(self: *RuntimeStatus, band: []const u8, free_bytes: u64) void {
        self.disk = band;
        self.disk_free_bytes = free_bytes;
        self.disk_ms = nowMs();
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const cli = parseArgs(init.minimal.args) catch {
        std.debug.print(
            "usage: alphabound [--config PATH] [--self-check] [--version] [--ticks N] [--agent-once] [--agent-stats] [--control pause|resume|reconcile|cancel-all|flatten|shutdown|status] [--verify-db PATH]\n",
            .{},
        );
        return 2;
    };

    if (cli.show_version) {
        std.debug.print("alphabound {s}\n", .{version_string});
        return 0;
    }

    // Restore drill (AC-OPS4): verify a backup snapshot read-only and exit.
    // Deliberately before config load — drills run against bare .bak files.
    if (cli.verify_db_path) |vpath| return verifyDbSnapshot(vpath);

    // ---- BOOTING ---------------------------------------------------------
    std.debug.print("[boot] alphabound {s} loading {s}\n", .{ version_string, cli.config_path });

    var cfg = ab.config.loadFile(gpa, io, cli.config_path) catch |err| {
        std.debug.print("[boot] FATAL config: {t}\n", .{err});
        return 1;
    };
    defer cfg.deinit();

    // Local admin control is a one-shot CLI that never starts the daemon.
    if (cli.control_cmd) |cmd_name| {
        return runControlCli(io, cmd_name, cfg.db_path);
    }

    const okx_env = OkxEnvCreds.load(env);
    if (okx_env) |c| {
        std.debug.print(
            "[boot] OKX credentials present (key_len={d} secret_len={d} pass_len={d} simulated={})\n",
            .{ c.api_key.len, c.secret_key.len, c.passphrase.len, c.simulated },
        );
    } else {
        std.debug.print("[boot] OKX credentials absent — public market path only\n", .{});
    }

    const llm_env = LlmEnv.load(env, &cfg);
    if (llm_env) |l| {
        std.debug.print(
            "[boot] LLM credentials present (key_len={d} base_url={s} model={s} enabled={})\n",
            .{ l.api_key.len, l.base_url, l.model, cfg.agent_enabled },
        );
    } else {
        std.debug.print("[boot] LLM credentials absent — agent slow-loop idle\n", .{});
    }

    // Refuse live mode without keys (and refuse live entirely until Gate 4).
    if (cfg.mode == .live) {
        std.debug.print("[boot] FATAL mode=live is disabled until Gate 4; use shadow\n", .{});
        return 1;
    }
    if (cfg.mode == .demo and okx_env == null) {
        std.debug.print("[boot] FATAL mode=demo requires OKX_* credentials\n", .{});
        return 1;
    }
    if (cfg.mode == .demo and okx_env != null and !okx_env.?.simulated and !okx_env.?.real_money_ok) {
        // Demo trading needs an explicit venue: simulated keys, or a real
        // small sub-account with the operator's explicit opt-in.
        std.debug.print(
            "[boot] FATAL mode=demo needs OKX_SIMULATED=1 or OKX_REAL_MONEY_OK=1 (refusing implicit real keys)\n",
            .{},
        );
        return 1;
    }
    if (cfg.mode == .demo and okx_env != null and !okx_env.?.simulated and okx_env.?.real_money_ok) {
        std.debug.print(
            "[boot] *** REAL-MONEY EXECUTION AUTHORIZED (OKX_REAL_MONEY_OK=1) — small sub-account expected ***\n",
            .{},
        );
    }
    exec_venue_authorized = if (okx_env) |c| (c.simulated or c.real_money_ok) else false;

    var db_path_buf: [512:0]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&db_path_buf, "{s}", .{cfg.db_path}) catch return 1;

    // AC-FD8: if a DB file already exists and open fails, refuse boot — never
    // silently recreate an empty trading database over a corrupted file.
    const db_existed = blk: {
        std.Io.Dir.cwd().access(io, cfg.db_path, .{}) catch break :blk false;
        break :blk true;
    };

    // Ensure parent dir for relative local db paths exists is caller's job;
    // open fails clearly if missing.
    var db = ab.storage.Db.open(db_path) catch |err| {
        if (db_existed and ab.storage_policy.looksLikeCorruption(true, false)) {
            std.debug.print(
                "[boot] FATAL db open failed on existing file (refuse empty recreate) path={s} err={t} action={s}\n",
                .{ cfg.db_path, err, @tagName(ab.storage_policy.onCorruptOpen()) },
            );
            return 1;
        }
        std.debug.print("[boot] FATAL db open {s}: {t}\n", .{ cfg.db_path, err });
        return 1;
    };
    defer db.close();

    if (cli.agent_stats) {
        printAgentStats(&db);
        return 0;
    }

    if (cli.self_check) {
        std.debug.print(
            "[self-check] ok\n  config_hash:  {s}\n  instrument:   {s}\n  mode:         {t}\n  max_drawdown: {f}\n  db:           {s} (user_version {d})\n  web:          {s}\n  okx_keys:     {s}\n  agent:        enabled={} provider={s} model={s} base_url={s} llm_keys={s}\n  schedule:     base_ms={d} quiet_ms={d} min_ms={d} active_utc={s} price_move={f} dd_step={f} reflect_on_hold={}\n",
            .{
                cfg.hash(),
                cfg.instrument,
                cfg.mode,
                cfg.max_drawdown,
                cfg.db_path,
                ab.storage.Db.queryInt(&db, "PRAGMA user_version") catch -1,
                cfg.web_bind,
                if (okx_env != null) "present" else "absent",
                cfg.agent_enabled,
                cfg.agent_provider,
                if (llm_env) |l| l.model else cfg.agent_model,
                if (llm_env) |l| l.base_url else cfg.agent_base_url,
                if (llm_env != null) "present" else "absent",
                cfg.decision_interval_ms,
                cfg.decision_interval_quiet_ms,
                cfg.decision_min_interval_ms,
                if (cfg.active_hours_utc.len > 0) cfg.active_hours_utc else "always",
                cfg.event_price_move,
                cfg.event_drawdown_step,
                cfg.agent_llm_reflection_on_hold,
            },
        );

        // Optional private read-only probe when keys are loaded.
        if (okx_env) |c| {
            var okx_sc = ab.okx_rest.Client.init(gpa, io, cfg.rest_url, c.asAuth());
            defer okx_sc.deinit();
            okx_sc.simulated = c.simulated;
            const probe = probePrivateBalance(gpa, &okx_sc);
            switch (probe) {
                .ok => |b| std.debug.print(
                    "[self-check] private balance ok usdt={f} avail={f} btc={f}\n",
                    .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
                ),
                .err => |e| {
                    std.debug.print("[self-check] private balance FAILED: {s}\n", .{e});
                    if (std.mem.eql(u8, e, "ip_whitelist")) {
                        std.debug.print(
                            "[self-check] hint: add this machine's public IP to the OKX API key IP whitelist (read-only key is enough)\n",
                            .{},
                        );
                        // Signing reached OKX; policy block is ops, not a binary defect.
                    } else {
                        return 1;
                    }
                },
            }
        }
        return 0;
    }

    // Signal handlers for graceful shutdown (§7.4).
    const action = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);

    var engine = ab.state.Engine.init(.{
        .fee_rate = cfg.taker_fee_rate,
        .slippage_rate = cfg.slippage_rate,
    }, cfg.max_drawdown);

    var events_repo = try ab.storage.EventsRepo.init(&db);
    defer events_repo.deinit();
    var equity_repo = try ab.storage.EquityRepo.init(&db);
    defer equity_repo.deinit();
    var agent_runs = try ab.storage.AgentRunsRepo.init(&db);
    defer agent_runs.deinit();
    var tool_calls = try ab.storage.ToolCallsRepo.init(&db);
    defer tool_calls.deinit();
    var memories_repo = try ab.storage.MemoriesRepo.init(&db);
    defer memories_repo.deinit();
    var orders_repo = try ab.storage.OrdersRepo.init(&db);
    defer orders_repo.deinit();
    var fills_repo = try ab.storage.FillsRepo.init(&db);
    defer fills_repo.deinit();

    // In-process memory index rebuilt from SQLite latest versions.
    var mem_store = ab.memory.Store.init(gpa);
    defer mem_store.deinit();
    loadMemoriesFromDb(&memories_repo, &db, &mem_store);
    if (mem_store.count() == 0) {
        seedBootstrapMemories(gpa, &mem_store, &memories_repo, &events_repo, &engine, &cfg);
    }
    std.debug.print("[boot] memories loaded count={d}\n", .{mem_store.count()});

    // Restore HWM from durable storage (survives restarts, §5.1).
    {
        var hwm_buf: [64]u8 = undefined;
        if (equity_repo.latestHwm(&db, &hwm_buf)) |hwm_text| {
            const hwm = ab.decimal.Decimal.parse(hwm_text) catch ab.decimal.Decimal.zero;
            engine.restoreHwm(hwm);
            std.debug.print("[boot] restored HWM {f}\n", .{hwm});
        } else |_| {
            std.debug.print("[boot] no prior HWM — fresh start\n", .{});
        }
    }

    var web_state = WebState{};
    web_state.initEmpty();
    @memcpy(&web_state.config_hash, cfg.hash());
    const boot_ms = nowMs();

    // Tool registry (observation only — no live tool providers yet).
    var tool_reg = ab.tools.Registry{};
    registerDefaultTools(&tool_reg) catch {};

    // Optional OpenAI-compatible client for shadow decisions.
    var llm_client: ?ab.openai.Client = null;
    defer if (llm_client) |*c| c.deinit();
    if (cfg.agent_enabled) {
        if (llm_env) |l| {
            llm_client = ab.openai.Client.init(gpa, io, l.base_url, l.api_key, l.model);
            llm_client.?.timeout_ms = cfg.decision_timeout_ms;
        }
    }

    // ---- Web API thread (loopback only, §6.4) -----------------------------
    const web_thread = std.Thread.spawn(.{}, webThreadMain, .{ io, cfg.webHost(), cfg.webPort(), &web_state }) catch |err| {
        std.debug.print("[boot] FATAL web listen: {t}\n", .{err});
        return 1;
    };
    web_thread.detach();

    // ---- CONNECTING --------------------------------------------------------
    const auth_creds: ?ab.okx_auth.Credentials = if (okx_env) |c| c.asAuth() else null;
    var okx = ab.okx_rest.Client.init(gpa, io, cfg.rest_url, auth_creds);
    defer okx.deinit();
    if (okx_env) |c| {
        okx.simulated = c.simulated;
    }
    // Instrument constraints for planner (demo execution). Fallback = OKX BTC-USDT defaults.
    var trade_instrument = ab.planner.Instrument{
        .tick_size = ab.decimal.Decimal.parse("0.1") catch ab.decimal.Decimal.one,
        .lot_size = ab.decimal.Decimal.parse("0.00000001") catch ab.decimal.Decimal.one,
        .min_size = ab.decimal.Decimal.parse("0.00001") catch ab.decimal.Decimal.one,
        .min_notional = ab.decimal.Decimal.parse("1") catch ab.decimal.Decimal.one,
    };
    {
        var ipath_buf: [96]u8 = undefined;
        const ipath = std.fmt.bufPrint(&ipath_buf, "/api/v5/public/instruments?instType=SPOT&instId={s}", .{cfg.instrument}) catch "";
        if (ipath.len > 0) {
            if (okx.getPublic(ipath)) |ibody| {
                defer gpa.free(ibody);
                if (ab.okx_rest.parseInstrument(gpa, ibody)) |info| {
                    trade_instrument = .{
                        .tick_size = info.tick_size,
                        .lot_size = info.lot_size,
                        .min_size = info.min_size,
                        .min_notional = trade_instrument.min_notional,
                    };
                    std.debug.print(
                        "[boot] instrument {s} tick={f} lot={f} min={f}\n",
                        .{ cfg.instrument, info.tick_size, info.lot_size, info.min_size },
                    );
                } else |_| {
                    std.debug.print("[boot] instrument parse failed — using BTC-USDT defaults\n", .{});
                }
            } else |_| {
                std.debug.print("[boot] instrument fetch failed — using BTC-USDT defaults\n", .{});
            }
        }
    }

    std.debug.print("[connect] probing {s}\n", .{cfg.rest_url});
    if (okx.getPublic("/api/v5/public/time")) |body| {
        defer gpa.free(body);
        const t = ab.okx_rest.parseServerTime(gpa, body) catch {
            std.debug.print("[connect] malformed time response\n", .{});
            return 1;
        };
        std.debug.print("[connect] okx server time {d}\n", .{t.ts_ms});
    } else |err| {
        std.debug.print("[connect] unreachable ({t}) — cannot run shadow loop\n", .{err});
        return 1;
    }

    // ---- RECONCILING --------------------------------------------------------
    // Shadow: engine cash = initial_capital (simulated).
    // Demo: engine cash/BTC from private REST balance (simulated venue).
    const now_boot = nowMs();
    var boot_cash = cfg.initial_capital;
    var boot_btc = ab.decimal.Decimal.zero;
    var boot_btc_avail = ab.decimal.Decimal.zero;
    if (okx_env != null) {
        const probe = probePrivateBalance(gpa, &okx);
        switch (probe) {
            .ok => |b| {
                if (cfg.mode == .demo) {
                    boot_cash = b.usdt_cash;
                    boot_btc = b.btc_cash;
                    boot_btc_avail = b.btc_avail;
                    std.debug.print(
                        "[reconcile] demo balance applied usdt={f} avail={f} btc={f}\n",
                        .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
                    );
                } else {
                    std.debug.print(
                        "[reconcile] private balance ok usdt={f} avail={f} btc={f} (shadow keeps simulated engine cash)\n",
                        .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
                    );
                }
                logEvent(&events_repo, &engine, "PRIVATE_BALANCE_OK", "exchange", "INFO", &cfg);
            },
            .err => |e| {
                std.debug.print("[reconcile] private balance FAILED: {s}\n", .{e});
                logEvent(&events_repo, &engine, "PRIVATE_BALANCE_FAILED", "exchange", "CRITICAL", &cfg);
                // Shadow may continue on public data; demo requires working keys.
                if (cfg.mode == .demo) return 1;
            },
        }
        // AC-SEC1 (code side): real-money execution refuses keys that can
        // withdraw. Read+trade is the ceiling for this agent.
        if (cfg.mode == .demo and okx_env.?.real_money_ok and !okx_env.?.simulated) {
            if (okx.getPrivate("/api/v5/account/config", nowMs())) |cbody| {
                defer gpa.free(cbody);
                if (ab.okx_rest.parseKeyPerms(gpa, cbody)) |perms| {
                    if (perms.can_withdraw) {
                        std.debug.print("[boot] FATAL real-money key has WITHDRAW permission — use a read+trade-only key\n", .{});
                        logEvent(&events_repo, &engine, "KEY_PERMS_REJECTED", "exchange", "CRITICAL", &cfg);
                        return 1;
                    }
                    std.debug.print(
                        "[boot] key perms ok read={} trade={} withdraw={}\n",
                        .{ perms.can_read, perms.can_trade, perms.can_withdraw },
                    );
                } else |_| {
                    std.debug.print("[boot] WARN key perms unparseable — proceeding (verify manually)\n", .{});
                }
            } else |_| {
                std.debug.print("[boot] WARN key perms probe failed — proceeding (verify manually)\n", .{});
            }
        }
        // Private WS probe is opt-in: TLS+WS over std.http.Client currently gets
        // OKX close 4004 after upgrade on some paths; REST reconcile remains the
        // Gate 1 default. Set ALPHABOUND_PRIVATE_WS=1 to attempt a boot probe.
        if (envGetTruthy(env, "ALPHABOUND_PRIVATE_WS")) {
            runPrivateWsProbe(gpa, &okx, okx_env.?.asAuth(), &engine, &events_repo, &cfg);
        } else {
            std.debug.print("[reconcile] private WS probe skipped (set ALPHABOUND_PRIVATE_WS=1 to enable)\n", .{});
        }
    } else {
        std.debug.print("[reconcile] no keys — skip private balance\n", .{});
    }

    _ = engine.apply(.{ .reconcile_result = .{
        .ts_ms = now_boot,
        .cash_usdt = boot_cash,
        .btc_total = boot_btc,
        .btc_available = boot_btc_avail,
        .hwm_from_db = engine.snapshot().high_watermark,
        .clean = true,
    } }) catch return 1;
    logEvent(&events_repo, &engine, "RECONCILE_COMPLETED", "core", "INFO", &cfg);

    // Local admin pause flag (control file). Risk/market loop keeps running.
    var admin_paused: bool = false;
    var runtime_status = RuntimeStatus{};

    var control_path_buf: [640]u8 = undefined;
    const control_path = ab.admin_control.pathFromDb(cfg.db_path, &control_path_buf) catch "var/trading.control";
    var control_state_buf: [640]u8 = undefined;
    const control_state_path = ab.admin_control.pathStateFromDb(cfg.db_path, &control_state_buf) catch "var/trading.control.state";
    writeControlState(io, control_state_path, admin_paused, .none, true);

    // Shadow buy-and-hold baseline (initialized on first live bid).
    var bh = ab.shadow_bench.Snapshot{};
    var last_bh_cmp = ab.shadow_bench.Comparison{
        .shadow_equity = cfg.initial_capital,
        .bh_equity = cfg.initial_capital,
        .alpha = ab.decimal.Decimal.zero,
        .entry_bid = ab.decimal.Decimal.zero,
        .bh_btc = ab.decimal.Decimal.zero,
    };

    // ---- READY: shadow loop -------------------------------------------------
    std.debug.print(
        "[ready] mode={t} inst={s} cash={f} USDT btc={f} web={s} keys={s} agent={s} exec={s}\n",
        .{
            cfg.mode,
            cfg.instrument,
            engine.snapshot().cash_usdt,
            engine.snapshot().btc_total,
            cfg.web_bind,
            if (okx_env != null) "yes" else "no",
            if (llm_client != null) "on" else "off",
            if (ab.okx_trade.executionAllowed(cfg.mode == .demo, exec_venue_authorized)) "demo" else "off",
        },
    );
    web_state.update(engine.snapshot(), true);
    // AC-NFR01: market tick → risk state update latency (µs), in-process.
    var risk_latency = ab.latency.Histogram{};
    refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, &orders_repo, &fills_repo, last_bh_cmp);
    refreshCandlesCache(gpa, &web_state, &okx, &cfg);
    refreshEgressIp(&okx, &runtime_status);
    refreshDiskStatus(&cfg, &engine, &events_repo, &runtime_status);
    refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status, &risk_latency);
    logEvent(&events_repo, &engine, "STATE_READY", "core", "INFO", &cfg);

    var tick_count: u64 = 0;
    var last_sample_min: i64 = 0;
    var last_private_ms: i64 = 0;
    var last_dashboard_ms: i64 = 0;
    var agent_done_once = false;
    // Multi-factor decision scheduler: session-aware base cadence + event
    // triggers (price move / drawdown step / risk-mode change) + cooldown floor.
    var agent_sched = ab.scheduler.Scheduler.init(.{
        .base_interval_ms = @as(i64, cfg.decision_interval_ms),
        .quiet_interval_ms = @as(i64, cfg.decision_interval_quiet_ms),
        .min_interval_ms = @as(i64, cfg.decision_min_interval_ms),
        .active_hours = ab.scheduler.parseHours(cfg.active_hours_utc) catch .{},
        .price_move = cfg.event_price_move,
        .drawdown_step = cfg.event_drawdown_step,
    });
    var ticker_path_buf: [128]u8 = undefined;
    const ticker_path = std.fmt.bufPrint(&ticker_path_buf, "/api/v5/market/ticker?instId={s}", .{cfg.instrument}) catch return 1;
    // Gate 1: periodic private REST reconcile; private WS is boot probe + optional re-probe.
    // Demo executes against the real account: reconcile must beat account_ttl_ms
    // (30s) or the risk kernel flaps NORMAL→EXIT_ONLY between reconciles.
    const private_reconcile_ms: i64 = if (cfg.mode == .demo) 20_000 else 60_000;
    const dashboard_refresh_ms: i64 = 5_000;
    const private_ws_reprobe_ms: i64 = 300_000;
    const backup_interval_ms: i64 = 3_600_000;
    const egress_refresh_ms: i64 = 3_600_000;
    // FD7: probe DB volume free space often enough to catch fill-ups.
    const disk_refresh_ms: i64 = 60_000;
    var last_egress_ms: i64 = 0;
    var last_disk_ms: i64 = 0;
    var last_private_ws_ms: i64 = now_boot;
    var last_backup_ms: i64 = 0;

    while (!shutdown_requested.load(.acquire)) {
        if (cli.max_ticks > 0 and tick_count >= cli.max_ticks) break;

        // One-shot admin commands from local control file.
        {
            var req_buf: [256]u8 = undefined;
            const req = ab.admin_control.consumeRequest(io, control_path, &req_buf) catch ab.admin_control.Request{};
            if (req.cmd != .none) {
                switch (req.cmd) {
                    .pause => {
                        admin_paused = true;
                        std.debug.print("[admin] paused\n", .{});
                        logEvent(&events_repo, &engine, "ADMIN_PAUSED", "admin", "CRITICAL", &cfg);
                    },
                    .unpause => {
                        admin_paused = false;
                        std.debug.print("[admin] resumed\n", .{});
                        logEvent(&events_repo, &engine, "ADMIN_RESUMED", "admin", "CRITICAL", &cfg);
                    },
                    .reconcile => {
                        std.debug.print("[admin] reconcile requested\n", .{});
                        if (okx_env != null) {
                            runPrivateReconcile(gpa, &okx, &engine, &events_repo, &cfg, &runtime_status);
                        }
                        logEvent(&events_repo, &engine, "ADMIN_RECONCILE", "admin", "INFO", &cfg);
                    },
                    .cancel_all => {
                        const canceled_n = adminCancelAll(gpa, &okx, &cfg, &engine, &events_repo);
                        std.debug.print("[admin] cancel-all mode={t} canceled≈{d}\n", .{ cfg.mode, canceled_n });
                        var cab: [192]u8 = undefined;
                        const cap = std.fmt.bufPrint(
                            &cab,
                            "{{\"mode\":\"{t}\",\"canceled\":{d}}}",
                            .{ cfg.mode, canceled_n },
                        ) catch "{\"canceled\":0}";
                        logEventPayload(&events_repo, &engine, "ADMIN_CANCEL_ALL", "admin", "CRITICAL", &cfg, cap);
                        _ = engine.apply(.{ .order_ambiguity = .{ .present = false } }) catch {};
                    },
                    .flatten => {
                        const prev = engine.snapshot().risk_mode;
                        _ = engine.apply(.{ .risk_trigger = .exit_trigger }) catch {};
                        const now_mode = engine.snapshot().risk_mode;
                        std.debug.print("[admin] flatten {t} -> {t}\n", .{ prev, now_mode });
                        var flb: [192]u8 = undefined;
                        const flp = std.fmt.bufPrint(
                            &flb,
                            "{{\"from\":\"{t}\",\"to\":\"{t}\",\"trigger\":\"operator_exit\"}}",
                            .{ prev, now_mode },
                        ) catch "{\"trigger\":\"operator_exit\"}";
                        logEventPayload(&events_repo, &engine, "ADMIN_FLATTEN", "admin", "CRITICAL", &cfg, flp);
                        web_state.update(engine.snapshot(), true);
                    },
                    .shutdown => {
                        std.debug.print("[admin] safe-shutdown requested\n", .{});
                        shutdown_requested.store(true, .release);
                        logEvent(&events_repo, &engine, "ADMIN_SHUTDOWN", "admin", "CRITICAL", &cfg);
                    },
                    .none => {},
                }
                writeControlState(io, control_state_path, admin_paused, req.cmd, true);
            }
        }

        if (okx.getPublic(ticker_path)) |body| {
            defer gpa.free(body);
            if (ab.okx_rest.parseTicker(gpa, body)) |ticker| {
                const prev_mode = engine.snapshot().risk_mode;
                const lat_t0 = ab.clock.SystemClock.clock().monotonicNs();
                const res = engine.apply(.{ .market_tick = .{
                    .ts_ms = ticker.ts_ms,
                    .bid = ticker.bid,
                    .mark = ticker.last,
                } }) catch continue;
                const lat_us = (ab.clock.SystemClock.clock().monotonicNs() -| lat_t0) / 1000;
                risk_latency.record(@intCast(@min(lat_us, std.math.maxInt(u32))));
                // Shadow uses a simulated book: keep account freshness aligned with
                // market ticks so the risk mode does not spuriously enter EXIT_ONLY
                // after account_ttl without private WS updates.
                if (cfg.mode == .shadow) {
                    const s0 = engine.snapshot();
                    _ = engine.apply(.{ .account_update = .{
                        .ts_ms = ticker.ts_ms,
                        .cash_usdt = s0.cash_usdt,
                        .btc_total = s0.btc_total,
                        .btc_available = s0.btc_available,
                    } }) catch {};
                }
                const snap = engine.snapshot();
                web_state.update(snap, true);

                // Init BH on first valid bid after READY.
                if (!bh.initialized and !ticker.bid.isZero()) {
                    bh = ab.shadow_bench.init(cfg.initial_capital, ticker.bid, cfg.taker_fee_rate);
                    if (bh.initialized) {
                        std.debug.print(
                            "[shadow-bh] baseline entry_bid={f} bh_btc={f} fee={f}\n",
                            .{ bh.entry_bid, bh.bh_btc, bh.fee_rate },
                        );
                        logEvent(&events_repo, &engine, "SHADOW_BH_INIT", "core", "INFO", &cfg);
                    }
                }
                last_bh_cmp = ab.shadow_bench.evaluate(bh, ticker.bid, snap.conservative_equity);
                {
                    var bid_txt: [48]u8 = undefined;
                    const bt = decFmt(&bid_txt, ticker.bid);
                    runtime_status.setBid(bt);
                    runtime_status.setPub("ok", "ticker");
                }
                // Push BH JSON every tick so /api/v1/shadow never lags on agent work.
                {
                    var bh_json_buf: [512]u8 = undefined;
                    if (ab.shadow_bench.formatJson(&bh_json_buf, last_bh_cmp)) |j| {
                        web_state.setJson(.shadow, j);
                    } else |_| {}
                }
                if (tick_count % 10 == 0) {
                    std.debug.print(
                        "[tick {d}] bid {f} equity {f} bh {f} alpha {f} dd {f} mode {t}\n",
                        .{ tick_count, ticker.bid, snap.conservative_equity, last_bh_cmp.bh_equity, last_bh_cmp.alpha, snap.drawdown, snap.risk_mode },
                    );
                }

                if (res.mode_changed) {
                    std.debug.print("[risk] mode {t} -> {t}\n", .{ prev_mode, snap.risk_mode });
                    logEvent(&events_repo, &engine, "RISK_MODE_CHANGED", "risk-kernel", "CRITICAL", &cfg);
                }

                // 1-minute equity samples (§6.2 retention).
                const minute = @divFloor(snap.as_of_ms, 60_000);
                if (minute != last_sample_min) {
                    last_sample_min = minute;
                    writeEquitySample(&equity_repo, snap);
                }
            } else |_| {
                _ = engine.apply(.{ .clock_tick = .{ .ts_ms = nowMs() } }) catch {};
                web_state.update(engine.snapshot(), true);
            }
        } else |err| {
            std.debug.print("[loop] ticker fetch failed: {t}\n", .{err});
            runtime_status.setPub("error", "ticker_http");
            _ = engine.apply(.{ .clock_tick = .{ .ts_ms = nowMs() } }) catch {};
            web_state.update(engine.snapshot(), true);
        }

        // Periodic read-only private balance probe (shadow keeps simulated engine cash).
        if (okx_env != null) {
            const tnow = nowMs();
            if (last_private_ms == 0 or tnow - last_private_ms >= private_reconcile_ms) {
                last_private_ms = tnow;
                runPrivateReconcile(gpa, &okx, &engine, &events_repo, &cfg, &runtime_status);
            }
            if (envGetTruthy(env, "ALPHABOUND_PRIVATE_WS") and
                tnow - last_private_ws_ms >= private_ws_reprobe_ms)
            {
                last_private_ws_ms = tnow;
                runPrivateWsProbe(gpa, &okx, okx_env.?.asAuth(), &engine, &events_repo, &cfg);
            }
        }

        // Publish connectivity status before slow agent work so Dashboard stays fresh
        // even while an LLM call blocks the loop for tens of seconds.
        refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status, &risk_latency);

        // Slow agent loop (shadow): proposals audited only — never sent to exchange.
        // Paused: keep risk/market/reconcile; skip agent decisions.
        if (!admin_paused) {
            if (llm_client) |*client| {
                const tnow = nowMs();
                const snap_now = engine.snapshot();
                const verdict = agent_sched.evaluate(tnow, snap_now.bid_price, snap_now.drawdown, snap_now.risk_mode);
                const due_once = cli.agent_once and !agent_done_once and tick_count >= 1;
                if (verdict.fire or due_once) {
                    agent_sched.commit(tnow, snap_now.bid_price, snap_now.drawdown, snap_now.risk_mode);
                    agent_done_once = true;
                    const reason_txt = if (verdict.fire) verdict.reason.text() else "manual_once";
                    std.debug.print("[agent] trigger reason={s}\n", .{reason_txt});
                    var trig_buf: [192]u8 = undefined;
                    const trig_payload = std.fmt.bufPrint(
                        &trig_buf,
                        "{{\"reason\":\"{s}\",\"hour_utc\":{d},\"interval_ms\":{d}}}",
                        .{ reason_txt, ab.scheduler.hourUtc(tnow), agent_sched.params.effectiveInterval(ab.scheduler.hourUtc(tnow)) },
                    ) catch "{\"reason\":\"unknown\"}";
                    logEventPayload(&events_repo, &engine, "AGENT_TRIGGER", "agent", "INFO", &cfg, trig_payload);
                    runAgentDecision(gpa, client, &okx, &cfg, &engine, &tool_reg, &agent_runs, &tool_calls, &events_repo, &orders_repo, &fills_repo, &db, &mem_store, &memories_repo, env, &runtime_status, trade_instrument);
                    refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, &orders_repo, &fills_repo, last_bh_cmp);
                    refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status, &risk_latency);
                }
            }
        }

        // Refresh dashboard JSON caches from SQLite (single-writer thread).
        {
            const tnow = nowMs();
            if (last_dashboard_ms == 0 or tnow - last_dashboard_ms >= dashboard_refresh_ms) {
                last_dashboard_ms = tnow;
                refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, &orders_repo, &fills_repo, last_bh_cmp);
                refreshCandlesCache(gpa, &web_state, &okx, &cfg);
                refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status, &risk_latency);
            }
            if (last_egress_ms == 0 or tnow - last_egress_ms >= egress_refresh_ms) {
                last_egress_ms = tnow;
                refreshEgressIp(&okx, &runtime_status);
            }
            if (last_disk_ms == 0 or tnow - last_disk_ms >= disk_refresh_ms) {
                last_disk_ms = tnow;
                refreshDiskStatus(&cfg, &engine, &events_repo, &runtime_status);
            }
            if (last_backup_ms == 0 or tnow - last_backup_ms >= backup_interval_ms) {
                last_backup_ms = tnow;
                runSqliteBackup(io, &db, &cfg, &engine, &events_repo);
            }
        }

        tick_count += 1;
        io.sleep(.{ .nanoseconds = @as(i96, cfg.poll_interval_ms) * 1_000_000 }, .awake) catch break;
    }

    // ---- Graceful shutdown (§7.4) -------------------------------------------
    std.debug.print("[shutdown] draining after {d} ticks\n", .{tick_count});
    writeEquitySample(&equity_repo, engine.snapshot());
    refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, &orders_repo, &fills_repo, last_bh_cmp);
    logEvent(&events_repo, &engine, "SHUTDOWN_CLEAN", "core", "CRITICAL", &cfg);
    return 0;
}

const PrivateProbe = union(enum) {
    ok: ab.okx_rest.Balance,
    err: []const u8,
};

/// Read-only signed GET /api/v5/account/balance. Never places orders.
fn probePrivateBalance(gpa: std.mem.Allocator, client: *ab.okx_rest.Client) PrivateProbe {
    const body = client.getPrivate("/api/v5/account/balance", nowMs()) catch {
        return .{ .err = "http_failed" };
    };
    defer gpa.free(body);
    const bal = ab.okx_rest.parseBalance(gpa, body) catch {
        return .{ .err = ab.okx_rest.classifyErrorBody(body) };
    };
    return .{ .ok = bal };
}

fn registerDefaultTools(reg: *ab.tools.Registry) !void {
    try reg.register(.{
        .name = "market.ticker",
        .domain = .market,
        .source = "okx",
        .max_age_ms = 15_000,
        .schema_note = "bid/ask/last + ts_ms",
    });
    try reg.register(.{
        .name = "market.candles",
        .domain = .market,
        .source = "okx",
        .max_age_ms = 120_000,
        .schema_note = "1H OHLCV array (newest first)",
    });
}

fn runControlCli(io: std.Io, cmd_name: []const u8, db_path: []const u8) u8 {
    var path_buf: [640]u8 = undefined;
    const cpath = ab.admin_control.pathFromDb(db_path, &path_buf) catch {
        std.debug.print("[control] path error\n", .{});
        return 1;
    };
    var spath_buf: [640]u8 = undefined;
    const spath = ab.admin_control.pathStateFromDb(db_path, &spath_buf) catch cpath;

    if (std.mem.eql(u8, cmd_name, "status")) {
        var buf: [512]u8 = undefined;
        const raw = ab.admin_control.readFile(io, spath, &buf) catch "";
        if (raw.len == 0) {
            std.debug.print("{{\"paused\":false,\"ready\":false,\"note\":\"no daemon state file\"}}\n", .{});
        } else {
            std.debug.print("{s}", .{raw});
        }
        return 0;
    }

    const cmd = ab.admin_control.Cmd.fromString(cmd_name) orelse {
        std.debug.print("[control] unknown cmd '{s}' (pause|resume|reconcile|cancel-all|flatten|shutdown|status)\n", .{cmd_name});
        return 2;
    };
    if (cmd == .none) {
        std.debug.print("[control] unknown cmd '{s}'\n", .{cmd_name});
        return 2;
    }
    var body_buf: [128]u8 = undefined;
    const body = ab.admin_control.formatRequest(&body_buf, cmd, nowMs()) catch {
        std.debug.print("[control] format failed\n", .{});
        return 1;
    };
    ab.admin_control.writeFile(io, cpath, body) catch |err| {
        std.debug.print("[control] write {s} failed: {t}\n", .{ cpath, err });
        return 1;
    };
    std.debug.print("[control] wrote {s} -> {s}\n", .{ cmd.text(), cpath });
    return 0;
}

fn writeControlState(io: std.Io, path: []const u8, paused: bool, last: ab.admin_control.Cmd, ready: bool) void {
    var buf: [256]u8 = undefined;
    const body = ab.admin_control.formatState(&buf, .{
        .paused = paused,
        .last_cmd = last,
        .last_ts_ms = nowMs(),
        .ready = ready,
    }) catch return;
    ab.admin_control.writeFile(io, path, body) catch {};
}

fn printAgentStats(db: *ab.storage.Db) void {
    const total = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs") catch 0;
    const ok = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status = 'ok'") catch 0;
    const invalid = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status LIKE 'invalid%'") catch 0;
    const errors = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status LIKE 'error%'") catch 0;
    const running = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status = 'running'") catch 0;
    const tools_n = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM tool_calls") catch 0;
    const rate: f64 = if (total > 0) @as(f64, @floatFromInt(ok)) * 100.0 / @as(f64, @floatFromInt(total)) else 0;
    std.debug.print(
        \\[agent-stats]
        \\  agent_runs total:     {d}
        \\  ok:                   {d}
        \\  invalid_*:            {d}
        \\  error_*:              {d}
        \\  running (orphan):     {d}
        \\  valid_proposal_rate:  {d:.1}%
        \\  tool_calls total:     {d}
        \\
    ,
        .{ total, ok, invalid, errors, running, rate, tools_n },
    );
}

fn refreshWebCaches(
    ws: *WebState,
    db: *ab.storage.Db,
    runs: *ab.storage.AgentRunsRepo,
    equity: *ab.storage.EquityRepo,
    events: *ab.storage.EventsRepo,
    memories: *ab.storage.MemoriesRepo,
    orders: *ab.storage.OrdersRepo,
    fills: *ab.storage.FillsRepo,
    bh: ab.shadow_bench.Comparison,
) void {
    // Separate scratch buffers so a large events dump cannot clobber shadow JSON mid-format.
    var tmp_agent: [24576]u8 = undefined;
    var tmp_equity: [8192]u8 = undefined;
    var tmp_events: [12288]u8 = undefined;
    var tmp_shadow: [512]u8 = undefined;
    var tmp_mem: [8192]u8 = undefined;
    if (runs.listRecentJson(db, &tmp_agent, 50)) |j| {
        ws.setJson(.agent, j);
    } else |_| {}
    if (equity.listRecentJson(db, &tmp_equity, 60)) |j| {
        ws.setJson(.equity, j);
    } else |_| {}
    if (events.listRecentJson(db, &tmp_events, 40)) |j| {
        ws.setJson(.events, j);
    } else |_| {}
    var tmp_dec: [49152]u8 = undefined;
    if (events.listAgentDecisionsJson(db, &tmp_dec, 80)) |j| {
        ws.setJson(.decisions, j);
    } else |_| {}
    if (memories.listLatestJson(db, &tmp_mem, 40)) |j| {
        ws.setJson(.memories, j);
    } else |_| {}
    if (ab.shadow_bench.formatJson(&tmp_shadow, bh)) |j| {
        ws.setJson(.shadow, j);
    } else |_| {}

    // Orders bundle for Dashboard / Gate3 trade visibility.
    var tmp_ord: [16384]u8 = undefined;
    var tmp_fills: [8192]u8 = undefined;
    var tmp_bundle: [24576]u8 = undefined;
    const orders_j = orders.listRecentJson(db, &tmp_ord, 80) catch "[]";
    const fills_j = fills.listRecentJson(db, &tmp_fills, 80) catch "[]";
    var bw: std.Io.Writer = .fixed(&tmp_bundle);
    bw.print("{{\"orders\":{s},\"fills\":{s}}}", .{ orders_j, fills_j }) catch {
        ws.setJson(.orders, "{\"orders\":[],\"fills\":[]}");
        return;
    };
    ws.setJson(.orders, bw.buffered());
}

const CandleBarSpec = struct { okx_bar: []const u8, limit: u16 };

/// Dashboard timeframes (OKX public candles). 1m powers 分时 line chart.
// Aggregate JSON must fit web body buffer (~192KiB).
const candle_bar_specs = [_]CandleBarSpec{
    .{ .okx_bar = "1m", .limit = 180 }, // 分时 / 1分 ≈ 3h
    .{ .okx_bar = "5m", .limit = 120 },
    .{ .okx_bar = "15m", .limit = 96 },
    .{ .okx_bar = "1H", .limit = 72 },
    .{ .okx_bar = "4H", .limit = 60 },
    .{ .okx_bar = "1D", .limit = 90 },
};

fn refreshCandlesCache(
    gpa: std.mem.Allocator,
    ws: *WebState,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
) void {
    // Keep 1H candles for legacy top-level `candles` field (and default UI).
    var default_bars: [100]ab.okx_rest.Candle = undefined;
    var default_n: usize = 0;

    var tmp: [131072]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tmp);
    w.print(
        "{{\"instrument\":\"{s}\",\"default_bar\":\"1H\",\"bars\":{{",
        .{cfg.instrument},
    ) catch return;

    var any = false;
    for (candle_bar_specs) |spec| {
        var path_buf: [192]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/api/v5/market/candles?instId={s}&bar={s}&limit={d}",
            .{ cfg.instrument, spec.okx_bar, spec.limit },
        ) catch continue;
        const body = okx.getPublic(path) catch continue;
        defer gpa.free(body);

        var raw: [300]ab.okx_rest.Candle = undefined;
        const count = ab.okx_rest.parseCandles(gpa, body, raw[0..spec.limit]) catch continue;
        if (count == 0) continue;

        var ordered: [300]ab.okx_rest.Candle = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            ordered[i] = raw[count - 1 - i];
        }

        if (std.mem.eql(u8, spec.okx_bar, "1H")) {
            const n = @min(count, default_bars.len);
            @memcpy(default_bars[0..n], ordered[0..n]);
            default_n = n;
        }

        if (any) w.writeByte(',') catch return;
        any = true;
        w.print("\"{s}\":{{\"bar\":\"{s}\",\"candles\":", .{ spec.okx_bar, spec.okx_bar }) catch return;
        writeCandlesArray(&w, ordered[0..count]) catch return;
        w.writeByte('}') catch return;
    }

    if (!any) return;

    // Close bars; legacy top-level fields keep older clients working.
    w.writeAll("},\"bar\":\"1H\",\"candles\":") catch return;
    if (default_n > 0) {
        writeCandlesArray(&w, default_bars[0..default_n]) catch return;
    } else {
        w.writeAll("[]") catch return;
    }
    w.writeAll("}") catch return;
    ws.setJson(.candles, w.buffered());
}

fn writeCandlesArray(w: *std.Io.Writer, candles: []const ab.okx_rest.Candle) error{BufferTooSmall}!void {
    w.writeByte('[') catch return error.BufferTooSmall;
    for (candles, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print(
            "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\"}}",
            .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol },
        ) catch return error.BufferTooSmall;
    }
    w.writeByte(']') catch return error.BufferTooSmall;
}

/// One-shot private WS TLS login/subscribe probe. Never places orders.
fn runPrivateWsProbe(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    creds: ab.okx_auth.Credentials,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
    cfg: *const ab.config.Config,
) void {
    std.debug.print("[private-ws] probing wss://ws.okx.com:8443/ws/v5/private …\n", .{});
    var detail_buf: [256]u8 = undefined;
    const result = ab.okx_private_ws_client.probe(gpa, &okx.http, creds, nowMs(), &detail_buf) catch |err| {
        const tag: []const u8 = switch (err) {
            error.ConnectFailed => "connect_or_tls_failed",
            error.HandshakeFailed => "handshake_failed",
            error.LoginFailed => "login_failed",
            error.SubscribeFailed => "subscribe_failed",
            error.ReadFailed => "read_failed",
            error.WriteFailed => "write_failed",
            error.Timeout => "timeout",
            error.OutOfMemory => "oom",
            error.BufferTooSmall => "buffer",
        };
        std.debug.print("[private-ws] probe hard-error: {s} detail={s}\n", .{ tag, detail_buf[0..@min(detail_buf.len, 64)] });
        var payload_buf: [200]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &payload_buf,
            "{{\"ok\":false,\"error\":\"{s}\",\"source\":\"private_ws\"}}",
            .{tag},
        ) catch "{\"ok\":false}";
        logEventPayload(events_repo, engine, "PRIVATE_WS_PROBE_FAILED", "exchange", "WARN", cfg, payload);
        return;
    };
    std.debug.print(
        "[private-ws] login_ok={} subscribed={} push={} detail={s}\n",
        .{ result.login_ok, result.subscribed, result.push_seen, result.detail },
    );
    var payload_buf: [384]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"ok\":{},\"login_ok\":{},\"subscribed\":{},\"push_seen\":{},\"detail\":\"{s}\",\"source\":\"private_ws\"}}",
        .{ result.login_ok, result.login_ok, result.subscribed, result.push_seen, result.detail },
    ) catch "{\"ok\":false}";
    if (result.login_ok) {
        logEventPayload(events_repo, engine, "PRIVATE_WS_PROBE_OK", "exchange", "INFO", cfg, payload);
    } else {
        logEventPayload(events_repo, engine, "PRIVATE_WS_PROBE_FAILED", "exchange", "WARN", cfg, payload);
    }
}

/// Read-only private balance probe for Gate 1 connectivity (no engine cash mutation in shadow).
fn runPrivateReconcile(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
    cfg: *const ab.config.Config,
    st: *RuntimeStatus,
) void {
    const probe = probePrivateBalance(gpa, okx);
    switch (probe) {
        .ok => |b| {
            if (cfg.mode == .demo) {
                _ = engine.apply(.{ .reconcile_result = .{
                    .ts_ms = nowMs(),
                    .cash_usdt = b.usdt_cash,
                    .btc_total = b.btc_cash,
                    .btc_available = b.btc_avail,
                    .hwm_from_db = engine.snapshot().high_watermark,
                    .clean = true,
                } }) catch {};
                std.debug.print(
                    "[reconcile] demo balance applied usdt={f} avail={f} btc={f}\n",
                    .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
                );
            } else {
                std.debug.print(
                    "[reconcile] private balance ok usdt={f} avail={f} btc={f} (shadow engine cash unchanged)\n",
                    .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
                );
            }
            var payload_buf: [256]u8 = undefined;
            const payload = std.fmt.bufPrint(
                &payload_buf,
                "{{\"usdt\":\"{f}\",\"avail\":\"{f}\",\"btc\":\"{f}\",\"source\":\"rest\"}}",
                .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
            ) catch "{}";
            var u_buf: [48]u8 = undefined;
            var b_buf: [48]u8 = undefined;
            st.setAccount(decFmt(&u_buf, b.usdt_cash), decFmt(&b_buf, b.btc_cash));
            st.setPriv("ok", "balance");
            logEventPayload(events_repo, engine, "PRIVATE_BALANCE_OK", "exchange", "INFO", cfg, payload);
        },
        .err => |e| {
            std.debug.print("[reconcile] private balance FAILED: {s}\n", .{e});
            var payload_buf: [128]u8 = undefined;
            const payload = std.fmt.bufPrint(
                &payload_buf,
                "{{\"error\":\"{s}\",\"source\":\"rest\"}}",
                .{e},
            ) catch "{\"error\":\"unknown\"}";
            st.setPriv(if (std.mem.eql(u8, e, "ip_whitelist")) "ip_whitelist" else "error", e);
            logEventPayload(events_repo, engine, "PRIVATE_BALANCE_FAILED", "exchange", "WARN", cfg, payload);
        },
    }
}

/// Fetch market.ticker + market.candles; journal tool_calls; return observation JSON lines.
fn collectMarketTools(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    registry: *const ab.tools.Registry,
    run_id: []const u8,
    tools_repo: *ab.storage.ToolCallsRepo,
    obs_bufs: *[2][2048]u8,
    obs_out: *[2][]const u8,
) usize {
    var n: usize = 0;

    // market.ticker
    if (registry.find("market.ticker")) |spec| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v5/market/ticker?instId={s}", .{cfg.instrument}) catch return n;
        var data_buf: [512]u8 = undefined;
        var result: ab.tools.ToolResult = undefined;
        const t_start = nowMs();
        if (okx.getPublic(path)) |body| {
            defer gpa.free(body);
            if (ab.okx_rest.parseTicker(gpa, body)) |ticker| {
                const latency: u32 = @intCast(@max(@as(i64, 0), nowMs() - t_start));
                if (ab.market_tools.formatTickerData(&data_buf, cfg.instrument, ticker)) |data| {
                    result = ab.market_tools.okResult("okx", ticker.ts_ms, latency, data);
                } else |_| {
                    result = ab.market_tools.errResult("okx", nowMs(), latency, "buffer");
                }
            } else |_| {
                const latency: u32 = @intCast(@max(@as(i64, 0), nowMs() - t_start));
                result = ab.market_tools.errResult("okx", nowMs(), latency, "parse");
            }
        } else |_| {
            // Transport failure → UNAVAILABLE (AC-FD2), not a fabricated zero quote.
            result = ab.market_tools.unavailableResult("okx", nowMs());
        }
        const rec = ab.tools.auditRecord(spec, result, nowMs());
        journalToolCall(tools_repo, run_id, rec);
        if (ab.market_tools.formatObservation(&obs_bufs[n], spec.name, rec, result.data_json)) |line| {
            obs_out[n] = line;
            n += 1;
        } else |_| {}
    }

    // market.candles — fetch 24h, expose newest 8 bars in context (size budget)
    if (registry.find("market.candles")) |spec| {
        if (n >= obs_out.len) return n;
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/api/v5/market/candles?instId={s}&bar=1H&limit=24",
            .{cfg.instrument},
        ) catch return n;
        var data_buf: [1536]u8 = undefined;
        var result: ab.tools.ToolResult = undefined;
        const t_start = nowMs();
        if (okx.getPublic(path)) |body| {
            defer gpa.free(body);
            var candles: [24]ab.okx_rest.Candle = undefined;
            if (ab.okx_rest.parseCandles(gpa, body, &candles)) |count| {
                const latency: u32 = @intCast(@max(@as(i64, 0), nowMs() - t_start));
                const as_of: i64 = if (count > 0) candles[0].ts_ms else nowMs();
                const show_n = @min(count, @as(usize, 8));
                if (ab.market_tools.formatCandlesData(&data_buf, cfg.instrument, candles[0..show_n])) |data| {
                    result = ab.market_tools.okResult("okx", as_of, latency, data);
                } else |_| {
                    result = ab.market_tools.errResult("okx", nowMs(), latency, "buffer");
                }
            } else |_| {
                const latency: u32 = @intCast(@max(@as(i64, 0), nowMs() - t_start));
                result = ab.market_tools.errResult("okx", nowMs(), latency, "parse");
            }
        } else |_| {
            result = ab.market_tools.unavailableResult("okx", nowMs());
        }
        const rec = ab.tools.auditRecord(spec, result, nowMs());
        journalToolCall(tools_repo, run_id, rec);
        if (ab.market_tools.formatObservation(&obs_bufs[n], spec.name, rec, result.data_json)) |line| {
            obs_out[n] = line;
            n += 1;
        } else |_| {
            if (ab.market_tools.formatObservation(&obs_bufs[n], spec.name, rec, "null")) |line| {
                obs_out[n] = line;
                n += 1;
            } else |_| {}
        }
    }

    return n;
}

fn journalToolCall(repo: *ab.storage.ToolCallsRepo, run_id: []const u8, rec: ab.tools.AuditRecord) void {
    var ts_buf: [32]u8 = undefined;
    const ts = ab.clock.formatRfc3339Ms(nowMs(), &ts_buf) catch return;
    var as_of_buf: [32]u8 = undefined;
    const as_of = ab.clock.formatRfc3339Ms(rec.as_of_ms, &as_of_buf) catch "";
    var cost_buf: [32]u8 = undefined;
    const cost = decFmt(&cost_buf, rec.cost_usd);
    repo.append(.{
        .run_id = run_id,
        .tool = rec.tool,
        .source = rec.source,
        .as_of = as_of,
        .latency_ms = rec.latency_ms,
        .cost = cost,
        .result_digest = &rec.result_digest,
        .ts = ts,
    }) catch |err| {
        std.debug.print("[agent] tool_calls append failed: {t}\n", .{err});
    };
}

/// Shadow-path Risk Kernel admission (audit only — never places orders).
const ShadowAdmission = struct {
    verdict_txt: []const u8,
    reason_txt: []const u8,
    admitted_weight: ab.decimal.Decimal,
    stress_equity: ab.decimal.Decimal,
    floor: ab.decimal.Decimal,
};

fn defaultStressParams(cfg: *const ab.config.Config) ab.admission.StressParams {
    return .{
        .price_shock = ab.decimal.Decimal.parse("0.05") catch ab.decimal.Decimal.zero,
        .trade_fee_rate = cfg.taker_fee_rate,
        .trade_slippage_rate = cfg.slippage_rate,
        .exit_costs = .{ .fee_rate = cfg.taker_fee_rate, .slippage_rate = cfg.slippage_rate },
        // Small absolute reserve so tiny shadow books still exercise the floor path.
        .exit_reserve = ab.decimal.Decimal.parse("0.50") catch ab.decimal.Decimal.zero,
    };
}

fn shadowAdmit(
    snap: ab.state.PortfolioState,
    proposal_snapshot_version: u64,
    target_btc_weight: ab.decimal.Decimal,
    cfg: *const ab.config.Config,
    now_ms: i64,
) ShadowAdmission {
    const view = ab.admission.SnapshotView{
        .version = snap.version,
        .reconciled = snap.reconciled,
        .market_fresh = snap.freshness.marketFresh(now_ms),
        .account_fresh = snap.freshness.accountFresh(now_ms),
        .unresolved_orders = snap.unresolved_orders,
        .risk_mode = snap.risk_mode,
        .cash_usdt = snap.cash_usdt,
        .btc_total = snap.btc_total,
        .liq_price = snap.bid_price,
        .mark_price = if (snap.mark_price.gt(ab.decimal.Decimal.zero)) snap.mark_price else snap.bid_price,
        .high_watermark = snap.high_watermark,
    };
    const prop = ab.admission.ProposalView{
        .snapshot_version = proposal_snapshot_version,
        .target_btc_weight = target_btc_weight,
    };
    const result = ab.admission.admit(view, prop, cfg.max_drawdown, defaultStressParams(cfg)) catch {
        return .{
            .verdict_txt = "ERROR",
            .reason_txt = "admission_math_error",
            .admitted_weight = ab.decimal.Decimal.zero,
            .stress_equity = ab.decimal.Decimal.zero,
            .floor = ab.decimal.Decimal.zero,
        };
    };
    return switch (result.verdict) {
        .approve => |w| .{
            .verdict_txt = "APPROVE",
            .reason_txt = "ok",
            .admitted_weight = w,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
        .approve_reduced => |w| .{
            .verdict_txt = "REDUCE",
            .reason_txt = "reduced_to_boundary",
            .admitted_weight = w,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
        .reject => |r| .{
            .verdict_txt = "REJECT",
            .reason_txt = r.text(),
            .admitted_weight = ab.decimal.Decimal.zero,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
    };
}

/// One slow-loop decision: tools → context → LLM → proposal → admission → optional demo exec.
fn runAgentDecision(
    gpa: std.mem.Allocator,
    client: *ab.openai.Client,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    registry: *const ab.tools.Registry,
    runs: *ab.storage.AgentRunsRepo,
    tools_repo: *ab.storage.ToolCallsRepo,
    events_repo: *ab.storage.EventsRepo,
    orders_repo: *ab.storage.OrdersRepo,
    fills_repo: *ab.storage.FillsRepo,
    db: *ab.storage.Db,
    mem_store: *ab.memory.Store,
    memories_repo: *ab.storage.MemoriesRepo,
    env: *const std.process.Environ.Map,
    st: *RuntimeStatus,
    instrument: ab.planner.Instrument,
) void {
    const snap = engine.snapshot();

    var run_id_buf: [64]u8 = undefined;
    const run_id = std.fmt.bufPrint(&run_id_buf, "run_{d}", .{nowMs()}) catch return;
    var started_buf: [32]u8 = undefined;
    const started_ts = ab.clock.formatRfc3339Ms(nowMs(), &started_buf) catch return;

    var prompt_hash_buf: [64]u8 = undefined;
    ab.context.digest(default_system_prompt, &prompt_hash_buf);
    const prompt_hash: []const u8 = &prompt_hash_buf;

    // Start run early so tool_calls FK can reference run_id.
    runs.start(.{
        .run_id = run_id,
        .snapshot_version = @intCast(snap.version),
        .model = client.model,
        .prompt_hash = prompt_hash,
        .input_digest = "",
        .status = "running",
        .started_ts = started_ts,
    }) catch |err| {
        std.debug.print("[agent] agent_runs start failed: {t}\n", .{err});
        return;
    };

    var obs_bufs: [2][2048]u8 = undefined;
    var obs_ptrs: [2][]const u8 = .{ "", "" };
    const obs_n = collectMarketTools(gpa, okx, cfg, registry, run_id, tools_repo, &obs_bufs, &obs_ptrs);
    const observations = obs_ptrs[0..obs_n];

    // Retrieve long-term memories into the decision envelope (§4.5 / FR-07).
    var scored = ab.memory.retrieve(mem_store, gpa, .{
        .tags = &.{ cfg.instrument, "BTC", "shadow" },
        .now_ms = nowMs(),
        .limit = 8,
    }, ab.memory.substringTagMatch) catch blk: {
        break :blk @as(std.ArrayList(ab.memory.Scored), .empty);
    };
    defer scored.deinit(gpa);

    // Significant recent events (oldest first) for context narrative.
    var ev_backing: [4096]u8 = undefined;
    var ev_ptrs: [12][]const u8 = undefined;
    const ev_n = events_repo.listCompactForContext(db, &ev_backing, &ev_ptrs) catch 0;
    const recent_events = ev_ptrs[0..ev_n];

    var ctx_buf: [32 * 1024]u8 = undefined;
    const ctx_json = ab.context.render(&ctx_buf, .{
        .snapshot = snap,
        .recent_events = recent_events,
        .memories = scored.items,
        .registry = registry,
        .tool_observations = observations,
        .max_drawdown = cfg.max_drawdown,
        .instrument = cfg.instrument,
        .now_ms = nowMs(),
    }) catch {
        std.debug.print("[agent] context render failed\n", .{});
        completeRun(runs, run_id, "error_context", "", "", nowMs());
        return;
    };

    var digest_hex: [64]u8 = undefined;
    ab.context.digest(ctx_json, &digest_hex);
    const input_digest: []const u8 = &digest_hex;

    std.debug.print(
        "[agent] calling {s} model={s} snap={d} tools={d} memories={d} events={d}\n",
        .{ client.base_url, client.model, snap.version, obs_n, scored.items.len, ev_n },
    );

    const user_msg_prefix =
        \\Respond with ONE JSON Decision Proposal only. Context:
        \\
    ;
    var user_buf: [36 * 1024]u8 = undefined;
    const user_msg = std.fmt.bufPrint(&user_buf, "{s}{s}", .{ user_msg_prefix, ctx_json }) catch {
        completeRun(runs, run_id, "error_buffer", "", input_digest, nowMs());
        return;
    };

    const chat_res = client.chat(default_system_prompt, user_msg) catch |err| {
        const tag: []const u8 = switch (err) {
            error.HttpFailed => "http_failed",
            error.Timeout => "timeout",
            error.ApiError => "api_error",
            error.MalformedResponse => "malformed_response",
            error.EmptyContent => "empty_content",
            error.OutOfMemory => "oom",
            error.BufferTooSmall => "buffer",
        };
        std.debug.print("[agent] LLM failed: {s} → HOLD\n", .{tag});
        st.setLlm("error", tag);
        completeRun(runs, run_id, "error_llm", "", input_digest, nowMs());
        var fail_buf: [256]u8 = undefined;
        const fail_payload = std.fmt.bufPrint(
            &fail_buf,
            "{{\"run_id\":\"{s}\",\"model\":\"{s}\",\"error\":\"{s}\",\"degraded\":\"HOLD\"}}",
            .{ run_id, client.model, tag },
        ) catch "{\"degraded\":\"HOLD\"}";
        logEventPayload(events_repo, engine, "AGENT_LLM_FAILED", "agent", "WARN", cfg, fail_payload);
        return;
    };
    defer gpa.free(chat_res.content);
    st.addUsage(chat_res.usage);
    st.setLlm("ok", "proposal");
    const raw = chat_res.content;

    var out_digest_buf: [64]u8 = undefined;
    ab.context.digest(raw, &out_digest_buf);
    const out_digest: []const u8 = &out_digest_buf;

    const json_slice = ab.openai.extractJsonObject(raw) orelse {
        std.debug.print("[agent] no JSON object in model output → HOLD\n", .{});
        completeRun(runs, run_id, "invalid_output", out_digest, input_digest, nowMs());
        var inv_buf: [320]u8 = undefined;
        const inv_payload = std.fmt.bufPrint(
            &inv_buf,
            "{{\"run_id\":\"{s}\",\"output_digest\":\"{s}\",\"reason\":\"no_json_object\",\"degraded\":\"HOLD\"}}",
            .{ run_id, out_digest },
        ) catch "{\"degraded\":\"HOLD\"}";
        logEventPayload(events_repo, engine, "AGENT_INVALID_OUTPUT", "agent", "WARN", cfg, inv_payload);
        return;
    };

    var prop = ab.proposal.parse(gpa, json_slice) catch |err| {
        std.debug.print("[agent] proposal invalid ({t}) → HOLD\n", .{err});
        completeRun(runs, run_id, "invalid_proposal", out_digest, input_digest, nowMs());
        var invp_buf: [320]u8 = undefined;
        const invp_payload = std.fmt.bufPrint(
            &invp_buf,
            "{{\"run_id\":\"{s}\",\"output_digest\":\"{s}\",\"reason\":\"{t}\",\"degraded\":\"HOLD\"}}",
            .{ run_id, out_digest, err },
        ) catch "{\"degraded\":\"HOLD\"}";
        logEventPayload(events_repo, engine, "AGENT_INVALID_PROPOSAL", "agent", "WARN", cfg, invp_payload);
        return;
    };
    defer prop.deinit();

    // Risk Kernel admission (always). Demo may execute; shadow never does.
    const action_txt: []const u8 = switch (prop.action) {
        .hold => "HOLD",
        .rebalance => "REBALANCE",
    };
    const admit_now = nowMs();
    const admission = shadowAdmit(snap, prop.snapshot_version, prop.target_btc_weight, cfg, admit_now);
    var exec_note: []const u8 = "not_executed";
    if (ab.okx_trade.executionAllowed(cfg.mode == .demo, exec_venue_authorized)) {
        exec_note = tryDemoExecute(
            gpa,
            okx,
            cfg,
            engine,
            orders_repo,
            fills_repo,
            events_repo,
            prop.decision_id,
            admission,
            instrument,
            snap,
            prop.order_policy,
        );
    }
    std.debug.print(
        "[agent] proposal ok id={s} action={s} target_btc={f} conf={f} mem={d} admit={s} exec={s}\n",
        .{ prop.decision_id, action_txt, prop.target_btc_weight, prop.confidence, scored.items.len, admission.verdict_txt, exec_note },
    );
    completeRun(runs, run_id, "ok", out_digest, input_digest, admit_now);
    recordProposalEpisode(gpa, mem_store, memories_repo, run_id, prop.decision_id, action_txt, prop.target_btc_weight, prop.confidence);
    // Reflection: prefer LLM structured memory_ops; fail-closed → deterministic.
    // HOLD cycles skip the second LLM call unless explicitly enabled — quiet
    // markets should not burn tokens re-reflecting on identical no-ops.
    const reflect_this_action = cfg.agent_llm_reflection_on_hold or prop.action != .hold;
    const want_llm_reflect = cfg.agent_llm_reflection and reflect_this_action and llmReflectionWanted(env);
    var reflected = false;
    if (want_llm_reflect) {
        reflected = tryLlmReflection(
            gpa,
            client,
            mem_store,
            memories_repo,
            events_repo,
            engine,
            cfg,
            run_id,
            prop.decision_id,
            action_txt,
            prop.target_btc_weight,
            prop.confidence,
            ctx_json,
            st,
        );
    }
    if (!reflected) {
        applyShadowReflection(gpa, mem_store, memories_repo, events_repo, engine, cfg, run_id, prop.decision_id, action_txt, prop.target_btc_weight, prop.confidence);
    }

    var ok_buf: [896]u8 = undefined;
    var w_buf: [48]u8 = undefined;
    var c_buf: [48]u8 = undefined;
    var aw_buf: [48]u8 = undefined;
    var se_buf: [48]u8 = undefined;
    var fl_buf: [48]u8 = undefined;
    const weight_s = decFmt(&w_buf, prop.target_btc_weight);
    const conf_s = decFmt(&c_buf, prop.confidence);
    const admitted_s = decFmt(&aw_buf, admission.admitted_weight);
    const stress_s = decFmt(&se_buf, admission.stress_equity);
    const floor_s = decFmt(&fl_buf, admission.floor);
    const executed = !std.mem.eql(u8, exec_note, "not_executed") and
        !std.mem.eql(u8, exec_note, "hold") and
        !std.mem.eql(u8, exec_note, "skipped_reject") and
        !std.mem.eql(u8, exec_note, "plan_hold") and
        !std.mem.eql(u8, exec_note, "plan_error");
    const ok_payload = std.fmt.bufPrint(
        &ok_buf,
        "{{\"run_id\":\"{s}\",\"decision_id\":\"{s}\",\"action\":\"{s}\",\"target_btc_weight\":\"{s}\",\"confidence\":\"{s}\",\"snapshot_version\":{d},\"output_digest\":\"{s}\",\"tools\":{d},\"executed\":{},\"exec\":\"{s}\",\"admission\":{{\"verdict\":\"{s}\",\"reason\":\"{s}\",\"admitted_weight\":\"{s}\",\"stress_equity\":\"{s}\",\"floor\":\"{s}\"}},\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}",
        .{ run_id, prop.decision_id, action_txt, weight_s, conf_s, prop.snapshot_version, out_digest, obs_n, executed, exec_note, admission.verdict_txt, admission.reason_txt, admitted_s, stress_s, floor_s, chat_res.usage.prompt_tokens, chat_res.usage.completion_tokens, chat_res.usage.total_tokens },
    ) catch "{\"executed\":false}";
    {
        var dbuf: [160]u8 = undefined;
        const dtxt = std.fmt.bufPrint(&dbuf, "{s} {s} conf={s} admit={s} exec={s}", .{ action_txt, prop.decision_id, conf_s, admission.verdict_txt, exec_note }) catch action_txt;
        st.setLastDecision(dtxt);
    }
    logEventPayload(events_repo, engine, "AGENT_PROPOSAL_OK", "agent", "INFO", cfg, ok_payload);
    logEventPayload(events_repo, engine, "RISK_ADMISSION", "risk", "INFO", cfg, ok_payload);
}

/// Demo-only: plan + place market order after APPROVE/REDUCE. Never called for live.
/// Partial fills: REST-reconcile portfolio then re-plan residual (max 3 legs).
/// Returns a short stable token for logs/events (no secrets).
fn tryDemoExecute(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    orders_repo: *ab.storage.OrdersRepo,
    fills_repo: *ab.storage.FillsRepo,
    events_repo: *ab.storage.EventsRepo,
    decision_id: []const u8,
    admission: ShadowAdmission,
    instrument: ab.planner.Instrument,
    snap_in: ab.state.PortfolioState,
    order_policy: ab.proposal.OrderPolicy,
) []const u8 {
    if (!std.mem.eql(u8, admission.verdict_txt, "APPROVE") and !std.mem.eql(u8, admission.verdict_txt, "REDUCE")) {
        return "skipped_reject";
    }

    // LIMIT_ONLY → limit legs; LIMIT_OR_MARKET → market (demo default, fast fill).
    const prefer_limit = order_policy.type == .limit_only;
    const max_legs = ab.okx_trade.max_replan_legs;
    var seq: u16 = 0;
    var last_note: []const u8 = "plan_hold";
    var snap = snap_in;
    var any_fill = false;

    while (seq < max_legs) : (seq += 1) {
        const mark = if (snap.mark_price.gt(ab.decimal.Decimal.zero)) snap.mark_price else snap.bid_price;
        const equity = if (snap.conservative_equity.gt(ab.decimal.Decimal.zero))
            snap.conservative_equity
        else
            snap.cash_usdt;

        const planned = ab.planner.plan(.{
            .cash_usdt = snap.cash_usdt,
            .btc_total = snap.btc_total,
            .equity = equity,
            .mark_price = mark,
            .admitted_btc_weight = admission.admitted_weight,
            .instrument = instrument,
        }) catch return if (seq == 0) "plan_error" else last_note;

        const po = switch (planned) {
            .hold => {
                if (seq == 0) {
                    logEventPayload(events_repo, engine, "EXEC_HOLD", "execution", "INFO", cfg, "{\"reason\":\"dust_or_zero_delta\"}");
                    return "plan_hold";
                }
                // Residual below instrument mins after partial(s).
                logEventPayload(events_repo, engine, "EXEC_REPLAN_HOLD", "execution", "INFO", cfg, "{\"reason\":\"residual_dust\"}");
                return if (any_fill) "partial_then_hold" else last_note;
            },
            .order => |o| o,
        };

        if (seq > 0) {
            var rbuf: [192]u8 = undefined;
            var qbuf: [48]u8 = undefined;
            const q_s = decFmt(&qbuf, po.qty);
            const rp = std.fmt.bufPrint(
                &rbuf,
                "{{\"decision_id\":\"{s}\",\"seq\":{d},\"side\":\"{s}\",\"qty\":\"{s}\"}}",
                .{ decision_id, seq, po.side.jsonName(), q_s },
            ) catch "{\"replan\":true}";
            logEventPayload(events_repo, engine, "EXEC_REPLAN", "execution", "INFO", cfg, rp);
            std.debug.print("[exec] replan leg={d} side={s} qty={s}\n", .{ seq, po.side.jsonName(), q_s });
        }

        const leg = placeDemoLeg(
            gpa,
            okx,
            cfg,
            engine,
            orders_repo,
            fills_repo,
            events_repo,
            decision_id,
            snap.version,
            seq,
            po,
            mark,
            instrument,
            prefer_limit,
            order_policy.urgency,
            order_policy.max_wait_ms,
        );
        last_note = leg;

        if (ab.okx_trade.wantsResidualPlan(leg)) {
            any_fill = true;
            // Pull venue balances so residual plan uses true position (§5.5).
            _ = refreshDemoPortfolio(gpa, okx, engine);
            snap = engine.snapshot();
            if (std.mem.eql(u8, leg, "filled")) {
                // If residual is dust, done; else continue for another leg.
                const mark2 = if (snap.mark_price.gt(ab.decimal.Decimal.zero)) snap.mark_price else snap.bid_price;
                const eq2 = if (snap.conservative_equity.gt(ab.decimal.Decimal.zero)) snap.conservative_equity else snap.cash_usdt;
                const more = ab.planner.plan(.{
                    .cash_usdt = snap.cash_usdt,
                    .btc_total = snap.btc_total,
                    .equity = eq2,
                    .mark_price = mark2,
                    .admitted_btc_weight = admission.admitted_weight,
                    .instrument = instrument,
                }) catch break;
                if (more == .hold) return "filled";
            }
            if (!ab.okx_trade.canPlaceAnotherLeg(seq)) break;
            continue;
        }
        // Terminal non-success or ambiguous — stop (fail-closed, no blind resend).
        return leg;
    }

    if (any_fill and std.mem.eql(u8, last_note, "partial")) return "partial_max_legs";
    return last_note;
}

/// Apply private REST balances into the engine (demo only). Returns false on probe failure.
fn refreshDemoPortfolio(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    engine: *ab.state.Engine,
) bool {
    const probe = probePrivateBalance(gpa, okx);
    switch (probe) {
        .ok => |b| {
            _ = engine.apply(.{ .reconcile_result = .{
                .ts_ms = nowMs(),
                .cash_usdt = b.usdt_cash,
                .btc_total = b.btc_cash,
                .btc_available = b.btc_avail,
                .hwm_from_db = engine.snapshot().high_watermark,
                .clean = true,
            } }) catch {};
            return true;
        },
        .err => return false,
    }
}

/// Single place + query/resolve leg. `seq` differentiates client_order_id on replans.
/// When `prefer_limit`, posts a limit at urgency-adjusted mark (tick-snapped).
fn placeDemoLeg(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    orders_repo: *ab.storage.OrdersRepo,
    fills_repo: *ab.storage.FillsRepo,
    events_repo: *ab.storage.EventsRepo,
    decision_id: []const u8,
    snap_version: u64,
    seq: u16,
    po: ab.planner.PlannedOrder,
    mark: ab.decimal.Decimal,
    instrument: ab.planner.Instrument,
    prefer_limit: bool,
    urgency: ab.decimal.Decimal,
    max_wait_ms: u32,
) []const u8 {
    var cl_buf: [32]u8 = undefined;
    const cl_id = ab.orders.clientOrderId(&cl_buf, decision_id, snap_version, seq);

    var px_opt: ?ab.decimal.Decimal = null;
    if (prefer_limit) {
        const max_passive = ab.decimal.Decimal.parse("0.001") catch ab.decimal.Decimal.zero; // 10 bps
        px_opt = ab.planner.limitPriceFromMark(mark, instrument.tick_size, po.side, urgency, max_passive) catch null;
        if (px_opt == null) return "limit_price_error";
    }

    var body_buf: [384]u8 = undefined;
    const body = blk: {
        if (px_opt) |px| {
            break :blk ab.okx_trade.formatPlaceLimitBody(&body_buf, .{
                .inst_id = cfg.instrument,
                .side = po.side,
                .qty = po.qty,
                .price = px,
                .client_order_id = cl_id,
            }) catch return "body_error";
        } else {
            break :blk ab.okx_trade.formatPlaceMarketBody(&body_buf, .{
                .inst_id = cfg.instrument,
                .side = po.side,
                .qty = po.qty,
                .client_order_id = cl_id,
            }) catch return "body_error";
        }
    };

    var qty_buf: [48]u8 = undefined;
    const qty_s = decFmt(&qty_buf, po.qty);
    var price_buf: [48]u8 = undefined;
    const price_s: []const u8 = if (px_opt) |px| decFmt(&price_buf, px) else "market";
    const ts_now = nowMs();
    var ts_buf: [32]u8 = undefined;
    const ts = ab.clock.formatRfc3339Ms(ts_now, &ts_buf) catch return "ts_error";

    orders_repo.upsert(.{
        .client_order_id = cl_id,
        .exchange_order_id = "",
        .decision_id = decision_id,
        .side = po.side.jsonName(),
        .qty = qty_s,
        .price = price_s,
        .status = ab.orders.OrderStatus.planned.jsonName(),
        .created_ts = ts,
        .updated_ts = ts,
    }) catch {};

    var status = ab.orders.OrderStatus.planned;
    status = ab.orders.next(status, .submit) catch .submitted;

    const resp = okx.postPrivate("/api/v5/trade/order", body, ts_now) catch {
        status = ab.orders.next(status, .timeout) catch .unknown;
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        orders_repo.upsert(.{
            .client_order_id = cl_id,
            .decision_id = decision_id,
            .side = po.side.jsonName(),
            .qty = qty_s,
            .price = price_s,
            .status = status.jsonName(),
            .created_ts = ts,
            .updated_ts = ts,
        }) catch {};
        _ = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);
        logEventPayload(events_repo, engine, "ORDER_UNKNOWN", "execution", "CRITICAL", cfg, "{\"reason\":\"http_timeout_or_error\"}");
        return "unknown_http";
    };
    defer gpa.free(resp);

    const ack = ab.okx_rest.parseOrderAck(gpa, resp) catch {
        status = ab.orders.next(status, .timeout) catch .unknown;
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        _ = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);
        return "unknown_parse";
    };

    if (!ack.s_code_ok) {
        status = ab.orders.next(status, .reject_confirmed) catch .rejected;
        orders_repo.upsert(.{
            .client_order_id = cl_id,
            .exchange_order_id = ack.exchangeOrderId(),
            .decision_id = decision_id,
            .side = po.side.jsonName(),
            .qty = qty_s,
            .price = price_s,
            .status = status.jsonName(),
            .created_ts = ts,
            .updated_ts = ts,
        }) catch {};
        var rbuf: [288]u8 = undefined;
        const rp = std.fmt.bufPrint(
            &rbuf,
            "{{\"clOrdId\":\"{s}\",\"status\":\"REJECTED\",\"side\":\"{s}\",\"qty\":\"{s}\",\"px\":\"{s}\",\"seq\":{d}}}",
            .{ cl_id, po.side.jsonName(), qty_s, price_s, seq },
        ) catch "{\"status\":\"REJECTED\"}";
        logEventPayload(events_repo, engine, "ORDER_REJECTED", "execution", "WARN", cfg, rp);
        return "rejected";
    }

    status = ab.orders.next(status, .ack) catch .acknowledged;
    const ex_id = ack.exchangeOrderId();
    orders_repo.upsert(.{
        .client_order_id = cl_id,
        .exchange_order_id = ex_id,
        .decision_id = decision_id,
        .side = po.side.jsonName(),
        .qty = qty_s,
        .price = price_s,
        .status = status.jsonName(),
        .created_ts = ts,
        .updated_ts = ts,
    }) catch {};

    var abuf: [360]u8 = undefined;
    const ap = std.fmt.bufPrint(
        &abuf,
        "{{\"clOrdId\":\"{s}\",\"ordId\":\"{s}\",\"side\":\"{s}\",\"qty\":\"{s}\",\"px\":\"{s}\",\"status\":\"ACKNOWLEDGED\",\"seq\":{d}}}",
        .{ cl_id, ex_id, po.side.jsonName(), qty_s, price_s, seq },
    ) catch "{\"status\":\"ACKNOWLEDGED\"}";
    logEventPayload(events_repo, engine, "ORDER_ACK", "execution", "INFO", cfg, ap);

    var resolved = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);

    // LIMIT_ONLY: do not leave working leaves when replan may fire.
    if (prefer_limit and std.mem.eql(u8, resolved, "partial")) {
        _ = cancelDemoClOrd(gpa, okx, cfg, engine, events_repo, cl_id, "partial_remainder", 0);
        resolved = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);
        if (std.mem.eql(u8, resolved, "canceled")) resolved = "partial";
        return resolved;
    }

    // Poll until terminal or max_wait, then cancel remainder (no stuck leaves).
    if (prefer_limit and isOpenOrderNote(resolved)) {
        resolved = waitOrCancelLimit(
            gpa,
            okx,
            cfg,
            engine,
            orders_repo,
            fills_repo,
            events_repo,
            decision_id,
            cl_id,
            po.side.jsonName(),
            qty_s,
            ts,
            max_wait_ms,
        );
    }
    return resolved;
}

fn isOpenOrderNote(note: []const u8) bool {
    return std.mem.eql(u8, note, "acked") or
        std.mem.eql(u8, note, "open") or
        std.mem.eql(u8, note, "partial");
}

fn cancelDemoClOrd(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
    cl_id: []const u8,
    reason: []const u8,
    wait_ms: u32,
) bool {
    var cbuf: [192]u8 = undefined;
    const cbody = ab.okx_trade.formatCancelBody(&cbuf, .{
        .inst_id = cfg.instrument,
        .client_order_id = cl_id,
    }) catch return false;
    const resp = okx.postPrivate("/api/v5/trade/cancel-order", cbody, nowMs()) catch return false;
    defer gpa.free(resp);
    var pbuf: [224]u8 = undefined;
    const p = std.fmt.bufPrint(
        &pbuf,
        "{{\"clOrdId\":\"{s}\",\"reason\":\"{s}\",\"wait_ms\":{d}}}",
        .{ cl_id, reason, wait_ms },
    ) catch "{\"reason\":\"cancel\"}";
    logEventPayload(events_repo, engine, "ORDER_CANCEL_SENT", "execution", "INFO", cfg, p);
    return true;
}

/// Poll order state until terminal or deadline; cancel if still working.
fn waitOrCancelLimit(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    orders_repo: *ab.storage.OrdersRepo,
    fills_repo: *ab.storage.FillsRepo,
    events_repo: *ab.storage.EventsRepo,
    decision_id: []const u8,
    cl_id: []const u8,
    side: []const u8,
    qty_s: []const u8,
    ts: []const u8,
    max_wait_ms: u32,
) []const u8 {
    const wait_cap_ms: u32 = if (max_wait_ms == 0) 30_000 else @min(max_wait_ms, 300_000);
    const deadline = nowMs() + @as(i64, wait_cap_ms);
    var last: []const u8 = "acked";

    while (nowMs() < deadline) {
        // Prefer the process Io clock (Zig 0.16); no Thread.sleep / posix.nanosleep.
        okx.http.io.sleep(.{ .nanoseconds = 250_000_000 }, .awake) catch {};
        last = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, side, qty_s, ts);
        if (std.mem.eql(u8, last, "partial")) {
            _ = cancelDemoClOrd(gpa, okx, cfg, engine, events_repo, cl_id, "partial_remainder", wait_cap_ms);
            last = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, side, qty_s, ts);
            if (std.mem.eql(u8, last, "canceled")) return "partial";
            return last;
        }
        if (!isOpenOrderNote(last)) return last;
    }

    _ = cancelDemoClOrd(gpa, okx, cfg, engine, events_repo, cl_id, "max_wait_ms", wait_cap_ms);
    last = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, side, qty_s, ts);
    if (std.mem.eql(u8, last, "filled") or std.mem.eql(u8, last, "partial")) return last;
    if (std.mem.eql(u8, last, "canceled")) return "limit_timeout";
    return last;
}

fn queryAndResolveOrder(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    orders_repo: *ab.storage.OrdersRepo,
    fills_repo: *ab.storage.FillsRepo,
    events_repo: *ab.storage.EventsRepo,
    decision_id: []const u8,
    cl_id: []const u8,
    side: []const u8,
    qty_s: []const u8,
    ts: []const u8,
) []const u8 {
    var path_buf: [192]u8 = undefined;
    const path = ab.okx_trade.formatQueryPath(&path_buf, cfg.instrument, cl_id) catch return "query_path_error";
    const body = okx.getPrivate(path, nowMs()) catch {
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        return "query_http_error";
    };
    defer gpa.free(body);

    const q = ab.okx_rest.parseOrderQuery(gpa, body) catch {
        // Empty data often means not found yet or never accepted.
        if (std.mem.indexOf(u8, body, "\"data\":[]") != null) {
            orders_repo.upsert(.{
                .client_order_id = cl_id,
                .decision_id = decision_id,
                .side = side,
                .qty = qty_s,
                .price = "market",
                .status = ab.orders.OrderStatus.canceled.jsonName(),
                .created_ts = ts,
                .updated_ts = ts,
            }) catch {};
            _ = engine.apply(.{ .order_ambiguity = .{ .present = false } }) catch {};
            return "not_found_canceled";
        }
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        return "query_parse_error";
    };

    const st = ab.okx_trade.mapOkxState(q.status());
    var fill_buf: [48]u8 = undefined;
    const fill_s = decFmt(&fill_buf, q.filled_qty);
    var avg_buf: [48]u8 = undefined;
    const avg_s = if (q.avg_price.gt(ab.decimal.Decimal.zero)) decFmt(&avg_buf, q.avg_price) else "market";
    orders_repo.upsert(.{
        .client_order_id = cl_id,
        .decision_id = decision_id,
        .side = side,
        .qty = qty_s,
        .price = avg_s,
        .status = st.jsonName(),
        .created_ts = ts,
        .updated_ts = ts,
    }) catch {};

    // Projection fill row when exchange reports cumulative filled qty.
    // Idempotent fill_id = clOrdId + "f0" (single aggregate for REST query path;
    // private WS multi-fill can mint f1/f2 later).
    if (q.filled_qty.gt(ab.decimal.Decimal.zero)) {
        var fid_buf: [40]u8 = undefined;
        const fill_id = std.fmt.bufPrint(&fid_buf, "{s}f0", .{cl_id}) catch "fill0";
        fills_repo.append(.{
            .fill_id = fill_id,
            .order_id = cl_id,
            .price = avg_s,
            .qty = fill_s,
            .fee = "0",
            .fee_ccy = "USDT",
            .ts = ts,
        }) catch {};
    }

    if (st == .filled or st == .canceled or st == .rejected) {
        _ = engine.apply(.{ .order_ambiguity = .{ .present = false } }) catch {};
    } else if (st == .unknown or st == .partial or st == .acknowledged) {
        // Market orders usually fill quickly; leave ambiguity only for unknown.
        _ = engine.apply(.{ .order_ambiguity = .{ .present = st == .unknown } }) catch {};
    }

    var pbuf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &pbuf,
        "{{\"clOrdId\":\"{s}\",\"okx_state\":\"{s}\",\"status\":\"{s}\",\"filled\":\"{s}\",\"avgPx\":\"{s}\"}}",
        .{ cl_id, q.status(), st.jsonName(), fill_s, avg_s },
    ) catch "{}";
    logEventPayload(events_repo, engine, "ORDER_QUERY", "execution", "INFO", cfg, payload);

    return switch (st) {
        .filled => "filled",
        .partial => "partial",
        .canceled => "canceled",
        .rejected => "rejected",
        .acknowledged => "acked",
        else => "open",
    };
}

/// Cancel pending demo orders (shadow: no-op count 0).
fn adminCancelAll(
    gpa: std.mem.Allocator,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
) usize {
    if (!ab.okx_trade.executionAllowed(cfg.mode == .demo, exec_venue_authorized)) return 0;

    var path_buf: [160]u8 = undefined;
    const path = ab.okx_trade.formatPendingPath(&path_buf, cfg.instrument) catch return 0;
    const body = okx.getPrivate(path, nowMs()) catch return 0;
    defer gpa.free(body);

    var ids: [32][]const u8 = undefined;
    var backing: [1024]u8 = undefined;
    const n = ab.okx_rest.parsePendingClOrdIds(gpa, body, &ids, &backing) catch 0;
    var canceled: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var cbuf: [192]u8 = undefined;
        const cbody = ab.okx_trade.formatCancelBody(&cbuf, .{
            .inst_id = cfg.instrument,
            .client_order_id = ids[i],
        }) catch continue;
        if (okx.postPrivate("/api/v5/trade/cancel-order", cbody, nowMs())) |resp| {
            defer gpa.free(resp);
            canceled += 1;
            var pbuf: [160]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "{{\"clOrdId\":\"{s}\"}}", .{ids[i]}) catch "{}";
            logEventPayload(events_repo, engine, "ORDER_CANCEL_SENT", "execution", "INFO", cfg, p);
        } else |_| {}
    }
    return canceled;
}

fn completeRun(
    runs: *ab.storage.AgentRunsRepo,
    run_id: []const u8,
    status: []const u8,
    out_digest: []const u8,
    input_digest: []const u8,
    finished_ms: i64,
) void {
    var ts_buf: [32]u8 = undefined;
    const ts = ab.clock.formatRfc3339Ms(finished_ms, &ts_buf) catch return;
    runs.completeWithInput(run_id, status, out_digest, input_digest, ts) catch |err| {
        std.debug.print("[agent] agent_runs complete failed: {t}\n", .{err});
    };
}

const MemLoadCtx = struct {
    store: *ab.memory.Store,
};

fn loadMemCb(ctx: *anyopaque, row: ab.storage.MemoryRow) void {
    const self: *MemLoadCtx = @ptrCast(@alignCast(ctx));
    const kind = ab.memory.Kind.fromString(row.kind) orelse return;
    const status = ab.memory.Status.fromString(row.status) orelse .active;
    var conf_buf: [32]u8 = undefined;
    const conf_s = std.fmt.bufPrint(&conf_buf, "{d:.6}", .{row.confidence}) catch "0";
    const conf = ab.decimal.Decimal.parse(conf_s) catch ab.decimal.Decimal.zero;
    const created = ab.clock.parseRfc3339Ms(row.created_ts) catch 0;
    self.store.load(.{
        .memory_id = row.memory_id,
        .version = @intCast(@max(row.version, 1)),
        .kind = kind,
        .status = status,
        .confidence = conf,
        .evidence_count = @intCast(@max(row.evidence_count, 0)),
        .content_json = row.content_json,
        .created_ms = created,
    }) catch {};
}

fn loadMemoriesFromDb(repo: *ab.storage.MemoriesRepo, db: *ab.storage.Db, store: *ab.memory.Store) void {
    var ctx = MemLoadCtx{ .store = store };
    repo.forEachLatest(db, &ctx, loadMemCb) catch |err| {
        std.debug.print("[boot] memories load failed: {t}\n", .{err});
    };
}

fn persistMemory(repo: *ab.storage.MemoriesRepo, m: ab.memory.Memory) void {
    var ts_buf: [32]u8 = undefined;
    const ts = ab.clock.formatRfc3339Ms(m.created_ms, &ts_buf) catch return;
    var conf_buf: [48]u8 = undefined;
    const conf_s = decFmt(&conf_buf, m.confidence);
    const conf_f = std.fmt.parseFloat(f64, conf_s) catch 0;
    repo.append(.{
        .memory_id = m.memory_id,
        .version = @intCast(m.version),
        .kind = m.kind.text(),
        .status = m.status.text(),
        .confidence = conf_f,
        .evidence_count = @intCast(m.evidence_count),
        .content_json = m.content_json,
        .created_ts = ts,
    }) catch |err| {
        std.debug.print("[memory] persist failed: {t}\n", .{err});
    };
}

fn seedBootstrapMemories(
    gpa: std.mem.Allocator,
    store: *ab.memory.Store,
    repo: *ab.storage.MemoriesRepo,
    events_repo: *ab.storage.EventsRepo,
    engine: *ab.state.Engine,
    cfg: *const ab.config.Config,
) void {
    var touched: std.ArrayList(ab.memory.Memory) = .empty;
    defer touched.deinit(gpa);
    const now = nowMs();
    store.applyOp(.{ .create = .{
        .memory_id = "W_shadow_policy",
        .kind = .working,
        .status = .active,
        .confidence = ab.decimal.Decimal.parse("0.95") catch ab.decimal.Decimal.one,
        .content_json = "{\"summary\":\"Shadow mode never places orders; proposals are audited only.\",\"tags\":[\"shadow\",\"BTC-USDT\",\"policy\"]}",
    } }, now, &touched) catch {};
    store.applyOp(.{ .create = .{
        .memory_id = "H_btc_spot_default",
        .kind = .strategy,
        .status = .unverified,
        .confidence = ab.decimal.Decimal.parse("0.40") catch ab.decimal.Decimal.zero,
        .content_json = "{\"hypothesis\":\"Default to HOLD until multi-hour evidence favors risk; prefer cash over forced BTC exposure in shadow.\",\"tags\":[\"BTC\",\"BTC-USDT\",\"shadow\"]}",
    } }, now, &touched) catch {};
    for (touched.items) |m| persistMemory(repo, m);
    logEventPayload(events_repo, engine, "MEMORY_BOOTSTRAP", "memory", "INFO", cfg, "{\"seeded\":true}");
    std.debug.print("[boot] seeded bootstrap memories n={d}\n", .{touched.items.len});
}

fn recordProposalEpisode(
    gpa: std.mem.Allocator,
    store: *ab.memory.Store,
    repo: *ab.storage.MemoriesRepo,
    run_id: []const u8,
    decision_id: []const u8,
    action: []const u8,
    target: ab.decimal.Decimal,
    conf: ab.decimal.Decimal,
) void {
    var id_buf: [80]u8 = undefined;
    const mid = std.fmt.bufPrint(&id_buf, "E_{s}", .{run_id}) catch return;
    var t_buf: [48]u8 = undefined;
    var c_buf: [48]u8 = undefined;
    const t_s = decFmt(&t_buf, target);
    const c_s = decFmt(&c_buf, conf);
    var content_buf: [512]u8 = undefined;
    const content = std.fmt.bufPrint(
        &content_buf,
        "{{\"type\":\"proposal_episode\",\"run_id\":\"{s}\",\"decision_id\":\"{s}\",\"action\":\"{s}\",\"target_btc_weight\":\"{s}\",\"confidence\":\"{s}\",\"tags\":[\"BTC-USDT\",\"shadow\",\"episode\"]}}",
        .{ run_id, decision_id, action, t_s, c_s },
    ) catch return;
    var touched: std.ArrayList(ab.memory.Memory) = .empty;
    defer touched.deinit(gpa);
    store.applyOp(.{ .create = .{
        .memory_id = mid,
        .kind = .episodic,
        .status = .active,
        .confidence = conf,
        .content_json = content,
    } }, nowMs(), &touched) catch return;
    for (touched.items) |m| persistMemory(repo, m);

    // Refresh working "last decision" pointer (update if exists else create).
    var w_content_buf: [256]u8 = undefined;
    const w_content = std.fmt.bufPrint(
        &w_content_buf,
        "{{\"summary\":\"Last shadow proposal {s} action={s}\",\"decision_id\":\"{s}\",\"tags\":[\"BTC-USDT\",\"shadow\"]}}",
        .{ run_id, action, decision_id },
    ) catch return;
    touched.clearRetainingCapacity();
    if (store.find("W_last_decision") != null) {
        store.applyOp(.{ .update = .{
            .memory_id = "W_last_decision",
            .confidence_delta = ab.decimal.Decimal.zero,
            .evidence_increment = 1,
            .new_status = .active,
            .content_json = w_content,
        } }, nowMs(), &touched) catch {};
    } else {
        store.applyOp(.{ .create = .{
            .memory_id = "W_last_decision",
            .kind = .working,
            .status = .active,
            .confidence = ab.decimal.Decimal.parse("0.7") catch ab.decimal.Decimal.zero,
            .content_json = w_content,
        } }, nowMs(), &touched) catch {};
    }
    for (touched.items) |m| persistMemory(repo, m);
}

fn refreshSystemCache(
    ws: *WebState,
    db: *ab.storage.Db,
    cfg: *const ab.config.Config,
    mem_store: *const ab.memory.Store,
    boot_ms: i64,
    private_keys: bool,
    private_ws: bool,
    agent_on: bool,
    paused: bool,
    st: *const RuntimeStatus,
    risk_lat: *const ab.latency.Histogram,
) void {
    const total = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs") catch 0;
    const ok = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status = 'ok'") catch 0;
    const invalid = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status LIKE 'invalid%'") catch 0;
    const errors = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status LIKE 'error%'") catch 0;
    const tools_n = ab.storage.Db.queryInt(db, "SELECT COUNT(*) FROM tool_calls") catch 0;
    const rate: f64 = if (total > 0) @as(f64, @floatFromInt(ok)) * 100.0 / @as(f64, @floatFromInt(total)) else 0;
    const uptime = @max(@as(i64, 0), nowMs() - boot_ms);
    const mode_txt: []const u8 = switch (cfg.mode) {
        .shadow => "shadow",
        .demo => "demo",
        .live => "live",
    };
    var tmp: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tmp);
    w.print(
        "{{\"software_version\":\"{s}\",\"config_hash\":\"{s}\",\"mode\":\"{s}\",\"instrument\":\"{s}\",\"ready\":true,\"paused\":{},\"started_ms\":{d},\"uptime_ms\":{d},\"web_bind\":\"{s}\",\"private_keys\":{},\"private_ws_opt_in\":{},\"agent_enabled\":{},\"memories\":{d},",
        .{
            version_string,
            cfg.hash(),
            mode_txt,
            cfg.instrument,
            paused,
            boot_ms,
            uptime,
            cfg.web_bind,
            private_keys,
            private_ws,
            agent_on,
            mem_store.count(),
        },
    ) catch return;
    w.print(
        "\"agent\":{{\"total\":{d},\"ok\":{d},\"invalid\":{d},\"errors\":{d},\"valid_rate\":{d:.1},\"tool_calls\":{d}}},",
        .{ total, ok, invalid, errors, rate, tools_n },
    ) catch return;
    w.print(
        "\"schedule\":{{\"base_ms\":{d},\"quiet_ms\":{d},\"min_ms\":{d},\"active_hours_utc\":\"{s}\",\"price_move\":\"{f}\",\"drawdown_step\":\"{f}\",\"reflect_on_hold\":{}}},",
        .{
            cfg.decision_interval_ms,
            cfg.decision_interval_quiet_ms,
            cfg.decision_min_interval_ms,
            if (cfg.active_hours_utc.len > 0) cfg.active_hours_utc else "always",
            cfg.event_price_move,
            cfg.event_drawdown_step,
            cfg.agent_llm_reflection_on_hold,
        },
    ) catch return;
    w.print(
        "\"status\":{{\"okx_public\":\"{s}\",\"okx_public_ms\":{d},\"okx_public_detail\":\"{s}\",\"okx_private\":\"{s}\",\"okx_private_ms\":{d},\"okx_private_detail\":\"{s}\",\"llm\":\"{s}\",\"llm_ms\":{d},\"llm_detail\":\"{s}\",\"last_bid\":\"{s}\",",
        .{
            st.okx_public,
            st.okx_public_ms,
            st.okx_public_detail,
            st.okx_private,
            st.okx_private_ms,
            st.okx_private_detail,
            st.llm,
            st.llm_ms,
            st.llm_detail,
            st.last_bid,
        },
    ) catch return;
    w.print(
        "\"latency_us\":{{\"p50\":{d},\"p99\":{d},\"max\":{d},\"samples\":{d}}},",
        .{ risk_lat.percentile(50), risk_lat.percentile(99), risk_lat.maxUs(), risk_lat.count() },
    ) catch return;
    w.print(
        "\"egress_ip\":\"{s}\",\"egress_ip_ms\":{d},\"disk\":\"{s}\",\"disk_free_bytes\":{d},\"disk_ms\":{d},\"llm_calls\":{d},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"acct_usdt\":\"{s}\",\"acct_btc\":\"{s}\",\"last_decision\":\"{s}\",\"last_decision_ms\":{d}}}}}",
        .{
            st.egress_ip,
            st.egress_ip_ms,
            st.disk,
            st.disk_free_bytes,
            st.disk_ms,
            st.llm_calls,
            st.prompt_tokens,
            st.completion_tokens,
            st.total_tokens,
            st.acct_usdt,
            st.acct_btc,
            st.last_decision,
            st.last_decision_ms,
        },
    ) catch return;
    ws.setJson(.system, w.buffered());
}

/// AC-FD7: classify free space on the DB volume and feed the risk engine.
fn refreshDiskStatus(
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
    st: *RuntimeStatus,
) void {
    const free = ab.storage_disk.freeBytes(cfg.db_path) catch {
        st.setDisk("unknown", 0);
        return;
    };
    const band = ab.storage_policy.classifyDiskFree(
        free,
        ab.storage_disk.default_low_bytes,
        ab.storage_disk.default_critical_bytes,
    );
    const band_txt: []const u8 = switch (band) {
        .ok => "ok",
        .low => "low",
        .critical => "critical",
    };
    st.setDisk(band_txt, free);

    const prev = engine.snapshot();
    // disk_ok false for low/critical so evaluateHealth stays degraded.
    const disk_ok = band == .ok;
    _ = engine.apply(.{ .disk_status = .{ .ok = disk_ok } }) catch {};
    if (band == .critical) {
        // Escalate to HALTED; sticky until operator_reset.
        _ = engine.apply(.{ .risk_trigger = .fatal }) catch {};
    }
    const snap = engine.snapshot();
    if (snap.risk_mode != prev.risk_mode or (!disk_ok and prev.disk_ok)) {
        std.debug.print(
            "[disk] band={s} free_bytes={d} risk_mode={s}\n",
            .{ band_txt, free, snap.risk_mode.jsonName() },
        );
        var pbuf: [192]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &pbuf,
            "{{\"band\":\"{s}\",\"free_bytes\":{d},\"risk_mode\":\"{s}\"}}",
            .{ band_txt, free, snap.risk_mode.jsonName() },
        ) catch "{\"band\":\"?\"}";
        const sev: []const u8 = if (band == .critical) "CRITICAL" else if (band == .low) "WARN" else "INFO";
        logEventPayload(events_repo, engine, "DISK_STATUS", "storage", sev, cfg, payload);
    }
}

fn refreshEgressIp(okx: *ab.okx_rest.Client, st: *RuntimeStatus) void {
    // Best-effort; never let a half-closed pooled socket permanently block egress probe.
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        var sink: [ab.security_limits.max_probe_response_bytes]u8 = undefined;
        var fixed_writer: std.Io.Writer = .fixed(&sink);
        const result = okx.http.fetch(.{
            .location = .{ .url = "https://api.ipify.org" },
            .method = .GET,
            .response_writer = &fixed_writer,
            .keep_alive = false,
        }) catch {
            if (attempt == 0) {
                const io = okx.http.io;
                const allocator = okx.http.allocator;
                okx.http.deinit();
                okx.http = .{ .allocator = allocator, .io = io };
                continue;
            }
            return;
        };
        _ = result;
        const body = fixed_writer.buffered();
        const ip = std.mem.trim(u8, body, " \t\r\n");
        if (ip.len > 0 and ip.len < 64) st.setEgress(ip);
        return;
    }
}

/// AC-OPS4 restore drill: read-only verification of a backup snapshot.
/// Exit 0 = verifiable (integrity ok, schema current, projections readable).
fn verifyDbSnapshot(path: []const u8) u8 {
    var path_buf: [640:0]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
        std.debug.print("[verify-db] path too long\n", .{});
        return 1;
    };
    var db = ab.storage.Db.openReadOnly(zpath) catch {
        std.debug.print("[verify-db] FAIL open read-only: {s}\n", .{path});
        return 1;
    };
    defer db.close();

    var fails: u8 = 0;

    // 1. Page-level integrity.
    {
        var stmt = db.prepare("PRAGMA integrity_check") catch {
            std.debug.print("[verify-db] FAIL integrity_check prepare\n", .{});
            return 1;
        };
        defer stmt.finalize();
        const row = stmt.step() catch false;
        const verdict = if (row) stmt.columnText(0) else "no-result";
        if (!std.mem.eql(u8, verdict, "ok")) {
            std.debug.print("[verify-db] FAIL integrity_check: {s}\n", .{verdict});
            fails += 1;
        } else {
            std.debug.print("[verify-db] integrity_check ok\n", .{});
        }
    }

    // 2. Schema version matches this binary's migrations.
    {
        const uv = db.queryInt("PRAGMA user_version") catch -1;
        if (uv != ab.storage.expected_user_version) {
            std.debug.print("[verify-db] FAIL user_version {d} != expected {d}\n", .{ uv, ab.storage.expected_user_version });
            fails += 1;
        } else {
            std.debug.print("[verify-db] user_version {d} ok\n", .{uv});
        }
    }

    // 3. Core projections are present and readable.
    const events = db.queryInt("SELECT COUNT(*) FROM events") catch -1;
    const orders = db.queryInt("SELECT COUNT(*) FROM orders") catch -1;
    const fills = db.queryInt("SELECT COUNT(*) FROM fills") catch -1;
    const equity = db.queryInt("SELECT COUNT(*) FROM equity_samples") catch -1;
    const runs = db.queryInt("SELECT COUNT(*) FROM agent_runs") catch -1;
    const mems = db.queryInt("SELECT COUNT(*) FROM memories") catch -1;
    std.debug.print(
        "[verify-db] counts events={d} orders={d} fills={d} equity_samples={d} agent_runs={d} memories={d}\n",
        .{ events, orders, fills, equity, runs, mems },
    );
    if (events < 0 or orders < 0 or fills < 0 or equity < 0 or runs < 0 or mems < 0) {
        std.debug.print("[verify-db] FAIL missing core table(s)\n", .{});
        fails += 1;
    }

    // 4. Event sequence sane: ids unique (PK) and seq strictly positive range.
    if (events > 0) {
        const min_seq = db.queryInt("SELECT MIN(seq) FROM events") catch -1;
        const max_seq = db.queryInt("SELECT MAX(seq) FROM events") catch -1;
        if (min_seq < 1 or max_seq < min_seq) {
            std.debug.print("[verify-db] FAIL event seq range min={d} max={d}\n", .{ min_seq, max_seq });
            fails += 1;
        } else {
            std.debug.print("[verify-db] event seq {d}..{d} ok\n", .{ min_seq, max_seq });
        }
    }

    // 5. HWM restorable: latest sample parses as a non-negative decimal.
    if (equity > 0) {
        var stmt = db.prepare("SELECT hwm FROM equity_samples ORDER BY ts DESC LIMIT 1") catch {
            std.debug.print("[verify-db] FAIL hwm query\n", .{});
            return fails + 1;
        };
        defer stmt.finalize();
        if (stmt.step() catch false) {
            const hwm_text = stmt.columnText(0);
            const hwm = ab.decimal.Decimal.parse(hwm_text) catch {
                std.debug.print("[verify-db] FAIL hwm unparseable: {s}\n", .{hwm_text});
                fails += 1;
                return fails;
            };
            if (hwm.isNegative()) {
                std.debug.print("[verify-db] FAIL hwm negative\n", .{});
                fails += 1;
            } else {
                std.debug.print("[verify-db] hwm {s} restorable\n", .{hwm_text});
            }
        }
    }

    // 6. Audit chain (AC-GO5): every order traceable to its decision event
    //    (decision_id → AGENT_PROPOSAL_OK payload, carrying snapshot_version
    //    + admission verdict), stamped with config_hash/software_version,
    //    covered by ORDER_* events; fills must reference a known order.
    {
        const o_no_dec = db.queryInt(
            "SELECT COUNT(*) FROM orders WHERE decision_id = ''",
        ) catch -1;
        const o_no_proposal = db.queryInt(
            \\SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (
            \\  SELECT 1 FROM events e WHERE e.type = 'AGENT_PROPOSAL_OK'
            \\  AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0)
        ) catch -1;
        const o_unstamped_dec = db.queryInt(
            \\SELECT COUNT(*) FROM orders o WHERE EXISTS (
            \\  SELECT 1 FROM events e WHERE e.type = 'AGENT_PROPOSAL_OK'
            \\  AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0
            \\  AND (e.config_hash = '' OR e.software_version = ''))
        ) catch -1;
        const o_no_events = db.queryInt(
            \\SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (
            \\  SELECT 1 FROM events e WHERE e.type LIKE 'ORDER_%'
            \\  AND instr(e.payload_json, o.client_order_id) > 0)
        ) catch -1;
        const orphan_fills = db.queryInt(
            \\SELECT COUNT(*) FROM fills f WHERE NOT EXISTS (
            \\  SELECT 1 FROM orders o WHERE o.client_order_id = f.order_id)
        ) catch -1;
        if (o_no_dec != 0 or o_no_proposal != 0 or o_unstamped_dec != 0 or
            o_no_events != 0 or orphan_fills != 0)
        {
            std.debug.print(
                "[verify-db] FAIL audit chain: no_decision_id={d} no_proposal_event={d} unstamped_decision={d} no_order_events={d} orphan_fills={d}\n",
                .{ o_no_dec, o_no_proposal, o_unstamped_dec, o_no_events, orphan_fills },
            );
            fails += 1;
        } else {
            std.debug.print("[verify-db] audit chain ok ({d} orders, {d} fills)\n", .{ orders, fills });
        }
    }

    if (fails == 0) {
        std.debug.print("[verify-db] PASS {s}\n", .{path});
        return 0;
    }
    std.debug.print("[verify-db] FAIL {d} check(s): {s}\n", .{ fails, path });
    return 1;
}

fn runSqliteBackup(
    io: std.Io,
    db: *ab.storage.Db,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
) void {
    // Latest pointer: <db_path>.bak (same directory); online Backup API.
    var dest_buf: [640:0]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&dest_buf, "{s}.bak", .{cfg.db_path}) catch {
        std.debug.print("[backup] path too long\n", .{});
        return;
    };
    ab.storage.backupToPath(db, dest) catch |err| {
        std.debug.print("[backup] failed: {t}\n", .{err});
        var err_buf: [160]u8 = undefined;
        const payload = std.fmt.bufPrint(&err_buf, "{{\"dest\":\"{s}\",\"ok\":false}}", .{dest}) catch "{\"ok\":false}";
        logEventPayload(events_repo, engine, "BACKUP_FAILED", "storage", "WARN", cfg, payload);
        return;
    };
    std.debug.print("[backup] ok {s}\n", .{dest});
    var ok_buf: [200]u8 = undefined;
    const payload = std.fmt.bufPrint(&ok_buf, "{{\"dest\":\"{s}\",\"ok\":true}}", .{dest}) catch "{\"ok\":true}";
    logEventPayload(events_repo, engine, "BACKUP_DONE", "storage", "INFO", cfg, payload);

    // AC-OPS3/OPS9: rotated snapshots + retention sweep.
    const now_ms = nowMs();
    rotateBackups(io, db, cfg, now_ms);
    runRetentionSweep(db, now_ms);
}

/// Hourly/daily rotated snapshots next to the DB, pruned to the newest
/// retention.keep_hourly / keep_daily. Best-effort: failures only log.
fn rotateBackups(io: std.Io, db: *ab.storage.Db, cfg: *const ab.config.Config, now_ms: i64) void {
    var name_buf: [600]u8 = undefined;
    var z_buf: [640:0]u8 = undefined;

    // Hourly snapshot (same stamp within the hour → cheap overwrite skip).
    if (ab.retention.hourlyName(&name_buf, cfg.db_path, now_ms)) |hourly| {
        if (std.fmt.bufPrintZ(&z_buf, "{s}", .{hourly})) |zdest| {
            if (!fileExists(io, zdest)) {
                ab.storage.backupToPath(db, zdest) catch |err|
                    std.debug.print("[backup] hourly failed: {t}\n", .{err});
            }
        } else |_| {}
    } else |_| {}

    // Daily snapshot: write once per UTC day.
    if (ab.retention.dailyName(&name_buf, cfg.db_path, now_ms)) |daily| {
        if (std.fmt.bufPrintZ(&z_buf, "{s}", .{daily})) |zdest| {
            if (!fileExists(io, zdest)) {
                ab.storage.backupToPath(db, zdest) catch |err|
                    std.debug.print("[backup] daily failed: {t}\n", .{err});
            }
        } else |_| {}
    } else |_| {}

    pruneRotated(io, cfg.db_path, ab.retention.hourly_infix, ab.retention.keep_hourly);
    pruneRotated(io, cfg.db_path, ab.retention.daily_infix, ab.retention.keep_daily);
}

fn fileExists(io: std.Io, path: [:0]const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Delete rotated backups beyond the newest `keep` for the given infix.
fn pruneRotated(io: std.Io, db_path: []const u8, infix: []const u8, keep: usize) void {
    const dir_path = std.fs.path.dirname(db_path) orelse ".";
    const base_name = std.fs.path.basename(db_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const max_names = 64;
    var storage: [max_names][320]u8 = undefined;
    var names: [max_names][]const u8 = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!ab.retention.isRotatedBackup(entry.name, base_name, infix)) continue;
        if (n >= max_names or entry.name.len > storage[n].len) continue;
        @memcpy(storage[n][0..entry.name.len], entry.name);
        names[n] = storage[n][0..entry.name.len];
        n += 1;
    }

    var out: [max_names]usize = undefined;
    const doomed = ab.retention.selectDoomed(names[0..n], keep, &out);
    for (doomed) |idx| {
        dir.deleteFile(io, names[idx]) catch |err|
            std.debug.print("[backup] prune {s} failed: {t}\n", .{ names[idx], err });
    }
}

/// AC-OPS9: prune old tool_calls rows and '1s' equity samples.
fn runRetentionSweep(db: *ab.storage.Db, now_ms: i64) void {
    var cut_buf: [40]u8 = undefined;

    if (ab.retention.cutoffRfc3339(&cut_buf, now_ms, ab.retention.tool_calls_days)) |cutoff| {
        var stmt = db.prepare(ab.retention.prune_tool_calls_sql) catch return;
        defer stmt.finalize();
        stmt.bindText(1, cutoff) catch return;
        _ = stmt.step() catch |err|
            std.debug.print("[retention] tool_calls prune failed: {t}\n", .{err});
    } else |_| {}

    if (ab.retention.cutoffRfc3339(&cut_buf, now_ms, ab.retention.equity_1s_days)) |cutoff| {
        var stmt = db.prepare(ab.retention.prune_equity_1s_sql) catch return;
        defer stmt.finalize();
        stmt.bindText(1, cutoff) catch return;
        _ = stmt.step() catch |err|
            std.debug.print("[retention] equity_1s prune failed: {t}\n", .{err});
    } else |_| {}
}

fn llmReflectionWanted(env: *const std.process.Environ.Map) bool {
    // ALPHABOUND_LLM_REFLECTION=0/false/off disables even when config enables.
    const v = env.get("ALPHABOUND_LLM_REFLECTION") orelse return true;
    if (v.len == 0) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "no"))
        return false;
    return true;
}

/// Copy s into buf replacing " and \ with space — safe inside a JSON string value.
fn sanitizeJsonString(s: []const u8, buf: []u8) []const u8 {
    const n = @min(s.len, buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = s[i];
        buf[i] = if (c == '"' or c == '\\' or c == '\n' or c == '\r') ' ' else c;
    }
    return buf[0..n];
}

/// Second LLM call → strict Reflection schema → memory_ops. Returns true if applied.
fn tryLlmReflection(
    gpa: std.mem.Allocator,
    client: *ab.openai.Client,
    store: *ab.memory.Store,
    repo: *ab.storage.MemoriesRepo,
    events_repo: *ab.storage.EventsRepo,
    engine: *ab.state.Engine,
    cfg: *const ab.config.Config,
    run_id: []const u8,
    decision_id: []const u8,
    action: []const u8,
    target: ab.decimal.Decimal,
    conf: ab.decimal.Decimal,
    decision_ctx_json: []const u8,
    st: *RuntimeStatus,
) bool {
    var t_buf: [48]u8 = undefined;
    var c_buf: [48]u8 = undefined;
    const t_s = decFmt(&t_buf, target);
    const c_s = decFmt(&c_buf, conf);

    // Keep user payload bounded: proposal summary + truncated decision context.
    const ctx_snip = if (decision_ctx_json.len > 6000) decision_ctx_json[0..6000] else decision_ctx_json;
    var user_buf: [8 * 1024]u8 = undefined;
    const user_msg = std.fmt.bufPrint(
        &user_buf,
        \\Emit ONE Reflection JSON for this shadow proposal (not executed).
        \\run_id={s}
        \\decision_id={s}
        \\action={s}
        \\target_btc_weight={s}
        \\confidence={s}
        \\decision_context={s}
        \\
    ,
        .{ run_id, decision_id, action, t_s, c_s, ctx_snip },
    ) catch {
        std.debug.print("[reflect] user buffer full → deterministic\n", .{});
        return false;
    };

    std.debug.print("[reflect] LLM calling model={s}\n", .{client.model});
    const chat_res = client.chat(default_reflection_prompt, user_msg) catch |err| {
        std.debug.print("[reflect] LLM failed ({t}) → deterministic\n", .{err});
        var fail_buf: [200]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &fail_buf,
            "{{\"run_id\":\"{s}\",\"error\":\"llm\",\"fallback\":\"deterministic\"}}",
            .{run_id},
        ) catch "{\"fallback\":\"deterministic\"}";
        logEventPayload(events_repo, engine, "AGENT_REFLECTION_LLM_FAILED", "memory", "WARN", cfg, payload);
        return false;
    };
    defer gpa.free(chat_res.content);
    st.addUsage(chat_res.usage);
    st.setLlm("ok", "reflection");
    const raw = chat_res.content;

    const json_slice = ab.openai.extractJsonObject(raw) orelse {
        std.debug.print("[reflect] no JSON → deterministic\n", .{});
        logEventPayload(events_repo, engine, "AGENT_REFLECTION_INVALID", "memory", "WARN", cfg, "{\"reason\":\"no_json\",\"fallback\":\"deterministic\"}");
        return false;
    };

    var reflection = ab.reflection.parse(gpa, json_slice) catch |err| {
        std.debug.print("[reflect] parse invalid ({t}) → deterministic\n", .{err});
        var inv_buf: [160]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &inv_buf,
            "{{\"reason\":\"{t}\",\"fallback\":\"deterministic\"}}",
            .{err},
        ) catch "{\"fallback\":\"deterministic\"}";
        logEventPayload(events_repo, engine, "AGENT_REFLECTION_INVALID", "memory", "WARN", cfg, payload);
        return false;
    };
    defer reflection.deinit();

    const applied = applyReflectionOps(gpa, store, repo, reflection.memory_ops);
    // Always journal a reflection memory row summarizing the document.
    var rid_buf: [80]u8 = undefined;
    const rid = std.fmt.bufPrint(&rid_buf, "R_{s}", .{run_id}) catch return applied > 0;
    var content_buf: [1024]u8 = undefined;
    var lesson_buf: [256]u8 = undefined;
    var expected_buf: [256]u8 = undefined;
    const lesson0 = sanitizeJsonString(if (reflection.lessons.len > 0) reflection.lessons[0] else "", &lesson_buf);
    const expected0 = sanitizeJsonString(reflection.expected_outcome, &expected_buf);
    const content = std.fmt.bufPrint(
        &content_buf,
        "{{\"episode_id\":\"{s}\",\"expected_outcome\":\"{s}\",\"actual_outcome\":{s},\"lesson\":\"{s}\",\"ops\":{d},\"source\":\"llm\",\"tags\":[\"BTC-USDT\",\"shadow\",\"reflection\"]}}",
        .{ reflection.episode_id, expected0, reflection.actual_outcome_json, lesson0, applied },
    ) catch null;
    if (content) |cj| {
        var touched: std.ArrayList(ab.memory.Memory) = .empty;
        defer touched.deinit(gpa);
        // Prefer CREATE; if id collides (re-run), UPDATE content.
        if (store.find(rid) == null) {
            store.applyOp(.{ .create = .{
                .memory_id = rid,
                .kind = .reflection,
                .status = .active,
                .confidence = conf,
                .content_json = cj,
            } }, nowMs(), &touched) catch {};
        } else {
            store.applyOp(.{ .update = .{
                .memory_id = rid,
                .evidence_increment = 1,
                .new_status = .active,
                .content_json = cj,
            } }, nowMs(), &touched) catch {};
        }
        for (touched.items) |m| persistMemory(repo, m);
    }

    var ok_buf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &ok_buf,
        "{{\"run_id\":\"{s}\",\"decision_id\":\"{s}\",\"episode_id\":\"{s}\",\"ops_applied\":{d},\"source\":\"llm\"}}",
        .{ run_id, decision_id, reflection.episode_id, applied },
    ) catch "{\"source\":\"llm\"}";
    logEventPayload(events_repo, engine, "AGENT_REFLECTION_OK", "memory", "INFO", cfg, payload);
    std.debug.print("[reflect] LLM ok episode={s} ops_applied={d}\n", .{ reflection.episode_id, applied });
    return true;
}

fn applyReflectionOps(
    gpa: std.mem.Allocator,
    store: *ab.memory.Store,
    repo: *ab.storage.MemoriesRepo,
    ops: []const ab.memory.Op,
) usize {
    var applied: usize = 0;
    var touched: std.ArrayList(ab.memory.Memory) = .empty;
    defer touched.deinit(gpa);
    for (ops) |op| {
        touched.clearRetainingCapacity();
        // Skip destructive ops on bootstrap policy.
        switch (op) {
            .invalidate => |i| {
                if (std.mem.eql(u8, i.memory_id, "W_shadow_policy")) continue;
            },
            .merge => |m| {
                if (std.mem.eql(u8, m.from_id, "W_shadow_policy") or std.mem.eql(u8, m.into_id, "W_shadow_policy")) continue;
            },
            else => {},
        }
        store.applyOp(op, nowMs(), &touched) catch |err| {
            std.debug.print("[reflect] op skipped: {t}\n", .{err});
            continue;
        };
        for (touched.items) |m| persistMemory(repo, m);
        applied += 1;
    }
    return applied;
}

/// Deterministic shadow reflection: structured memory_ops without a second LLM call.
/// Fail-closed on store errors; never touches orders.
fn applyShadowReflection(
    gpa: std.mem.Allocator,
    store: *ab.memory.Store,
    repo: *ab.storage.MemoriesRepo,
    events_repo: *ab.storage.EventsRepo,
    engine: *ab.state.Engine,
    cfg: *const ab.config.Config,
    run_id: []const u8,
    decision_id: []const u8,
    action: []const u8,
    target: ab.decimal.Decimal,
    conf: ab.decimal.Decimal,
) void {
    var touched: std.ArrayList(ab.memory.Memory) = .empty;
    defer touched.deinit(gpa);
    const now = nowMs();

    var id_buf: [80]u8 = undefined;
    const rid = std.fmt.bufPrint(&id_buf, "R_{s}", .{run_id}) catch return;
    var t_buf: [48]u8 = undefined;
    var c_buf: [48]u8 = undefined;
    const t_s = decFmt(&t_buf, target);
    const c_s = decFmt(&c_buf, conf);
    var content_buf: [640]u8 = undefined;
    const content = std.fmt.bufPrint(
        &content_buf,
        "{{\"episode_id\":\"ep_{s}\",\"expected_outcome\":\"shadow audit only\",\"actual_outcome\":{{\"executed\":false,\"action\":\"{s}\",\"target_btc_weight\":\"{s}\"}},\"lessons\":[\"Proposals remain non-executing in shadow.\"],\"tags\":[\"BTC-USDT\",\"shadow\",\"reflection\"],\"decision_id\":\"{s}\",\"confidence\":\"{s}\"}}",
        .{ run_id, action, t_s, decision_id, c_s },
    ) catch return;

    store.applyOp(.{ .create = .{
        .memory_id = rid,
        .kind = .reflection,
        .status = .active,
        .confidence = conf,
        .content_json = content,
    } }, now, &touched) catch |err| {
        std.debug.print("[reflect] create failed: {t}\n", .{err});
        return;
    };

    // Touch strategy hypothesis with tiny evidence if present.
    if (store.find("H_btc_spot_default") != null) {
        const delta = if (std.mem.eql(u8, action, "HOLD"))
            (ab.decimal.Decimal.parse("0.01") catch ab.decimal.Decimal.zero)
        else
            (ab.decimal.Decimal.parse("-0.01") catch ab.decimal.Decimal.zero);
        store.applyOp(.{ .update = .{
            .memory_id = "H_btc_spot_default",
            .confidence_delta = delta,
            .evidence_increment = 1,
            .new_status = .active,
        } }, now, &touched) catch {};
    }

    for (touched.items) |m| persistMemory(repo, m);

    var payload_buf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"run_id\":\"{s}\",\"decision_id\":\"{s}\",\"reflection_id\":\"{s}\",\"ops\":{d},\"source\":\"deterministic_shadow\"}}",
        .{ run_id, decision_id, rid, touched.items.len },
    ) catch "{\"source\":\"deterministic_shadow\"}";
    logEventPayload(events_repo, engine, "AGENT_REFLECTION_OK", "memory", "INFO", cfg, payload);
    std.debug.print("[reflect] ok id={s} ops={d}\n", .{ rid, touched.items.len });
}

fn webThreadMain(io: std.Io, host: []const u8, port: u16, ws: *WebState) void {
    ab.web.serve(io, .{ .host = host, .port = port }, WebState.contextFn, ws) catch |err| {
        std.debug.print("[web] server stopped: {t} (bind {s}:{d})\n", .{ err, host, port });
        if (err == error.AddressInUse) {
            std.debug.print(
                "[web] hint: port in use — change [web].bind in config or free the listener (lsof -nP -iTCP:{d} -sTCP:LISTEN)\n",
                .{port},
            );
        }
    };
}

var event_counter = std.atomic.Value(u64).init(0);

/// Venue authorization for demo execution: simulated keys, or explicit
/// real-money opt-in (OKX_REAL_MONEY_OK=1). Set once during boot.
var exec_venue_authorized: bool = false;

fn logEvent(
    repo: *ab.storage.EventsRepo,
    engine: *ab.state.Engine,
    event_type: []const u8,
    source: []const u8,
    severity: []const u8,
    cfg: *const ab.config.Config,
) void {
    logEventPayload(repo, engine, event_type, source, severity, cfg, "{}");
}

fn logEventPayload(
    repo: *ab.storage.EventsRepo,
    engine: *ab.state.Engine,
    event_type: []const u8,
    source: []const u8,
    severity: []const u8,
    cfg: *const ab.config.Config,
    payload_json: []const u8,
) void {
    const snap = engine.snapshot();
    const n = event_counter.fetchAdd(1, .monotonic);
    var id_buf: [64]u8 = undefined;
    const event_id = std.fmt.bufPrint(&id_buf, "evt_{d}_{d}", .{ nowMs(), n }) catch return;
    var ts_buf: [32]u8 = undefined;
    const ts = ab.clock.formatRfc3339Ms(nowMs(), &ts_buf) catch return;
    // Boundary redaction (§7.3 / AC-SEC3): never persist secrets in event payloads.
    var red_buf: [4096]u8 = undefined;
    const safe_payload = if (payload_json.len + 64 <= red_buf.len)
        ab.redaction.redact(payload_json, &red_buf)
    else
        payload_json;
    if (ab.redaction.looksLeaky(safe_payload)) {
        std.debug.print("[journal] drop leaky payload for {s}\n", .{event_type});
        return;
    }
    repo.append(.{
        .event_id = event_id,
        .ts = ts,
        .type = event_type,
        .source = source,
        .severity = severity,
        .state_version = @intCast(snap.version),
        .software_version = version_string,
        .config_hash = cfg.hash(),
        .payload_json = safe_payload,
    }) catch |err| {
        std.debug.print("[journal] append failed: {t}\n", .{err});
    };
}

fn writeEquitySample(repo: *ab.storage.EquityRepo, snap: ab.state.PortfolioState) void {
    var ts_buf: [32]u8 = undefined;
    const ts = ab.clock.formatRfc3339Ms(snap.as_of_ms, &ts_buf) catch return;
    var e_buf: [48]u8 = undefined;
    var h_buf: [48]u8 = undefined;
    var d_buf: [48]u8 = undefined;
    var c_buf: [48]u8 = undefined;
    var b_buf: [48]u8 = undefined;
    const btc_value = snap.btc_total.mul(snap.bid_price, .down) catch ab.decimal.Decimal.zero;
    repo.append(.{
        .ts = ts,
        .interval = "1m",
        .equity = decFmt(&e_buf, snap.conservative_equity),
        .hwm = decFmt(&h_buf, snap.high_watermark),
        .drawdown = decFmt(&d_buf, snap.drawdown),
        .cash = decFmt(&c_buf, snap.cash_usdt),
        .btc_value = decFmt(&b_buf, btc_value),
    }) catch |err| {
        std.debug.print("[journal] equity sample failed: {t}\n", .{err});
    };
}

fn decFmt(buf: []u8, v: ab.decimal.Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

test "version string sane" {
    try std.testing.expect(version_string.len >= 5);
}
