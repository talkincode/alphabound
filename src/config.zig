//! Configuration loader — minimal TOML subset sufficient for
//! /etc/alphabound/alphabound.toml (appendix B):
//! [section] headers, key = "string" | integer | float | true/false,
//! full-line and trailing comments with '#'.
//! Unknown keys are rejected (config drift is a deployment bug, not a warning).

const std = @import("std");
const dec = @import("core/decimal.zig");
const scheduler = @import("core/scheduler.zig");
const Decimal = dec.Decimal;

pub const Mode = enum {
    shadow,
    demo,
    live,

    fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "shadow")) return .shadow;
        if (std.mem.eql(u8, s, "demo")) return .demo;
        if (std.mem.eql(u8, s, "live")) return .live;
        return null;
    }

    /// Demo (OKX simulated) or live (real small sub-account) — both use the
    /// exchange book + optional order path. Shadow never does.
    pub fn isTrading(self: Mode) bool {
        return self == .demo or self == .live;
    }
};

pub const Config = struct {
    // [app]
    environment: []const u8 = "development",
    instance_id: []const u8 = "dev-local",
    // [exchange]
    exchange_provider: []const u8 = "okx",
    instrument: []const u8 = "BTC-USDT",
    mode: Mode = .shadow,
    rest_url: []const u8 = "https://www.okx.com",
    poll_interval_ms: u32 = 2_000,
    // [risk] — max_drawdown is deliberately NOT hot-reloadable (§8.5)
    max_drawdown: Decimal = Decimal.parse("0.10") catch unreachable,
    allow_runtime_override: bool = false,
    taker_fee_rate: Decimal = Decimal.parse("0.001") catch unreachable,
    slippage_rate: Decimal = Decimal.parse("0.0005") catch unreachable,
    initial_capital: Decimal = Decimal.parse("100") catch unreachable,
    // [agent]
    agent_provider: []const u8 = "openai",
    agent_model: []const u8 = "gpt-4o-mini",
    /// OpenAI-compatible API root (no trailing slash), e.g. https://api.openai.com/v1
    /// Overridable by LLM_API_URL / OPENAI_BASE_URL env.
    agent_base_url: []const u8 = "https://api.openai.com/v1",
    decision_timeout_ms: u32 = 120_000,
    /// Slow-loop base cadence (active session); 0 disables scheduled agent
    /// ticks (manual/env only). Not a short-term strategy — default 10 min.
    decision_interval_ms: u32 = 600_000,
    /// Cadence outside `active_hours_utc`; 0 → same as decision_interval_ms.
    decision_interval_quiet_ms: u32 = 0,
    /// Hard cooldown floor between any two decisions (event triggers included).
    decision_min_interval_ms: u32 = 120_000,
    /// UTC active trading session "start-end" (end exclusive, may wrap e.g.
    /// "22-4"); empty → every hour uses the base cadence.
    active_hours_utc: []const u8 = "",
    /// Early decision when |bid − last_bid| / last_bid ≥ this fraction; 0 off.
    event_price_move: Decimal = Decimal.parse("0.005") catch unreachable,
    /// Early decision when drawdown deepens by ≥ this fraction; 0 off.
    event_drawdown_step: Decimal = Decimal.parse("0.01") catch unreachable,
    prompt_dir: []const u8 = "prompts",
    /// When false, never call LLM even if keys are present.
    agent_enabled: bool = true,
    /// When true, after a valid proposal run a second LLM reflection call
    /// (structured memory_ops). Fail-closed → deterministic fallback.
    agent_llm_reflection: bool = true,
    /// When false (default), HOLD proposals use the deterministic reflection
    /// only — skipping the second LLM call on quiet cycles.
    agent_llm_reflection_on_hold: bool = false,
    // [storage]
    db_path: []const u8 = "trading.db",
    wal: bool = true,
    // [web]
    web_bind: []const u8 = "127.0.0.1:8080",
    static_dir: []const u8 = "dashboard/dist",

    /// sha256 of the raw config text, "sha256:<hex>" — stamped on every event.
    config_hash: [71]u8 = undefined,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn hash(self: *const Config) []const u8 {
        return &self.config_hash;
    }

    /// Host component of web_bind (`127.0.0.1` or `0.0.0.0`).
    pub fn webHost(self: *const Config) []const u8 {
        const colon = std.mem.lastIndexOfScalar(u8, self.web_bind, ':') orelse return "127.0.0.1";
        return self.web_bind[0..colon];
    }

    /// Port component of web_bind.
    pub fn webPort(self: *const Config) u16 {
        const colon = std.mem.lastIndexOfScalar(u8, self.web_bind, ':') orelse return 8080;
        return std.fmt.parseInt(u16, self.web_bind[colon + 1 ..], 10) catch 8080;
    }
};

