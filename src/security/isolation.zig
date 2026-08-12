//! Agent capability isolation — architectural guarantees as tests (AC-SEC6 / AC-GO2).
//!
//! The design forbids the agent layer from ever holding: exchange credentials,
//! order execution, shell/process access, filesystem access, environment
//! variables, or risk-config mutation. Rather than trusting review, these
//! tests scan the agent sources at compile time and fail the build if a
//! forbidden capability is imported.
//!
//! If one of these tests fails, an agent-layer file gained a capability the
//! security model says it must never have. Do not "fix the test".

const std = @import("std");
const testing = std.testing;

const context_src = @embedFile("../agent/context.zig");
const proposal_src = @embedFile("../agent/proposal.zig");
const reflection_src = @embedFile("../agent/reflection.zig");
const openai_src = @embedFile("../agent/openai.zig");

/// Sources that assemble untrusted context / parse model output.
/// These must be pure: no I/O of any kind.
const pure_sources = [_]struct { name: []const u8, src: []const u8 }{
    .{ .name = "agent/context.zig", .src = context_src },
    .{ .name = "agent/proposal.zig", .src = proposal_src },
    .{ .name = "agent/reflection.zig", .src = reflection_src },
};

fn expectAbsent(name: []const u8, src: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, src, needle) != null) {
        std.debug.print("FORBIDDEN capability '{s}' found in {s}\n", .{ needle, name });
        return error.ForbiddenCapability;
    }
}

test "AC-SEC6 pure agent sources have no I/O, process, fs, or exchange access" {
    for (pure_sources) |f| {
        // no network
        try expectAbsent(f.name, f.src, "std.http");
        try expectAbsent(f.name, f.src, "std.net");
        // no filesystem
        try expectAbsent(f.name, f.src, "std.fs");
        // no process / env / shell
        try expectAbsent(f.name, f.src, "std.process");
        try expectAbsent(f.name, f.src, "getenv");
        try expectAbsent(f.name, f.src, "Child");
        // no exchange or execution layer imports
        try expectAbsent(f.name, f.src, "exchange/okx");
        try expectAbsent(f.name, f.src, "execution/");
        // no direct sqlite / storage access
        try expectAbsent(f.name, f.src, "storage/db.zig");
        try expectAbsent(f.name, f.src, "sqlite3");
    }
}

test "AC-SEC6 LLM adapter cannot touch exchange, fs, process, or storage" {
    // openai.zig legitimately uses std.http (that is its job) but must not
    // read the environment, touch disk, or import exchange/execution code.
    try expectAbsent("agent/openai.zig", openai_src, "std.fs");
    try expectAbsent("agent/openai.zig", openai_src, "std.process");
    try expectAbsent("agent/openai.zig", openai_src, "getenv");
    try expectAbsent("agent/openai.zig", openai_src, "exchange/okx");
    try expectAbsent("agent/openai.zig", openai_src, "execution/");
    try expectAbsent("agent/openai.zig", openai_src, "storage/db.zig");
    try expectAbsent("agent/openai.zig", openai_src, "sqlite3");
    try expectAbsent("agent/openai.zig", openai_src, "Child");
}

test "AC-SEC6 agent layer cannot import risk admission or mutate config" {
    // The agent may see RiskMode text via core state, but must not import the
    // admission kernel (it could learn to pre-shape around it) nor config.
    for (pure_sources) |f| {
        try expectAbsent(f.name, f.src, "risk/admission.zig");
        try expectAbsent(f.name, f.src, "config.zig");
    }
    try expectAbsent("agent/openai.zig", openai_src, "risk/admission.zig");
    try expectAbsent("agent/openai.zig", openai_src, "config.zig");
}

test "AC-GO2 credential names never appear in agent sources" {
    const cred_tokens = [_][]const u8{
        "OKX_API_KEY",
        "OKX_API_SECRET",
        "OKX_API_PASSPHRASE",
        "OK-ACCESS-SIGN",
        "OK-ACCESS-PASSPHRASE",
    };
    for (pure_sources) |f| {
        for (cred_tokens) |tok| try expectAbsent(f.name, f.src, tok);
    }
    for (cred_tokens) |tok| try expectAbsent("agent/openai.zig", openai_src, tok);
}
