const std = @import("std");

const assert = std.debug.assert;

const Backend = enum {
    native,
    mock,
};

const ExampleUse = enum {
    installed,
    checked,
};

const Steps = struct {
    check: *std.Build.Step,
    ci: *std.Build.Step,
    examples: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_linux: *std.Build.Step,
    test_mock: *std.Build.Step,
    test_unit: *std.Build.Step,
    test_windows: *std.Build.Step,
};

const format_paths = [_][]const u8{ "build.zig", "src", "examples" };
const example_directory = "examples";
const example_name_bytes_max: u32 = 256;
const windows_libraries = [_][]const u8{ "kernel32", "ole32" };

const linux_query = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .linux,
    .abi = .gnu,
};

const windows_query = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .windows,
    .abi = .gnu,
};

comptime {
    assert(format_paths.len > 0);
    assert(windows_libraries.len > 0);
    assert(example_name_bytes_max >= 64);
}

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const steps = create_steps(builder);

    const backend = builder.option(Backend, "backend", "Backend selection: native or mock") orelse
        .native;

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const build_options = create_options(builder, backend == .mock);
    const mock_build_options = create_options(builder, true);
    const native_build_options = create_options(builder, false);

    const mantra = builder.addModule("mantra", .{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mantra.addImport("build_options", build_options);

    link_platform(mantra, target);

    add_format(builder, &steps);

    add_suite(
        builder,
        steps.test_unit,
        &steps,
        mock_build_options,
        "src/unit_tests.zig",
        optimize,
        filters,
    );

    add_suite(
        builder,
        steps.test_mock,
        &steps,
        mock_build_options,
        "src/mock_tests.zig",
        optimize,
        filters,
    );

    add_linux_tests(builder, &steps, native_build_options, optimize, filters);
    add_windows_tests(builder, &steps, native_build_options, target, optimize, filters);
    add_examples(builder, &steps, mantra, native_build_options, target, optimize);

    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.test_unit);
    steps.ci.dependOn(steps.test_mock);
    steps.ci.dependOn(steps.test_linux);
    steps.ci.dependOn(steps.test_windows);

    builder.default_step.dependOn(steps.check);
}

fn create_steps(builder: *std.Build) Steps {
    return .{
        .check = builder.step("check", "Compile every artifact without running it"),
        .ci = builder.step("ci", "Run every check and test"),
        .examples = builder.step("examples", "Build every example"),
        .test_all = builder.step("test", "Run every test suite and the format check"),
        .test_fmt = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_linux = builder.step("test:linux", "Run the PulseAudio tests on a Linux host"),
        .test_mock = builder.step("test:mock", "Run the end to end tests against the mock backend"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
        .test_windows = builder.step("test:windows", "Run the WASAPI tests on a Windows host"),
    };
}

fn create_options(builder: *std.Build, mock: bool) *std.Build.Module {
    const options = builder.addOptions();

    options.addOption([]const u8, "library", "mantra");
    options.addOption(bool, "backend_mock", mock);

    return options.createModule();
}

fn add_format(builder: *std.Build, steps: *const Steps) void {
    const fmt = builder.addFmt(.{
        .paths = builder.pathList(&format_paths),
        .check = true,
    });

    steps.test_fmt.dependOn(&fmt.step);
    steps.test_all.dependOn(&fmt.step);
}

fn add_suite(
    builder: *std.Build,
    step: *std.Build.Step,
    steps: *const Steps,
    build_options: *std.Build.Module,
    root: []const u8,
    optimize: std.lang.Optimize,
    filters: []const []const u8,
) void {
    const module = builder.createModule(.{
        .root_source_file = builder.path(root),
        .target = builder.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options }},
    });

    link_platform(module, builder.graph.host);

    const suite = builder.addTest(.{
        .root_module = module,
        .filters = filters,
    });

    const run = builder.addRunArtifact(suite);

    run.setCwd(builder.path("."));

    step.dependOn(&run.step);

    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&suite.step);
}

