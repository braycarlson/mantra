const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const events = @import("events.zig");
const mmdevice = @import("mmdevice.zig");
const sync = @import("sync.zig");
const text = @import("text.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

pub const endpoint_count_max: u32 = device_module.device_count_max;

comptime {
    assert(endpoint_count_max > 0);
}

const Endpoint = struct {
    id: Device.Id,
    volume: *mmdevice.IAudioEndpointVolume,
};

var apartment: com.Apartment = .borrowed;
var endpoint_victim: u32 = 0;
var endpoints: [endpoint_count_max]?Endpoint = @splat(null);
var enumerator: ?*mmdevice.IMMDeviceEnumerator = null;
var lock: sync.Mutex = .{};
var opened: bool = false;
var owner: u32 = 0;
var policy: ?*mmdevice.IPolicyConfig = null;

pub fn open() PlatformError!void {
    lock.lock();
    defer lock.unlock();

    assert(!opened);
    assert(enumerator == null);
    assert(policy == null);

    apartment = com.initialize() catch |err| {
        return to_platform_error(err);
    };

    errdefer com.uninitialize(apartment);

    enumerator = mmdevice.create_enumerator() catch |err| {
        return to_platform_error(err);
    };

    policy = mmdevice.create_policy() catch null;
    opened = true;
    owner = com.thread_id();

    assert(opened);
    assert(owner != 0);
}

pub fn close() void {
    events.unsubscribe();

    lock.lock();
    defer lock.unlock();

    if (!opened) {
        return;
    }

    assert(owner == com.thread_id());

    endpoints_release();

    if (policy) |config| {
        config.release();
    }

    if (enumerator) |source| {
        source.release();
    }

    enumerator = null;
    opened = false;
    policy = null;

    com.uninitialize(apartment);

    apartment = .borrowed;
    owner = 0;

    assert(!opened);
}

pub fn is_open() bool {
    lock.lock();
    defer lock.unlock();

    return opened;
}

pub fn enumerator_acquire() *mmdevice.IMMDeviceEnumerator {
    lock.lock();

    assert(opened);

    return enumerator orelse unreachable;
}

pub fn enumerator_release() void {
    lock.unlock();
}

pub fn policy_get() ?*mmdevice.IPolicyConfig {
    assert(opened);

    return policy;
}

pub fn endpoint_acquire(
    id: *const Device.Id,
) (PlatformError || RequestError)!*mmdevice.IAudioEndpointVolume {
    assert(id.is_valid());

    lock.lock();
    errdefer lock.unlock();

    assert(opened);

    if (endpoint_find(id)) |index| {
        if (endpoints[index]) |cached| {
            return cached.volume;
        }
    }

    const volume = try endpoint_open(id);
    const index = endpoint_slot();

    endpoints[index] = .{ .id = id.*, .volume = volume };

    return volume;
}

pub fn endpoint_release() void {
    lock.unlock();
}

pub fn endpoint_evict(id: *const Device.Id) void {
    assert(opened);
    assert(id.is_valid());

    const index = endpoint_find(id) orelse return;

    if (endpoints[index]) |cached| {
        cached.volume.release();
    }

    endpoints[index] = null;
}

fn endpoint_find(id: *const Device.Id) ?u32 {
    for (&endpoints, 0..) |*slot, index| {
        const cached = slot.* orelse continue;

        if (cached.id.eql(id)) {
            return @intCast(index);
        }
    }

    return null;
}

fn endpoint_open(
    id: *const Device.Id,
) (PlatformError || RequestError)!*mmdevice.IAudioEndpointVolume {
    var storage: [text.id_wide_units_max]u16 = undefined;

    const target = text.to_wide(id.slice(), &storage) catch {
        return error.DeviceUnknown;
    };

    const source = enumerator orelse unreachable;

    const device = source.device(target) catch |err| {
        return to_call_error(err);
    };

    defer device.release();

    const volume = device.endpoint_volume() catch |err| {
        return to_call_error(err);
    };

    return volume;
}

fn endpoint_slot() u32 {
    for (endpoints, 0..) |slot, index| {
        if (slot == null) {
            return @intCast(index);
        }
    }

    const index = endpoint_victim;

    if (endpoints[index]) |cached| {
        cached.volume.release();
    }

    endpoints[index] = null;
    endpoint_victim = (endpoint_victim + 1) % endpoint_count_max;

    assert(index < endpoint_count_max);

    return index;
}

fn endpoints_release() void {
    for (&endpoints) |*slot| {
        if (slot.*) |cached| {
            cached.volume.release();
        }

        slot.* = null;
    }

    endpoint_victim = 0;
}

pub fn to_platform_error(err: com.Error) PlatformError {
    const result: PlatformError = switch (err) {
        com.Error.Denied => error.AccessDenied,
        com.Error.NotOpen, com.Error.Unavailable => error.ServiceUnavailable,
        com.Error.Failed, com.Error.Invalid, com.Error.NotFound => error.CallFailed,
    };

    return result;
}

pub fn to_call_error(err: com.Error) (PlatformError || RequestError) {
    const result: (PlatformError || RequestError) = switch (err) {
        com.Error.Invalid, com.Error.NotFound => error.DeviceUnknown,
        else => to_platform_error(err),
    };

    return result;
}
