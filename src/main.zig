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

    fn load(map: *const std.process.Environ.Map) ?OkxEnvCreds {
        const key = map.get("OKX_API_KEY") orelse return null;
        const secret = map.get("OKX_API_SECRET") orelse return null;
        const pass = map.get("OKX_API_PASSPHRASE") orelse return null;
        if (key.len == 0 or secret.len == 0 or pass.len == 0) return null;
        const sim_raw = map.get("OKX_SIMULATED") orelse "";
        const simulated = std.mem.eql(u8, sim_raw, "1") or std.mem.eql(u8, sim_raw, "true");
        return .{
            .api_key = key,
            .secret_key = secret,
            .passphrase = pass,
            .simulated = simulated,
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
    /// One-shot local admin command: pause|resume|reconcile|shutdown|status.
    control_cmd: ?[]const u8 = null,
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
    candles_buf: [12288]u8 = undefined,
    candles_len: usize = 2,
    memories_buf: [8192]u8 = undefined,
    memories_len: usize = 2,
    system_buf: [4096]u8 = undefined,
    system_len: usize = 2,
    decisions_buf: [49152]u8 = undefined,
    decisions_len: usize = 2,

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
            var candles: [12288]u8 = undefined;
            var memories: [8192]u8 = undefined;
            var system: [4096]u8 = undefined;
            var decisions: [49152]u8 = undefined;
            var config_hash: [71]u8 = undefined;
            var agent_len: usize = 2;
            var equity_len: usize = 2;
            var events_len: usize = 2;
            var shadow_len: usize = 2;
            var candles_len: usize = 2;
            var memories_len: usize = 2;
            var system_len: usize = 2;
            var decisions_len: usize = 2;
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
            if (al > Tls.agent.len or el > Tls.equity.len or vl > Tls.events.len or sl > Tls.shadow.len or cl > Tls.candles.len or ml > Tls.memories.len or yl > Tls.system.len or dl > Tls.decisions.len) {
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
            @memcpy(Tls.config_hash[0..], self.config_hash[0..]);
            Tls.agent_len = al;
            Tls.equity_len = el;
            Tls.events_len = vl;
            Tls.shadow_len = sl;
            Tls.candles_len = cl;
            Tls.memories_len = ml;
            Tls.system_len = yl;
            Tls.decisions_len = dl;
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

    fn setJson(self: *WebState, comptime which: enum { agent, equity, events, shadow, candles, memories, system, decisions }, src: []const u8) void {
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
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    const cli = parseArgs(init.minimal.args) catch {
        std.debug.print(
            "usage: alphabound [--config PATH] [--self-check] [--version] [--ticks N] [--agent-once] [--agent-stats] [--control CMD]\n",
            .{},
        );
        return 2;
    };

    if (cli.show_version) {
        std.debug.print("alphabound {s}\n", .{version_string});
        return 0;
    }

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

    var db_path_buf: [512:0]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&db_path_buf, "{s}", .{cfg.db_path}) catch return 1;

    // Ensure parent dir for relative local db paths exists is caller's job;
    // open fails clearly if missing.
    var db = ab.storage.Db.open(db_path) catch |err| {
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
            "[self-check] ok\n  config_hash:  {s}\n  instrument:   {s}\n  mode:         {t}\n  max_drawdown: {f}\n  db:           {s} (user_version {d})\n  web:          {s}\n  okx_keys:     {s}\n  agent:        enabled={} provider={s} model={s} base_url={s} interval_ms={d} llm_keys={s}\n",
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
                cfg.decision_interval_ms,
                if (llm_env != null) "present" else "absent",
            },
        );

        // Optional private read-only probe when keys are loaded.
        if (okx_env) |c| {
            var okx_sc = ab.okx_rest.Client.init(gpa, io, cfg.rest_url, c.asAuth());
            defer okx_sc.deinit();
            okx_sc.simulated = c.simulated or cfg.mode == .demo;
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
        okx.simulated = c.simulated or cfg.mode == .demo;
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
    // Shadow: engine cash = initial_capital (simulated). When keys exist we still
    // probe private balance read-only for Gate 1 connectivity — never place orders.
    const now_boot = nowMs();
    if (okx_env != null) {
        const probe = probePrivateBalance(gpa, &okx);
        switch (probe) {
            .ok => |b| {
                std.debug.print(
                    "[reconcile] private balance ok usdt={f} avail={f} btc={f} (shadow keeps simulated engine cash)\n",
                    .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
                );
                logEvent(&events_repo, &engine, "PRIVATE_BALANCE_OK", "exchange", "INFO", &cfg);
            },
            .err => |e| {
                std.debug.print("[reconcile] private balance FAILED: {s}\n", .{e});
                logEvent(&events_repo, &engine, "PRIVATE_BALANCE_FAILED", "exchange", "CRITICAL", &cfg);
                // Shadow may continue on public data; demo requires working keys.
                if (cfg.mode == .demo) return 1;
            },
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
        .cash_usdt = cfg.initial_capital,
        .btc_total = ab.decimal.Decimal.zero,
        .btc_available = ab.decimal.Decimal.zero,
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
        "[ready] mode={t} live {s} data, simulated engine cash {f} USDT, web {s}, private_keys={s}, agent={s}\n",
        .{
            cfg.mode,
            cfg.instrument,
            cfg.initial_capital,
            cfg.web_bind,
            if (okx_env != null) "yes" else "no",
            if (llm_client != null) "on" else "off",
        },
    );
    web_state.update(engine.snapshot(), true);
    refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, last_bh_cmp);
    refreshCandlesCache(gpa, &web_state, &okx, &cfg);
    refreshEgressIp(gpa, &okx, &runtime_status);
    refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status);
    logEvent(&events_repo, &engine, "STATE_READY", "core", "INFO", &cfg);

    var tick_count: u64 = 0;
    var last_sample_min: i64 = 0;
    var last_agent_ms: i64 = 0;
    var last_private_ms: i64 = 0;
    var last_dashboard_ms: i64 = 0;
    var agent_done_once = false;
    var ticker_path_buf: [128]u8 = undefined;
    const ticker_path = std.fmt.bufPrint(&ticker_path_buf, "/api/v5/market/ticker?instId={s}", .{cfg.instrument}) catch return 1;
    // Gate 1: periodic private REST reconcile; private WS is boot probe + optional re-probe.
    const private_reconcile_ms: i64 = 60_000;
    const dashboard_refresh_ms: i64 = 5_000;
    const private_ws_reprobe_ms: i64 = 300_000;
    const backup_interval_ms: i64 = 3_600_000;
    const egress_refresh_ms: i64 = 3_600_000;
    var last_egress_ms: i64 = 0;
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
                const res = engine.apply(.{ .market_tick = .{
                    .ts_ms = ticker.ts_ms,
                    .bid = ticker.bid,
                    .mark = ticker.last,
                } }) catch continue;
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
        refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status);

        // Slow agent loop (shadow): proposals audited only — never sent to exchange.
        // Paused: keep risk/market/reconcile; skip agent decisions.
        if (!admin_paused) {
            if (llm_client) |*client| {
                const tnow = nowMs();
                const due_interval = cfg.decision_interval_ms > 0 and
                    (last_agent_ms == 0 or tnow - last_agent_ms >= @as(i64, cfg.decision_interval_ms));
                const due_once = cli.agent_once and !agent_done_once and tick_count >= 1;
                if (due_interval or due_once) {
                    last_agent_ms = tnow;
                    agent_done_once = true;
                    runAgentDecision(gpa, client, &okx, &cfg, &engine, &tool_reg, &agent_runs, &tool_calls, &events_repo, &db, &mem_store, &memories_repo, env, &runtime_status);
                    refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, last_bh_cmp);
                    refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status);
                }
            }
        }

        // Refresh dashboard JSON caches from SQLite (single-writer thread).
        {
            const tnow = nowMs();
            if (last_dashboard_ms == 0 or tnow - last_dashboard_ms >= dashboard_refresh_ms) {
                last_dashboard_ms = tnow;
                refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, last_bh_cmp);
                refreshCandlesCache(gpa, &web_state, &okx, &cfg);
                refreshSystemCache(&web_state, &db, &cfg, &mem_store, boot_ms, okx_env != null, envGetTruthy(env, "ALPHABOUND_PRIVATE_WS"), llm_client != null, admin_paused, &runtime_status);
            }
            if (last_egress_ms == 0 or tnow - last_egress_ms >= egress_refresh_ms) {
                last_egress_ms = tnow;
                refreshEgressIp(gpa, &okx, &runtime_status);
            }
            if (last_backup_ms == 0 or tnow - last_backup_ms >= backup_interval_ms) {
                last_backup_ms = tnow;
                runSqliteBackup(&db, &cfg, &engine, &events_repo);
            }
        }

        tick_count += 1;
        io.sleep(.{ .nanoseconds = @as(i96, cfg.poll_interval_ms) * 1_000_000 }, .awake) catch break;
    }

    // ---- Graceful shutdown (§7.4) -------------------------------------------
    std.debug.print("[shutdown] draining after {d} ticks\n", .{tick_count});
    writeEquitySample(&equity_repo, engine.snapshot());
    refreshWebCaches(&web_state, &db, &agent_runs, &equity_repo, &events_repo, &memories_repo, last_bh_cmp);
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
        std.debug.print("[control] unknown cmd '{s}' (pause|resume|reconcile|shutdown|status)\n", .{cmd_name});
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
}

