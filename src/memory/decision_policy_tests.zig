//! Synthetic decision-memory isolation regressions; no external data or I/O.
const std = @import("std");
const testing = std.testing;
const memory = @import("store.zig");
const Decimal = @import("../core/decimal.zig").Decimal;
const live = memory.DecisionScope{ .mode = .live };
const demo = memory.DecisionScope{ .mode = .demo };
const now: i64 = 3 * memory.MAX_DECISION_AGE_MS;
const tags = "{\"tags\":[\"BTC-USDT\"],\"observation\":\"synthetic current data\"}";

const Fixture = struct {
    store: memory.Store = memory.Store.init(testing.allocator),
    touched: std.ArrayList(memory.Memory) = .empty,

    fn deinit(self: *Fixture) void {
        self.touched.deinit(testing.allocator);
        self.store.deinit();
    }

    fn create(self: *Fixture, id: []const u8, scope: memory.DecisionScope, timestamp: i64, status: memory.Status, content: []const u8) !void {
        try self.store.applyOpWithScope(.{ .create = .{
            .memory_id = id,
            .kind = .reflection,
            .status = status,
            .confidence = Decimal.one,
            .content_json = content,
        } }, timestamp, scope, &self.touched);
    }

    fn query(self: *Fixture, timestamp: i64, query_tags: []const []const u8) !std.ArrayList(memory.Scored) {
        return memory.retrieve(&self.store, testing.allocator, .{
            .decision_scope = live,
            .now_ms = timestamp,
            .tags = query_tags,
            .limit = 100,
        }, memory.substringTagMatch);
    }
};

test "decision scope excludes legacy high confidence, other epoch/mode, future, expired and unusable status" {
    var f = Fixture{};
    defer f.deinit();
    try f.store.load(.{
        .memory_id = "legacy-high-confidence",
        .version = 77,
        .kind = .strategy,
        .status = .active,
        .confidence = Decimal.one,
        .evidence_count = 99999,
        .content_json = tags,
        .created_ms = now,
    });
    try f.create("other-epoch", .{ .mode = .live, .policy_epoch = memory.CURRENT_POLICY_EPOCH + 1 }, now, .active, tags);
    try f.create("demo", demo, now, .active, tags);
    try f.create("shadow", .{ .mode = .shadow }, now, .active, tags);
    try f.create("future", live, now + 1, .active, tags);
    try f.create("expired", live, now - memory.MAX_DECISION_AGE_MS - 1, .active, tags);
    try f.create("unverified", live, now, .unverified, tags);
    try f.create("invalidated", live, now, .invalidated, tags);
    try f.create("merged", live, now, .merged, tags);
    try f.create("current", live, now, .active, tags);
    var results = try f.query(now, &.{"BTC-USDT"});
    defer results.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("current", results.items[0].memory.memory_id);
    try testing.expectEqual(@as(usize, 10), f.store.count());
    try testing.expectEqual(@as(u32, 77), f.store.find("legacy-high-confidence").?.version);
    try testing.expectEqual(@as(u32, 99999), f.store.find("legacy-high-confidence").?.evidence_count);

    // The persisted envelope survives a boot-style load; no schema changes or
    // in-place historical rewrites are necessary for the new read policy.
    var rebooted = memory.Store.init(testing.allocator);
    defer rebooted.deinit();
    for (f.store.items.items) |m| try rebooted.load(m);
    var reloaded = try memory.retrieve(&rebooted, testing.allocator, .{
        .decision_scope = live,
        .now_ms = now,
    }, memory.substringTagMatch);
    defer reloaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), reloaded.items.len);
    try testing.expectEqualStrings("current", reloaded.items[0].memory.memory_id);
}