/// Allowed binds: loopback (bare metal / SSH tunnel) or all-interfaces
/// (container; host should still publish only to 127.0.0.1).
fn validWebBind(bind: []const u8) bool {
    const colon = std.mem.lastIndexOfScalar(u8, bind, ':') orelse return false;
    if (colon == 0 or colon + 1 >= bind.len) return false;
    const host = bind[0..colon];
    const port_s = bind[colon + 1 ..];
    _ = std.fmt.parseInt(u16, port_s, 10) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "0.0.0.0");
}

pub const ConfigError = error{
    UnknownSection,
    UnknownKey,
    SyntaxError,
    InvalidValue,
    OutOfMemory,
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) ConfigError!Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var cfg = Config{ .arena = undefined };
    computeHash(text, &cfg.config_hash);

    var section: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.SyntaxError;
            section = line[1 .. line.len - 1];
            const known = [_][]const u8{ "app", "exchange", "risk", "agent", "storage", "web" };
            var ok = false;
            for (known) |k| {
                if (std.mem.eql(u8, section, k)) ok = true;
            }
            if (!ok) return error.UnknownSection;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.SyntaxError;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        try applyKey(a, &cfg, section, key, val);
    }
    cfg.arena = arena; // final arena state, after all allocations
    return cfg;
}

pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024));
    defer gpa.free(text);
    return try parse(gpa, text);
}

fn computeHash(text: []const u8, out: *[71]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    out[0..7].* = "sha256:".*;
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[7 + i * 2] = hex[b >> 4];
        out[7 + i * 2 + 1] = hex[b & 0x0f];
    }
}

fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (c == '#' and !in_str) return std.mem.trim(u8, line[0..i], " \t");
    }
    return line;
}

