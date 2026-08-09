const std = @import("std");

const mantra = @import("root.zig");
const state = @import("platform/mock/state.zig");

const DeviceEvent = mantra.DeviceEvent;
const DeviceId = mantra.DeviceId;
const DeviceList = mantra.DeviceList;
const Direction = mantra.Direction;
const testing = std.testing;

test {
    _ = @import("platform/mock/control.zig");
    _ = @import("platform/mock/devices.zig");
    _ = @import("platform/mock/events.zig");
    _ = @import("platform/mock/runtime.zig");
    _ = @import("platform/mock/state.zig");
}

const Recorder = struct {
    var directions: [8]?Direction = [_]?Direction{null} ** 8;
    var events: [8]DeviceEvent = [_]DeviceEvent{.added} ** 8;
    var count: u32 = 0;

    fn reset() void {
        count = 0;
    }

    fn handle(event: DeviceEvent, direction: ?Direction, context: ?*anyopaque) void {
        _ = context;

        if (count >= events.len) {
            return;
        }

        events[count] = event;
        directions[count] = direction;
        count += 1;
    }
};

fn open() !void {
    state.reset();
    Recorder.reset();

    try mantra.runtime.open();
}

fn first(direction: Direction) !DeviceId {
    var list = DeviceList.init();

    try mantra.devices.enumerate(direction, &list);
    try testing.expect(!list.is_empty());

    return list.items[0].id;
}

test "a closed runtime refuses every operation" {
    state.reset();

    try testing.expect(!mantra.runtime.is_open());

    var list = DeviceList.init();

    try testing.expectError(
        mantra.DeviceError.NotOpen,
        mantra.devices.enumerate(.capture, &list),
    );

    try testing.expectError(mantra.DeviceError.NotOpen, mantra.devices.default(.capture));
}

test "opening twice is reported rather than silently accepted" {
    try open();
    defer mantra.runtime.close();

    try testing.expect(mantra.runtime.is_open());
    try testing.expectError(mantra.RuntimeError.AlreadyOpen, mantra.runtime.open());
}

test "enumeration returns only the devices of the requested direction" {
    try open();
    defer mantra.runtime.close();

    var capture = DeviceList.init();
    var render = DeviceList.init();

    try mantra.devices.enumerate(.capture, &capture);
    try mantra.devices.enumerate(.render, &render);

    try testing.expectEqual(@as(u32, 2), capture.count);
    try testing.expectEqual(@as(u32, 2), render.count);

    for (capture.slice()) |info| {
        try testing.expectEqual(Direction.capture, info.id.direction);
    }

    for (render.slice()) |info| {
        try testing.expectEqual(Direction.render, info.id.direction);
    }

    try testing.expectEqualStrings("Mock Microphone", capture.items[0].get_name());
    try testing.expectEqualStrings("Mock Speakers", render.items[0].get_name());
}

test "enumeration marks exactly the default device of each direction" {
    try open();
    defer mantra.runtime.close();

    var list = DeviceList.init();

    try mantra.devices.enumerate(.render, &list);

    try testing.expect(list.items[0].is_default);
    try testing.expect(!list.items[1].is_default);

    const id = try mantra.devices.default(.render);

    try testing.expect(id.eql(&list.items[0].id));
}

test "setting the default moves it and enumeration agrees" {
    try open();
    defer mantra.runtime.close();

    var list = DeviceList.init();

    try mantra.devices.enumerate(.capture, &list);

    const second = list.items[1].id;

    try mantra.devices.set_default(&second);

    const id = try mantra.devices.default(.capture);

    try testing.expect(id.eql(&second));

    list.clear();

    try mantra.devices.enumerate(.capture, &list);

    try testing.expect(!list.items[0].is_default);
    try testing.expect(list.items[1].is_default);
}

test "a device that is not present is reported as missing" {
    try open();
    defer mantra.runtime.close();

    const absent = try DeviceId.init(.capture, "absent");

    try testing.expectError(mantra.DeviceError.NotFound, mantra.devices.set_default(&absent));
    try testing.expectError(mantra.ControlError.NotFound, mantra.control.is_muted(&absent));
}

test "mute state round trips through the control surface" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.capture);

    try testing.expect(!try mantra.control.is_muted(&id));

    try mantra.control.set_mute(&id, true);

    try testing.expect(try mantra.control.is_muted(&id));

    try mantra.control.set_mute(&id, false);

    try testing.expect(!try mantra.control.is_muted(&id));
}

test "volume round trips and is clamped at the seam" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.render);

    try mantra.control.set_volume(&id, 0.25);

    try testing.expectEqual(@as(f32, 0.25), try mantra.control.get_volume(&id));

    try mantra.control.set_volume(&id, 4.0);

    try testing.expectEqual(mantra.volume_max, try mantra.control.get_volume(&id));

    try mantra.control.set_volume(&id, -1.0);

    try testing.expectEqual(mantra.volume_min, try mantra.control.get_volume(&id));
}

test "the two directions carry independent mute state" {
    try open();
    defer mantra.runtime.close();

    const capture = try first(.capture);
    const render = try first(.render);

    try mantra.control.set_mute(&capture, true);

    try testing.expect(try mantra.control.is_muted(&capture));
    try testing.expect(!try mantra.control.is_muted(&render));
}

test "a subscriber receives injected events and unsubscribes cleanly" {
    try open();
    defer mantra.runtime.close();

    try testing.expect(!mantra.events.is_subscribed());

    try mantra.events.subscribe(Recorder.handle, null);

    try testing.expect(mantra.events.is_subscribed());

    try testing.expectError(
        mantra.EventError.AlreadySubscribed,
        mantra.events.subscribe(Recorder.handle, null),
    );

    state.emit(.added, null);
    state.emit(.default_changed, .render);

    try testing.expectEqual(@as(u32, 2), Recorder.count);
    try testing.expectEqual(DeviceEvent.added, Recorder.events[0]);
    try testing.expect(Recorder.directions[0] == null);
    try testing.expectEqual(DeviceEvent.default_changed, Recorder.events[1]);
    try testing.expectEqual(Direction.render, Recorder.directions[1].?);

    mantra.events.unsubscribe();

    try testing.expect(!mantra.events.is_subscribed());

    state.emit(.removed, null);

    try testing.expectEqual(@as(u32, 2), Recorder.count);
}

test "closing the runtime drops the subscriber" {
    try open();

    try mantra.events.subscribe(Recorder.handle, null);

    mantra.runtime.close();

    try testing.expect(!mantra.events.is_subscribed());
}

test "removing a device clears the default that pointed at it" {
    try open();
    defer mantra.runtime.close();

    const id = try mantra.devices.default(.capture);

    state.remove(&id);

    try testing.expectError(mantra.DeviceError.NotFound, mantra.devices.default(.capture));

    var list = DeviceList.init();

    try mantra.devices.enumerate(.capture, &list);

    try testing.expectEqual(@as(u32, 1), list.count);
}

test "injected failures surface as errors and clear themselves" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.capture);

    state.fail_next(.set_mute);

    try testing.expectError(mantra.ControlError.Failed, mantra.control.set_mute(&id, true));

    try mantra.control.set_mute(&id, true);

    try testing.expect(try mantra.control.is_muted(&id));
}

test "every call reaching the backend is recorded" {
    try open();
    defer mantra.runtime.close();

    const id = try first(.capture);

    const before = state.count_of(.set_mute);

    try mantra.control.set_mute(&id, true);
    try mantra.control.set_mute(&id, false);

    try testing.expectEqual(before + 2, state.count_of(.set_mute));
    try testing.expectEqual(@as(u32, 1), state.count_of(.open));
}
