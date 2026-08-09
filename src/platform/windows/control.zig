const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const mmdevice = @import("mmdevice.zig");
const runtime = @import("runtime.zig");
const text = @import("text.zig");

const assert = std.debug.assert;

const DeviceId = contract.DeviceId;

pub const Error = contract.ControlError;

pub const wide_bytes_max: u32 = contract.id_bytes_max + 1;

comptime {
    assert(wide_bytes_max > contract.id_bytes_max);
}

pub fn is_muted(id: *const DeviceId) Error!bool {
    const endpoint = try acquire(id);
    defer com.release(endpoint);

    const result = endpoint.is_muted() catch |err| {
        return runtime.to_control_error(err);
    };

    return result;
}

pub fn set_mute(id: *const DeviceId, muted: bool) Error!void {
    const endpoint = try acquire(id);
    defer com.release(endpoint);

    endpoint.set_mute(muted) catch |err| {
        return runtime.to_control_error(err);
    };
}

pub fn get_volume(id: *const DeviceId) Error!f32 {
    const endpoint = try acquire(id);
    defer com.release(endpoint);

    const raw = endpoint.level() catch |err| {
        return runtime.to_control_error(err);
    };

    const result = contract.clamp_volume(raw);

    assert(result >= contract.volume_min);
    assert(result <= contract.volume_max);

    return result;
}

pub fn set_volume(id: *const DeviceId, level: f32) Error!void {
    const endpoint = try acquire(id);
    defer com.release(endpoint);

    const wanted = contract.clamp_volume(level);

    endpoint.set_level(wanted) catch |err| {
        return runtime.to_control_error(err);
    };
}

fn acquire(id: *const DeviceId) Error!*mmdevice.IAudioEndpointVolume {
    if (!id.is_valid()) {
        return Error.Invalid;
    }

    if (!runtime.is_open()) {
        return Error.NotOpen;
    }

    var storage: [wide_bytes_max]u16 = undefined;

    const target = text.to_wide(id.slice(), &storage) catch {
        return Error.Invalid;
    };

    const enumerator = mmdevice.create_enumerator() catch |err| {
        return runtime.to_control_error(err);
    };

    defer com.release(enumerator);

    const device = enumerator.device(target) catch |err| {
        return runtime.to_control_error(err);
    };

    defer com.release(device);

    const result = device.endpoint_volume() catch |err| {
        return runtime.to_control_error(err);
    };

    return result;
}
