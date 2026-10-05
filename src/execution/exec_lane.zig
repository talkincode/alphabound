//! Execution lane: the only thread that talks to the venue's trade endpoints.
//!
//! The fast risk loop must never wait on an order (a resting limit order can
//! wait minutes; a venue call can hang). All order work — agent rebalances,
//! operator target weights, flatten drives, cancel-all and restart recovery —
//! runs here, serialized, with its own HTTP client and its own SQLite
//! connection. Engine state is only ever *submitted* to the risk loop, which
//! stays the single writer.
//!
//! Safety properties:
//!  * bounded queue; senders learn when it is full and drop instead of piling up;
//!  * emergency jobs jump the queue;
//!  * `agent_blocked` (level-triggered, set while paused / FLATTENING / HALTED)
//!    makes a running agent job cancel its resting order and stop, and makes
//!    queued agent jobs drop themselves;
//!  * agent jobs older than `max_queue_age_ms` are dropped, never executed late;
//!  * every agent job is admitted again on a fresh snapshot at execution time.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const clock = @import("../core/clock.zig");
const config = @import("../config.zig");
const lanes = @import("../core/lanes.zig");
const storage = @import("../storage/db.zig");
const okx_rest = @import("../exchange/okx/rest.zig");
const okx_trade = @import("okx_trade.zig");
const demo_runner = @import("demo_runner.zig");
const operator = @import("operator.zig");
const planner = @import("planner.zig");
const proposal = @import("../agent/proposal.zig");
const gate = @import("../risk/gate.zig");
const web_cache = @import("../web/cache.zig");

const Decimal = dec.Decimal;

/// An agent rebalance older than this when the lane reaches it is stale.
pub const max_queue_age_ms: i64 = 60_000;

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

fn decFmt(buf: []u8, v: Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

fn FixedText(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), text: []const u8) void {
            const n = @min(text.len, N);
            @memcpy(self.buf[0..n], text[0..n]);
            self.len = n;
        }

        pub fn get(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

/// Result slot for an agent execution; lives on the waiting (thinking) lane's
/// stack, written once by the execution lane, then `done` is released.
pub const Reply = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    note: FixedText(64) = .{},
    verdict: FixedText(16) = .{},
    reason: FixedText(96) = .{},
    admitted_weight: FixedText(48) = .{},
    stress_equity: FixedText(48) = .{},
    floor: FixedText(48) = .{},
    /// Engine snapshot version the execution-time admission ran on.
    exec_version: u64 = 0,
};

pub const AgentJob = struct {
    decision_id: FixedText(64) = .{},
    requested_weight: Decimal,
    order_type: proposal.OrderPolicyType,
    urgency: Decimal,
    max_wait_ms: u32,
    created_ms: i64,
    reply: *Reply,
};

pub const Job = union(enum) {
    flatten: struct { force: bool },
    target_weight: struct { weight: FixedText(24) },
    cancel_all,
    recover,
    agent: AgentJob,
};

pub const Deps = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    engine: *state.Engine,
    instrument: planner.Instrument,
    venue_authorized: bool,
    db_path: [:0]const u8,
    /// Builds the lane's own venue client (own sockets, same credentials).
    make_client: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io) okx_rest.Client,
    client_ctx: ?*anyopaque = null,
    /// Authoritative account reconcile, executed by the risk loop.
    service: *lanes.Service,
    status: ?*web_cache.RuntimeStatus = null,
    idle_poll_ms: u32 = 20,
    reconcile_timeout_ms: u32 = 20_000,
};

