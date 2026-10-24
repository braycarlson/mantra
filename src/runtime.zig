const std = @import("std");

const platform = @import("platform.zig");

const assert = std.debug.assert;

const backend = platform.backend.runtime;

const PlatformError = platform.PlatformError;

pub fn open() PlatformError!void {
    assert(!backend.is_open());

    try backend.open();

    assert(backend.is_open());
}

pub fn close() void {
    backend.close();

    assert(!backend.is_open());
}

pub fn is_open() bool {
    return backend.is_open();
}

const testing = std.testing;

const mock = platform.mock;

test open {
    mock.state.reset();

    try open();
    defer close();

    try testing.expect(is_open());
    try testing.expectEqual(@as(u32, 1), mock.state.count_of(.open));
}

test close {
    mock.state.reset();

    try open();

    close();

    try testing.expect(!is_open());

    close();

    try testing.expectEqual(@as(u32, 2), mock.state.count_of(.close));
}

test "a refused open leaves the runtime closed" {
    mock.state.reset();
    mock.state.fail_next(.open);

    try testing.expectError(error.ServiceUnavailable, open());
    try testing.expect(!is_open());
}
