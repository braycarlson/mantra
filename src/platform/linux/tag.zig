const std = @import("std");

const assert = std.debug.assert;

pub const Error = error{
    Overflow,
    Truncated,
    Unexpected,
};

pub const Tag = enum(u8) {
    invalid = 0,
    boolean_false = '0',
    boolean_true = '1',
    string_null = 'N',
    uint8 = 'B',
    proplist = 'P',
    uint64 = 'R',
    timeval = 'T',
    usec = 'U',
    volume = 'V',
    uint32 = 'L',
    sample_spec = 'a',
    format_info = 'f',
    channel_map = 'm',
    int64 = 'r',
    string = 't',
    cvolume = 'v',
    arbitrary = 'x',
};

pub const channels_max: u8 = 32;
pub const nesting_max: u32 = 8;

comptime {
    assert(channels_max > 0);
    assert(nesting_max > 0);
}

pub const Writer = struct {
    buffer: []u8,
    len: usize = 0,
    overflow: bool = false,

    pub fn init(buffer: []u8) Writer {
        const result = Writer{ .buffer = buffer };

        assert(result.len == 0);

        return result;
    }

    pub fn reset(writer: *Writer) void {
        writer.len = 0;
        writer.overflow = false;

        assert(writer.len == 0);
    }

    pub fn written(writer: *const Writer) Error![]const u8 {
        if (writer.overflow) {
            return Error.Overflow;
        }

        return writer.buffer[0..writer.len];
    }

    pub fn put_u8(writer: *Writer, value: u8) void {
        writer.tag(.uint8);
        writer.raw_u8(value);
    }

    pub fn put_u32(writer: *Writer, value: u32) void {
        writer.tag(.uint32);
        writer.raw_u32(value);
    }

    pub fn put_boolean(writer: *Writer, value: bool) void {
        writer.tag(if (value) .boolean_true else .boolean_false);
    }

    pub fn put_string(writer: *Writer, value: ?[]const u8) void {
        const text = value orelse {
            writer.tag(.string_null);

            return;
        };

        writer.tag(.string);
        writer.bytes(text);
        writer.raw_u8(0);
    }

    pub fn put_arbitrary(writer: *Writer, value: []const u8) void {
        writer.tag(.arbitrary);
        writer.raw_u32(@intCast(value.len));
        writer.bytes(value);
    }

    pub fn put_cvolume(writer: *Writer, channels: u8, level: u32) void {
        assert(channels > 0);
        assert(channels <= channels_max);

        writer.tag(.cvolume);
        writer.raw_u8(channels);

        var index: u8 = 0;

        while (index < channels) : (index += 1) {
            writer.raw_u32(level);
        }
    }

    pub fn put_proplist(writer: *Writer, entries: []const Property) void {
        writer.tag(.proplist);

        for (entries) |entry| {
            assert(entry.key.len > 0);

            writer.put_string(entry.key);
            writer.put_u32(@intCast(entry.value.len + 1));
            writer.put_arbitrary_terminated(entry.value);
        }

        writer.put_string(null);
    }

    fn put_arbitrary_terminated(writer: *Writer, value: []const u8) void {
        writer.tag(.arbitrary);
        writer.raw_u32(@intCast(value.len + 1));
        writer.bytes(value);
        writer.raw_u8(0);
    }

    fn tag(writer: *Writer, value: Tag) void {
        writer.raw_u8(@intFromEnum(value));
    }

    fn raw_u8(writer: *Writer, value: u8) void {
        if (writer.len + 1 > writer.buffer.len) {
            writer.overflow = true;

            return;
        }

        writer.buffer[writer.len] = value;
        writer.len += 1;
    }

    fn raw_u32(writer: *Writer, value: u32) void {
        if (writer.len + 4 > writer.buffer.len) {
            writer.overflow = true;

            return;
        }

        std.mem.writeInt(u32, writer.buffer[writer.len..][0..4], value, .big);

        writer.len += 4;
    }

    fn bytes(writer: *Writer, value: []const u8) void {
        if (writer.len + value.len > writer.buffer.len) {
            writer.overflow = true;

            return;
        }

        @memcpy(writer.buffer[writer.len..][0..value.len], value);

        writer.len += value.len;
    }
};

pub const Cvolume = struct {
    channels: u8,
    level: u32,
};

pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const Reader = struct {
    buffer: []const u8,
    offset: usize = 0,

    pub fn init(buffer: []const u8) Reader {
        const result = Reader{ .buffer = buffer };

        assert(result.offset == 0);

        return result;
    }

    pub fn is_empty(reader: *const Reader) bool {
        return reader.offset >= reader.buffer.len;
    }

    pub fn peek(reader: *const Reader) Error!Tag {
        if (reader.offset >= reader.buffer.len) {
            return Error.Truncated;
        }

        return to_tag(reader.buffer[reader.offset]);
    }

    pub fn read_u8(reader: *Reader) Error!u8 {
        try reader.expect(.uint8);

        return try reader.raw_u8();
    }

    pub fn read_u32(reader: *Reader) Error!u32 {
        try reader.expect(.uint32);

        return try reader.raw_u32();
    }

    pub fn read_boolean(reader: *Reader) Error!bool {
        const found = try reader.peek();

        if (found == .boolean_true) {
            reader.offset += 1;

            return true;
        }

        if (found == .boolean_false) {
            reader.offset += 1;

            return false;
        }

        return Error.Unexpected;
    }

    pub fn read_string(reader: *Reader) Error!?[]const u8 {
        const found = try reader.peek();

        if (found == .string_null) {
            reader.offset += 1;

            return null;
        }

        if (found != .string) {
            return Error.Unexpected;
        }

        reader.offset += 1;

        const start = reader.offset;

        const end = std.mem.indexOfScalarPos(u8, reader.buffer, start, 0) orelse {
            return Error.Truncated;
        };

        reader.offset = end + 1;

        return reader.buffer[start..end];
    }

    pub fn read_cvolume(reader: *Reader) Error!Cvolume {
        try reader.expect(.cvolume);

        const channels = try reader.raw_u8();

        if (channels == 0 or channels > channels_max) {
            return Error.Unexpected;
        }

        var highest: u32 = 0;
        var index: u8 = 0;

        while (index < channels) : (index += 1) {
            const level = try reader.raw_u32();

            highest = @max(highest, level);
        }

        return Cvolume{ .channels = channels, .level = highest };
    }

    pub fn skip(reader: *Reader) Error!void {
        try reader.skip_at(0);
    }

    fn skip_at(reader: *Reader, depth: u32) Error!void {
        if (depth >= nesting_max) {
            return Error.Unexpected;
        }

        const found = try reader.peek();

        reader.offset += 1;

        switch (found) {
            .boolean_false, .boolean_true, .string_null, .invalid => return,
            .uint8 => try reader.advance(1),
            .uint32, .volume => try reader.advance(4),
            .uint64, .int64, .usec, .timeval => try reader.advance(8),
            .sample_spec => try reader.advance(6),
            .string => try reader.skip_string(),
            .arbitrary => try reader.skip_arbitrary(),
            .channel_map => try reader.skip_counted(1),
            .cvolume => try reader.skip_counted(4),
            .proplist => try reader.skip_proplist(depth),
            .format_info => try reader.skip_format_info(depth),
        }
    }

    fn skip_string(reader: *Reader) Error!void {
        const end = std.mem.indexOfScalarPos(u8, reader.buffer, reader.offset, 0) orelse {
            return Error.Truncated;
        };

        reader.offset = end + 1;
    }

    fn skip_arbitrary(reader: *Reader) Error!void {
        const length = try reader.raw_u32();

        try reader.advance(length);
    }

    fn skip_counted(reader: *Reader, stride: u32) Error!void {
        const count = try reader.raw_u8();

        try reader.advance(@as(usize, count) * stride);
    }

    fn skip_proplist(reader: *Reader, depth: u32) Error!void {
        var entries: u32 = 0;

        while (entries < 1024) : (entries += 1) {
            const key = try reader.read_string();

            if (key == null) {
                return;
            }

            try reader.skip_at(depth + 1);
            try reader.skip_at(depth + 1);
        }

        return Error.Unexpected;
    }

    fn skip_format_info(reader: *Reader, depth: u32) Error!void {
        try reader.skip_at(depth + 1);
        try reader.skip_at(depth + 1);
    }

    fn expect(reader: *Reader, wanted: Tag) Error!void {
        const found = try reader.peek();

        if (found != wanted) {
            return Error.Unexpected;
        }

        reader.offset += 1;
    }

    fn advance(reader: *Reader, count: usize) Error!void {
        if (reader.offset + count > reader.buffer.len) {
            return Error.Truncated;
        }

        reader.offset += count;
    }

    fn raw_u8(reader: *Reader) Error!u8 {
        if (reader.offset + 1 > reader.buffer.len) {
            return Error.Truncated;
        }

        const result = reader.buffer[reader.offset];

        reader.offset += 1;

        return result;
    }

    fn raw_u32(reader: *Reader) Error!u32 {
        if (reader.offset + 4 > reader.buffer.len) {
            return Error.Truncated;
        }

        const result = std.mem.readInt(u32, reader.buffer[reader.offset..][0..4], .big);

        reader.offset += 4;

        return result;
    }
};

