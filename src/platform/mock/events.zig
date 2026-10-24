const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = contract.Listener;
const PlatformError = contract.PlatformError;

pub fn subscribe(listener: Listener, context: *anyopaque) PlatformError!void {
    assert(state.is_open());
    assert(!state.has_subscriber());

    state.record(.subscribe);

    if (state.should_fail(.subscribe)) {
        return error.CallFailed;
    }

    state.set_subscriber(listener, context);

    assert(state.has_subscriber());
}

pub fn unsubscribe() void {
    state.record(.unsubscribe);
    state.set_subscriber(null, null);

    assert(!state.has_subscriber());
}

pub fn is_subscribed() bool {
    return state.has_subscriber();
}

const testing = std.testing;

test "one subscriber at a time, and unsubscribe clears it" {
    state.reset();
    defer state.clear();

    state.mark_open();

    var seen: u32 = 0;

    try subscribe(observe, &seen);

    try testing.expect(is_subscribed());

    state.emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), seen);

    unsubscribe();

    try testing.expect(!is_subscribed());
}

test "a scripted failure leaves no subscriber behind" {
    state.reset();
    defer state.clear();

    state.mark_open();
    state.fail_next(.subscribe);

    var seen: u32 = 0;

    try testing.expectError(error.CallFailed, subscribe(observe, &seen));
    try testing.expect(!is_subscribed());
}

fn observe(context: *anyopaque, event: Device.Event, _: ?Direction) void {
    assert(event.is_valid());

    const seen: *u32 = @ptrCast(@alignCast(context));

    seen.* += 1;
}
