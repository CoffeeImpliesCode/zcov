const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Self-coverage: zig-cov measuring its own test suite. These are the same
    // options `zig-cov test` passes to any project (see the README setup), which
    // is what lets the tool dogfood itself in CI.
    const coverage = b.option(bool, "coverage", "Instrument zig-cov's own tests with zig-cov") orelse false;
    const coverage_rt = b.option([]const u8, "coverage-rt", "Path to zig-cov-rt.o") orelse null;

    // zig-cov CLI executable
    const exe = b.addExecutable(.{
        .name = "zig-cov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // build_orchestrator.zig calls std.c.getpid() and zcov_format.zig
            // uses fopen/fread. macOS links libc implicitly; Linux does not, so
            // it must be explicit or the build fails on Linux.
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // zig-cov-rt: runtime linked into instrumented test binaries. Emitted as a
    // relocatable OBJECT (not a static library): the sancov callbacks must be
    // force-included, but lld pulls .a members lazily and drops them, so on Linux
    // __sanitizer_cov_trace_pc_guard ends up undefined. An object is always
    // linked in full. link_libc = true so atexit()/fopen() are available.
    const rt_obj = b.addObject(.{
        .name = "zig-cov-rt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(rt_obj.getEmittedBin(), .lib, "zig-cov-rt.o").step);

    // Run step for the CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Passthrough of trailing args after `--`. `addPassthruArgs` is absent from
    // std.Build.Step.Run on Zig 0.16 and present again on the 0.17 master this
    // project tracks; the comptime guard keeps build.zig loadable on both, which
    // is a precondition for the `docs` step below existing at all.
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zig-cov");
    run_step.dependOn(&run_cmd.step);

    // Autodoc bundle (run with: zig build docs). The documented root is the CLI
    // root, src/main.zig: it is the tool's public module, and every other file
    // (coverage model, DWARF resolver, report writers, sancov runtime) is
    // reachable from it by @import, so autodoc documents the whole tool.
    //
    // An object compile, not a plain `zig build-obj src/main.zig`: build-obj has
    // no package manager and cannot turn link_libc on, and this root reaches
    // libc transitively — std.c.getpid() from build_orchestrator.zig and
    // fopen/fread from runtime/zcov_format.zig. Without it the compile dies on
    // "dependency on libc must be explicitly specified in the build command".
    // The root module below mirrors the exe's configuration, which is what
    // makes the docs root analyze standalone.
    const docs_obj = b.addObject(.{
        .name = "zig-cov-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const docs_step = b.step("docs", "Build the autodoc bundle into zig-out/docs");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    // Tests for zig-cov itself (main + report + coverage model).
    // link_libc = true is required because zcov_format.zig (imported transitively)
    // has tests that call fopen/fread, which need the system C library.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (coverage) instrument(unit_tests, coverage_rt);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Runtime library tests
    const rt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/sancov.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    // Deliberately NOT instrumented: this binary's root module *is* the coverage
    // runtime, so linking zig-cov-rt.o would duplicate the sancov symbols, and
    // instrumenting the trace callbacks would have them record their own calls.
    const run_rt_tests = b.addRunArtifact(rt_tests);
    test_step.dependOn(&run_rt_tests.step);

    // Coverage model + report formatter tests.
    // Uses a dedicated root (report_tests.zig) so that DCE does not drop these
    // modules: their code is only reachable from the CLI main, which is replaced
    // by the test runner and therefore eliminated in a test binary.
    const report_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/report_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (coverage) instrument(report_tests, coverage_rt);
    const run_report_tests = b.addRunArtifact(report_tests);
    test_step.dependOn(&run_report_tests.step);

    // Integration test (run with: zig build itest)
    // Builds the sample project under test/sample/ with coverage and verifies
    // that the full pipeline (sancov → .zcov → DWARF → report) is correct.
    const itest_options = b.addOptions();
    itest_options.addOptionPath("rt_lib_path", rt_obj.getEmittedBin());
    itest_options.addOption([]const u8, "sample_dir", sampleDir(b));
    itest_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);

    const itest_exe = b.addExecutable(.{
        .name = "zig-cov-itest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            // Uses std.c.getpid() and, via zcov_format.zig, fopen/fread — libc
            // must be explicit for the Linux build (see the exe above).
            .link_libc = true,
        }),
    });
    itest_exe.root_module.addOptions("build_options", itest_options);
    itest_exe.step.dependOn(b.getInstallStep()); // ensure zig-cov-rt.o is installed first

    const run_itest = b.addRunArtifact(itest_exe);
    const itest_step = b.step("itest", "Run integration tests (full pipeline: sancov → .zcov → DWARF → report)");
    itest_step.dependOn(&run_itest.step);

    // Synthetic benchmarks (run with: zig build bench)
    const bench_exe = b.addExecutable(.{
        .name = "zig-cov-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run synthetic performance benchmarks");
    bench_step.dependOn(&run_bench.step);
}

/// Absolute path of the integration-test sample project. 0.17 exposes the build
/// root as `b.root` with `joinString`; 0.16 exposes `b.pathFromRoot`. Both
/// resolve to <build root>/test/sample, so the branch is a pure API shim.
fn sampleDir(b: *std.Build) []const u8 {
    if (@hasField(std.Build, "root")) {
        return b.root.joinString(b.graph.arena, "test/sample") catch @panic("OOM");
    }
    return b.pathFromRoot("test/sample");
}

/// Apply zig-cov instrumentation to a test binary — the same three settings the
/// README tells users to add to their own build.zig:
///   * use_llvm: coverage instrumentation is only emitted by the LLVM backend
///   * fuzz: emits inline 8-bit counters and the PC table zig-cov reads
///   * link_libc: the runtime writes its .zcov from a libc atexit handler
fn instrument(compile: *std.Build.Step.Compile, rt_path: ?[]const u8) void {
    compile.use_llvm = true;
    compile.root_module.fuzz = true;
    compile.root_module.link_libc = true;
    if (rt_path) |p| compile.root_module.addObjectFile(.{ .cwd_relative = p });
}
