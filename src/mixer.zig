const std = @import("std");

const device_module = @import("device.zig");
const platform = @import("platform.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = platform.PlatformError;
const RequestError = device_module.RequestError;

pub fn MixerType(comptime Platform: type) type {
    return struct {
        platform: Platform,

        const Mixer = @This();
        pub const Options = Platform.Options;

        pub fn init(mixer: *Mixer, options: Options) PlatformError!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);

            try mixer.platform.init(options);

            assert(!mixer.platform.events_is_subscribed());
        }

        pub fn deinit(mixer: *Mixer) void {
            mixer.platform.deinit();
        }

        pub fn enumerate(
            mixer: *Mixer,
            list: *Device.List,
            direction: Direction,
        ) (CapacityError || PlatformError)!void {
            assert(direction.is_valid());

            try mixer.platform.devices_enumerate(list, direction);

            assert(list.count <= device_module.count_max);

            for (list.slice()) |device| {
                assert(device.id.direction == direction);
            }
        }

        pub fn default(
            mixer: *Mixer,
            direction: Direction,
        ) (CapacityError || PlatformError || RequestError)!Device.Id {
            assert(direction.is_valid());

            const result = try mixer.platform.devices_default(direction);

            assert(result.is_valid());
            assert(result.direction == direction);

            return result;
        }

        pub fn set_default(
            mixer: *Mixer,
            id: *const Device.Id,
        ) (PlatformError || RequestError)!void {
            assert(id.is_valid());

            try mixer.platform.devices_set_default(id);
        }

        pub fn get_volume(mixer: *Mixer, id: *const Device.Id) (PlatformError || RequestError)!f32 {
            assert(id.is_valid());

            const result = try mixer.platform.control_get_volume(id);

            assert(result >= platform.volume_fraction_min);
            assert(result <= platform.volume_fraction_max);

            return result;
        }

        pub fn is_muted(mixer: *Mixer, id: *const Device.Id) (PlatformError || RequestError)!bool {
            assert(id.is_valid());

            return try mixer.platform.control_is_muted(id);
        }

        pub fn mute(mixer: *Mixer, id: *const Device.Id) (PlatformError || RequestError)!void {
            assert(id.is_valid());

            try mixer.platform.control_set_mute(id, true);
        }

        pub fn set_volume(
            mixer: *Mixer,
            id: *const Device.Id,
            level: f32,
        ) (PlatformError || RequestError)!void {
            assert(id.is_valid());

            try mixer.platform.control_set_volume(id, level);
        }

        pub fn unmute(mixer: *Mixer, id: *const Device.Id) (PlatformError || RequestError)!void {
            assert(id.is_valid());

            try mixer.platform.control_set_mute(id, false);
        }

        pub fn subscribe(
            mixer: *Mixer,
            comptime Owner: type,
            owner: *Owner,
            comptime callback: fn (*Owner, Device.Event, ?Direction) void,
        ) PlatformError!void {
            assert(!mixer.platform.events_is_subscribed());

            const Listener = ListenerType(Owner, callback);

            try mixer.platform.events_subscribe(Listener.invoke, owner);

            assert(mixer.platform.events_is_subscribed());
        }

        pub fn unsubscribe(mixer: *Mixer) void {
            mixer.platform.events_unsubscribe();

            assert(!mixer.platform.events_is_subscribed());
        }

        pub fn is_subscribed(mixer: *Mixer) bool {
            return mixer.platform.events_is_subscribed();
        }
    };
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
const FakeMixer = MixerType(platform.Fake);

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

fn microphone(mixer: *FakeMixer) !Device.Id {
    const result = try Device.Id.init(.capture, "fake-capture-0");

    try mixer.init(.{});

    return result;
}

test MixerType {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    try testing.expect(mixer.platform.opened);
    try testing.expectEqual(@as(u32, 1), mixer.platform.count_of(.init));
}

test "deinit" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});

    mixer.deinit();

    try testing.expect(!mixer.platform.opened);
    try testing.expectEqual(@as(u32, 1), mixer.platform.count_of(.deinit));
}

test "a refused init leaves the platform closed" {
    var mixer: FakeMixer = undefined;

    try testing.expectError(error.ServiceUnavailable, mixer.init(.{ .fault = .init }));
    try testing.expect(!mixer.platform.opened);
}

test "enumerate" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var list = Device.List.init();

    try mixer.enumerate(&list, .capture);

    try testing.expectEqual(@as(u32, 2), list.count);
    try testing.expectEqualStrings("Fake Microphone", list.slice()[0].get_name());
    try testing.expect(list.slice()[0].is_default);
}

test "default" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const id = try mixer.default(.render);

    try testing.expectEqualStrings("fake-render-0", id.slice());
    try testing.expectEqual(Direction.render, id.direction);
}