fn refreshCandlesCache(
    gpa: std.mem.Allocator,
    ws: *WebState,
    okx: *ab.okx_rest.Client,
    cfg: *const ab.config.Config,
) void {
    var path_buf: [160]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "/api/v5/market/candles?instId={s}&bar=1H&limit=48",
        .{cfg.instrument},
    ) catch return;
    const body = okx.getPublic(path) catch return;
    defer gpa.free(body);
    var candles: [48]ab.okx_rest.Candle = undefined;
    const count = ab.okx_rest.parseCandles(gpa, body, &candles) catch return;
    if (count == 0) return;
    // Chronological for sparkline (OKX is newest-first).
    var ordered: [48]ab.okx_rest.Candle = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        ordered[i] = candles[count - 1 - i];
    }
    var tmp: [12288]u8 = undefined;
    if (formatCandlesApiJson(&tmp, cfg.instrument, ordered[0..count])) |j| {
        ws.setJson(.candles, j);
    } else |_| {}
}

fn formatCandlesApiJson(buf: []u8, instrument: []const u8, candles: []const ab.okx_rest.Candle) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"instrument\":\"{s}\",\"bar\":\"1H\",\"candles\":[", .{instrument}) catch return error.BufferTooSmall;
    for (candles, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print(
            "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\"}}",
            .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol },
        ) catch return error.BufferTooSmall;
    }
    w.writeAll("]}") catch return error.BufferTooSmall;
    return w.buffered();
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
            std.debug.print(
                "[reconcile] private balance ok usdt={f} avail={f} btc={f} (shadow engine cash unchanged)\n",
                .{ b.usdt_cash, b.usdt_avail, b.btc_cash },
            );
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

