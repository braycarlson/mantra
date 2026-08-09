const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const mmdevice = @import("mmdevice.zig");
const runtime = @import("runtime.zig");
const text = @import("text.zig");

const assert = std.debug.assert;

const DeviceId = contract.DeviceId;
const DeviceInfo = contract.DeviceInfo;
const DeviceList = contract.DeviceList;
const Direction = contract.Direction;

pub const Error = contract.DeviceError;

pub const wide_bytes_max: u32 = contract.id_bytes_max + 1;

comptime {
    assert(wide_bytes_max > contract.id_bytes_max);
}

pub fn enumerate(direction: Direction, list: *DeviceList) Error!void {
    assert(direction.is_valid());

    if (!runtime.is_open()) {
        return Error.NotOpen;
    }

    const enumerator = mmdevice.create_enumerator() catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.release(enumerator);

    const collection = enumerator.endpoints(
        mmdevice.to_data_flow(direction),
        mmdevice.device_state_active,
    ) catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.release(collection);

    const total = collection.count() catch |err| {
        return runtime.to_device_error(err);
    };

    const chosen = resolve_default(enumerator, direction);

    list.clear();

    var index: u32 = 0;

    while (index < total) : (index += 1) {
        const device = collection.item(index) catch {
            continue;
        };

        defer com.release(device);

        const id = read_id(device, direction) catch {
            continue;
        };

        var storage: [contract.name_bytes_max]u8 = undefined;

        const name = read_name(device, &storage) catch id.slice();
        const is_default = if (chosen) |value| value.eql(&id) else false;

        try list.append(DeviceInfo.init(id, name, is_default));
    }

    assert(list.count <= total);
}

pub fn default(direction: Direction) Error!DeviceId {
    assert(direction.is_valid());

    if (!runtime.is_open()) {
        return Error.NotOpen;
    }

    const enumerator = mmdevice.create_enumerator() catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.release(enumerator);

    const device = enumerator.default_endpoint(
        mmdevice.to_data_flow(direction),
        mmdevice.role_console,
    ) catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.release(device);

    const result = try read_id(device, direction);

    assert(result.is_valid());

    return result;
}

pub fn set_default(id: *const DeviceId) Error!void {
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
        return runtime.to_device_error(err);
    };

    defer com.release(enumerator);

    const device = enumerator.device(target) catch |err| {
        return runtime.to_device_error(err);
    };

    com.release(device);

    const policy = mmdevice.create_policy() catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.release(policy);

    policy.set_default_all(target) catch |err| {
        return runtime.to_device_error(err);
    };
}

fn resolve_default(enumerator: *mmdevice.IMMDeviceEnumerator, direction: Direction) ?DeviceId {
    const device = enumerator.default_endpoint(
        mmdevice.to_data_flow(direction),
        mmdevice.role_console,
    ) catch {
        return null;
    };

    defer com.release(device);

    const result = read_id(device, direction) catch {
        return null;
    };

    return result;
}

fn read_id(device: *mmdevice.IMMDevice, direction: Direction) Error!DeviceId {
    const raw = device.id() catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.free(@ptrCast(raw));

    var storage: [contract.id_bytes_max]u8 = undefined;

    const utf8 = text.from_wide(raw, &storage) catch {
        return Error.Invalid;
    };

    return try DeviceId.init(direction, utf8);
}

fn read_name(device: *mmdevice.IMMDevice, storage: []u8) Error![]const u8 {
    const store = device.property_store() catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.release(store);

    var property = store.value(&mmdevice.key_friendly_name) catch |err| {
        return runtime.to_device_error(err);
    };

    defer com.clear(&property);

    if (property.vt != com.vt_lpwstr) {
        return Error.NotFound;
    }

    const raw = property.data.text orelse {
        return Error.NotFound;
    };

    const result = text.from_wide(raw, storage) catch {
        return Error.Invalid;
    };

    return result;
}
