const std = @import("std");

const contract = @import("../contract.zig");
const pulse = @import("pulse.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const DeviceId = contract.DeviceId;
const DeviceInfo = contract.DeviceInfo;
const DeviceList = contract.DeviceList;
const Direction = contract.Direction;

pub const Error = contract.DeviceError;

pub fn enumerate(direction: Direction, list: *DeviceList) Error!void {
    assert(direction.is_valid());

    const connection = runtime.acquire() orelse {
        return Error.NotOpen;
    };

    defer runtime.release();

    var raw = pulse.DeviceList{};

    connection.list(runtime.list_command(direction), &raw) catch |err| {
        return runtime.to_device_error(err);
    };

    var info = pulse.ServerInfo{};

    connection.server_info(&info) catch |err| {
        return runtime.to_device_error(err);
    };

    const chosen = default_name(direction, &info);

    list.clear();

    for (raw.slice()) |device| {
        const name = device.get_name();

        if (name.len == 0) {
            continue;
        }

        const id = DeviceId.init(direction, name) catch {
            continue;
        };

        const label = if (device.description_len > 0) device.get_description() else name;
        const is_default = std.mem.eql(u8, name, chosen);

        try list.append(DeviceInfo.init(id, label, is_default));
    }
}

pub fn default(direction: Direction) Error!DeviceId {
    assert(direction.is_valid());

    const connection = runtime.acquire() orelse {
        return Error.NotOpen;
    };

    defer runtime.release();

    var info = pulse.ServerInfo{};

    connection.server_info(&info) catch |err| {
        return runtime.to_device_error(err);
    };

    const name = default_name(direction, &info);

    if (name.len == 0) {
        return Error.NotFound;
    }

    const result = try DeviceId.init(direction, name);

    assert(result.is_valid());

    return result;
}

pub fn set_default(id: *const DeviceId) Error!void {
    if (!id.is_valid()) {
        return Error.Invalid;
    }

    const connection = runtime.acquire() orelse {
        return Error.NotOpen;
    };

    defer runtime.release();

    connection.set_default(
        runtime.default_command(id.direction),
        id.slice(),
    ) catch |err| {
        return runtime.to_device_error(err);
    };
}

fn default_name(direction: Direction, info: *const pulse.ServerInfo) []const u8 {
    const result = switch (direction) {
        .capture => info.get_default_source(),
        .render => info.get_default_sink(),
    };

    return result;
}

const testing = std.testing;

test "the default name is read from the half of the server info that matches" {
    var info = pulse.ServerInfo{};

    @memcpy(info.default_sink[0..5], "sink0");
    info.default_sink_len = 5;

    @memcpy(info.default_source[0..7], "source0");
    info.default_source_len = 7;

    try testing.expectEqualStrings("source0", default_name(.capture, &info));
    try testing.expectEqualStrings("sink0", default_name(.render, &info));
}

test "a closed runtime refuses enumeration rather than reaching the socket" {
    var list = DeviceList.init();

    try testing.expectError(Error.NotOpen, enumerate(.capture, &list));
    try testing.expectError(Error.NotOpen, default(.render));
}

test "an invalid identifier is rejected before the runtime is consulted" {
    const id = DeviceId{};

    try testing.expectError(Error.Invalid, set_default(&id));
}
