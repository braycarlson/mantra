const std = @import("std");

const fuzz = @import("testing/fuzz.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Fuzzers = .{
    .tag = @import("platform/linux/tag_fuzz.zig"),
};

const Fuzzer = std.meta.FieldEnum(@TypeOf(Fuzzers));

const Error = error{
    UsageInvalid,
};

const arguments_min: u32 = 2;
const arguments_max: u32 = 4;
const usage = "usage: fuzz <fuzzer> [seed] [events]\n";

comptime {
    assert(arguments_min < arguments_max);
    assert(@typeInfo(Fuzzer).@"enum".field_names.len > 0);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    if (arguments.len < arguments_min) return usage_invalid();
    if (arguments.len > arguments_max) return usage_invalid();

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse return usage_invalid();

    const seed = if (arguments.len > 2)
        try fuzz.parse_seed(arguments[2])
    else
        fuzz.random_seed(init.io);

    const events_max = if (arguments.len > 3)
        std.fmt.parseUnsigned(u32, arguments[3], 10) catch return usage_invalid()
    else
        fuzz.events_max_default;

    if (events_max < 1) return usage_invalid();

    var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer assert(safe_allocator.deinit() == 0);

    std.debug.print("fuzzer={t} seed={d} events={d}\n", .{ fuzzer, seed, events_max });

    try run(safe_allocator.allocator(), fuzzer, .{ .events_max = events_max, .seed = seed });
}

fn run(gpa: Allocator, fuzzer: Fuzzer, args: fuzz.Arguments) !void {
    assert(args.events_max >= 1);

    switch (fuzzer) {
        inline else => |name| try @field(Fuzzers, @tagName(name)).main(gpa, args),
    }
}

fn usage_invalid() Error {
    std.debug.print(usage, .{});

    return Error.UsageInvalid;
}
