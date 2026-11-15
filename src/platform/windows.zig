const std = @import("std");

const com = @import("windows/com.zig");
const device_module = @import("../device.zig");
const Events = @import("windows/events.zig");
const interface = @import("interface.zig");
const mmdevice = @import("windows/mmdevice.zig");
const sync = @import("windows/sync.zig");
const text = @import("windows/text.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const EndpointVolume = mmdevice.IAudioEndpointVolume;
const Listener = interface.Listener;
const PlatformError = interface.PlatformError;
const RequestError = device_module.RequestError;

apartment: com.Apartment,
endpoint_victim: u32,
endpoints: [endpoint_count_max]?Endpoint,
enumerator: *mmdevice.IMMDeviceEnumerator,
events: Events,
mutex: sync.Mutex,
opened: bool,
owner: u32,
policy: ?*mmdevice.IPolicyConfig,

const Windows = @This();

const Endpoint = struct {
    id: Device.Id,
    volume: *EndpointVolume,
};

pub const Options = struct {};
pub const endpoint_count_max: u32 = device_module.count_max;
const attempt_count_max: u32 = 2;
const endpoint_scan_max: u32 = device_module.count_max * 4;

comptime {
    assert(endpoint_count_max > 0);
    assert(attempt_count_max >= 2);
    assert(endpoint_scan_max >= device_module.count_max);

    interface.assert_backend(Windows);
}

pub fn init(windows: *Windows, _: Options) PlatformError!void {
    const apartment = com.initialize() catch |err| {
        return to_platform_error(err);
    };

    errdefer com.uninitialize(apartment);

    const enumerator = mmdevice.create_enumerator() catch |err| {
        return to_platform_error(err);
    };

    windows.* = .{
        .apartment = apartment,
        .endpoint_victim = 0,
        .endpoints = @splat(null),
        .enumerator = enumerator,
        .events = undefined,
        .mutex = .{},
        .opened = true,
        .owner = com.thread_id(),
        .policy = mmdevice.create_policy() catch null,
    };

    windows.events.init();

    assert(windows.opened);
    assert(windows.owner != 0);
}

pub fn deinit(windows: *Windows) void {
    assert(windows.opened);
    assert(windows.owner == com.thread_id());

    windows.events.unsubscribe();

    windows.mutex.lock();
    defer windows.mutex.unlock();

    windows.endpoints_release();

    if (windows.policy) |config| {
        config.release();
    }

    windows.enumerator.release();
    windows.opened = false;
    windows.policy = null;

    com.uninitialize(windows.apartment);

    windows.apartment = .borrowed;
    windows.owner = 0;

    assert(!windows.events.is_subscribed());
}

pub fn devices_enumerate(
    windows: *Windows,
    list: *Device.List,
    direction: Direction,
) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());

    const enumerator = windows.enumerator_acquire();
    defer windows.enumerator_release();

    const collection = enumerator.endpoints(
        mmdevice.to_data_flow(direction),
        .{ .active = true },
    ) catch |err| {
        return to_platform_error(err);
    };

    defer collection.release();

    const total = collection.count() catch |err| {
        return to_platform_error(err);
    };

    const scanned = @min(total, endpoint_scan_max);
    const chosen = resolve_default(enumerator, direction);

    list.clear();

    var index: u32 = 0;

    while (index < scanned) : (index += 1) {
        assert(index < endpoint_scan_max);

        const device = collection.item(index) catch {
            continue;
        };

        defer device.release();

        const id = read_id(device, direction) catch {
            continue;
        };

        var storage: [device_module.name_bytes_max]u8 = undefined;

        const name = read_name(device, &storage) catch id.slice();
        const is_default = if (chosen) |value| value.eql(&id) else false;

        try list.append(Device.init(id, name, .{ .is_default = is_default }));
    }

    assert(list.count <= total);
}

pub fn devices_default(
    windows: *Windows,
    direction: Direction,
) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());

    const enumerator = windows.enumerator_acquire();
    defer windows.enumerator_release();

    const device = enumerator.default_endpoint(
        mmdevice.to_data_flow(direction),
        .console,
    ) catch |err| switch (err) {
        com.Error.NotFound => return error.DefaultMissing,
        else => return to_platform_error(err),
    };

    defer device.release();

    const result = try read_id(device, direction);

    assert(result.is_valid());

    return result;
}

