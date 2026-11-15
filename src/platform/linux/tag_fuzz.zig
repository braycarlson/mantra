const std = @import("std");

const fuzz = @import("../../testing/fuzz.zig");
const tag = @import("tag.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const Alphabet = enum {
    binary,
    text,
};

const Kind = enum {
    arbitrary,
    boolean,
    cvolume,
    proplist,
    string,
    uint8,
    uint32,
};

const Value = union(Kind) {
    arbitrary: []const u8,
    boolean: bool,
    cvolume: tag.Cvolume,
    proplist: []const tag.Property,
    string: ?[]const u8,
    uint8: u8,
    uint32: u32,
};

const Scratch = struct {
    entries: [entries_total_max]tag.Property,
    entry_count: u32,
    text: [text_bytes_total_max]u8,
    text_count: u32,

    fn generate(scratch: *Scratch, random: std.Random) Value {
        const result: Value = switch (random.enumValue(Kind)) {
            .arbitrary => .{ .arbitrary = scratch.random_bytes(random, 0, .binary) },
            .boolean => .{ .boolean = random.boolean() },
            .cvolume => .{ .cvolume = random_cvolume(random) },
            .proplist => .{ .proplist = scratch.random_properties(random) },
            .string => .{ .string = scratch.random_string(random) },
            .uint8 => .{ .uint8 = random.int(u8) },
            .uint32 => .{ .uint32 = random.int(u32) },
        };

        return result;
    }

    fn random_bytes(
        scratch: *Scratch,
        random: std.Random,
        length_min: u32,
        alphabet: Alphabet,
    ) []const u8 {
        assert(length_min <= text_bytes_max);

        const length = random.intRangeAtMost(u32, length_min, text_bytes_max);

        assert(scratch.text_count + length <= text_bytes_total_max);

        const result = scratch.text[scratch.text_count..][0..length];

        random.bytes(result);

        if (alphabet == .text) {
            for (result) |*byte| {
                if (byte.* == 0) byte.* = 1;
            }
        }

        scratch.text_count += length;

        return result;
    }

    fn random_properties(scratch: *Scratch, random: std.Random) []const tag.Property {
        const count = random.uintAtMost(u32, entries_max);

        assert(scratch.entry_count + count <= entries_total_max);

        const result = scratch.entries[scratch.entry_count..][0..count];

        for (result) |*entry| {
            entry.* = .{
                .key = scratch.random_bytes(random, 1, .text),
                .value = scratch.random_bytes(random, 0, .text),
            };
        }

        scratch.entry_count += count;

        return result;
    }

    fn random_string(scratch: *Scratch, random: std.Random) ?[]const u8 {
        if (random.uintLessThan(u32, string_null_odds) == 0) return null;
        return scratch.random_bytes(random, 0, .text);
    }
};

pub const entries_max: u32 = 4;
pub const operations_max: u32 = 64;
pub const packet_bytes_max: u32 = 4096;
pub const text_bytes_max: u32 = 32;
pub const values_max: u32 = 8;
const entries_total_max: u32 = values_max * entries_max;
const noise_odds: u32 = 4;
const string_null_odds: u32 = 4;
const text_bytes_total_max: u32 = values_max * (2 * entries_max + 1) * text_bytes_max;
const value_bytes_max: u32 = 2 + entries_max * (2 * text_bytes_max + 13);

comptime {
    assert(entries_max <= tag.proplist_entries_max);
    assert(operations_max > 0);
    assert(values_max * value_bytes_max <= packet_bytes_max);
    assert(2 + 4 * @as(u32, tag.channels_max) <= value_bytes_max);
    assert(5 + text_bytes_max <= value_bytes_max);
}

pub fn main(gpa: Allocator, args: fuzz.Arguments) !void {
    _ = gpa;

    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        try fuzz_event(random);
    }

    assert(event == args.events_max);
}

fn fuzz_event(random: std.Random) !void {
    var scratch: Scratch = undefined;
    var storage: [packet_bytes_max]u8 = undefined;
    var values: [values_max]Value = undefined;

    scratch.entry_count = 0;
    scratch.text_count = 0;

    const count = random.intRangeAtMost(u32, 1, values_max);

    for (values[0..count]) |*value| {
        value.* = scratch.generate(random);
    }

    var writer = tag.Writer.init(&storage);

    for (values[0..count]) |*value| {
        put(&writer, value);
    }

    const bytes = try writer.written();

    try check_reads(bytes, values[0..count]);
    try check_skips(bytes, values[0..count]);
    try check_noise(random, bytes);
}

fn put(writer: *tag.Writer, value: *const Value) void {
    switch (value.*) {
        .arbitrary => |bytes| writer.put_arbitrary(bytes),
        .boolean => |flag| writer.put_boolean(flag),
        .cvolume => |volume| writer.put_cvolume(volume.channels, volume.level),
        .proplist => |entries| writer.put_proplist(entries),
        .string => |text| writer.put_string(text),
        .uint8 => |number| writer.put_u8(number),
        .uint32 => |number| writer.put_u32(number),
    }
}