pub const ExecLane = struct {
    deps: Deps = undefined,
    jobs: lanes.Mailbox(Job, 8) = .{},
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Level-triggered by the risk loop: paused / FLATTENING / HALTED.
    agent_blocked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set after a job that changed ledger/account state; the risk loop
    /// refreshes dashboard caches when it sees it.
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    jobs_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Last restart-recovery pass reached agreement (ledger == venue).
    recovery_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    db: storage.Db = undefined,
    orders_repo: storage.OrdersRepo = undefined,
    fills_repo: storage.FillsRepo = undefined,
    events_repo: storage.EventsRepo = undefined,
    okx: okx_rest.Client = undefined,
    started: bool = false,
    last_flatten_ms: i64 = 0,

    pub fn start(self: *ExecLane, deps: Deps) !void {
        self.deps = deps;
        self.db = try storage.Db.open(deps.db_path);
        errdefer self.db.close();
        self.orders_repo = try storage.OrdersRepo.init(&self.db);
        errdefer self.orders_repo.deinit();
        self.fills_repo = try storage.FillsRepo.init(&self.db);
        errdefer self.fills_repo.deinit();
        self.events_repo = try storage.EventsRepo.init(&self.db);
        errdefer self.events_repo.deinit();
        self.okx = deps.make_client(deps.client_ctx, deps.gpa, deps.io);
        self.started = true;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Queue a job. `urgent` jumps the queue. False = queue full (job dropped).
    pub fn submit(self: *ExecLane, job: Job, urgent: bool) bool {
        return if (urgent) self.jobs.pushFront(job) else self.jobs.push(job);
    }

    /// Ask the thread to finish: resting agent orders are canceled and confirmed
    /// first. Pair with `isStopped`, then `shutdown`.
    pub fn requestStop(self: *ExecLane) void {
        self.stop.store(true, .release);
        self.agent_blocked.store(true, .release);
    }

    pub fn isStopped(self: *const ExecLane) bool {
        return self.stopped.load(.acquire);
    }

    pub fn setAgentBlocked(self: *ExecLane, blocked: bool) void {
        self.agent_blocked.store(blocked, .release);
    }

    pub fn isBusy(self: *const ExecLane) bool {
        return self.busy.load(.acquire);
    }

    pub fn takeDirty(self: *ExecLane) bool {
        return self.dirty.swap(false, .acq_rel);
    }

    /// Stop the thread (the running job finishes its cancel-and-confirm path
    /// first) and release resources. False = the lane is still stuck (for
    /// example in a hung venue call) after `timeout_ms`; nothing is released.
    pub fn shutdown(self: *ExecLane, timeout_ms: u32) bool {
        if (!self.started) return true;
        self.stop.store(true, .release);
        self.agent_blocked.store(true, .release);
        var waited: u32 = 0;
        while (!self.stopped.load(.acquire)) {
            if (waited >= timeout_ms) return false;
            self.deps.io.sleep(.{ .nanoseconds = 10_000_000 }, .awake) catch break;
            waited += 10;
        }
        if (self.thread) |t| t.join();
        self.thread = null;
        self.okx.deinit();
        self.events_repo.deinit();
        self.fills_repo.deinit();
        self.orders_repo.deinit();
        self.db.close();
        self.started = false;
        return true;
    }

    fn refresherThunk(raw: *anyopaque) bool {
        const self: *ExecLane = @ptrCast(@alignCast(raw));
        return self.deps.service.call(self.deps.io, self.deps.reconcile_timeout_ms);
    }

    fn env(self: *ExecLane) operator.Env {
        return .{
            .gpa = self.deps.gpa,
            .okx = &self.okx,
            .cfg = self.deps.cfg,
            .engine = self.deps.engine,
            .db = &self.db,
            .orders_repo = &self.orders_repo,
            .fills_repo = &self.fills_repo,
            .events_repo = &self.events_repo,
            .refresher = .{ .context = self, .run_fn = refresherThunk },
            .instrument = self.deps.instrument,
            .venue_authorized = self.deps.venue_authorized,
            .fetch_ticker = false,
        };
    }

    fn run(self: *ExecLane) void {
        defer self.stopped.store(true, .release);
        while (!self.stop.load(.acquire)) {
            const job = self.jobs.pop() orelse {
                self.deps.io.sleep(.{ .nanoseconds = @as(i96, self.deps.idle_poll_ms) * 1_000_000 }, .awake) catch return;
                continue;
            };
            self.busy.store(true, .release);
            self.handle(job);
            self.busy.store(false, .release);
            _ = self.jobs_done.fetchAdd(1, .acq_rel);
        }
        // Anything still queued will never run: release waiting agent jobs.
        while (self.jobs.pop()) |job| {
            if (job == .agent) {
                job.agent.reply.note.set("exec_lane_stopped");
                job.agent.reply.done.store(true, .release);
            }
        }
    }

    fn handle(self: *ExecLane, job: Job) void {
        const e = self.env();
        switch (job) {
            .flatten => |f| {
                operator.driveFlatten(e, &self.last_flatten_ms, f.force);
                self.dirty.store(true, .release);
            },
            .target_weight => |t| {
                const out = operator.runTargetWeight(e, t.weight.get());
                if (self.deps.status) |st| {
                    if (out.status().len > 0) st.setLastDecision(out.status());
                }
                std.debug.print("[admin] target-weight={s} exec={s}\n", .{ t.weight.get(), out.note });
                self.dirty.store(true, .release);
            },
            .cancel_all => {
                const report = operator.cancelAll(e);
                std.debug.print("[admin] cancel-all canceled={d} remaining={d} verified={}\n", .{ report.canceled, report.remaining, report.verified_clear });
                // The book changed: re-derive whether trading may reopen (a blocked
                // boot recovery is only released by a fresh, complete pass).
                self.runRecovery();
                self.dirty.store(true, .release);
            },
            .recover => {
                self.runRecovery();
                self.dirty.store(true, .release);
            },
            .agent => |a| self.runAgent(e, a),
        }
    }

    fn runRecovery(self: *ExecLane) void {
        const report = demo_runner.recoverOrders(
            self.deps.gpa,
            &self.okx,
            self.deps.cfg,
            self.deps.engine,
            &self.db,
            &self.orders_repo,
            &self.fills_repo,
            &self.events_repo,
        );
        self.recovery_complete.store(report.complete, .release);
    }

    fn runAgent(self: *ExecLane, e: operator.Env, job: AgentJob) void {
        const reply = job.reply;
        defer reply.done.store(true, .release);
        if (nowMs() - job.created_ms > max_queue_age_ms) {
            reply.note.set("stale_dropped");
            return;
        }
        if (self.agent_blocked.load(.acquire)) {
            reply.note.set("aborted");
            return;
        }
        if (!okx_trade.executionAllowed(e.cfg.mode.isTrading(), e.venue_authorized)) {
            reply.note.set("not_executed");
            return;
        }
        // Authoritative balances right before the decision is admitted.
        operator.refreshBeforeAdmission(e.gpa, e.okx, e.cfg, e.engine, e.refresher, false);
        const snap = e.engine.snapshot();
        const adm = gate.shadowAdmit(snap, snap.version, job.requested_weight, e.cfg, nowMs());
        reply.exec_version = snap.version;
        reply.verdict.set(adm.verdict_txt);
        reply.reason.set(adm.reason_txt);
        var b1: [48]u8 = undefined;
        var b2: [48]u8 = undefined;
        var b3: [48]u8 = undefined;
        reply.admitted_weight.set(decFmt(&b1, adm.admitted_weight));
        reply.stress_equity.set(decFmt(&b2, adm.stress_equity));
        reply.floor.set(decFmt(&b3, adm.floor));

        const note = demo_runner.tryDemoExecute(
            e.gpa,
            e.okx,
            e.cfg,
            e.engine,
            e.db,
            e.orders_repo,
            e.fills_repo,
            e.events_repo,
            e.refresher,
            job.decision_id.get(),
            adm.verdict_txt,
            adm.admitted_weight,
            e.instrument,
            snap,
            .{ .type = job.order_type, .urgency = job.urgency, .max_wait_ms = job.max_wait_ms },
            .{ .requested_weight = job.requested_weight, .abort = &self.agent_blocked },
        );
        reply.note.set(note);
        self.dirty.store(true, .release);
    }
};
