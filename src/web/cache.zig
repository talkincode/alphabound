//! Dashboard JSON cache layer: seqlock-published state + pre-rendered API
//! blobs the web thread serves lock-free. Extracted from main.zig; the core
//! loop is the single writer, web connections are readers.

const std = @import("std");
const state = @import("../core/state.zig");
const web = @import("server.zig");
const web_auth = @import("auth.zig");
const storage = @import("../storage/db.zig");
const shadow_bench = @import("../core/shadow_bench.zig");
const okx_rest = @import("../exchange/okx/rest.zig");
const config = @import("../config.zig");
const memory = @import("../memory/store.zig");
const latency = @import("../observability/latency.zig");
const openai = @import("../agent/openai.zig");
const clock = @import("../core/clock.zig");
const review = @import("review.zig");
const analytics = @import("../analytics/ab_factor.zig");

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

pub const WebState = struct {
    /// Seqlock: odd = write in progress. Single writer (core loop), many
    /// readers (web connections) — no blocking, no Io dependency.
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    snapshot: state.PortfolioState = .{},
    ready: bool = false,
    config_hash: [71]u8 = @splat(0),
    /// Set once at boot (main owns the literals / embedded blob).
    software_version: []const u8 = "",
    index_html: []const u8 = "",
    /// Pre-rendered JSON blobs (owned buffers inside WebState).
    agent_runs_buf: [24576]u8 = undefined,
    agent_runs_len: usize = 2,
    /// ~1m samples × ~170B; 48KiB holds ~280 points (~4.5h) with headroom.
    equity_buf: [49152]u8 = undefined,
    equity_len: usize = 2,
    events_buf: [12288]u8 = undefined,
    events_len: usize = 2,
    shadow_buf: [512]u8 = undefined,
    shadow_len: usize = 2,
    /// Multi-timeframe candles JSON (分时/1m…1D); sized for ~1k bars total.
    candles_buf: [131072]u8 = undefined,
    candles_len: usize = 2,
    memories_buf: [24576]u8 = undefined,
    memories_len: usize = 2,
    system_buf: [8192]u8 = undefined,
    system_len: usize = 2,
    decisions_buf: [49152]u8 = undefined,
    decisions_len: usize = 2,
    /// Bundle: {"orders":[...],"fills":[...]}.
    orders_buf: [24576]u8 = undefined,
    orders_len: usize = 2,
    /// 复盘 chat transcripts (recent turns, newest first).
    review_buf: [49152]u8 = undefined,
    review_len: usize = 2,
    /// Last requested 复盘 context window: {"decision_id":..,"events":[..]}.
    review_ctx_buf: [24576]u8 = undefined,
    review_ctx_len: usize = 2,
    /// Review request mailbox (web thread enqueues, core loop drains).
    review_inbox: ?*review.Inbox = null,
    /// Recent scheduled-audit reports (newest first).
    audit_buf: [24576]u8 = undefined,
    audit_len: usize = 2,
    /// Recent 定期复盘 reports (newest first; 8h + weekly cycles).
    periodic_buf: [49152]u8 = undefined,
    periodic_len: usize = 2,
    /// AB 因子复盘 analytics blob (experimental; sized for 48h/5m + IC rows).
    /// Must match the worst-case test in src/analytics/ab_factor.zig.
    analytics_buf: [131072]u8 = undefined,
    analytics_len: usize = 2,
    /// Durable LLM / portfolio / trading statistics (UTC windows).
    statistics_buf: [98304]u8 = undefined,
    statistics_len: usize = 2,
    /// Dashboard / MCP auth (optional; empty token = open).
    auth_cfg: web_auth.Config = .{},
    cred_store: ?*web_auth.CredStore = null,
    challenges: ?*web_auth.ChallengeBank = null,
    fail_guard: ?*web_auth.FailGuard = null,
    trust_proxy: bool = false,
    trusted_proxy_hops: u32 = 1,

    pub fn initEmpty(self: *WebState) void {
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
        @memcpy(self.review_buf[0..2], "[]");
        self.review_len = 2;
        @memcpy(self.review_ctx_buf[0..2], "{}");
        self.review_ctx_len = 2;
        @memcpy(self.audit_buf[0..2], "[]");
        self.audit_len = 2;
        @memcpy(self.periodic_buf[0..2], "[]");
        self.periodic_len = 2;
        @memcpy(self.analytics_buf[0..2], "{}");
        self.analytics_len = 2;
        @memcpy(self.statistics_buf[0..2], "{}");
        self.statistics_len = 2;
    }

    pub fn contextFn(userdata: ?*anyopaque) web.Context {
        // Process-static copies so returned Context slices stay stable across
        // handle()/copyBody even if the core loop mutates WebState mid-request.
        // Safe: web accept loop is single-threaded.
        const Tls = struct {
            var agent: [24576]u8 = undefined;
            var equity: [49152]u8 = undefined;
            var events: [12288]u8 = undefined;
            var shadow: [512]u8 = undefined;
            var candles: [131072]u8 = undefined;
            var memories: [24576]u8 = undefined;
            var system: [8192]u8 = undefined;
            var decisions: [49152]u8 = undefined;
            var orders: [24576]u8 = undefined;
            var review_chats: [49152]u8 = undefined;
            var review_ctx: [24576]u8 = undefined;
            var audit: [24576]u8 = undefined;
            var periodic: [49152]u8 = undefined;
            var analytics: [131072]u8 = undefined;
            var statistics: [98304]u8 = undefined;
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
            var review_len: usize = 2;
            var review_ctx_len: usize = 2;
            var audit_len: usize = 2;
            var periodic_len: usize = 2;
            var analytics_len: usize = 2;
            var statistics_len: usize = 2;
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
            const rl = self.review_len;
            const rcl = self.review_ctx_len;
            const aul = self.audit_len;
            const pdl = self.periodic_len;
            const anl = self.analytics_len;
            const stl = self.statistics_len;
            if (al > Tls.agent.len or el > Tls.equity.len or vl > Tls.events.len or sl > Tls.shadow.len or cl > Tls.candles.len or ml > Tls.memories.len or yl > Tls.system.len or dl > Tls.decisions.len or ol > Tls.orders.len or rl > Tls.review_chats.len or rcl > Tls.review_ctx.len or aul > Tls.audit.len or pdl > Tls.periodic.len or anl > Tls.analytics.len or stl > Tls.statistics.len) {
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
            @memcpy(Tls.review_chats[0..rl], self.review_buf[0..rl]);
            @memcpy(Tls.review_ctx[0..rcl], self.review_ctx_buf[0..rcl]);
            @memcpy(Tls.audit[0..aul], self.audit_buf[0..aul]);
            @memcpy(Tls.periodic[0..pdl], self.periodic_buf[0..pdl]);
            @memcpy(Tls.analytics[0..anl], self.analytics_buf[0..anl]);
            @memcpy(Tls.statistics[0..stl], self.statistics_buf[0..stl]);
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
            Tls.review_len = rl;
            Tls.review_ctx_len = rcl;
            Tls.audit_len = aul;
            Tls.periodic_len = pdl;
            Tls.analytics_len = anl;
            Tls.statistics_len = stl;
            const s2 = self.seq.load(.acquire);
            if (s1 == s2) {
                return .{
                    .snapshot = snap,
                    .ready = ready,
                    .software_version = self.software_version,
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
                    .review_json = Tls.review_chats[0..Tls.review_len],
                    .review_ctx_json = Tls.review_ctx[0..Tls.review_ctx_len],
                    .review_inbox = self.review_inbox,
                    .audit_json = Tls.audit[0..Tls.audit_len],
                    .periodic_json = Tls.periodic[0..Tls.periodic_len],
                    .analytics_json = Tls.analytics[0..Tls.analytics_len],
                    .statistics_json = Tls.statistics[0..Tls.statistics_len],
                    .index_html = self.index_html,
                    .auth_cfg = self.auth_cfg,
                    .cred_store = self.cred_store,
                    .challenges = self.challenges,
                    .fail_guard = self.fail_guard,
                    .trust_proxy = self.trust_proxy,
                    .trusted_proxy_hops = self.trusted_proxy_hops,
                };
            }
        }
    }

    pub fn update(self: *WebState, snap: state.PortfolioState, ready: bool) void {
        _ = self.seq.fetchAdd(1, .acq_rel); // odd: writing
        self.snapshot = snap;
        self.ready = ready;
        _ = self.seq.fetchAdd(1, .release); // even: stable
    }

    pub fn setJson(self: *WebState, comptime which: enum { agent, equity, events, shadow, candles, memories, system, decisions, orders, review, review_ctx, audit, periodic, analytics, statistics }, src: []const u8) void {
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
            .review => {
                const n = @min(src.len, self.review_buf.len);
                @memcpy(self.review_buf[0..n], src[0..n]);
                self.review_len = n;
            },
            .review_ctx => {
                const n = @min(src.len, self.review_ctx_buf.len);
                @memcpy(self.review_ctx_buf[0..n], src[0..n]);
                self.review_ctx_len = n;
            },
            .audit => {
                const n = @min(src.len, self.audit_buf.len);
                @memcpy(self.audit_buf[0..n], src[0..n]);
                self.audit_len = n;
            },
            .periodic => {
                const n = @min(src.len, self.periodic_buf.len);
                @memcpy(self.periodic_buf[0..n], src[0..n]);
                self.periodic_len = n;
            },
            .analytics => {
                const n = @min(src.len, self.analytics_buf.len);
                @memcpy(self.analytics_buf[0..n], src[0..n]);
                self.analytics_len = n;
            },
            .statistics => {
                const n = @min(src.len, self.statistics_buf.len);
                @memcpy(self.statistics_buf[0..n], src[0..n]);
                self.statistics_len = n;
            },
        }
        _ = self.seq.fetchAdd(1, .release);
    }
};

