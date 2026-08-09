const std = @import("std");

const contract = @import("../contract.zig");
const events = @import("events.zig");
const pulse = @import("pulse.zig");
const sync = @import("sync.zig");

const assert = std.debug.assert;

pub const Error = contract.RuntimeError;

pub const client_name = "mantra";

comptime {
    assert(client_name.len > 0);
}

var connection: pulse.Connection = pulse.Connection.init();
var lock: sync.Mutex = .{};
var opened: bool = false;

pub fn open() Error!void {
    lock.lock();
    defer lock.unlock();

    if (opened) {
        return Error.AlreadyOpen;
    }

    connection = pulse.Connection.init();

    connection.open(client_name) catch |err| {
        return to_runtime_error(err);
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

pub fn acquire() ?*pulse.Connection {
    lock.lock();

    if (!opened) {
        lock.unlock();

        return null;
    }

    return &connection;
}

pub fn release() void {
    lock.unlock();
}

pub fn to_runtime_error(err: pulse.Error) Error {
    const result: Error = switch (err) {
        pulse.Error.Auth => Error.Denied,
        pulse.Error.Connect => Error.Unavailable,
        pulse.Error.Refused => Error.Denied,
        else => Error.Failed,
    };

    return result;
}

pub fn to_device_error(err: pulse.Error) contract.DeviceError {
    return switch (err) {
        pulse.Error.Auth => contract.DeviceError.Failed,
        pulse.Error.Connect, pulse.Error.Transport => contract.DeviceError.NotOpen,
        pulse.Error.Overflow, pulse.Error.Protocol => contract.DeviceError.Invalid,
        pulse.Error.Refused => contract.DeviceError.NotFound,
    };
}

pub fn to_control_error(err: pulse.Error) contract.ControlError {
    return switch (err) {
        pulse.Error.Auth => contract.ControlError.Denied,
        pulse.Error.Connect, pulse.Error.Transport => contract.ControlError.NotOpen,
        pulse.Error.Overflow, pulse.Error.Protocol => contract.ControlError.Invalid,
        pulse.Error.Refused => contract.ControlError.NotFound,
    };
}

pub fn list_command(direction: contract.Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .get_source_info_list,
        .render => .get_sink_info_list,
    };

    return result;
}

pub fn mute_command(direction: contract.Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_source_mute,
        .render => .set_sink_mute,
    };

    return result;
}

pub fn volume_command(direction: contract.Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_source_volume,
        .render => .set_sink_volume,
    };

    return result;
}

pub fn default_command(direction: contract.Direction) pulse.Command {
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

test "transport failures map to the canonical error sets" {
    try testing.expectEqual(Error.Unavailable, to_runtime_error(pulse.Error.Connect));
    try testing.expectEqual(Error.Denied, to_runtime_error(pulse.Error.Auth));
    try testing.expectEqual(Error.Failed, to_runtime_error(pulse.Error.Transport));

    try testing.expectEqual(contract.DeviceError.Failed, to_device_error(pulse.Error.Auth));
    try testing.expectEqual(contract.DeviceError.NotOpen, to_device_error(pulse.Error.Connect));
    try testing.expectEqual(contract.DeviceError.NotOpen, to_device_error(pulse.Error.Transport));
    try testing.expectEqual(contract.DeviceError.Invalid, to_device_error(pulse.Error.Overflow));
    try testing.expectEqual(contract.DeviceError.Invalid, to_device_error(pulse.Error.Protocol));
    try testing.expectEqual(contract.DeviceError.NotFound, to_device_error(pulse.Error.Refused));

    try testing.expectEqual(contract.ControlError.Denied, to_control_error(pulse.Error.Auth));
    try testing.expectEqual(contract.ControlError.NotOpen, to_control_error(pulse.Error.Connect));
    try testing.expectEqual(contract.ControlError.NotOpen, to_control_error(pulse.Error.Transport));
    try testing.expectEqual(contract.ControlError.Invalid, to_control_error(pulse.Error.Overflow));
    try testing.expectEqual(contract.ControlError.Invalid, to_control_error(pulse.Error.Protocol));
    try testing.expectEqual(contract.ControlError.NotFound, to_control_error(pulse.Error.Refused));
}
