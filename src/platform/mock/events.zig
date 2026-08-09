const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const EventCallback = contract.EventCallback;

pub const Error = contract.EventError;

pub fn subscribe(callback: EventCallback, context: ?*anyopaque) Error!void {
    state.record(.subscribe);

    if (!state.is_open()) {
        return Error.NotOpen;
    }

    if (state.should_fail(.subscribe)) {
        return Error.Failed;
    }

    if (state.has_subscriber()) {
        return Error.AlreadySubscribed;
    }

    state.set_subscriber(callback, context);

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

test "subscribing is refused while the runtime is closed" {
    state.reset();
    defer state.clear();

    try testing.expectError(Error.NotOpen, subscribe(observe, null));
    try testing.expect(!is_subscribed());
}

test "one subscriber at a time, and unsubscribe clears it" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    try subscribe(observe, null);

    try testing.expect(is_subscribed());
    try testing.expectError(Error.AlreadySubscribed, subscribe(observe, null));

    unsubscribe();

    try testing.expect(!is_subscribed());
}

test "a scripted failure leaves no subscriber behind" {
    state.reset();
    defer state.clear();

    state.set_open(true);
    state.fail_next(.subscribe);

    try testing.expectError(Error.Failed, subscribe(observe, null));
    try testing.expect(!is_subscribed());
}

fn observe(_: contract.DeviceEvent, _: ?contract.Direction, _: ?*anyopaque) void {}