test "new evidence cohort excludes earlier same-mode notes and cannot be bypassed by update or merge" {
    var f = Fixture{};
    defer f.deinit();
    const cohort = memory.DecisionScope{ .mode = .live, .not_before_ms = now };
    try f.create("earlier-live", live, now - 2, .active, tags);
    try f.create("intervening-demo", demo, now - 1, .active, tags);
    try f.create("current-live", cohort, now, .active, tags);
    var results = try memory.retrieve(&f.store, testing.allocator, .{
        .decision_scope = cohort,
        .now_ms = now,
        .tags = &.{"BTC-USDT"},
    }, memory.substringTagMatch);
    defer results.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("current-live", results.items[0].memory.memory_id);
    try testing.expectError(error.ContentReplacementRequired, f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "earlier-live",
        .new_status = .active,
        .evidence_increment = 100,
    } }, now, cohort, &f.touched));
    try testing.expectError(error.ContentReplacementRequired, f.store.applyOpWithScope(.{ .merge = .{
        .from_id = "earlier-live",
        .into_id = "current-live",
    } }, now, cohort, &f.touched));
    try testing.expectError(error.ContentReplacementRequired, f.store.applyOpWithScope(.{ .merge = .{
        .from_id = "current-live",
        .into_id = "earlier-live",
    } }, now, cohort, &f.touched));
    try testing.expectEqual(@as(u32, 1), f.store.find("earlier-live").?.version);
    try testing.expectEqual(@as(u32, 1), f.store.find("current-live").?.version);

    // Even explicit replacement cannot renew identical pre-cohort content.
    try f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "earlier-live",
        .content_json = tags,
        .new_status = .active,
    } }, now + 1, cohort, &f.touched);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("earlier-live").?.*, cohort, now + 1));
    // A replacement constructed from genuinely new host facts may enter.
    try f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "earlier-live",
        .content_json = "{\"tags\":[\"BTC-USDT\"],\"observation\":\"synthetic new cohort fact\"}",
        .new_status = .active,
    } }, now + 2, cohort, &f.touched);
    try testing.expect(try memory.isDecisionEligible(testing.allocator, f.store.find("earlier-live").?.*, cohort, now + 2));
    try testing.expectEqual(now - 2, f.touched.items[0].created_ms);
    try testing.expectEqual(@as(usize, 5), f.touched.items.len);
}

test "negative and future evidence cohort boundaries fail closed" {
    var f = Fixture{};
    defer f.deinit();
    try f.create("current", live, now, .active, tags);
    for ([_]i64{ -1, now + 1 }) |boundary| {
        const invalid = memory.DecisionScope{ .mode = .live, .not_before_ms = boundary };
        try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("current").?.*, invalid, now));
        try testing.expectError(error.InvalidDecisionScope, f.create("invalid", invalid, now, .active, tags));
    }
    try testing.expectEqual(@as(usize, 1), f.store.count());
    try testing.expectEqual(@as(usize, 1), f.touched.items.len);
}

test "decision tags are exact JSON array members and duplicate tags add no relevance" {
    var f = Fixture{};
    defer f.deinit();
    try f.create("substring", live, now, .active, "{\"tags\":[\"BTC-USDT-SWAP\"]}");
    try f.create("narrative", live, now, .active, "{\"lesson\":\"BTC-USDT\"}");
    try f.create("nested", live, now, .active, "{\"nested\":{\"tags\":[\"BTC-USDT\"]}}");
    try f.create("string-not-array", live, now, .active, "{\"tags\":\"BTC-USDT\"}");
    try f.create("mixed-array", live, now, .active, "{\"tags\":[\"BTC-USDT\",42]}");
    try f.create("escaped-exact", live, now, .active, "{\"tags\":[\"\\u0042TC-USDT\",\"BTC-USDT\"]}");
    var results = try f.query(now, &.{ "BTC-USDT", "BTC-USDT" });
    defer results.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("escaped-exact", results.items[0].memory.memory_id);
    var single = try f.query(now, &.{"BTC-USDT"});
    defer single.deinit(testing.allocator);
    try testing.expectEqual(single.items[0].score, results.items[0].score);
    var partial = try f.query(now, &.{"BTC"});
    defer partial.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), partial.items.len);
}

test "self repetition and merges do not outrank fresh facts or renew original content age" {
    var f = Fixture{};
    defer f.deinit();
    const old_time = now - memory.MAX_DECISION_AGE_MS + 100;
    try f.create("a-repeated", live, old_time, .active, tags);
    try f.create("duplicate", live, old_time, .active, tags);
    try f.create("E_run_fresh", live, now - 10, .active, tags);
    var before = try f.query(now, &.{"BTC-USDT"});
    defer before.deinit(testing.allocator);
    const repeated_score = before.items[1].score;
    for (0..100) |_| {
        try f.store.applyOpWithScope(.{ .update = .{
            .memory_id = "a-repeated",
            .confidence_delta = Decimal.one,
            .evidence_increment = std.math.maxInt(u32),
            .new_status = .active,
        } }, now, live, &f.touched);
    }
    try f.store.applyOpWithScope(.{ .merge = .{ .from_id = "duplicate", .into_id = "a-repeated" } }, now, live, &f.touched);
    var after = try f.query(now, &.{"BTC-USDT"});
    defer after.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), after.items.len);
    try testing.expectEqualStrings("E_run_fresh", after.items[0].memory.memory_id);
    try testing.expectEqualStrings("a-repeated", after.items[1].memory.memory_id);
    try testing.expectEqual(repeated_score, after.items[1].score);
    try testing.expectEqual(old_time, after.items[1].memory.created_ms);
    try testing.expectEqual(@as(u32, 0), after.items[1].memory.evidence_count);
    try testing.expect(after.items[1].memory.confidence.isZero());
    try testing.expectEqual(@as(u32, 0), f.store.find("a-repeated").?.evidence_count);
    var expired = try f.query(now + 101, &.{"BTC-USDT"});
    defer expired.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), expired.items.len);
    try testing.expectEqualStrings("E_run_fresh", expired.items[0].memory.memory_id);
}