fn add_linux_tests(
    builder: *std.Build,
    steps: *const Steps,
    build_options: *std.Build.Module,
    optimize: std.lang.Optimize,
    filters: []const []const u8,
) void {
    const native = builder.graph.host.result.os.tag == .linux;
    const resolved = if (native) builder.graph.host else builder.resolveTargetQuery(linux_query);

    const module = builder.createModule(.{
        .root_source_file = builder.path("src/linux_tests.zig"),
        .target = resolved,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options }},
    });

    const suite = builder.addTest(.{
        .root_module = module,
        .filters = filters,
    });

    steps.check.dependOn(&suite.step);

    if (!native) return;

    const run = builder.addRunArtifact(suite);

    run.setCwd(builder.path("."));

    steps.test_linux.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
}

fn add_windows_tests(
    builder: *std.Build,
    steps: *const Steps,
    build_options: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    filters: []const []const u8,
) void {
    const resolved = if (target.result.os.tag == .windows)
        target
    else
        builder.resolveTargetQuery(windows_query);

    const module = builder.createModule(.{
        .root_source_file = builder.path("src/windows_tests.zig"),
        .target = resolved,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options }},
    });

    link_platform(module, resolved);

    const suite = builder.addTest(.{
        .root_module = module,
        .filters = filters,
    });

    steps.check.dependOn(&suite.step);

    if (builder.graph.host.result.os.tag != .windows) {
        return;
    }

    const run = builder.addRunArtifact(suite);

    run.setCwd(builder.path("."));

    steps.test_windows.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
}

fn add_examples(
    builder: *std.Build,
    steps: *const Steps,
    mantra: *std.Build.Module,
    build_options: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const windows = target.result.os.tag == .windows;

    add_example_directory(builder, steps, mantra, target, optimize, .installed);

    const other = builder.resolveTargetQuery(if (windows) linux_query else windows_query);
    const library = library_module(builder, build_options, other, optimize);

    add_example_directory(builder, steps, library, other, optimize, .checked);
}

fn library_module(
    builder: *std.Build,
    build_options: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Module {
    const module = builder.createModule(.{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = build_options }},
    });

    link_platform(module, target);

    return module;
}

fn add_example_directory(
    builder: *std.Build,
    steps: *const Steps,
    mantra: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    use: ExampleUse,
) void {
    const io = builder.graph.io;

    var dir = builder.root.openDir(io, example_directory, .{ .iterate = true }) catch return;
    defer dir.close(io);

    builder.dependOnDirectoryContents(builder.path(example_directory));

    var iterator = dir.iterate();

    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const name = entry.name[0 .. entry.name.len - ".zig".len];

        var path_buffer: [example_name_bytes_max]u8 = undefined;

        const path = std.mem.print(
            &path_buffer,
            "{s}/{s}",
            .{ example_directory, entry.name },
        ) catch continue;

        const module = builder.createModule(.{
            .root_source_file = builder.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mantra", .module = mantra }},
        });

        const exe = builder.addExecutable(.{
            .name = name,
            .root_module = module,
        });

        switch (use) {
            .installed => add_example_run(builder, steps, exe, name),
            .checked => steps.check.dependOn(&exe.step),
        }
    }
}

fn add_example_run(
    builder: *std.Build,
    steps: *const Steps,
    exe: *std.Build.Step.Compile,
    name: []const u8,
) void {
    const install = builder.addInstallArtifact(exe, .{});

    steps.examples.dependOn(&install.step);
    steps.check.dependOn(&exe.step);

    var run_name_buffer: [example_name_bytes_max]u8 = undefined;
    const run_name = std.mem.print(&run_name_buffer, "run-{s}", .{name}) catch return;

    var description_buffer: [example_name_bytes_max]u8 = undefined;

    const description = std.mem.print(
        &description_buffer,
        "Run the {s} example",
        .{name},
    ) catch return;

    const run = builder.addRunArtifact(exe);

    run.step.dependOn(&install.step);

    builder.step(run_name, description).dependOn(&run.step);
}

fn link_platform(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) {
        return;
    }

    for (windows_libraries) |library| {
        module.linkSystemLibrary(library, .{});
    }
}
