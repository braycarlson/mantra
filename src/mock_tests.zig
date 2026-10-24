const std = @import("std");

const mantra = @import("root.zig");

const Device = mantra.Device;
const Direction = mantra.Direction;
const state = mantra.mock.state;
const testing = std.testing;

test {
    _ = @import("control.zig");
    _ = @import("devices.zig");
    _ = @import("events.zig");
    _ = @import("platform/mock/control.zig");
    _ = @import("platform/mock/devices.zig");
    _ = @import("platform/mock/events.zig");
    _ = @import("platform/mock/runtime.zig");
    _ = @import("platform/mock/state.zig");
    _ = @import("root.zig");
    _ = @import("runtime.zig");
}

const Recorder = struct {
    count: u32 = 0,
    events: [8]Device.Event = @splat(.added),

    fn on_change(recorder: *Recorder, event: Device.Event, _: ?Direction) void {
        if (recorder.count == recorder.events.len) return;

        recorder.events[recorder.count] = event;
        recorder.count += 1;
    }
};

fn open() !void {
    state.reset();

    try mantra.runtime.open();
}

fn first(direction: Direction) !Device.Id {
    var list = Device.List.init();

    try mantra.devices.enumerate(&list, direction);
    try testing.expect(!list.is_empty());

    return list.slice()[0].id;
}

test "enumeration returns only the devices of the requested direction" {
    try open();
    defer mantra.runtime.close();

    var capture = Device.List.init();
    var render = Device.List.init();

    try mantra.devices.enumerate(&capture, .capture);
    try mantra.devices.enumerate(&render, .render);

    try testing.expectEqual(@as(u32, 2), capture.count);
    try testing.expectEqual(@as(u32, 2), render.count);

    for (capture.slice()) |device| {
        try testing.expectEqual(Direction.capture, device.id.direction);
    }

    for (render.slice()) |device| {
        try testing.expectEqual(Direction.render, device.id.direction);
    }

    try testing.expectEqualStrings("Mock Speakers", render.slice()[0].get_name());
}

test "enumeration marks exactly the default device of each direction" {
    try open();
    defer mantra.runtime.close();

    var list = Device.List.init();

    try mantra.devices.enumerate(&list, .render);

    try testing.expect(list.slice()[0].is_default);
    try testing.expect(!list.slice()[1].is_default);

    const id = try mantra.devices.default(.render);

    try testing.expect(id.eql(&list.slice()[0].id));
}

test "setting the default moves it and enumeration agrees" {
    try open();
    defer mantra.runtime.close();

    var list = Device.List.init();

    try mantra.devices.enumerate(&list, .capture);

    const second = list.slice()[1].id;

    try mantra.devices.set_default(&second);

    const id = try mantra.devices.default(.capture);

    try testing.expect(id.eql(&second));

    try mantra.devices.enumerate(&list, .capture);

    try testing.expect(!list.slice()[0].is_default);
    try testing.expect(list.slice()[1].is_default);
}

test "mute state round trips through the control surface" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.capture);

    try testing.expect(!try mantra.control.is_muted(&id));

    try mantra.control.mute(&id);

    try testing.expect(try mantra.control.is_muted(&id));

    try mantra.control.unmute(&id);

    try testing.expect(!try mantra.control.is_muted(&id));
}

test "a subscriber receives injected events and unsubscribes cleanly" {
    try open();
    defer mantra.runtime.close();

    var recorder = Recorder{};

    try mantra.events.subscribe(Recorder, &recorder, Recorder.on_change);

    state.emit(.added, null);
    state.emit(.default_changed, .render);

    try testing.expectEqual(@as(u32, 2), recorder.count);
    try testing.expectEqual(Device.Event.added, recorder.events[0]);
    try testing.expectEqual(Device.Event.default_changed, recorder.events[1]);

    mantra.events.unsubscribe();

    state.emit(.removed, null);

    try testing.expectEqual(@as(u32, 2), recorder.count);
}

test "a subscription can be renewed after it is released" {
    try open();
    defer mantra.runtime.close();

    var recorder = Recorder{};

    try mantra.events.subscribe(Recorder, &recorder, Recorder.on_change);

    mantra.events.unsubscribe();

    try mantra.events.subscribe(Recorder, &recorder, Recorder.on_change);

    state.emit(.state_changed, .capture);

    try testing.expectEqual(@as(u32, 1), recorder.count);
    try testing.expect(mantra.events.is_subscribed());
}

test "removing a device clears the default that pointed at it" {
    try open();
    defer mantra.runtime.close();

    const id = try mantra.devices.default(.capture);

    state.remove(&id);

    try testing.expectError(error.DefaultMissing, mantra.devices.default(.capture));

    var list = Device.List.init();

    try mantra.devices.enumerate(&list, .capture);

    try testing.expectEqual(@as(u32, 1), list.count);
}

test "injected failures surface as errors and clear themselves" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.capture);

    state.fail_next(.set_mute);

    try testing.expectError(error.CallFailed, mantra.control.mute(&id));

    try mantra.control.mute(&id);

    try testing.expect(try mantra.control.is_muted(&id));
}

test "every call reaching the backend is recorded" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.capture);
    const before = state.count_of(.set_mute);

    try mantra.control.mute(&id);
    try mantra.control.unmute(&id);

    try testing.expectEqual(before + 2, state.count_of(.set_mute));
    try testing.expectEqual(@as(u32, 1), state.count_of(.open));
}
