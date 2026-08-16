const std = @import("std");

const contract = @import("../contract.zig");
const pulse = @import("pulse.zig");
const runtime = @import("runtime.zig");
const sync = @import("sync.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const DeviceEvent = contract.DeviceEvent;
const Direction = contract.Direction;
const EventCallback = contract.EventCallback;

pub const Error = contract.EventError;

pub const client_name = "mantra-events";
pub const subscription_mask: u32 = pulse.subscription_mask_sink |
    pulse.subscription_mask_source |
    pulse.subscription_mask_server;

comptime {
    assert(client_name.len > 0);
    assert(subscription_mask != 0);
}

var callback: ?EventCallback = null;
var connection: pulse.Connection = pulse.Connection.init();
var context: ?*anyopaque = null;
var lock: sync.Mutex = .{};
var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;

pub fn subscribe(handler: EventCallback, handler_context: ?*anyopaque) Error!void {
    if (!runtime.is_open()) {
        return Error.NotOpen;
    }

    lock.lock();
    defer lock.unlock();

    if (thread != null) {
        return Error.AlreadySubscribed;
    }

    connection = pulse.Connection.init();

    connection.open(client_name) catch {
        return Error.Failed;
    };

    errdefer connection.close();

    connection.subscribe(subscription_mask) catch {
        return Error.Failed;
    };

    callback = handler;
    context = handler_context;

    running.store(true, .seq_cst);

    thread = std.Thread.spawn(.{}, pump, .{}) catch {
        running.store(false, .seq_cst);
        callback = null;
        context = null;

        return Error.Failed;
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

    callback = null;
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

pub fn to_event(facility: u32, change: u32) ?DeviceEvent {
    if (facility == pulse.facility_server) {
        return .default_changed;
    }

    if (facility != pulse.facility_sink and facility != pulse.facility_source) {
        return null;
    }

    const result: DeviceEvent = switch (change) {
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
        const event = connection.read_event() catch {
            return;
        };

        const payload = event orelse continue;

        deliver(payload.facility, payload.change);
    }
}

fn deliver(facility: u32, change: u32) void {
    const event = to_event(facility, change) orelse return;
    const handler = callback orelse return;

    handler(event, to_direction(facility), context);
}

const testing = std.testing;

test "a server notification is a default change with no direction" {
    try testing.expectEqual(
        DeviceEvent.default_changed,
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
        DeviceEvent.added,
        to_event(pulse.facility_sink, pulse.change_new).?,
    );

    try testing.expectEqual(
        DeviceEvent.removed,
        to_event(pulse.facility_sink, pulse.change_removed).?,
    );

    try testing.expectEqual(
        DeviceEvent.state_changed,
        to_event(pulse.facility_source, pulse.change_changed).?,
    );
}

test "a facility this library does not watch is dropped" {
    try testing.expect(to_event(0x0002, pulse.change_new) == null);
    try testing.expect(to_event(0x0005, pulse.change_changed) == null);
}

test "subscribing without an open runtime is refused" {
    try testing.expect(!is_subscribed());
    try testing.expectError(Error.NotOpen, subscribe(ignore, null));
}

fn ignore(_: DeviceEvent, _: ?Direction, _: ?*anyopaque) void {}
