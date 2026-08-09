const std = @import("std");

const contract = @import("../contract.zig");
const pulse = @import("pulse.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const DeviceId = contract.DeviceId;

pub const Error = contract.ControlError;

pub fn is_muted(id: *const DeviceId) Error!bool {
    const device = try lookup(id);

    return device.muted;
}

pub fn set_mute(id: *const DeviceId, muted: bool) Error!void {
    if (!id.is_valid()) {
        return Error.Invalid;
    }

    const connection = runtime.acquire() orelse {
        return Error.NotOpen;
    };

    defer runtime.release();

    connection.set_mute(
        runtime.mute_command(id.direction),
        id.slice(),
        muted,
    ) catch |err| {
        return runtime.to_control_error(err);
    };
}

pub fn get_volume(id: *const DeviceId) Error!f32 {
    const device = try lookup(id);
    const result = pulse.from_pulse_volume(device.volume);

    assert(result >= contract.volume_min);
    assert(result <= contract.volume_max);

    return result;
}

pub fn set_volume(id: *const DeviceId, level: f32) Error!void {
    const device = try lookup(id);

    assert(device.channels > 0);

    const connection = runtime.acquire() orelse {
        return Error.NotOpen;
    };

    defer runtime.release();

    connection.set_volume(
        runtime.volume_command(id.direction),
        id.slice(),
        device.channels,
        pulse.to_pulse_volume(level),
    ) catch |err| {
        return runtime.to_control_error(err);
    };
}

fn lookup(id: *const DeviceId) Error!pulse.Device {
    if (!id.is_valid()) {
        return Error.Invalid;
    }

    const connection = runtime.acquire() orelse {
        return Error.NotOpen;
    };

    defer runtime.release();

    var raw = pulse.DeviceList{};

    connection.list(runtime.list_command(id.direction), &raw) catch |err| {
        return runtime.to_control_error(err);
    };

    const wanted = id.slice();

    for (raw.slice()) |device| {
        if (std.mem.eql(u8, device.get_name(), wanted)) {
            return device;
        }
    }

    return Error.NotFound;
}

const testing = std.testing;

test "a closed runtime refuses every control call" {
    const id = try DeviceId.init(.capture, "some-source");

    try testing.expectError(Error.NotOpen, is_muted(&id));
    try testing.expectError(Error.NotOpen, get_volume(&id));
    try testing.expectError(Error.NotOpen, set_mute(&id, true));
    try testing.expectError(Error.NotOpen, set_volume(&id, 0.5));
}

test "an invalid identifier is rejected before the runtime is consulted" {
    const id = DeviceId{};

    try testing.expectError(Error.Invalid, is_muted(&id));
    try testing.expectError(Error.Invalid, set_mute(&id, true));
}
