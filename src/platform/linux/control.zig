const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const pulse = @import("pulse.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

pub fn is_muted(id: *const Device.Id) (PlatformError || RequestError)!bool {
    const device = try lookup(id);
    return device.muted;
}

pub fn set_mute(id: *const Device.Id, muted: bool) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    const connection = runtime.acquire();
    defer runtime.release();

    connection.set_mute(
        runtime.mute_command(id.direction),
        id.slice(),
        muted,
    ) catch |err| {
        return runtime.to_call_error(err);
    };
}

pub fn get_volume(id: *const Device.Id) (PlatformError || RequestError)!f32 {
    const device = try lookup(id);
    const result = pulse.from_pulse_volume(device.volume);

    assert(result >= contract.volume_fraction_min);
    assert(result <= contract.volume_fraction_max);

    return result;
}

pub fn set_volume(id: *const Device.Id, level: f32) (PlatformError || RequestError)!void {
    const device = try lookup(id);

    assert(device.channels > 0);

    const connection = runtime.acquire();
    defer runtime.release();

    connection.set_volume(
        runtime.volume_command(id.direction),
        id.slice(),
        device.channels,
        pulse.to_pulse_volume(level),
    ) catch |err| {
        return runtime.to_call_error(err);
    };
}

fn lookup(id: *const Device.Id) (PlatformError || RequestError)!pulse.Device {
    assert(id.is_valid());

    const connection = runtime.acquire();
    defer runtime.release();

    var raw = pulse.DeviceList{};

    connection.list(runtime.list_command(id.direction), &raw) catch |err| switch (err) {
        pulse.Error.Exhausted => {},
        else => return runtime.to_call_error(err),
    };

    const wanted = id.slice();

    for (raw.slice()) |device| {
        if (std.mem.eql(u8, device.get_name(), wanted)) {
            return device;
        }
    }

    return error.DeviceUnknown;
}