test "identical or equivalent full replacements retain original age and cannot revive expired content" {
    var f = Fixture{};
    defer f.deinit();
    const old_time = now - memory.MAX_DECISION_AGE_MS + 100;
    const original = "{\"tags\":[\"BTC-USDT\"],\"observation\":{\"value\":1,\"series\":[null,true,1.5,\"abc\"]}}";
    const equivalent = "{ \"observation\": {\"series\":[null,true,1.5,\"\\u0061bc\"],\"value\":1}, \"tags\":[\"BTC-USDT\"] }";
    try f.create("replacement", live, old_time, .active, original);
    for ([_][]const u8{ original, equivalent }) |content| {
        try f.store.applyOpWithScope(.{ .update = .{
            .memory_id = "replacement",
            .content_json = content,
            .new_status = .active,
        } }, now, live, &f.touched);
        var results = try f.query(now, &.{"BTC-USDT"});
        defer results.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), results.items.len);
        try testing.expectEqual(old_time, results.items[0].memory.created_ms);
    }
    try f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "replacement",
        .content_json = original,
        .new_status = .active,
    } }, now + 101, live, &f.touched);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("replacement").?.*, live, now + 101));
    var expired = try f.query(now + 101, &.{"BTC-USDT"});
    defer expired.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), expired.items.len);

    // A changed observation remains a genuine replacement, with new content
    // time. The original persisted versions remain untouched in the output.
    const changed = "{\"tags\":[\"BTC-USDT\"],\"observation\":{\"value\":2,\"series\":[null,true,1.5,\"abc\"]}}";
    try f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "replacement",
        .content_json = changed,
        .new_status = .active,
    } }, now + 102, live, &f.touched);
    var refreshed = try f.query(now + 102, &.{"BTC-USDT"});
    defer refreshed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), refreshed.items.len);
    try testing.expectEqual(now + 102, refreshed.items[0].memory.created_ms);
    try testing.expectEqual(old_time, f.touched.items[0].created_ms);
    try testing.expectEqual(@as(usize, 5), f.touched.items.len);
}

test "partial updates cannot promote legacy, unverified, expired or future content" {
    var f = Fixture{};
    defer f.deinit();
    try f.store.applyOp(.{ .create = .{
        .memory_id = "legacy",
        .kind = .strategy,
        .status = .active,
        .confidence = Decimal.one,
        .content_json = "{\"lesson\":\"synthetic obsolete belief\"}",
    } }, now - 100, &f.touched);
    try f.store.applyOp(.{ .update = .{ .memory_id = "legacy", .evidence_increment = 500 } }, now, &f.touched);
    try testing.expectError(error.ScopeMismatch, f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "legacy",
        .new_status = .active,
    } }, now, live, &f.touched));
    try testing.expectEqual(@as(u32, 2), f.store.find("legacy").?.version);

    try f.create("unverified", live, now, .unverified, tags);
    try f.create("expired", live, now - memory.MAX_DECISION_AGE_MS - 1, .active, tags);
    try f.create("future", live, now + 1, .active, tags);
    for ([_][]const u8{ "unverified", "expired", "future" }) |id| {
        try testing.expectError(error.ContentReplacementRequired, f.store.applyOpWithScope(.{ .update = .{
            .memory_id = id,
            .new_status = .active,
            .confidence_delta = Decimal.one,
            .evidence_increment = 100,
        } }, now, live, &f.touched));
        try testing.expectEqual(@as(u32, 1), f.store.find(id).?.version);
    }

    // Explicit full replacement may reuse the ID, but inherits no authority or
    // status. A missing new_status defaults to unverified, not the old active.
    try f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "legacy",
        .content_json = tags,
        .confidence_delta = Decimal.one,
        .evidence_increment = 500,
    } }, now, live, &f.touched);
    const replacement = f.store.find("legacy").?;
    try testing.expectEqual(@as(u32, 3), replacement.version);
    try testing.expectEqual(memory.Status.unverified, replacement.status);
    try testing.expectEqual(@as(u32, 0), replacement.evidence_count);
    try testing.expect(replacement.confidence.isZero());
    try testing.expect(std.mem.indexOf(u8, replacement.content_json, "obsolete belief") == null);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, replacement.*, live, now));
    try f.store.applyOpWithScope(.{ .update = .{
        .memory_id = "legacy",
        .content_json = tags,
        .new_status = .active,
    } }, now, live, &f.touched);
    try testing.expect(try memory.isDecisionEligible(testing.allocator, replacement.*, live, now));
    // The previous versions are still in the append-only output, untouched.
    try testing.expect(std.mem.indexOf(u8, f.touched.items[0].content_json, "obsolete belief") != null);
}