test "set_default" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const headphones = try Device.Id.init(.render, "fake-render-1");

    try mixer.set_default(&headphones);

    const id = try mixer.default(.render);

    try testing.expect(id.eql(&headphones));
}

test "a device that is not present is unknown to every call" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const absent = try Device.Id.init(.capture, "absent");

    try testing.expectError(error.DeviceUnknown, mixer.set_default(&absent));
}

test "a direction with no default device reports the default missing" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const id = try mixer.default(.capture);

    mixer.platform.remove(&id);

    try testing.expectError(error.DefaultMissing, mixer.default(.capture));
}

test "get_volume" {
    var mixer: FakeMixer = undefined;

    const id = try microphone(&mixer);
    defer mixer.deinit();

    try testing.expectEqual(@as(f32, 0.5), try mixer.get_volume(&id));
}

test "is_muted" {
    var mixer: FakeMixer = undefined;

    const id = try microphone(&mixer);
    defer mixer.deinit();

    try testing.expect(!try mixer.is_muted(&id));
}

test "mute" {
    var mixer: FakeMixer = undefined;

    const id = try microphone(&mixer);
    defer mixer.deinit();

    try mixer.mute(&id);

    try testing.expect(try mixer.is_muted(&id));
}

test "set_volume" {
    var mixer: FakeMixer = undefined;

    const id = try microphone(&mixer);
    defer mixer.deinit();

    try mixer.set_volume(&id, 0.25);

    try testing.expectEqual(@as(f32, 0.25), try mixer.get_volume(&id));

    try mixer.set_volume(&id, 4.0);

    try testing.expectEqual(platform.volume_fraction_max, try mixer.get_volume(&id));

    try mixer.set_volume(&id, -1.0);

    try testing.expectEqual(platform.volume_fraction_min, try mixer.get_volume(&id));
}

test "unmute" {
    var mixer: FakeMixer = undefined;

    const id = try microphone(&mixer);
    defer mixer.deinit();

    try mixer.mute(&id);
    try mixer.unmute(&id);

    try testing.expect(!try mixer.is_muted(&id));
}

test "the two directions carry independent mute state" {
    var mixer: FakeMixer = undefined;

    const capture = try microphone(&mixer);
    defer mixer.deinit();

    const render = try Device.Id.init(.render, "fake-render-0");

    try mixer.mute(&capture);

    try testing.expect(try mixer.is_muted(&capture));
    try testing.expect(!try mixer.is_muted(&render));
}

test "a device that is not present is unknown to every control call" {
    var mixer: FakeMixer = undefined;

    const absent = try Device.Id.init(.capture, "absent");

    try mixer.init(.{});
    defer mixer.deinit();

    try testing.expectError(error.DeviceUnknown, mixer.is_muted(&absent));
    try testing.expectError(error.DeviceUnknown, mixer.mute(&absent));
    try testing.expectError(error.DeviceUnknown, mixer.get_volume(&absent));
    try testing.expectError(error.DeviceUnknown, mixer.set_volume(&absent, 0.5));
}

test "subscribe" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var recorder = Recorder{};

    try mixer.subscribe(Recorder, &recorder, Recorder.on_change);

    mixer.platform.emit(.added, null);
    mixer.platform.emit(.default_changed, .render);

    try testing.expectEqual(@as(u32, 2), recorder.count);
    try testing.expectEqual(Device.Event.added, recorder.events[0]);
    try testing.expect(recorder.directions[0] == null);
    try testing.expectEqual(Device.Event.default_changed, recorder.events[1]);
    try testing.expectEqual(Direction.render, recorder.directions[1].?);
}

test "unsubscribe" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var recorder = Recorder{};

    try mixer.subscribe(Recorder, &recorder, Recorder.on_change);

    mixer.unsubscribe();

    mixer.platform.emit(.removed, null);

    try testing.expectEqual(@as(u32, 0), recorder.count);
    try testing.expect(!mixer.is_subscribed());
}

test "is_subscribed" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});

    var recorder = Recorder{};

    try testing.expect(!mixer.is_subscribed());

    try mixer.subscribe(Recorder, &recorder, Recorder.on_change);

    try testing.expect(mixer.is_subscribed());

    mixer.deinit();

    try testing.expect(!mixer.is_subscribed());
}

test "a refused subscription leaves no subscriber behind" {
    var mixer: FakeMixer = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    var recorder = Recorder{};

    mixer.platform.fault.arm(.events_subscribe);

    try testing.expectError(
        error.CallFailed,
        mixer.subscribe(Recorder, &recorder, Recorder.on_change),
    );

    try testing.expect(!mixer.is_subscribed());
}
