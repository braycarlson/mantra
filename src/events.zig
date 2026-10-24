const std = @import("std");

const device_module = @import("device.zig");
const platform = @import("platform.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const backend = platform.backend.events;

const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = platform.PlatformError;

pub fn subscribe(
    comptime Owner: type,
    owner: *Owner,
    comptime callback: fn (*Owner, Device.Event, ?Direction) void,
) PlatformError!void {
    assert(runtime.is_open());
    assert(!backend.is_subscribed());

    const Listener = ListenerType(Owner, callback);

    try backend.subscribe(Listener.invoke, owner);

    assert(backend.is_subscribed());
}

pub fn unsubscribe() void {
    backend.unsubscribe();

    assert(!backend.is_subscribed());
}

pub fn is_subscribed() bool {
    return backend.is_subscribed();
}

fn ListenerType(
    comptime Owner: type,
    comptime callback: fn (*Owner, Device.Event, ?Direction) void,
) type {
    return struct {
        fn invoke(context: *anyopaque, event: Device.Event, direction: ?Direction) void {
            assert(event.is_valid());

            const owner: *Owner = @ptrCast(@alignCast(context));

            callback(owner, event, direction);
        }
    };
}

const testing = std.testing;

const mock = platform.mock;

const Recorder = struct {
    count: u32 = 0,
    directions: [8]?Direction = @splat(null),
    events: [8]Device.Event = @splat(.added),

    fn on_change(recorder: *Recorder, event: Device.Event, direction: ?Direction) void {
        if (recorder.count == recorder.events.len) return;

        recorder.events[recorder.count] = event;
        recorder.directions[recorder.count] = direction;
        recorder.count += 1;
    }
};

test subscribe {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    var recorder = Recorder{};

    try subscribe(Recorder, &recorder, Recorder.on_change);

    mock.state.emit(.added, null);
    mock.state.emit(.default_changed, .render);

    try testing.expectEqual(@as(u32, 2), recorder.count);
    try testing.expectEqual(Device.Event.added, recorder.events[0]);
    try testing.expect(recorder.directions[0] == null);
    try testing.expectEqual(Device.Event.default_changed, recorder.events[1]);
    try testing.expectEqual(Direction.render, recorder.directions[1].?);
}

test unsubscribe {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    var recorder = Recorder{};

    try subscribe(Recorder, &recorder, Recorder.on_change);

    unsubscribe();

    mock.state.emit(.removed, null);

    try testing.expectEqual(@as(u32, 0), recorder.count);
    try testing.expect(!is_subscribed());
}

test is_subscribed {
    mock.state.reset();

    try runtime.open();

    var recorder = Recorder{};

    try testing.expect(!is_subscribed());

    try subscribe(Recorder, &recorder, Recorder.on_change);

    try testing.expect(is_subscribed());

    runtime.close();

    try testing.expect(!is_subscribed());
}

test "a refused subscription leaves no subscriber behind" {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    var recorder = Recorder{};

    mock.state.fail_next(.subscribe);

    try testing.expectError(
        error.CallFailed,
        subscribe(Recorder, &recorder, Recorder.on_change),
    );

    try testing.expect(!is_subscribed());
}