test "cross scope merge and partial update cannot launder source content or evidence" {
    var f = Fixture{};
    defer f.deinit();
    try f.create("live", live, now, .active, tags);
    try f.create("demo", demo, now, .active, tags);
    try f.create("epoch", .{ .mode = .live, .policy_epoch = memory.CURRENT_POLICY_EPOCH + 1 }, now, .active, tags);
    for ([_][]const u8{ "demo", "epoch" }) |id| {
        try testing.expectError(error.ScopeMismatch, f.store.applyOpWithScope(.{ .merge = .{
            .from_id = id,
            .into_id = "live",
        } }, now, live, &f.touched));
        try testing.expectError(error.ScopeMismatch, f.store.applyOpWithScope(.{ .merge = .{
            .from_id = "live",
            .into_id = id,
        } }, now, live, &f.touched));
        try testing.expectError(error.ScopeMismatch, f.store.applyOpWithScope(.{ .update = .{
            .memory_id = id,
            .new_status = .active,
        } }, now, live, &f.touched));
        try testing.expectEqual(@as(u32, 1), f.store.find(id).?.version);
    }
    try testing.expectEqual(@as(u32, 1), f.store.find("live").?.version);
    try testing.expectEqual(@as(usize, 3), f.touched.items.len);
}

test "trusted writer owns outer provenance and generic writes cannot forge or preserve it" {
    var f = Fixture{};
    defer f.deinit();
    const forged = "{\"_decision_scope\":{\"policy_epoch\":1,\"mode\":\"live\",\"content_ms\":1},\"content\":{\"tags\":[\"BTC-USDT\"]}}";
    try f.store.applyOp(.{ .create = .{
        .memory_id = "forged",
        .kind = .strategy,
        .status = .active,
        .content_json = forged,
    } }, 1, &f.touched);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("forged").?.*, live, 1));
    const escaped = "{\"\\u005fdecision_scope\":{\"policy_epoch\":1,\"mode\":\"live\",\"content_ms\":1},\"content\":{}}";
    try f.store.applyOp(.{ .update = .{ .memory_id = "forged", .content_json = escaped } }, 1, &f.touched);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("forged").?.*, live, 1));

    try f.create("nested-forgery", demo, now, .active, forged);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("nested-forgery").?.*, live, now));
    try testing.expect(try memory.isDecisionEligible(testing.allocator, f.store.find("nested-forgery").?.*, demo, now));
    try f.create("generic-update", live, now, .active, tags);
    try f.store.applyOp(.{ .update = .{
        .memory_id = "generic-update",
        .new_status = .active,
        .evidence_increment = 1,
    } }, now, &f.touched);
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("generic-update").?.*, live, now));
}

test "invalid provenance and invalid age bounds fail closed; age boundary is inclusive" {
    var f = Fixture{};
    defer f.deinit();
    try f.create("boundary", live, now - memory.MAX_DECISION_AGE_MS, .active, tags);
    try testing.expect(try memory.isDecisionEligible(testing.allocator, f.store.find("boundary").?.*, live, now));
    try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("boundary").?.*, live, now + 1));
    for ([_]i64{ -1, 0, memory.MAX_DECISION_AGE_MS + 1 }) |bound| {
        const invalid = memory.DecisionScope{ .mode = .live, .max_age_ms = bound };
        try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find("boundary").?.*, invalid, now));
        try testing.expectError(error.InvalidDecisionScope, f.store.applyOpWithScope(.{ .create = .{
            .memory_id = "invalid-scope",
            .kind = .reflection,
        } }, now, invalid, &f.touched));
    }
    try testing.expectError(error.InvalidContent, f.create("not-object", live, now, .active, "[]"));
    try testing.expectError(error.InvalidContent, f.create("malformed", live, now, .active, "{"));
    try testing.expectError(error.InvalidContent, f.create("duplicate-keys", live, now, .active, "{\"tags\":[],\"tags\":[\"BTC-USDT\"]}"));
    try testing.expectEqual(@as(usize, 1), f.store.count());
}

