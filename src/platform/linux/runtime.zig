const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const events = @import("events.zig");
const pulse = @import("pulse.zig");
const sync = @import("sync.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Direction = device_module.Direction;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

pub const client_name = "mantra";

comptime {
    assert(client_name.len > 0);
}

var connection: pulse.Connection = pulse.Connection.init();
var lock: sync.Mutex = .{};
var opened: bool = false;

pub fn open() PlatformError!void {
    lock.lock();
    defer lock.unlock();

    assert(!opened);

    connection = pulse.Connection.init();

    connection.open(client_name) catch |err| {
        return to_platform_error(err);
    };

    opened = true;

    assert(opened);
    assert(connection.is_open());
}

pub fn close() void {
    events.unsubscribe();

    lock.lock();
    defer lock.unlock();

    if (!opened) {
        return;
    }

    opened = false;

    connection.close();

    assert(!opened);
    assert(!connection.is_open());
}

pub fn is_open() bool {
    lock.lock();
    defer lock.unlock();

    return opened;
}

pub fn acquire() *pulse.Connection {
    lock.lock();

    assert(opened);

    return &connection;
}

pub fn release() void {
    lock.unlock();
}

pub fn to_platform_error(err: pulse.Error) PlatformError {
    const result: PlatformError = switch (err) {
        pulse.Error.Auth, pulse.Error.Refused => error.AccessDenied,
        pulse.Error.Connect => error.ServiceUnavailable,
        pulse.Error.Exhausted, pulse.Error.Overflow, pulse.Error.Protocol => error.ReplyInvalid,
        pulse.Error.Transport => error.ConnectionLost,
    };

    return result;
}

pub fn to_list_error(err: pulse.Error) (CapacityError || PlatformError) {
    const result: (CapacityError || PlatformError) = switch (err) {
        pulse.Error.Exhausted => error.DevicesExhausted,
        else => to_platform_error(err),
    };

    return result;
}

pub fn to_call_error(err: pulse.Error) (PlatformError || RequestError) {
    const result: (PlatformError || RequestError) = switch (err) {
        pulse.Error.Refused => error.DeviceUnknown,
        else => to_platform_error(err),
    };

    return result;
}

pub fn list_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .get_source_info_list,
        .render => .get_sink_info_list,
    };

    return result;
}

pub fn mute_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_source_mute,
        .render => .set_sink_mute,
    };

    return result;
}

pub fn volume_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_source_volume,
        .render => .set_sink_volume,
    };

    return result;
}

pub fn default_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_default_source,
        .render => .set_default_sink,
    };

    return result;
}

const testing = std.testing;

test "each direction maps to the source or sink half of the protocol" {
    try testing.expectEqual(pulse.Command.get_source_info_list, list_command(.capture));
    try testing.expectEqual(pulse.Command.get_sink_info_list, list_command(.render));
    try testing.expectEqual(pulse.Command.set_source_mute, mute_command(.capture));
    try testing.expectEqual(pulse.Command.set_sink_mute, mute_command(.render));
    try testing.expectEqual(pulse.Command.set_source_volume, volume_command(.capture));
    try testing.expectEqual(pulse.Command.set_sink_volume, volume_command(.render));
    try testing.expectEqual(pulse.Command.set_default_source, default_command(.capture));
    try testing.expectEqual(pulse.Command.set_default_sink, default_command(.render));
}

test "a transport failure is the platform's fault and a refusal names the device" {
    try testing.expectEqual(error.ServiceUnavailable, to_platform_error(pulse.Error.Connect));
    try testing.expectEqual(error.AccessDenied, to_platform_error(pulse.Error.Auth));
    try testing.expectEqual(error.AccessDenied, to_platform_error(pulse.Error.Refused));
    try testing.expectEqual(error.ConnectionLost, to_platform_error(pulse.Error.Transport));
    try testing.expectEqual(error.ReplyInvalid, to_platform_error(pulse.Error.Overflow));
    try testing.expectEqual(error.ReplyInvalid, to_platform_error(pulse.Error.Protocol));

    try testing.expectEqual(error.DevicesExhausted, to_list_error(pulse.Error.Exhausted));
    try testing.expectEqual(error.ConnectionLost, to_list_error(pulse.Error.Transport));

    try testing.expectEqual(error.DeviceUnknown, to_call_error(pulse.Error.Refused));
    try testing.expectEqual(error.ConnectionLost, to_call_error(pulse.Error.Transport));
}