fn check_reads(bytes: []const u8, values: []const Value) !void {
    assert(bytes.len > 0);
    assert(values.len > 0);

    var reader = tag.Reader.init(bytes);

    for (values) |*value| {
        const before = reader.offset;

        try check_read(&reader, value);
        try testing.expectEqual(before + encoded_length(value), reader.offset);
    }

    try testing.expect(reader.is_empty());
}

fn check_read(reader: *tag.Reader, value: *const Value) !void {
    switch (value.*) {
        .arbitrary, .proplist => try reader.skip(),
        .boolean => |flag| try testing.expectEqual(flag, try reader.read_boolean()),
        .cvolume => |volume| {
            const actual = try reader.read_cvolume();

            try testing.expectEqual(volume.channels, actual.channels);
            try testing.expectEqual(volume.level, actual.level);
        },
        .string => |text| try check_string(text, try reader.read_string()),
        .uint8 => |number| try testing.expectEqual(number, try reader.read_u8()),
        .uint32 => |number| try testing.expectEqual(number, try reader.read_u32()),
    }
}

fn check_string(expected: ?[]const u8, actual: ?[]const u8) !void {
    try testing.expectEqual(expected == null, actual == null);

    const text = expected orelse return;

    try testing.expectEqualStrings(text, actual.?);
}

fn check_skips(bytes: []const u8, values: []const Value) !void {
    assert(bytes.len > 0);
    assert(values.len > 0);

    var reader = tag.Reader.init(bytes);

    for (values) |*value| {
        const before = reader.offset;

        try reader.skip();
        try testing.expectEqual(before + encoded_length(value), reader.offset);
    }

    try testing.expect(reader.is_empty());
}

fn check_noise(random: std.Random, bytes: []const u8) !void {
    assert(bytes.len <= packet_bytes_max);

    var storage: [packet_bytes_max]u8 = undefined;

    const noise = scramble(random, bytes, &storage);

    var reader = tag.Reader.init(noise);
    var operation: u32 = 0;

    while (operation < operations_max) : (operation += 1) {
        if (reader.is_empty()) break;

        const before = reader.offset;

        step(random, &reader) catch {
            try testing.expect(reader.offset <= noise.len);

            break;
        };

        try testing.expect(reader.offset > before);
        try testing.expect(reader.offset <= noise.len);
    }
}

fn scramble(random: std.Random, bytes: []const u8, storage: *[packet_bytes_max]u8) []const u8 {
    assert(bytes.len <= packet_bytes_max);

    if (random.uintLessThan(u32, noise_odds) == 0) {
        const length = random.uintAtMost(usize, packet_bytes_max);

        random.bytes(storage[0..length]);

        return storage[0..length];
    }

    const length = random.uintAtMost(usize, bytes.len);

    @memcpy(storage[0..length], bytes[0..length]);

    if (length > 0) {
        storage[random.uintLessThan(usize, length)] = random.int(u8);
    }

    return storage[0..length];
}

fn step(random: std.Random, reader: *tag.Reader) tag.Error!void {
    switch (random.enumValue(Kind)) {
        .arbitrary, .proplist => try reader.skip(),
        .boolean => _ = try reader.read_boolean(),
        .cvolume => _ = try reader.read_cvolume(),
        .string => _ = try reader.read_string(),
        .uint8 => _ = try reader.read_u8(),
        .uint32 => _ = try reader.read_u32(),
    }
}

fn random_cvolume(random: std.Random) tag.Cvolume {
    const result: tag.Cvolume = .{
        .channels = random.intRangeAtMost(u8, 1, tag.channels_max),
        .level = random.uintAtMost(u32, std.math.maxInt(i32)),
    };

    assert(result.channels > 0);
    assert(result.channels <= tag.channels_max);

    return result;
}

fn encoded_length(value: *const Value) usize {
    const result: usize = switch (value.*) {
        .arbitrary => |bytes| 5 + bytes.len,
        .boolean => 1,
        .cvolume => |volume| 2 + 4 * @as(usize, volume.channels),
        .proplist => |entries| proplist_length(entries),
        .string => |text| if (text) |bytes| bytes.len + 2 else 1,
        .uint8 => 2,
        .uint32 => 5,
    };

    assert(result <= value_bytes_max);

    return result;
}

fn proplist_length(entries: []const tag.Property) usize {
    assert(entries.len <= entries_max);

    var length: usize = 2;

    for (entries) |entry| {
        assert(entry.key.len > 0);

        length += entry.key.len + 2 + 5 + entry.value.len + 6;
    }

    return length;
}

test "the tag fuzzer holds for the smoke seed" {
    try main(testing.allocator, .{ .events_max = fuzz.events_max_smoke, .seed = fuzz.seed_smoke });
}
