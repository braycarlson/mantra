const std = @import("std");

const mantra = @import("root.zig");

const Device = mantra.Device;
const Direction = mantra.Direction;
const Mixer = mantra.MixerType(mantra.Fake);
const testing = std.testing;

test {
    _ = @import("mixer.zig");
    _ = @import("platform/fake.zig");
    _ = @import("root.zig");
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

fn first(mixer: *Mixer, direction: Direction) !Device.Id {
    var list = Device.List.init();

    try mixer.enumerate(&list, direction);
    try testing.expect(!list.is_empty());

    return list.slice()[0].id;
}

test "enumeration returns only the devices of the requested direction" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var capture = Device.List.init();
    var render = Device.List.init();

    try mixer.enumerate(&capture, .capture);
    try mixer.enumerate(&render, .render);

    try testing.expectEqual(@as(u32, 2), capture.count);
    try testing.expectEqual(@as(u32, 2), render.count);

    for (capture.slice()) |device| {
        try testing.expectEqual(Direction.capture, device.id.direction);
    }

    for (render.slice()) |device| {
        try testing.expectEqual(Direction.render, device.id.direction);
    }

    try testing.expectEqualStrings("Fake Speakers", render.slice()[0].get_name());
}

test "enumeration marks exactly the default device of each direction" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var list = Device.List.init();

    try mixer.enumerate(&list, .render);

    try testing.expect(list.slice()[0].is_default);
    try testing.expect(!list.slice()[1].is_default);

    const id = try mixer.default(.render);

    try testing.expect(id.eql(&list.slice()[0].id));
}

test "setting the default moves it and enumeration agrees" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var list = Device.List.init();

    try mixer.enumerate(&list, .capture);

    const second = list.slice()[1].id;

    try mixer.set_default(&second);

    const id = try mixer.default(.capture);

    try testing.expect(id.eql(&second));

    try mixer.enumerate(&list, .capture);

    try testing.expect(!list.slice()[0].is_default);
    try testing.expect(list.slice()[1].is_default);
}

test "mute state round trips through the control surface" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const id = try first(&mixer, .capture);

    try testing.expect(!try mixer.is_muted(&id));

    try mixer.mute(&id);

    try testing.expect(try mixer.is_muted(&id));

    try mixer.unmute(&id);

    try testing.expect(!try mixer.is_muted(&id));
}

test "a subscriber receives injected events and unsubscribes cleanly" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var recorder = Recorder{};

    try mixer.subscribe(Recorder, &recorder, Recorder.on_change);

    mixer.platform.emit(.added, null);
    mixer.platform.emit(.default_changed, .render);

    try testing.expectEqual(@as(u32, 2), recorder.count);
    try testing.expectEqual(Device.Event.added, recorder.events[0]);
    try testing.expectEqual(Device.Event.default_changed, recorder.events[1]);

    mixer.unsubscribe();

    mixer.platform.emit(.removed, null);

    try testing.expectEqual(@as(u32, 2), recorder.count);
}

test "a subscription can be renewed after it is released" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var recorder = Recorder{};

    try mixer.subscribe(Recorder, &recorder, Recorder.on_change);

    mixer.unsubscribe();

    try mixer.subscribe(Recorder, &recorder, Recorder.on_change);

    mixer.platform.emit(.state_changed, .capture);

    try testing.expectEqual(@as(u32, 1), recorder.count);
    try testing.expect(mixer.is_subscribed());
}

test "removing a device clears the default that pointed at it" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const id = try mixer.default(.capture);

    mixer.platform.remove(&id);

    try testing.expectError(error.DefaultMissing, mixer.default(.capture));

    var list = Device.List.init();

    try mixer.enumerate(&list, .capture);

    try testing.expectEqual(@as(u32, 1), list.count);
}

test "injected failures surface as errors and clear themselves" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const id = try first(&mixer, .capture);

    mixer.platform.fault.arm(.control_set_mute);

    try testing.expectError(error.CallFailed, mixer.mute(&id));

    try mixer.mute(&id);

    try testing.expect(try mixer.is_muted(&id));
}

test "every call reaching the backend is recorded" {
    var mixer: Mixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const id = try first(&mixer, .capture);
    const before = mixer.platform.count_of(.control_set_mute);

    try mixer.mute(&id);
    try mixer.unmute(&id);

    try testing.expectEqual(before + 2, mixer.platform.count_of(.control_set_mute));
    try testing.expectEqual(@as(u32, 1), mixer.platform.count_of(.init));
}