pub fn devices_set_default(
    windows: *Windows,
    id: *const Device.Id,
) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    var storage: [text.id_wide_units_max]u16 = undefined;

    const target = text.to_wide(id.slice(), &storage) catch {
        return error.DeviceUnknown;
    };

    const enumerator = windows.enumerator_acquire();
    defer windows.enumerator_release();

    const device = enumerator.device(target) catch |err| {
        return to_call_error(err);
    };

    device.release();

    const policy = windows.policy orelse return error.CallFailed;

    policy.set_default_all(target) catch |err| {
        return to_call_error(err);
    };
}

pub fn control_is_muted(
    windows: *Windows,
    id: *const Device.Id,
) (PlatformError || RequestError)!bool {
    return windows.endpoint_call(bool, void, id, {}, mute_read);
}

pub fn control_set_mute(
    windows: *Windows,
    id: *const Device.Id,
    muted: bool,
) (PlatformError || RequestError)!void {
    return windows.endpoint_call(void, bool, id, muted, mute_write);
}

pub fn control_get_volume(
    windows: *Windows,
    id: *const Device.Id,
) (PlatformError || RequestError)!f32 {
    const raw = try windows.endpoint_call(f32, void, id, {}, level_read);
    const result = interface.clamp_volume(raw);

    assert(result >= interface.volume_fraction_min);
    assert(result <= interface.volume_fraction_max);

    return result;
}

pub fn control_set_volume(
    windows: *Windows,
    id: *const Device.Id,
    level: f32,
) (PlatformError || RequestError)!void {
    const wanted = interface.clamp_volume(level);
    return windows.endpoint_call(void, f32, id, wanted, level_write);
}

pub fn events_subscribe(
    windows: *Windows,
    listener: Listener,
    context: *anyopaque,
) PlatformError!void {
    assert(windows.opened);

    windows.events.subscribe(listener, context) catch |err| {
        return to_platform_error(err);
    };
}

pub fn events_unsubscribe(windows: *Windows) void {
    windows.events.unsubscribe();

    assert(!windows.events.is_subscribed());
}