/// One slow-loop decision: tools → context → LLM → proposal parse → journal. No orders.
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
    db: *ab.storage.Db,
    mem_store: *ab.memory.Store,
    memories_repo: *ab.storage.MemoriesRepo,
    env: *const std.process.Environ.Map,
    st: *RuntimeStatus,
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

    // Shadow: never execute. Audit only.
    const action_txt: []const u8 = switch (prop.action) {
        .hold => "HOLD",
        .rebalance => "REBALANCE",
    };
    std.debug.print(
        "[agent] proposal ok id={s} action={s} target_btc={f} conf={f} mem={d} (shadow: not executed)\n",
        .{ prop.decision_id, action_txt, prop.target_btc_weight, prop.confidence, scored.items.len },
    );
    completeRun(runs, run_id, "ok", out_digest, input_digest, nowMs());
    recordProposalEpisode(gpa, mem_store, memories_repo, run_id, prop.decision_id, action_txt, prop.target_btc_weight, prop.confidence);
    // Reflection: prefer LLM structured memory_ops; fail-closed → deterministic.
    const want_llm_reflect = cfg.agent_llm_reflection and llmReflectionWanted(env);
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

    var ok_buf: [512]u8 = undefined;
    var w_buf: [48]u8 = undefined;
    var c_buf: [48]u8 = undefined;
    const weight_s = decFmt(&w_buf, prop.target_btc_weight);
    const conf_s = decFmt(&c_buf, prop.confidence);
    const ok_payload = std.fmt.bufPrint(
        &ok_buf,
        "{{\"run_id\":\"{s}\",\"decision_id\":\"{s}\",\"action\":\"{s}\",\"target_btc_weight\":\"{s}\",\"confidence\":\"{s}\",\"snapshot_version\":{d},\"output_digest\":\"{s}\",\"tools\":{d},\"executed\":false,\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}",
        .{ run_id, prop.decision_id, action_txt, weight_s, conf_s, prop.snapshot_version, out_digest, obs_n, chat_res.usage.prompt_tokens, chat_res.usage.completion_tokens, chat_res.usage.total_tokens },
    ) catch "{\"executed\":false}";
    {
        var dbuf: [96]u8 = undefined;
        const dtxt = std.fmt.bufPrint(&dbuf, "{s} {s} conf={s}", .{ action_txt, prop.decision_id, conf_s }) catch action_txt;
        st.setLastDecision(dtxt);
    }
    logEventPayload(events_repo, engine, "AGENT_PROPOSAL_OK", "agent", "INFO", cfg, ok_payload);
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
        "\"egress_ip\":\"{s}\",\"egress_ip_ms\":{d},\"llm_calls\":{d},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"acct_usdt\":\"{s}\",\"acct_btc\":\"{s}\",\"last_decision\":\"{s}\",\"last_decision_ms\":{d}}}}}",
        .{
            st.egress_ip,
            st.egress_ip_ms,
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

fn refreshEgressIp(gpa: std.mem.Allocator, okx: *ab.okx_rest.Client, st: *RuntimeStatus) void {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    const result = okx.http.fetch(.{
        .location = .{ .url = "https://api.ipify.org" },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch return;
    _ = result;
    var list = aw.toArrayList();
    const body = list.toOwnedSlice(gpa) catch return;
    defer gpa.free(body);
    const ip = std.mem.trim(u8, body, " \t\r\n");
    if (ip.len > 0 and ip.len < 64) st.setEgress(ip);
}


fn runSqliteBackup(
    db: *ab.storage.Db,
    cfg: *const ab.config.Config,
    engine: *ab.state.Engine,
    events_repo: *ab.storage.EventsRepo,
) void {
    // dest = <db_path>.bak (same directory); online Backup API.
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
