const std = @import("std");

// Version information
const version = "0.1.11";

// macOS Build Note:
// If you encounter code signing issues on macOS (especially for notarization),
// set the ZIG_SYSTEM_LINKER_HACK=1 environment variable to use Apple's system
// linker which properly handles header padding for code signatures:
//   export ZIG_SYSTEM_LINKER_HACK=1
//   zig build --release=fast

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("cc_streamer_lib", lib_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cc_streamer",
        .root_module = lib_mod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "ccstreamer",
        .root_module = exe_mod,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Add tests for utility modules
    const allocator_tests = b.addTest(.{
        .root_source_file = b.path("src/utils/allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_allocator_tests = b.addRunArtifact(allocator_tests);

    const test_utils_tests = b.addTest(.{
        .root_source_file = b.path("src/test_utils.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_test_utils_tests = b.addRunArtifact(test_utils_tests);

    // Add stream processing tests
    const stream_reader_tests = b.addTest(.{
        .root_source_file = b.path("src/stream/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_stream_reader_tests = b.addRunArtifact(stream_reader_tests);

    const boundary_detector_tests = b.addTest(.{
        .root_source_file = b.path("src/stream/boundary_detector.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_boundary_detector_tests = b.addRunArtifact(boundary_detector_tests);

    // Add parser module tests
    const tokenizer_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/tokenizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tokenizer_tests = b.addRunArtifact(tokenizer_tests);

    const ast_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_ast_tests = b.addRunArtifact(ast_tests);

    const parser_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    // Add formatter module tests
    const indentation_tests = b.addTest(.{
        .root_source_file = b.path("src/formatter/indentation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_indentation_tests = b.addRunArtifact(indentation_tests);

    const json_formatter_tests = b.addTest(.{
        .root_source_file = b.path("src/formatter/json_formatter.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_json_formatter_tests = b.addRunArtifact(json_formatter_tests);

    const colors_tests = b.addTest(.{
        .root_source_file = b.path("src/formatter/colors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_colors_tests = b.addRunArtifact(colors_tests);

    // Add behavioral tests
    const behavioral_tests = b.addTest(.{
        .root_source_file = b.path("test/behavioral_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_behavioral_tests = b.addRunArtifact(behavioral_tests);

    // Add E2E tests
    const e2e_tests = b.addTest(.{
        .root_source_file = b.path("test/e2e_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_allocator_tests.step);
    test_step.dependOn(&run_test_utils_tests.step);
    test_step.dependOn(&run_stream_reader_tests.step);
    test_step.dependOn(&run_boundary_detector_tests.step);
    test_step.dependOn(&run_tokenizer_tests.step);
    test_step.dependOn(&run_ast_tests.step);
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_indentation_tests.step);
    test_step.dependOn(&run_json_formatter_tests.step);
    test_step.dependOn(&run_colors_tests.step);
    test_step.dependOn(&run_behavioral_tests.step);
    test_step.dependOn(&run_e2e_tests.step);

    // Create separate step for E2E tests only
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    // Add a step for running tests with coverage
    const coverage_step = b.step("test-coverage", "Run tests with coverage");
    coverage_step.dependOn(&run_allocator_tests.step);
    coverage_step.dependOn(&run_test_utils_tests.step);
    coverage_step.dependOn(&run_stream_reader_tests.step);
    coverage_step.dependOn(&run_boundary_detector_tests.step);
    coverage_step.dependOn(&run_tokenizer_tests.step);
    coverage_step.dependOn(&run_ast_tests.step);
    coverage_step.dependOn(&run_parser_tests.step);
    coverage_step.dependOn(&run_indentation_tests.step);
    coverage_step.dependOn(&run_json_formatter_tests.step);
    coverage_step.dependOn(&run_colors_tests.step);
    coverage_step.dependOn(&run_behavioral_tests.step);

    // Create a real coverage collection step using functional test validation
    const coverage_collection_cmd = b.addSystemCommand(&.{ "bash", "-c", "./run_real_tests.sh" });

    // Add coverage threshold enforcement step that actually works
    const coverage_check_step = b.step("check-coverage", "Check coverage meets minimum threshold");
    const coverage_check_cmd = b.addSystemCommand(&.{ "bash", "-c", "echo 'Checking coverage threshold...' && " ++
        "if [ -f tmp/coverage.txt ]; then " ++
        "COVERAGE=$(grep 'Overall coverage:' tmp/coverage.txt | grep -o '[0-9]*\\.[0-9]*' | head -1); " ++
        "echo \"Current coverage: $COVERAGE%\"; " ++
        "if (( $(echo \"$COVERAGE >= 60.0\" | bc -l) )); then " ++
        "echo 'Coverage threshold met (>= 60%)'; " ++
        "else " ++
        "echo 'ERROR: Coverage $COVERAGE% below minimum threshold of 60%'; exit 1; " ++
        "fi; " ++
        "else " ++
        "echo 'ERROR: No coverage report found. Run coverage collection first.'; exit 1; " ++
        "fi" });

    // Make coverage check depend on coverage collection
    coverage_check_cmd.step.dependOn(&coverage_collection_cmd.step);
    coverage_check_step.dependOn(&coverage_check_cmd.step);
}
