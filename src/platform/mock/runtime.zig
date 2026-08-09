const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

pub const Error = contract.RuntimeError;

pub fn open() Error!void {
    state.record(.open);

    if (state.should_fail(.open)) {
        return Error.Unavailable;
    }

    if (state.is_open()) {
        return Error.AlreadyOpen;
    }

    state.set_open(true);

    assert(state.is_open());
}

pub fn close() void {
    state.record(.close);
    state.set_subscriber(null, null);
    state.set_open(false);

    assert(!state.is_open());
}

pub fn is_open() bool {
    return state.is_open();
}

const testing = std.testing;

test "the runtime opens once and records both halves of the lifecycle" {
    state.reset();
    defer state.clear();

    try open();

    try testing.expect(is_open());
    try testing.expectError(Error.AlreadyOpen, open());

    close();

    try testing.expect(!is_open());
    try testing.expectEqual(@as(u32, 2), state.count_of(.open));
    try testing.expectEqual(@as(u32, 1), state.count_of(.close));
}

test "a scripted failure leaves the runtime closed" {
    state.reset();
    defer state.clear();

    state.fail_next(.open);

    try testing.expectError(Error.Unavailable, open());
    try testing.expect(!is_open());
}

test "closing drops whatever subscriber was installed" {
    state.reset();
    defer state.clear();

    try open();

    state.set_subscriber(observe, null);

    try testing.expect(state.has_subscriber());

    close();

    try testing.expect(!state.has_subscriber());
}

fn observe(_: contract.DeviceEvent, _: ?contract.Direction, _: ?*anyopaque) void {}
