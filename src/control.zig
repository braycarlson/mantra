const std = @import("std");

const device_module = @import("device.zig");
const platform = @import("platform.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const backend = platform.backend.control;

const Device = device_module.Device;
const PlatformError = platform.PlatformError;
const RequestError = device_module.RequestError;

pub fn get_volume(id: *const Device.Id) (PlatformError || RequestError)!f32 {
    assert(id.is_valid());
    assert(runtime.is_open());

    const result = try backend.get_volume(id);

    assert(result >= platform.volume_fraction_min);
    assert(result <= platform.volume_fraction_max);

    return result;
}

pub fn is_muted(id: *const Device.Id) (PlatformError || RequestError)!bool {
    assert(id.is_valid());
    assert(runtime.is_open());

    return try backend.is_muted(id);
}

pub fn mute(id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(runtime.is_open());

    try backend.set_mute(id, true);
}

pub fn set_volume(id: *const Device.Id, level: f32) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(runtime.is_open());

    try backend.set_volume(id, level);
}

pub fn unmute(id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(runtime.is_open());

    try backend.set_mute(id, false);
}

const testing = std.testing;

const mock = platform.mock;

fn microphone() !Device.Id {
    mock.state.reset();

    const result = try Device.Id.init(.capture, "mock-capture-0");

    try runtime.open();

    return result;
}

test get_volume {
    const id = try microphone();
    defer runtime.close();

    try testing.expectEqual(@as(f32, 0.5), try get_volume(&id));
}

test is_muted {
    const id = try microphone();
    defer runtime.close();

    try testing.expect(!try is_muted(&id));
}

test mute {
    const id = try microphone();
    defer runtime.close();

    try mute(&id);

    try testing.expect(try is_muted(&id));
}

test set_volume {
    const id = try microphone();
    defer runtime.close();

    try set_volume(&id, 0.25);

    try testing.expectEqual(@as(f32, 0.25), try get_volume(&id));

    try set_volume(&id, 4.0);

    try testing.expectEqual(platform.volume_fraction_max, try get_volume(&id));

    try set_volume(&id, -1.0);

    try testing.expectEqual(platform.volume_fraction_min, try get_volume(&id));
}

test unmute {
    const id = try microphone();
    defer runtime.close();

    try mute(&id);
    try unmute(&id);

    try testing.expect(!try is_muted(&id));
}

test "the two directions carry independent mute state" {
    const capture = try microphone();
    defer runtime.close();

    const render = try Device.Id.init(.render, "mock-render-0");

    try mute(&capture);

    try testing.expect(try is_muted(&capture));
    try testing.expect(!try is_muted(&render));
}

test "a device that is not present is unknown to every control call" {
    mock.state.reset();

    const absent = try Device.Id.init(.capture, "absent");

    try runtime.open();
    defer runtime.close();

    try testing.expectError(error.DeviceUnknown, is_muted(&absent));
    try testing.expectError(error.DeviceUnknown, mute(&absent));
    try testing.expectError(error.DeviceUnknown, get_volume(&absent));
    try testing.expectError(error.DeviceUnknown, set_volume(&absent, 0.5));
}