pub fn events_is_subscribed(windows: *Windows) bool {
    return windows.events.is_subscribed();
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

fn enumerator_acquire(windows: *Windows) *mmdevice.IMMDeviceEnumerator {
    windows.mutex.lock();

    assert(windows.opened);

    return windows.enumerator;
}

fn enumerator_release(windows: *Windows) void {
    windows.mutex.unlock();
}

fn endpoint_call(
    windows: *Windows,
    comptime Result: type,
    comptime Context: type,
    id: *const Device.Id,
    context: Context,
    comptime call: fn (*EndpointVolume, Context) com.Error!Result,
) (PlatformError || RequestError)!Result {
    assert(id.is_valid());
    if (Context == f32) assert(context >= interface.volume_fraction_min);
    if (Context == f32) assert(context <= interface.volume_fraction_max);

    for (0..attempt_count_max) |attempt| {
        const endpoint = try windows.endpoint_acquire(id);
        defer windows.endpoint_release();

        if (call(endpoint, context)) |result| {
            return result;
        } else |err| {
            windows.endpoint_evict(id);

            if (attempt + 1 == attempt_count_max) {
                return to_call_error(err);
            }
        }
    }

    unreachable;
}

fn endpoint_acquire(
    windows: *Windows,
    id: *const Device.Id,
) (PlatformError || RequestError)!*EndpointVolume {
    assert(id.is_valid());

    windows.mutex.lock();
    errdefer windows.mutex.unlock();

    assert(windows.opened);

    if (windows.endpoint_find(id)) |index| {
        if (windows.endpoints[index]) |cached| {
            return cached.volume;
        }
    }

    const volume = try windows.endpoint_open(id);
    const index = windows.endpoint_slot();

    windows.endpoints[index] = .{ .id = id.*, .volume = volume };

    return volume;
}

fn endpoint_release(windows: *Windows) void {
    windows.mutex.unlock();
}

fn endpoint_evict(windows: *Windows, id: *const Device.Id) void {
    assert(windows.opened);
    assert(id.is_valid());

    const index = windows.endpoint_find(id) orelse return;

    if (windows.endpoints[index]) |cached| {
        cached.volume.release();
    }

    windows.endpoints[index] = null;
}

fn endpoint_find(windows: *const Windows, id: *const Device.Id) ?u32 {
    for (&windows.endpoints, 0..) |*slot, index| {
        const cached = slot.* orelse continue;

        if (cached.id.eql(id)) {
            const result: u32 = @intCast(index);
            assert(result < endpoint_count_max);

            return result;
        }
    }

    return null;
}

fn endpoint_open(
    windows: *const Windows,
    id: *const Device.Id,
) (PlatformError || RequestError)!*EndpointVolume {
    var storage: [text.id_wide_units_max]u16 = undefined;

    const target = text.to_wide(id.slice(), &storage) catch {
        return error.DeviceUnknown;
    };

    const device = windows.enumerator.device(target) catch |err| {
        return to_call_error(err);
    };

    defer device.release();

    const volume = device.endpoint_volume() catch |err| {
        return to_call_error(err);
    };

    return volume;
}

fn endpoint_slot(windows: *Windows) u32 {
    for (windows.endpoints, 0..) |slot, index| {
        if (slot == null) {
            const result: u32 = @intCast(index);
            assert(windows.endpoints[result] == null);

            return result;
        }
    }

    const index = windows.endpoint_victim;

    if (windows.endpoints[index]) |cached| {
        cached.volume.release();
    }

    windows.endpoints[index] = null;
    windows.endpoint_victim = (windows.endpoint_victim + 1) % endpoint_count_max;

    assert(index < endpoint_count_max);

    return index;
}

fn endpoints_release(windows: *Windows) void {
    for (&windows.endpoints) |*slot| {
        if (slot.*) |cached| {
            cached.volume.release();
        }

        slot.* = null;
    }

    windows.endpoint_victim = 0;
}

fn resolve_default(enumerator: *mmdevice.IMMDeviceEnumerator, direction: Direction) ?Device.Id {
    const device = enumerator.default_endpoint(
        mmdevice.to_data_flow(direction),
        .console,
    ) catch {
        return null;
    };

    defer device.release();

    const result = read_id(device, direction) catch {
        return null;
    };

    return result;
}

fn read_id(
    device: *mmdevice.IMMDevice,
    direction: Direction,
) (CapacityError || PlatformError || RequestError)!Device.Id {
    const raw = device.id() catch |err| {
        return to_platform_error(err);
    };

    defer com.free(@ptrCast(raw));

    var storage: [device_module.id_bytes_max]u8 = undefined;

    const utf8 = text.from_wide(raw, &storage) catch |err| switch (err) {
        text.Error.TooLong => return error.IdTooLong,
        text.Error.Empty, text.Error.Invalid => return error.CallFailed,
    };

    return try Device.Id.init(direction, utf8);
}

fn read_name(device: *mmdevice.IMMDevice, storage: []u8) PlatformError![]const u8 {
    assert(storage.len > 0);
    assert(storage.len <= device_module.name_bytes_max);

    const store = device.property_store() catch |err| {
        return to_platform_error(err);
    };

    defer store.release();

    var property = store.value(&mmdevice.key_friendly_name) catch |err| {
        return to_platform_error(err);
    };

    defer com.clear(&property);

    if (property.vt != com.vt_lpwstr) {
        return error.CallFailed;
    }

    const raw = property.data.text orelse {
        return error.CallFailed;
    };

    const result = text.from_wide(raw, storage) catch {
        return error.CallFailed;
    };

    return result;
}

fn level_read(endpoint: *EndpointVolume, _: void) com.Error!f32 {
    return endpoint.level();
}

fn level_write(endpoint: *EndpointVolume, level: f32) com.Error!void {
    assert(level >= interface.volume_fraction_min);
    assert(level <= interface.volume_fraction_max);

    return endpoint.set_level(level);
}

fn mute_read(endpoint: *EndpointVolume, _: void) com.Error!bool {
    return endpoint.is_muted();
}

fn mute_write(endpoint: *EndpointVolume, muted: bool) com.Error!void {
    return endpoint.set_mute(muted);
}