/// Live connectivity/status snapshot for Dashboard「状态」页.
pub const RuntimeStatus = struct {
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
    // Scheduled audit surface (定时审计): status + findings for the alert bell.
    audit_status: []const u8 = "unknown",
    audit_ms: i64 = 0,
    audit_findings: u32 = 0,
    audit_alerts: []const u8 = "[]",
    audit_alerts_buf: [3072]u8 = undefined,
    // 定期复盘 surface: last cycle outcome + next-due countdowns.
    review_status: []const u8 = "idle",
    review_cycle: []const u8 = "",
    review_ms: i64 = 0,
    review_next_short_ms: i64 = 0,
    review_next_long_ms: i64 = 0,
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

    pub fn addUsage(self: *RuntimeStatus, u: openai.Usage) void {
        self.llm_calls += 1;
        self.prompt_tokens += u.prompt_tokens;
        self.completion_tokens += u.completion_tokens;
        self.total_tokens += if (u.total_tokens > 0) u.total_tokens else u.prompt_tokens + u.completion_tokens;
    }
    pub fn setBid(self: *RuntimeStatus, bid_txt: []const u8) void {
        const n = @min(bid_txt.len, self.bid_buf.len);
        @memcpy(self.bid_buf[0..n], bid_txt[0..n]);
        self.bid_len = n;
        self.last_bid = self.bid_buf[0..self.bid_len];
    }
    pub fn setPub(self: *RuntimeStatus, status: []const u8, detail: []const u8) void {
        self.okx_public = status;
        self.okx_public_ms = nowMs();
        const n = @min(detail.len, self.pub_detail_buf.len);
        @memcpy(self.pub_detail_buf[0..n], detail[0..n]);
        self.pub_detail_len = n;
        self.okx_public_detail = self.pub_detail_buf[0..self.pub_detail_len];
    }
    pub fn setPriv(self: *RuntimeStatus, status: []const u8, detail: []const u8) void {
        self.okx_private = status;
        self.okx_private_ms = nowMs();
        const n = @min(detail.len, self.priv_detail_buf.len);
        @memcpy(self.priv_detail_buf[0..n], detail[0..n]);
        self.priv_detail_len = n;
        self.okx_private_detail = self.priv_detail_buf[0..self.priv_detail_len];
    }
    pub fn setLlm(self: *RuntimeStatus, status: []const u8, detail: []const u8) void {
        self.llm = status;
        self.llm_ms = nowMs();
        const n = @min(detail.len, self.llm_detail_buf.len);
        @memcpy(self.llm_detail_buf[0..n], detail[0..n]);
        self.llm_detail_len = n;
        self.llm_detail = self.llm_detail_buf[0..self.llm_detail_len];
    }
    pub fn setAccount(self: *RuntimeStatus, usdt: []const u8, btc: []const u8) void {
        var n = @min(usdt.len, self.acct_usdt_buf.len);
        @memcpy(self.acct_usdt_buf[0..n], usdt[0..n]);
        self.acct_usdt = self.acct_usdt_buf[0..n];
        n = @min(btc.len, self.acct_btc_buf.len);
        @memcpy(self.acct_btc_buf[0..n], btc[0..n]);
        self.acct_btc = self.acct_btc_buf[0..n];
    }
    pub fn setLastDecision(self: *RuntimeStatus, text: []const u8) void {
        const n = @min(text.len, self.last_decision_buf.len);
        @memcpy(self.last_decision_buf[0..n], text[0..n]);
        self.last_decision = self.last_decision_buf[0..n];
        self.last_decision_ms = nowMs();
    }

    /// Publish the latest audit outcome. `status` must be a static string
    /// ("ok"/"warn"/"alert"); `alerts_json` is a findings JSON array.
    pub fn setAudit(self: *RuntimeStatus, status: []const u8, alerts_json: []const u8, findings: u32) void {
        self.audit_status = status;
        self.audit_findings = findings;
        self.audit_ms = nowMs();
        if (alerts_json.len <= self.audit_alerts_buf.len) {
            @memcpy(self.audit_alerts_buf[0..alerts_json.len], alerts_json);
            self.audit_alerts = self.audit_alerts_buf[0..alerts_json.len];
        } else {
            self.audit_alerts = "[]"; // oversized detail lives in audit_reports
        }
    }
    /// Publish the latest 定期复盘 outcome. `status` / `cycle` must be static
    /// strings ("ok"/"degraded"/"failed", "short"/"long").
    pub fn setPeriodicReview(self: *RuntimeStatus, status: []const u8, cycle: []const u8) void {
        self.review_status = status;
        self.review_cycle = cycle;
        self.review_ms = nowMs();
    }
    pub fn setReviewNext(self: *RuntimeStatus, next_short_ms: i64, next_long_ms: i64) void {
        self.review_next_short_ms = next_short_ms;
        self.review_next_long_ms = next_long_ms;
    }
    pub fn setEgress(self: *RuntimeStatus, ip: []const u8) void {
        const n = @min(ip.len, self.egress_buf.len);
        @memcpy(self.egress_buf[0..n], ip[0..n]);
        self.egress_len = n;
        self.egress_ip = self.egress_buf[0..self.egress_len];
        self.egress_ip_ms = nowMs();
    }
    pub fn setDisk(self: *RuntimeStatus, band: []const u8, free_bytes: u64) void {
        self.disk = band;
        self.disk_free_bytes = free_bytes;
        self.disk_ms = nowMs();
    }
};