fn applyKey(a: std.mem.Allocator, cfg: *Config, section: []const u8, key: []const u8, val: []const u8) ConfigError!void {
    if (std.mem.eql(u8, section, "app")) {
        if (std.mem.eql(u8, key, "environment")) {
            cfg.environment = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "instance_id")) {
            cfg.instance_id = try parseString(a, val);
        } else return error.UnknownKey;
    } else if (std.mem.eql(u8, section, "exchange")) {
        if (std.mem.eql(u8, key, "provider")) {
            cfg.exchange_provider = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "instrument")) {
            cfg.instrument = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "mode")) {
            cfg.mode = Mode.fromString(try parseString(a, val)) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "rest_url")) {
            cfg.rest_url = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "poll_interval_ms")) {
            cfg.poll_interval_ms = parseInt(u32, val) catch return error.InvalidValue;
            if (cfg.poll_interval_ms < 200) return error.InvalidValue; // rate-limit floor
        } else return error.UnknownKey;
    } else if (std.mem.eql(u8, section, "risk")) {
        if (std.mem.eql(u8, key, "max_drawdown")) {
            cfg.max_drawdown = Decimal.parse(val) catch return error.InvalidValue;
            if (cfg.max_drawdown.isNegative() or cfg.max_drawdown.gt(Decimal.parse("0.5") catch unreachable))
                return error.InvalidValue; // sanity bound: never above 50%
        } else if (std.mem.eql(u8, key, "valuation")) {
            const v = try parseString(a, val);
            if (!std.mem.eql(u8, v, "conservative_liquidation")) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "allow_runtime_override")) {
            cfg.allow_runtime_override = try parseBool(val);
            if (cfg.allow_runtime_override) return error.InvalidValue; // hard rule: never true
        } else if (std.mem.eql(u8, key, "taker_fee_rate")) {
            cfg.taker_fee_rate = Decimal.parse(val) catch return error.InvalidValue;
            if (cfg.taker_fee_rate.isNegative()) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "slippage_rate")) {
            cfg.slippage_rate = Decimal.parse(val) catch return error.InvalidValue;
            if (cfg.slippage_rate.isNegative()) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "initial_capital")) {
            cfg.initial_capital = Decimal.parse(val) catch return error.InvalidValue;
            if (!cfg.initial_capital.gt(Decimal.zero)) return error.InvalidValue;
        } else return error.UnknownKey;
    } else if (std.mem.eql(u8, section, "agent")) {
        if (std.mem.eql(u8, key, "provider")) {
            cfg.agent_provider = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "model")) {
            cfg.agent_model = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "base_url")) {
            cfg.agent_base_url = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "decision_timeout_ms")) {
            cfg.decision_timeout_ms = parseInt(u32, val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "decision_interval_ms")) {
            cfg.decision_interval_ms = parseInt(u32, val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "decision_interval_quiet_ms")) {
            cfg.decision_interval_quiet_ms = parseInt(u32, val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "decision_min_interval_ms")) {
            cfg.decision_min_interval_ms = parseInt(u32, val) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "active_hours_utc")) {
            cfg.active_hours_utc = try parseString(a, val);
            _ = scheduler.parseHours(cfg.active_hours_utc) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "event_price_move")) {
            cfg.event_price_move = Decimal.parse(val) catch return error.InvalidValue;
            if (cfg.event_price_move.isNegative() or
                cfg.event_price_move.gte(Decimal.fromInt(1))) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "event_drawdown_step")) {
            cfg.event_drawdown_step = Decimal.parse(val) catch return error.InvalidValue;
            if (cfg.event_drawdown_step.isNegative() or
                cfg.event_drawdown_step.gte(Decimal.fromInt(1))) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "prompt_dir")) {
            cfg.prompt_dir = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "enabled")) {
            cfg.agent_enabled = try parseBool(val);
        } else if (std.mem.eql(u8, key, "llm_reflection") or std.mem.eql(u8, key, "agent_llm_reflection")) {
            cfg.agent_llm_reflection = try parseBool(val);
        } else if (std.mem.eql(u8, key, "llm_reflection_on_hold")) {
            cfg.agent_llm_reflection_on_hold = try parseBool(val);
        } else return error.UnknownKey;
    } else if (std.mem.eql(u8, section, "storage")) {
        if (std.mem.eql(u8, key, "path")) {
            cfg.db_path = try parseString(a, val);
        } else if (std.mem.eql(u8, key, "wal")) {
            cfg.wal = try parseBool(val);
        } else return error.UnknownKey;
    } else if (std.mem.eql(u8, section, "web")) {
        if (std.mem.eql(u8, key, "bind")) {
            cfg.web_bind = try parseString(a, val);
            // §6.4: loopback by default; 0.0.0.0 only for container port-publish
            // (host must still pin published address to 127.0.0.1).
            if (!validWebBind(cfg.web_bind)) return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "static_dir")) {
            cfg.static_dir = try parseString(a, val);
        } else return error.UnknownKey;
    } else {
        return error.UnknownSection;
    }
}

fn parseString(a: std.mem.Allocator, val: []const u8) ConfigError![]const u8 {
    if (val.len < 2 or val[0] != '"' or val[val.len - 1] != '"') return error.SyntaxError;
    return a.dupe(u8, val[1 .. val.len - 1]) catch return error.OutOfMemory;
}

fn parseBool(val: []const u8) ConfigError!bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return error.InvalidValue;
}

