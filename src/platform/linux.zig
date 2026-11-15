const std = @import("std");

const device_module = @import("../device.zig");
const Events = @import("linux/events.zig");
const interface = @import("interface.zig");
const pulse = @import("linux/pulse.zig");
const sync = @import("linux/sync.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = interface.Listener;
const PlatformError = interface.PlatformError;
const RequestError = device_module.RequestError;

connection: pulse.Connection,
events: Events,
mutex: sync.Mutex,

const Linux = @This();
pub const Options = struct {};
pub const client_name = "mantra";

comptime {
    assert(client_name.len > 0);

    interface.assert_backend(Linux);
}

pub fn init(linux: *Linux, _: Options) PlatformError!void {
    linux.* = .{ .connection = pulse.Connection.init(), .events = undefined, .mutex = .{} };

    linux.events.init();

    linux.connection.open(client_name) catch |err| {
        return to_platform_error(err);
    };

    assert(linux.connection.is_open());
    assert(!linux.events.is_subscribed());
}

pub fn deinit(linux: *Linux) void {
    assert(linux.connection.is_open());

    linux.events.unsubscribe();

    linux.mutex.lock();
    defer linux.mutex.unlock();

    linux.connection.close();

    assert(!linux.connection.is_open());
    assert(!linux.events.is_subscribed());
}

pub fn devices_enumerate(
    linux: *Linux,
    list: *Device.List,
    direction: Direction,
) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());

    const connection = linux.acquire();
    defer linux.release();

    var raw = pulse.DeviceList{};

    connection.list(list_command(direction), &raw) catch |err| {
        return to_list_error(err);
    };

    var defaults = pulse.Defaults{};

    connection.defaults(&defaults) catch |err| {
        return to_platform_error(err);
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

pub fn devices_default(
    linux: *Linux,
    direction: Direction,
) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());

    const connection = linux.acquire();
    defer linux.release();

    var defaults = pulse.Defaults{};

    connection.defaults(&defaults) catch |err| {
        return to_platform_error(err);
    };

    const name = default_name(direction, &defaults);

    if (name.len == 0) {
        return error.DefaultMissing;
    }

    const result = try Device.Id.init(direction, name);

    assert(result.is_valid());

    return result;
}

pub fn devices_set_default(
    linux: *Linux,
    id: *const Device.Id,
) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    const connection = linux.acquire();
    defer linux.release();

    connection.set_default(default_command(id.direction), id.slice()) catch |err| {
        return to_call_error(err);
    };
}

pub fn control_is_muted(linux: *Linux, id: *const Device.Id) (PlatformError || RequestError)!bool {
    assert(id.is_valid());

    const device = try linux.lookup(id);
    return device.muted;
}

pub fn control_set_mute(
    linux: *Linux,
    id: *const Device.Id,
    muted: bool,
) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    const connection = linux.acquire();
    defer linux.release();

    connection.set_mute(mute_command(id.direction), id.slice(), muted) catch |err| {
        return to_call_error(err);
    };
}

pub fn control_get_volume(linux: *Linux, id: *const Device.Id) (PlatformError || RequestError)!f32 {
    assert(id.is_valid());

    const device = try linux.lookup(id);
    const result = pulse.from_pulse_volume(device.volume);

    assert(result >= interface.volume_fraction_min);
    assert(result <= interface.volume_fraction_max);

    return result;
}

pub fn control_set_volume(
    linux: *Linux,
    id: *const Device.Id,
    level: f32,
) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    const device = try linux.lookup(id);

    assert(device.channels > 0);

    const connection = linux.acquire();
    defer linux.release();

    connection.set_volume(
        volume_command(id.direction),
        id.slice(),
        device.channels,
        pulse.to_pulse_volume(interface.clamp_volume(level)),
    ) catch |err| {
        return to_call_error(err);
    };
}

pub fn events_subscribe(linux: *Linux, listener: Listener, context: *anyopaque) PlatformError!void {
    assert(linux.connection.is_open());

    linux.events.subscribe(listener, context) catch |err| switch (err) {
        error.ThreadSpawnFailed => return error.ThreadSpawnFailed,
        else => |failure| return to_platform_error(failure),
    };
}

pub fn events_unsubscribe(linux: *Linux) void {
    linux.events.unsubscribe();

    assert(!linux.events.is_subscribed());
}

pub fn events_is_subscribed(linux: *Linux) bool {
    return linux.events.is_subscribed();
}

fn acquire(linux: *Linux) *pulse.Connection {
    linux.mutex.lock();

    assert(linux.connection.is_open());

    return &linux.connection;
}

fn release(linux: *Linux) void {
    linux.mutex.unlock();
}

fn lookup(linux: *Linux, id: *const Device.Id) (PlatformError || RequestError)!pulse.Device {
    assert(id.is_valid());

    const connection = linux.acquire();
    defer linux.release();

    var raw = pulse.DeviceList{};

    connection.list(list_command(id.direction), &raw) catch |err| switch (err) {
        pulse.Error.Exhausted => {},
        else => return to_call_error(err),
    };

    const wanted = id.slice();

    for (raw.slice()) |device| {
        if (std.mem.eql(u8, device.get_name(), wanted)) {
            return device;
        }
    }

    return error.DeviceUnknown;
}

fn default_name(direction: Direction, defaults: *const pulse.Defaults) []const u8 {
    const result = switch (direction) {
        .capture => defaults.get_source(),
        .render => defaults.get_sink(),
    };

    return result;
}

fn to_platform_error(err: pulse.Error) PlatformError {
    const result: PlatformError = switch (err) {
        pulse.Error.Auth, pulse.Error.Refused => error.AccessDenied,
        pulse.Error.Connect => error.ServiceUnavailable,
        pulse.Error.Exhausted, pulse.Error.Overflow, pulse.Error.Protocol => error.ReplyInvalid,
        pulse.Error.Transport => error.ConnectionLost,
    };

    return result;
}

fn to_list_error(err: pulse.Error) (CapacityError || PlatformError) {
    const result: (CapacityError || PlatformError) = switch (err) {
        pulse.Error.Exhausted => error.DevicesExhausted,
        else => to_platform_error(err),
    };

    return result;
}

fn to_call_error(err: pulse.Error) (PlatformError || RequestError) {
    const result: (PlatformError || RequestError) = switch (err) {
        pulse.Error.Refused => error.DeviceUnknown,
        else => to_platform_error(err),
    };

    return result;
}

fn list_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .get_source_info_list,
        .render => .get_sink_info_list,
    };

    return result;
}

fn mute_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_source_mute,
        .render => .set_sink_mute,
    };

    return result;
}

fn volume_command(direction: Direction) pulse.Command {
    const result: pulse.Command = switch (direction) {
        .capture => .set_source_volume,
        .render => .set_sink_volume,
    };

    return result;
}

fn default_command(direction: Direction) pulse.Command {
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

test "the default name is read from the half of the defaults that matches" {
    var defaults = pulse.Defaults{};

    @memcpy(defaults.sink[0..5], "sink0");
    defaults.sink_len = 5;

    @memcpy(defaults.source[0..7], "source0");
    defaults.source_len = 7;

    try testing.expectEqualStrings("source0", default_name(.capture, &defaults));
    try testing.expectEqualStrings("sink0", default_name(.render, &defaults));
}
