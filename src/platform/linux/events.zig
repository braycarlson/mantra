const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const pulse = @import("pulse.zig");
const runtime = @import("runtime.zig");
const sync = @import("sync.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = contract.Listener;
const PlatformError = contract.PlatformError;

pub const client_name = "mantra-events";

pub const subscription_mask: u32 = pulse.subscription_mask_sink |
    pulse.subscription_mask_source |
    pulse.subscription_mask_server;

comptime {
    assert(client_name.len > 0);
    assert(subscription_mask != 0);
}

var connection: pulse.Connection = pulse.Connection.init();
var context: ?*anyopaque = null;
var listener: ?Listener = null;
var lock: sync.Mutex = .{};
var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;

pub fn subscribe(handler: Listener, owner: *anyopaque) PlatformError!void {
    assert(runtime.is_open());

    lock.lock();
    defer lock.unlock();

    assert(thread == null);

    connection = pulse.Connection.init();

    connection.open(client_name) catch |err| {
        return runtime.to_platform_error(err);
    };

    errdefer connection.close();

    connection.subscribe(subscription_mask) catch |err| {
        return runtime.to_platform_error(err);
    };

    listener = handler;
    context = owner;

    running.store(true, .seq_cst);

    thread = std.Thread.spawn(.{}, pump, .{}) catch {
        running.store(false, .seq_cst);
        listener = null;
        context = null;

        return error.ThreadSpawnFailed;
    };

    assert(thread != null);
}

pub fn unsubscribe() void {
    lock.lock();

    const worker = thread orelse {
        lock.unlock();

        return;
    };

    thread = null;

    running.store(false, .seq_cst);

    if (connection.socket) |handle| {
        sys.shutdown(handle);
    }

    lock.unlock();

    worker.join();

    lock.lock();
    defer lock.unlock();

    connection.close();

    listener = null;
    context = null;

    assert(thread == null);
}

pub fn is_subscribed() bool {
    lock.lock();
    defer lock.unlock();

    if (thread == null) {
        return false;
    }

    return running.load(.seq_cst);
}

pub fn to_event(facility: u32, change: u32) ?Device.Event {
    if (facility == pulse.facility_server) {
        return .default_changed;
    }

    switch (facility) {
        pulse.facility_sink, pulse.facility_source => {},
        else => return null,
    }

    const result: Device.Event = switch (change) {
        pulse.change_new => .added,
        pulse.change_removed => .removed,
        else => .state_changed,
    };

    return result;
}

pub fn to_direction(facility: u32) ?Direction {
    if (facility == pulse.facility_sink) {
        return .render;
    }

    if (facility == pulse.facility_source) {
        return .capture;
    }

    return null;
}

fn pump() void {
    defer running.store(false, .seq_cst);

    while (running.load(.seq_cst)) {
        var event: pulse.Event = undefined;

        const received = connection.read_event(&event) catch {
            return;
        };

        if (!received) continue;

        assert(event.facility <= pulse.facility_mask);

        deliver(event.facility, event.change);
    }
}

fn deliver(facility: u32, change: u32) void {
    const event = to_event(facility, change) orelse return;
    const handler = listener orelse return;
    const owner = context orelse return;

    handler(owner, event, to_direction(facility));
}

const testing = std.testing;

test "a server notification is a default change with no direction" {
    try testing.expectEqual(
        Device.Event.default_changed,
        to_event(pulse.facility_server, pulse.change_changed).?,
    );

    try testing.expect(to_direction(pulse.facility_server) == null);
}

test "sink and source notifications carry their own direction" {
    try testing.expectEqual(Direction.render, to_direction(pulse.facility_sink).?);
    try testing.expectEqual(Direction.capture, to_direction(pulse.facility_source).?);
}

test "every change kind maps to a hotplug event" {
    try testing.expectEqual(
        Device.Event.added,
        to_event(pulse.facility_sink, pulse.change_new).?,
    );

    try testing.expectEqual(
        Device.Event.removed,
        to_event(pulse.facility_sink, pulse.change_removed).?,
    );

    try testing.expectEqual(
        Device.Event.state_changed,
        to_event(pulse.facility_source, pulse.change_changed).?,
    );
}

test "a facility this library does not watch is dropped" {
    try testing.expect(to_event(0x0002, pulse.change_new) == null);
    try testing.expect(to_event(0x0005, pulse.change_changed) == null);
}

test "an idle subscription reports itself unsubscribed" {
    try testing.expect(!is_subscribed());

    unsubscribe();

    try testing.expect(!is_subscribed());
}
