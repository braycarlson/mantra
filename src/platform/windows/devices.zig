const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const mmdevice = @import("mmdevice.zig");
const runtime = @import("runtime.zig");
const text = @import("text.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

pub fn enumerate(list: *Device.List, direction: Direction) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());
    assert(runtime.is_open());

    const enumerator = runtime.enumerator_acquire();
    defer runtime.enumerator_release();

    const collection = enumerator.endpoints(
        mmdevice.to_data_flow(direction),
        .{ .active = true },
    ) catch |err| {
        return runtime.to_platform_error(err);
    };

    defer collection.release();

    const total = collection.count() catch |err| {
        return runtime.to_platform_error(err);
    };

    const chosen = resolve_default(enumerator, direction);

    list.clear();

    var index: u32 = 0;

    while (index < total) : (index += 1) {
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

pub fn default(direction: Direction) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());
    assert(runtime.is_open());

    const enumerator = runtime.enumerator_acquire();
    defer runtime.enumerator_release();

    const device = enumerator.default_endpoint(
        mmdevice.to_data_flow(direction),
        .console,
    ) catch |err| switch (err) {
        com.Error.NotFound => return error.DefaultMissing,
        else => return runtime.to_platform_error(err),
    };

    defer device.release();

    const result = try read_id(device, direction);

    assert(result.is_valid());

    return result;
}

pub fn set_default(id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(runtime.is_open());

    var storage: [text.id_wide_units_max]u16 = undefined;

    const target = text.to_wide(id.slice(), &storage) catch {
        return error.DeviceUnknown;
    };

    const enumerator = runtime.enumerator_acquire();
    defer runtime.enumerator_release();

    const device = enumerator.device(target) catch |err| {
        return runtime.to_call_error(err);
    };

    device.release();

    const policy = runtime.policy_get() orelse return error.CallFailed;

    policy.set_default_all(target) catch |err| {
        return runtime.to_call_error(err);
    };
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
        return runtime.to_platform_error(err);
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
    const store = device.property_store() catch |err| {
        return runtime.to_platform_error(err);
    };

    defer store.release();

    var property = store.value(&mmdevice.key_friendly_name) catch |err| {
        return runtime.to_platform_error(err);
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
