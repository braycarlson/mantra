const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = contract.PlatformError;

pub fn open() PlatformError!void {
    assert(!state.is_open());

    state.record(.open);

    if (state.should_fail(.open)) {
        return error.ServiceUnavailable;
    }

    state.mark_open();

    assert(state.is_open());
}

pub fn close() void {
    state.record(.close);
    state.set_subscriber(null, null);
    state.mark_closed();

    assert(!state.is_open());
    assert(!state.has_subscriber());
}

pub fn is_open() bool {
    return state.is_open();
}

const testing = std.testing;

test "the runtime records both halves of the lifecycle" {
    state.reset();
    defer state.clear();

    try open();

    try testing.expect(is_open());

    close();

    try testing.expect(!is_open());
    try testing.expectEqual(@as(u32, 1), state.count_of(.open));
    try testing.expectEqual(@as(u32, 1), state.count_of(.close));
}

test "a scripted failure leaves the runtime closed" {
    state.reset();
    defer state.clear();

    state.fail_next(.open);

    try testing.expectError(error.ServiceUnavailable, open());
    try testing.expect(!is_open());
}

test "closing drops whatever subscriber was installed" {
    state.reset();
    defer state.clear();

    try open();

    var witness: u32 = 0;

    state.set_subscriber(observe, &witness);

    try testing.expect(state.has_subscriber());

    close();

    try testing.expect(!state.has_subscriber());
}

fn observe(_: *anyopaque, _: Device.Event, _: ?Direction) void {}
