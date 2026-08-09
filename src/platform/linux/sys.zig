const std = @import("std");

const assert = std.debug.assert;

const linux = std.os.linux;
const posix = std.posix;

pub const Fd = linux.fd_t;

pub const Error = error{
    Failed,
    Interrupted,
};

pub const environ_bytes_max: u32 = 8 * 1024;
pub const environ_entries_max: u32 = 1024;
pub const environ_path = "/proc/self/environ";
pub const interrupt_retry_max: u32 = 64;
pub const transfer_attempts_max: u32 = 4096;

comptime {
    assert(environ_bytes_max > 0);
    assert(environ_entries_max > 0);
    assert(environ_path.len > 0);
    assert(interrupt_retry_max > 0);
    assert(transfer_attempts_max > 0);
}

var environ_storage: [environ_bytes_max]u8 = undefined;
var environ_length: u32 = 0;
var environ_loaded: bool = false;

pub fn ok(raw: usize) bool {
    return posix.errno(raw) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn shutdown(fd: Fd) void {
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
}

pub fn read(fd: Fd, buffer: []u8) Error!usize {
    assert(buffer.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.read(fd, buffer.ptr, buffer.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= buffer.len);

            return raw;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn read_all(fd: Fd, buffer: []u8) Error!void {
    var filled: usize = 0;
    var attempts: u32 = 0;

    while (filled < buffer.len and attempts < transfer_attempts_max) : (attempts += 1) {
        const count = try read(fd, buffer[filled..]);

        if (count == 0) {
            return Error.Failed;
        }

        filled += count;
    }

    if (filled < buffer.len) {
        return Error.Failed;
    }
}

pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    assert(bytes.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.write(fd, bytes.ptr, bytes.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= bytes.len);

            return raw;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn write_all(fd: Fd, bytes: []const u8) Error!void {
    if (bytes.len == 0) {
        return;
    }

    var sent: usize = 0;
    var attempts: u32 = 0;

    while (sent < bytes.len and attempts < transfer_attempts_max) : (attempts += 1) {
        const count = try write(fd, bytes[sent..]);

        if (count == 0) {
            return Error.Failed;
        }

        sent += count;
    }

    if (sent < bytes.len) {
        return Error.Failed;
    }
}

pub fn unix_socket() Error!Fd {
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    return result;
}

pub fn connect(fd: Fd, address: *const linux.sockaddr.un, length: u32) Error!void {
    const raw = linux.connect(fd, @ptrCast(address), length);

    if (!ok(raw)) {
        return Error.Failed;
    }
}

pub fn open_read(path: [*:0]const u8) Error!Fd {
    const raw = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    return result;
}

pub fn getenv(key: []const u8) ?[]const u8 {
    assert(key.len > 0);

    load_environ();

    if (environ_length == 0) {
        return null;
    }

    var start: u32 = 0;
    var visited: u32 = 0;

    while (start < environ_length and visited < environ_entries_max) : (visited += 1) {
        const end = find_terminator(start);
        const entry = environ_storage[start..end];

        if (entry.len > key.len and entry[key.len] == '=') {
            if (std.mem.eql(u8, entry[0..key.len], key)) {
                return entry[key.len + 1 ..];
            }
        }

        start = end + 1;
    }

    return null;
}

fn find_terminator(start: u32) u32 {
    var index = start;

    while (index < environ_length) : (index += 1) {
        assert(index < environ_bytes_max);

        if (environ_storage[index] == 0) return index;
    }

    return environ_length;
}

fn load_environ() void {
    if (environ_loaded) {
        return;
    }

    environ_loaded = true;
    environ_length = 0;

    const fd = open_read(environ_path) catch {
        return;
    };

    defer close(fd);

    var filled: usize = 0;
    var attempts: u32 = 0;

    while (filled < environ_bytes_max and attempts < transfer_attempts_max) : (attempts += 1) {
        const count = read(fd, environ_storage[filled..]) catch {
            break;
        };

        if (count == 0) {
            break;
        }

        filled += count;
    }

    environ_length = @intCast(filled);

    assert(environ_length <= environ_bytes_max);
}

const testing = std.testing;

test "getenv finds a variable the kernel exported" {
    const path = getenv("PATH");
    const missing = getenv("MANTRA_DEFINITELY_NOT_SET_1234");

    try testing.expect(path != null);
    try testing.expect(path.?.len > 0);
    try testing.expect(missing == null);
}

test "getenv rejects a prefix that is not a whole key" {
    const partial = getenv("PAT");

    try testing.expect(partial == null);
}

test "writing nothing is inert" {
    try write_all(-1, &.{});
}