pub fn refreshWebCaches(
    ws: *WebState,
    db: *storage.Db,
    runs: *storage.AgentRunsRepo,
    equity: *storage.EquityRepo,
    events: *storage.EventsRepo,
    memories: *storage.MemoriesRepo,
    orders: *storage.OrdersRepo,
    fills: *storage.FillsRepo,
    bh: shadow_bench.Comparison,
) void {
    // Separate scratch buffers so a large events dump cannot clobber shadow JSON mid-format.
    var tmp_agent: [24576]u8 = undefined;
    // Must match WebState.equity_buf. Old 8KiB overflowed ~60×1m rows → API stuck at [].
    var tmp_equity: [49152]u8 = undefined;
    var tmp_events: [12288]u8 = undefined;
    var tmp_shadow: [768]u8 = undefined;
    var tmp_mem: [24576]u8 = undefined;
    if (runs.listRecentJson(db, &tmp_agent, 50)) |j| {
        ws.setJson(.agent, j);
    } else |_| {}
    // Prefer ~4h of 1m samples; fall back if a row ever grows past estimate.
    {
        var eq_limit: i64 = 240;
        var equity_ok = false;
        while (eq_limit >= 30) : (eq_limit = @divTrunc(eq_limit, 2)) {
            if (equity.listRecentJson(db, &tmp_equity, eq_limit)) |j| {
                ws.setJson(.equity, j);
                equity_ok = true;
                break;
            } else |_| {}
        }
        if (!equity_ok) {
            std.debug.print("[dashboard] equity json render failed (buffer/db)\n", .{});
        }
    }
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
    if (shadow_bench.formatJson(&tmp_shadow, bh)) |j| {
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

/// Re-render 复盘 chat transcripts blob from SQLite (core loop only).
pub fn refreshReviewCache(ws: *WebState, db: *storage.Db, repo: *storage.ReviewChatsRepo) void {
    var tmp: [49152]u8 = undefined;
    if (repo.listRecentJson(db, &tmp, 150)) |j| {
        ws.setJson(.review, j);
    } else |_| {}
}

/// Re-render recent scheduled-audit reports blob (core loop only).
pub fn refreshAuditCache(ws: *WebState, db: *storage.Db, repo: *storage.AuditReportsRepo) void {
    var tmp: [24576]u8 = undefined;
    if (repo.listRecentJson(db, &tmp, 16)) |j| {
        ws.setJson(.audit, j);
    } else |_| {}
}

/// Re-render recent 定期复盘 reports blob (core loop only).
pub fn refreshPeriodicReviewCache(ws: *WebState, db: *storage.Db, repo: *storage.PeriodicReviewsRepo) void {
    var tmp: [49152]u8 = undefined;
    if (repo.listRecentJson(db, &tmp, 24)) |j| {
        ws.setJson(.periodic, j);
    } else |_| {}
}

/// Re-render the durable LLM metering ledger for the HTTP cache. The web
/// thread never opens SQLite; this preserves the core-loop single-writer model.
pub fn refreshStatisticsCache(ws: *WebState, db: *storage.Db, repo: *storage.LlmUsageRepo) void {
    var tmp: [65536]u8 = undefined;
    if (repo.writeStatisticsJson(db, &tmp, nowMs())) |json| {
        ws.setJson(.statistics, json);
    } else |err| {
        std.debug.print("[dashboard] statistics json render failed: {t}\n", .{err});
    }
}

/// Re-render the AB 因子复盘 analytics blob from the 1m equity trail (core
/// loop only). Research-only: the output feeds the 复盘 tab chart + IC table
/// and never any decision or risk path.
pub fn refreshAnalyticsCache(ws: *WebState, db: *storage.Db, equity: *storage.EquityRepo) void {
    // Static scratch: ~2880 EquityPoint (~250KiB) + Series (~350KiB) + JSON.
    // Single-writer core loop, so plain container-level state is safe.
    const S = struct {
        var points: [analytics.max_points]storage.EquityPoint = undefined;
        var series: analytics.Series = .{};
        var json: [131072]u8 = undefined;
    };
    var since_buf: [40]u8 = undefined;
    const since_ms = nowMs() - 48 * std.time.ms_per_hour;
    const since_ts = clock.formatRfc3339Ms(since_ms, &since_buf) catch return;
    const n = equity.listPointsAsc(db, &S.points, since_ts) catch return;
    const params: analytics.Params = .{};
    analytics.compute(S.points[0..n], params, &S.series);
    const ics = [_]analytics.IcRow{
        analytics.computeIc(S.points[0..n], &S.series, params, 60),
        analytics.computeIc(S.points[0..n], &S.series, params, 240),
    };
    const json = analytics.writeJson(&S.json, &S.series, &ics) catch {
        std.debug.print("[dashboard] analytics json overflow\n", .{});
        return;
    };
    ws.setJson(.analytics, json);
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

pub fn refreshCandlesCache(
    gpa: std.mem.Allocator,
    ws: *WebState,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
) void {
    // Keep 1H candles for legacy top-level `candles` field (and default UI).
    var default_bars: [100]okx_rest.Candle = undefined;
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

        var raw: [300]okx_rest.Candle = undefined;
        const count = okx_rest.parseCandles(gpa, body, raw[0..spec.limit]) catch continue;
        if (count == 0) continue;

        var ordered: [300]okx_rest.Candle = undefined;
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

fn writeCandlesArray(w: *std.Io.Writer, candles: []const okx_rest.Candle) error{BufferTooSmall}!void {
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

/// Execution flags computed by main at boot (venue authorization is main's
/// policy call; this layer only renders it).
pub const ExecFlags = struct {
    allowed: bool = false,
    real_money: bool = false,
};

pub fn refreshSystemCache(
    ws: *WebState,
    db: *storage.Db,
    cfg: *const config.Config,
    mem_store: *const memory.Store,
    boot_ms: i64,
    private_keys: bool,
    private_ws: bool,
    agent_on: bool,
    paused: bool,
    st: *const RuntimeStatus,
    risk_lat: *const latency.Histogram,
    exec: ExecFlags,
) void {
    const total = storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs") catch 0;
    const ok = storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status = 'ok'") catch 0;
    const invalid = storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status LIKE 'invalid%'") catch 0;
    const errors = storage.Db.queryInt(db, "SELECT COUNT(*) FROM agent_runs WHERE status LIKE 'error%'") catch 0;
    const tools_n = storage.Db.queryInt(db, "SELECT COUNT(*) FROM tool_calls") catch 0;
    const rate: f64 = if (total > 0) @as(f64, @floatFromInt(ok)) * 100.0 / @as(f64, @floatFromInt(total)) else 0;
    const uptime = @max(@as(i64, 0), nowMs() - boot_ms);
    const mode_txt: []const u8 = switch (cfg.mode) {
        .shadow => "shadow",
        .demo => "demo",
        .live => "live",
    };
    var tmp: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tmp);
    w.print(
        "{{\"software_version\":\"{s}\",\"config_hash\":\"{s}\",\"mode\":\"{s}\",\"instrument\":\"{s}\",\"ready\":true,\"paused\":{},\"started_ms\":{d},\"uptime_ms\":{d},\"web_bind\":\"{s}\",\"private_keys\":{},\"private_ws_opt_in\":{},\"agent_enabled\":{},\"memories\":{d},",
        .{
            ws.software_version,
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
        "\"execution\":{{\"enabled\":{},\"real_money\":{}}},",
        .{ exec.allowed, exec.real_money },
    ) catch return;
    w.print(
        "\"audit\":{{\"status\":\"{s}\",\"ts_ms\":{d},\"findings\":{d},\"interval_ms\":{d},\"alerts\":{s}}},",
        .{ st.audit_status, st.audit_ms, st.audit_findings, cfg.audit_interval_ms, st.audit_alerts },
    ) catch return;
    w.print(
        "\"review\":{{\"status\":\"{s}\",\"cycle\":\"{s}\",\"ts_ms\":{d},\"short_interval_ms\":{d},\"long_interval_ms\":{d},\"next_short_ms\":{d},\"next_long_ms\":{d}}},",
        .{
            st.review_status,
            st.review_cycle,
            st.review_ms,
            cfg.review_short_interval_ms,
            cfg.review_long_interval_ms,
            st.review_next_short_ms,
            st.review_next_long_ms,
        },
    ) catch return;
    w.print(
        "\"schedule\":{{\"base_ms\":{d},\"quiet_ms\":{d},\"min_ms\":{d},\"active_hours_utc\":\"{s}\",\"price_move\":\"{f}\",\"drawdown_step\":\"{f}\",\"reflect_on_hold\":{},\"review_backoff_max_ms\":{d},\"noop_backoff_max_ms\":{d}}},",
        .{
            cfg.decision_interval_ms,
            cfg.decision_interval_quiet_ms,
            cfg.decision_min_interval_ms,
            if (cfg.active_hours_utc.len > 0) cfg.active_hours_utc else "always",
            cfg.event_price_move,
            cfg.event_drawdown_step,
            cfg.agent_llm_reflection_on_hold,
            cfg.review_backoff_max_ms,
            cfg.event_noop_backoff_max_ms,
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

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "web state seqlock roundtrip preserves json blobs" {
    var ws = WebState{};
    ws.initEmpty();
    ws.software_version = "test";
    ws.index_html = "<html></html>";
    ws.setJson(.system, "{\"mode\":\"shadow\"}");
    ws.setJson(.orders, "{\"orders\":[1],\"fills\":[]}");
    const ctx = WebState.contextFn(&ws);
    try testing.expectEqualStrings("{\"mode\":\"shadow\"}", ctx.system_json);
    try testing.expectEqualStrings("{\"orders\":[1],\"fills\":[]}", ctx.orders_json);
    try testing.expectEqualStrings("test", ctx.software_version);
    try testing.expect(!ctx.ready);
}

test "web state setJson truncates oversized payloads instead of overflowing" {
    var ws = WebState{};
    ws.initEmpty();
    var big: [1024]u8 = undefined;
    @memset(&big, 'x');
    ws.setJson(.shadow, &big); // shadow_buf is 512
    try testing.expectEqual(@as(usize, 512), ws.shadow_len);
}

test "runtime status setters clamp and stamp" {
    var st = RuntimeStatus{};
    st.setBid("12345.6");
    try testing.expectEqualStrings("12345.6", st.last_bid);
    st.setPub("ok", "ticker");
    try testing.expectEqualStrings("ok", st.okx_public);
    try testing.expect(st.okx_public_ms != 0);
    var long: [200]u8 = undefined;
    @memset(&long, 'd');
    st.setLlm("error", &long);
    try testing.expectEqual(@as(usize, st.llm_detail_buf.len), st.llm_detail.len);
    st.addUsage(.{ .prompt_tokens = 10, .completion_tokens = 5, .total_tokens = 0 });
    try testing.expectEqual(@as(u64, 15), st.total_tokens);
    try testing.expectEqual(@as(u64, 1), st.llm_calls);
}
