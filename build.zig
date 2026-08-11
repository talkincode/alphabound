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
