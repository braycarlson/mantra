const std = @import("std");

const assert = std.debug.assert;

pub const Arguments = struct {
    events_max: u32,
    seed: u64,
};

pub const Error = error{
    SeedInvalid,
};

pub const events_max_default: u32 = 4096;
pub const events_max_smoke: u32 = 64;
pub const seed_smoke: u64 = 123;

comptime {
    assert(events_max_smoke >= 1);
    assert(events_max_smoke < events_max_default);
    assert(seed_smoke > 0);
}

pub fn parse_seed(text: []const u8) Error!u64 {
    assert(std.mem.findScalar(u8, text, 0) == null);

    return std.fmt.parseUnsigned(u64, text, 10) catch return Error.SeedInvalid;
}

pub fn random_seed(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;

    io.random(&bytes);

    return std.mem.readInt(u64, &bytes, .little);
}

const testing = std.testing;

test parse_seed {
    try testing.expectEqual(@as(u64, 123), try parse_seed("123"));
    try testing.expectError(Error.SeedInvalid, parse_seed(""));
    try testing.expectError(Error.SeedInvalid, parse_seed("12x"));
    try testing.expectError(Error.SeedInvalid, parse_seed("18446744073709551616"));
}
