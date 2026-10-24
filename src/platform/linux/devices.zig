const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const pulse = @import("pulse.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

pub fn enumerate(list: *Device.List, direction: Direction) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());

    const connection = runtime.acquire();
    defer runtime.release();

    var raw = pulse.DeviceList{};

    connection.list(runtime.list_command(direction), &raw) catch |err| {
        return runtime.to_list_error(err);
    };

    var defaults = pulse.Defaults{};

    connection.defaults(&defaults) catch |err| {
        return runtime.to_platform_error(err);
    };

    const chosen = default_name(direction, &defaults);

    list.clear();

    for (raw.slice()) |device| {
        const name = device.get_name();

        if (name.len == 0) {
            continue;
        }

        const id = Device.Id.init(direction, name) catch {
            continue;
        };

        const label = if (device.description_len > 0) device.get_description() else name;
        const is_default = std.mem.eql(u8, name, chosen);

        try list.append(Device.init(id, label, .{ .is_default = is_default }));
    }

    assert(list.count <= raw.count);
}

pub fn default(direction: Direction) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());

    const connection = runtime.acquire();
    defer runtime.release();

    var defaults = pulse.Defaults{};

    connection.defaults(&defaults) catch |err| {
        return runtime.to_platform_error(err);
    };

    const name = default_name(direction, &defaults);

    if (name.len == 0) {
        return error.DefaultMissing;
    }

    const result = try Device.Id.init(direction, name);

    assert(result.is_valid());

    return result;
}

pub fn set_default(id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    const connection = runtime.acquire();
    defer runtime.release();

    connection.set_default(
        runtime.default_command(id.direction),
        id.slice(),
    ) catch |err| {
        return runtime.to_call_error(err);
    };
}

fn default_name(direction: Direction, defaults: *const pulse.Defaults) []const u8 {
    const result = switch (direction) {
        .capture => defaults.get_source(),
        .render => defaults.get_sink(),
    };

    return result;
}

const testing = std.testing;

test "the default name is read from the half of the defaults that matches" {
    var defaults = pulse.Defaults{};

    @memcpy(defaults.sink[0..5], "sink0");
    defaults.sink_len = 5;

    @memcpy(defaults.source[0..7], "source0");
    defaults.source_len = 7;

    try testing.expectEqualStrings("source0", default_name(.capture, &defaults));
    try testing.expectEqualStrings("sink0", default_name(.render, &defaults));
}