fn parseInt(comptime T: type, val: []const u8) !T {
    return std.fmt.parseInt(T, val, 10);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\# AlphaBound config
    \\[app]
    \\environment = "production"
    \\instance_id = "azure-btc-01"
    \\
    \\[exchange]
    \\provider = "okx"
    \\instrument = "BTC-USDT"
    \\mode = "shadow"                # shadow | demo | live
    \\
    \\[risk]
    \\max_drawdown = 0.10
    \\valuation = "conservative_liquidation"
    \\allow_runtime_override = false
    \\
    \\[agent]
    \\provider = "configured-adapter"
    \\model = "configured-model"
    \\decision_timeout_ms = 30000
    \\prompt_dir = "/etc/alphabound/prompts"
    \\
    \\[storage]
    \\path = "/var/lib/alphabound/trading.db"
    \\wal = true
    \\
    \\[web]
    \\bind = "127.0.0.1:8080"
    \\static_dir = "/opt/alphabound/ui/current"
;

test "appendix B config parses" {
    var cfg = try parse(testing.allocator, sample);
    defer cfg.deinit();
    try testing.expectEqualStrings("azure-btc-01", cfg.instance_id);
    try testing.expectEqual(Mode.shadow, cfg.mode);
    try testing.expect(!Mode.shadow.isTrading());
    try testing.expect(Mode.demo.isTrading());
    try testing.expect(Mode.live.isTrading());
    try testing.expect(cfg.max_drawdown.eql(Decimal.parse("0.10") catch unreachable));
    try testing.expectEqual(@as(u32, 30000), cfg.decision_timeout_ms);
    try testing.expectEqualStrings("127.0.0.1:8080", cfg.web_bind);
    try testing.expect(std.mem.startsWith(u8, cfg.hash(), "sha256:"));
}

test "unknown keys and unsafe values rejected" {
    try testing.expectError(error.UnknownKey, parse(testing.allocator,
        \\[risk]
        \\yolo_mode = true
    ));
    try testing.expectError(error.InvalidValue, parse(testing.allocator,
        \\[risk]
        \\allow_runtime_override = true
    ));
    try testing.expectError(error.InvalidValue, parse(testing.allocator,
        \\[risk]
        \\max_drawdown = 0.9
    ));
    try testing.expectError(error.UnknownSection, parse(testing.allocator,
        \\[hacks]
        \\x = 1
    ));
    try testing.expectError(error.InvalidValue, parse(testing.allocator,
        \\[web]
        \\bind = "1.2.3.4:8080"
    ));
}

test "container bind 0.0.0.0 is allowed" {
    var cfg = try parse(testing.allocator,
        \\[web]
        \\bind = "0.0.0.0:8080"
    );
    defer cfg.deinit();
    try testing.expectEqualStrings("0.0.0.0", cfg.webHost());
    try testing.expectEqual(@as(u16, 8080), cfg.webPort());
}

test "config hash changes with content" {
    var c1 = try parse(testing.allocator, "[app]\nenvironment = \"a\"");
    defer c1.deinit();
    var c2 = try parse(testing.allocator, "[app]\nenvironment = \"b\"");
    defer c2.deinit();
    try testing.expect(!std.mem.eql(u8, c1.hash(), c2.hash()));
}

test "multi-factor schedule keys parse with validation" {
    var cfg = try parse(testing.allocator,
        \\[agent]
        \\decision_interval_ms = 900000
        \\decision_interval_quiet_ms = 3600000
        \\decision_min_interval_ms = 180000
        \\active_hours_utc = "13-21"
        \\event_price_move = 0.005
        \\event_drawdown_step = 0.01
        \\llm_reflection_on_hold = true
    );
    defer cfg.deinit();
    try testing.expectEqual(@as(u32, 900_000), cfg.decision_interval_ms);
    try testing.expectEqual(@as(u32, 3_600_000), cfg.decision_interval_quiet_ms);
    try testing.expectEqual(@as(u32, 180_000), cfg.decision_min_interval_ms);
    try testing.expectEqualStrings("13-21", cfg.active_hours_utc);
    try testing.expect(cfg.event_price_move.eql(Decimal.parse("0.005") catch unreachable));
    try testing.expect(cfg.agent_llm_reflection_on_hold);

    try testing.expectError(error.InvalidValue, parse(testing.allocator,
        \\[agent]
        \\active_hours_utc = "25-3"
    ));
    try testing.expectError(error.InvalidValue, parse(testing.allocator,
        \\[agent]
        \\event_price_move = 1.5
    ));
    try testing.expectError(error.InvalidValue, parse(testing.allocator,
        \\[agent]
        \\event_drawdown_step = -0.01
    ));
}
