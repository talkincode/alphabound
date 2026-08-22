const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Vendored SQLite amalgamation, compiled as a static C library.
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        },
    });
    sqlite.installHeader(b.path("vendor/sqlite/sqlite3.h"), "sqlite3.h");

    const mod = b.addModule("alphabound", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("vendor/sqlite"));
    mod.addAnonymousImport("migration_0001", .{
        .root_source_file = b.path("migrations/0001_init.sql"),
    });
    mod.addAnonymousImport("migration_0002", .{
        .root_source_file = b.path("migrations/0002_webauthn.sql"),
    });
    mod.addAnonymousImport("migration_0003", .{
        .root_source_file = b.path("migrations/0003_review.sql"),
    });
    mod.addAnonymousImport("migration_0004", .{
        .root_source_file = b.path("migrations/0004_audit.sql"),
    });
    mod.addAnonymousImport("migration_0005", .{
        .root_source_file = b.path("migrations/0005_runtime_kv.sql"),
    });
    mod.addAnonymousImport("migration_0006", .{
        .root_source_file = b.path("migrations/0006_equity_marks.sql"),
    });
    mod.addAnonymousImport("migration_0007", .{
        .root_source_file = b.path("migrations/0007_periodic_review.sql"),
    });
    mod.addAnonymousImport("migration_0008", .{
        .root_source_file = b.path("migrations/0008_llm_usage.sql"),
    });
    mod.addAnonymousImport("migration_0009", .{
        .root_source_file = b.path("migrations/0009_intel.sql"),
    });
    mod.addAnonymousImport("favicon_svg", .{
        .root_source_file = b.path("dashboard/favicon.svg"),
    });
    mod.addAnonymousImport("favicon_ico", .{
        .root_source_file = b.path("dashboard/favicon.ico"),
    });
    mod.addAnonymousImport("favicon_png", .{
        .root_source_file = b.path("dashboard/favicon.png"),
    });
    mod.addAnonymousImport("apple_touch_icon_png", .{
        .root_source_file = b.path("dashboard/apple-touch-icon.png"),
    });
    mod.addAnonymousImport("icon_192_png", .{
        .root_source_file = b.path("dashboard/icon-192.png"),
    });
    mod.addAnonymousImport("icon_512_png", .{
        .root_source_file = b.path("dashboard/icon-512.png"),
    });

    const exe = b.addExecutable(.{
        .name = "alphabound",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "alphabound", .module = mod },
            },
        }),
    });
    exe.root_module.linkLibrary(sqlite);
    exe.root_module.addAnonymousImport("dashboard_index_html", .{
        .root_source_file = b.path("dashboard/index.html"),
    });
    exe.root_module.addAnonymousImport("agent_system_prompt", .{
        .root_source_file = b.path("prompts/system.md"),
    });
    exe.root_module.addAnonymousImport("agent_reflection_prompt", .{
        .root_source_file = b.path("prompts/reflection.md"),
    });
    exe.root_module.addAnonymousImport("agent_review_prompt", .{
        .root_source_file = b.path("prompts/review.md"),
    });
    exe.root_module.addAnonymousImport("agent_periodic_review_prompt", .{
        .root_source_file = b.path("prompts/periodic_review.md"),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the daemon");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    mod.linkLibrary(sqlite);
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
