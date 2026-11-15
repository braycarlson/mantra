const std = @import("std");

const device_module = @import("../../device.zig");

const assert = std.debug.assert;

pub const Error = error{
    Empty,
    Invalid,
    TooLong,
};

pub const id_wide_units_max: u32 = device_module.id_bytes_max + 1;

comptime {
    assert(id_wide_units_max > device_module.id_bytes_max);
}

pub fn from_wide(wide: [*:0]const u16, buffer: []u8) Error![]const u8 {
    assert(buffer.len > 0);

    const source = std.mem.span(wide);

    if (source.len == 0) {
        return Error.Empty;
    }

    const needed = std.unicode.calcWtf8Len(source);

    if (needed > buffer.len) {
        return Error.TooLong;
    }

    const length = std.unicode.utf16LeToUtf8(buffer, source) catch {
        return Error.Invalid;
    };

    assert(length <= buffer.len);

    if (length == 0) {
        return Error.Empty;
    }

    return buffer[0..length];
}

pub fn to_wide(text: []const u8, buffer: []u16) Error![:0]const u16 {
    assert(buffer.len > 0);

    if (text.len == 0) {
        return Error.Empty;
    }

    const needed = std.unicode.calcUtf16LeLen(text) catch {
        return Error.Invalid;
    };

    if (needed + 1 > buffer.len) {
        return Error.TooLong;
    }

    const length = std.unicode.utf8ToUtf16Le(buffer, text) catch {
        return Error.Invalid;
    };

    assert(length == needed);
    assert(length < buffer.len);

    buffer[length] = 0;

    return buffer[0..length :0];
}
