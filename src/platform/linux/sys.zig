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

    while (attempts < transfer_attempts_max) : (attempts += 1) {
        if (filled >= buffer.len) {
            break;
        }

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

    while (attempts < transfer_attempts_max) : (attempts += 1) {
        if (sent >= bytes.len) {
            break;
        }

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

pub const Environ = struct {
    length: u32 = 0,
    storage: [environ_bytes_max]u8 = undefined,

    pub fn load(environ: *Environ) void {
        environ.length = 0;

        const fd = open_read(environ_path) catch {
            return;
        };

        defer close(fd);

        var filled: usize = 0;
        var attempts: u32 = 0;

        while (attempts < transfer_attempts_max) : (attempts += 1) {
            if (filled >= environ_bytes_max) {
                break;
            }

            const count = read(fd, environ.storage[filled..]) catch {
                break;
            };

            if (count == 0) {
                break;
            }

            filled += count;
        }

        environ.length = @intCast(filled);

        assert(environ.length <= environ_bytes_max);
    }

    pub fn get(environ: *const Environ, key: []const u8) ?[]const u8 {
        assert(key.len > 0);
        assert(environ.length <= environ_bytes_max);

        var start: u32 = 0;
        var visited: u32 = 0;

        while (visited < environ_entries_max) : (visited += 1) {
            if (start >= environ.length) {
                break;
            }

            const end = environ.find_terminator(start);
            const entry = environ.storage[start..end];

            if (entry.len > key.len) {
                if (entry[key.len] == '=') {
                    if (std.mem.eql(u8, entry[0..key.len], key)) {
                        return entry[key.len + 1 ..];
                    }
                }
            }

            start = end + 1;
        }

        return null;
    }

    fn find_terminator(environ: *const Environ, start: u32) u32 {
        var index = start;

        while (index < environ.length) : (index += 1) {
            assert(index < environ_bytes_max);

            if (environ.storage[index] == 0) return index;
        }

        return environ.length;
    }
};

const testing = std.testing;

test "getenv finds a variable the kernel exported" {
    var environ: Environ = .{};

    environ.load();

    const path = environ.get("PATH");
    const missing = environ.get("MANTRA_DEFINITELY_NOT_SET_1234");

    try testing.expect(path != null);
    try testing.expect(path.?.len > 0);
    try testing.expect(missing == null);
}

test "getenv rejects a prefix that is not a whole key" {
    var environ: Environ = .{};

    environ.load();

    const partial = environ.get("PAT");

    try testing.expect(partial == null);
}

test "writing nothing is inert" {
    try write_all(-1, &.{});
}