test "malformed or ambiguous persisted provenance is never eligible" {
    var f = Fixture{};
    defer f.deinit();
    const invalid_envelopes = [_][]const u8{
        "{",
        "{}",
        "{\"_decision_scope\":{\"policy_epoch\":1,\"mode\":\"live\",\"content_ms\":-1},\"content\":{}}",
        "{\"_decision_scope\":{\"policy_epoch\":1,\"mode\":\"unknown\",\"content_ms\":0},\"content\":{}}",
        "{\"_decision_scope\":{\"policy_epoch\":1,\"mode\":\"live\",\"content_ms\":\"0\"},\"content\":{}}",
        "{\"_decision_scope\":{\"policy_epoch\":1,\"mode\":\"live\",\"content_ms\":0,\"content_ms\":1},\"content\":{}}",
        "{\"_decision_scope\":{\"policy_epoch\":1,\"mode\":\"live\",\"content_ms\":0},\"content\":[]}",
    };
    for (invalid_envelopes, 0..) |content, index| {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "invalid-{d}", .{index});
        try f.store.load(.{
            .memory_id = id,
            .version = 1,
            .kind = .strategy,
            .status = .active,
            .confidence = Decimal.one,
            .evidence_count = 999,
            .content_json = content,
            .created_ms = 1,
        });
        try testing.expect(!try memory.isDecisionEligible(testing.allocator, f.store.find(id).?.*, live, 1));
    }
    var results = try f.query(1, &.{});
    defer results.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), results.items.len);
}

test "scoped creation at capacity prefers ineligible protected priors over current facts" {
    var f = Fixture{};
    defer f.deinit();
    try f.create("current-fact", live, now, .active, tags);
    try f.store.load(.{
        .memory_id = "PR_short",
        .version = 17,
        .kind = .strategy,
        .status = .active,
        .confidence = Decimal.one,
        .evidence_count = 999,
        .content_json = tags,
        .created_ms = 1,
    });
    var index: usize = 0;
    while (f.store.count() < memory.MAX_MEMORIES) : (index += 1) {
        var id_buf: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "legacy-strategy-{d}", .{index});
        try f.store.load(.{
            .memory_id = id,
            .version = 3,
            .kind = .strategy,
            .status = .active,
            .confidence = Decimal.one,
            .evidence_count = 999,
            .content_json = tags,
            .created_ms = 2,
        });
    }
    // All legacy rows are normally protected from generic eviction.
    try f.create("new-fact", live, now, .active, tags);
    try testing.expectEqual(memory.MAX_MEMORIES, f.store.count());
    try testing.expect(f.store.find("PR_short") == null);
    try testing.expect(f.store.find("current-fact") != null);
    try testing.expectEqual(@as(usize, 2), f.touched.items.len);
    var results = try f.query(now, &.{"BTC-USDT"});
    defer results.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), results.items.len);
}

test "scoped retrieval never exposes stored confidence or repetition as independent evidence" {
    var f = Fixture{};
    defer f.deinit();
    try f.create("synthetic-scoped", live, now, .active, tags);
    // Rebuild a persisted row with self-reported metadata from another writer.
    var row = f.store.find("synthetic-scoped").?.*;
    row.memory_id = "imported-metadata";
    row.confidence = Decimal.one;
    row.evidence_count = std.math.maxInt(u32);
    try f.store.load(row);
    var results = try f.query(now, &.{"BTC-USDT"});
    defer results.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), results.items.len);
    try testing.expectEqual(results.items[0].score, results.items[1].score);
    for (results.items) |scored| {
        try testing.expect(scored.memory.confidence.isZero());
        try testing.expectEqual(@as(u32, 0), scored.memory.evidence_count);
    }
    // Normalizing the decision view does not mutate the stored audit row.
    try testing.expectEqual(std.math.maxInt(u32), f.store.find("imported-metadata").?.evidence_count);
}