fn to_tag(value: u8) Error!Tag {
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        if (value == field.value) {
            return @enumFromInt(field.value);
        }
    }

    return Error.Unexpected;
}

const testing = std.testing;

test "scalars round trip through the writer and the reader" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_u32(0x01020304);
    writer.put_u8(0x7f);
    writer.put_boolean(true);
    writer.put_boolean(false);

    var reader = Reader.init(try writer.written());

    try testing.expectEqual(@as(u32, 0x01020304), try reader.read_u32());
    try testing.expectEqual(@as(u8, 0x7f), try reader.read_u8());
    try testing.expect(try reader.read_boolean());
    try testing.expect(!try reader.read_boolean());
    try testing.expect(reader.is_empty());
}

test "unsigned values are written big endian" {
    var storage: [8]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_u32(0x01020304);

    const bytes = try writer.written();

    try testing.expectEqualSlices(u8, &.{ 'L', 0x01, 0x02, 0x03, 0x04 }, bytes);
}

test "strings round trip and distinguish absence from emptiness" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_string("sink-name");
    writer.put_string(null);
    writer.put_string("");

    var reader = Reader.init(try writer.written());

    try testing.expectEqualStrings("sink-name", (try reader.read_string()).?);
    try testing.expect((try reader.read_string()) == null);
    try testing.expectEqualStrings("", (try reader.read_string()).?);
    try testing.expect(reader.is_empty());
}

test "an arbitrary block carries its own length" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    const payload = [_]u8{ 1, 2, 3, 0, 5 };

    writer.put_arbitrary(&payload);

    var reader = Reader.init(try writer.written());

    try reader.skip();
    try testing.expect(reader.is_empty());
}

test "a channel volume reports the loudest channel" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_cvolume(2, 0x8000);

    var reader = Reader.init(try writer.written());

    const volume = try reader.read_cvolume();

    try testing.expectEqual(@as(u8, 2), volume.channels);
    try testing.expectEqual(@as(u32, 0x8000), volume.level);
    try testing.expect(reader.is_empty());
}

test "a proplist is skipped whole, including its terminator" {
    var storage: [128]u8 = undefined;
    var writer = Writer.init(&storage);

    const entries = [_]Property{
        .{ .key = "application.name", .value = "mantra" },
        .{ .key = "media.role", .value = "music" },
    };

    writer.put_proplist(&entries);
    writer.put_u32(7);

    var reader = Reader.init(try writer.written());

    try reader.skip();

    try testing.expectEqual(@as(u32, 7), try reader.read_u32());
    try testing.expect(reader.is_empty());
}

test "an empty proplist is skipped whole" {
    var storage: [32]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_proplist(&.{});
    writer.put_u8(3);

    var reader = Reader.init(try writer.written());

    try reader.skip();

    try testing.expectEqual(@as(u8, 3), try reader.read_u8());
}

test "every skippable tag advances by its own width" {
    var storage: [128]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_u8(1);
    writer.put_u32(2);
    writer.put_boolean(true);
    writer.put_string("x");
    writer.put_cvolume(4, 9);
    writer.put_arbitrary(&.{ 7, 7, 7 });
    writer.put_u32(0xdeadbeef);

    var reader = Reader.init(try writer.written());

    var index: u32 = 0;

    while (index < 6) : (index += 1) {
        try reader.skip();
    }

    try testing.expectEqual(@as(u32, 0xdeadbeef), try reader.read_u32());
    try testing.expect(reader.is_empty());
}

test "a mismatched tag is reported rather than silently consumed" {
    var storage: [16]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_string("text");

    var reader = Reader.init(try writer.written());

    try testing.expectError(Error.Unexpected, reader.read_u32());
}

test "a truncated payload is reported" {
    const bytes = [_]u8{ 'L', 0x00, 0x01 };

    var reader = Reader.init(&bytes);

    try testing.expectError(Error.Truncated, reader.read_u32());
}

test "an unknown tag byte is reported" {
    const bytes = [_]u8{0xAA};

    var reader = Reader.init(&bytes);

    try testing.expectError(Error.Unexpected, reader.skip());
}

test "a writer that runs out of room reports the overflow instead of truncating" {
    var storage: [4]u8 = undefined;
    var writer = Writer.init(&storage);

    writer.put_string("far too long for the buffer");

    try testing.expectError(Error.Overflow, writer.written());

    writer.reset();
    writer.put_u8(1);

    const bytes = try writer.written();

    try testing.expectEqual(@as(usize, 2), bytes.len);
}
