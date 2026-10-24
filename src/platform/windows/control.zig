const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const mmdevice = @import("mmdevice.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const EndpointVolume = mmdevice.IAudioEndpointVolume;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

const attempt_count_max: u32 = 2;

comptime {
    assert(attempt_count_max >= 2);
}

pub fn is_muted(id: *const Device.Id) (PlatformError || RequestError)!bool {
    return endpoint_call(bool, void, id, {}, mute_read);
}

pub fn set_mute(id: *const Device.Id, muted: bool) (PlatformError || RequestError)!void {
    return endpoint_call(void, bool, id, muted, mute_write);
}

pub fn get_volume(id: *const Device.Id) (PlatformError || RequestError)!f32 {
    const raw = try endpoint_call(f32, void, id, {}, level_read);
    const result = contract.clamp_volume(raw);

    assert(result >= contract.volume_fraction_min);
    assert(result <= contract.volume_fraction_max);

    return result;
}

pub fn set_volume(id: *const Device.Id, level: f32) (PlatformError || RequestError)!void {
    const wanted = contract.clamp_volume(level);
    return endpoint_call(void, f32, id, wanted, level_write);
}

fn endpoint_call(
    comptime Result: type,
    comptime Context: type,
    id: *const Device.Id,
    context: Context,
    comptime call: fn (*EndpointVolume, Context) com.Error!Result,
) (PlatformError || RequestError)!Result {
    assert(id.is_valid());

    for (0..attempt_count_max) |attempt| {
        const endpoint = try runtime.endpoint_acquire(id);
        defer runtime.endpoint_release();

        if (call(endpoint, context)) |result| {
            return result;
        } else |err| {
            runtime.endpoint_evict(id);

            if (attempt + 1 == attempt_count_max) {
                return runtime.to_call_error(err);
            }
        }
    }

    unreachable;
}

fn level_read(endpoint: *EndpointVolume, _: void) com.Error!f32 {
    return endpoint.level();
}

fn level_write(endpoint: *EndpointVolume, level: f32) com.Error!void {
    return endpoint.set_level(level);
}

fn mute_read(endpoint: *EndpointVolume, _: void) com.Error!bool {
    return endpoint.is_muted();
}

fn mute_write(endpoint: *EndpointVolume, muted: bool) com.Error!void {
    return endpoint.set_mute(muted);
}
