const std = @import("std");

const device_module = @import("../../device.zig");
const interface = @import("../interface.zig");
const pulse = @import("pulse.zig");
const sync = @import("sync.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = interface.Listener;

connection: pulse.Connection,
context: ?*anyopaque,
listener: ?Listener,
mutex: sync.Mutex,
running: std.atomic.Value(bool),
thread: ?std.Thread,

const Events = @This();
pub const Error = pulse.Error || error{ThreadSpawnFailed};
pub const client_name = "mantra-events";

pub const subscription_mask: u32 = pulse.subscription_mask_sink |
    pulse.subscription_mask_source |
    pulse.subscription_mask_server;

comptime {
    assert(client_name.len > 0);
    assert(subscription_mask != 0);
}

pub fn init(events: *Events) void {
    events.* = .{
        .connection = pulse.Connection.init(),
        .context = null,
        .listener = null,
        .mutex = .{},
        .running = .init(false),
        .thread = null,
    };

    assert(!events.connection.is_open());
    assert(!events.running.load(.seq_cst));
}

pub fn subscribe(events: *Events, handler: Listener, owner: *anyopaque) Error!void {
    events.mutex.lock();
    defer events.mutex.unlock();

    assert(events.thread == null);

    events.connection = pulse.Connection.init();

    try events.connection.open(client_name);
    errdefer events.connection.close();

    try events.connection.subscribe(subscription_mask);

    events.listener = handler;
    events.context = owner;

    events.running.store(true, .seq_cst);

    events.thread = std.Thread.spawn(.{}, pump, .{events}) catch {
        events.running.store(false, .seq_cst);
        events.listener = null;
        events.context = null;

        return error.ThreadSpawnFailed;
    };

    assert(events.thread != null);
}

pub fn unsubscribe(events: *Events) void {
    events.mutex.lock();

    const worker = events.thread orelse {
        events.mutex.unlock();

        return;
    };

    events.thread = null;

    events.running.store(false, .seq_cst);

    if (events.connection.socket) |handle| {
        sys.shutdown(handle);
    }

    events.mutex.unlock();

    worker.join();

    events.mutex.lock();
    defer events.mutex.unlock();

    events.connection.close();

    events.listener = null;
    events.context = null;

    assert(events.thread == null);
}

pub fn is_subscribed(events: *Events) bool {
    events.mutex.lock();
    defer events.mutex.unlock();

    if (events.thread == null) {
        return false;
    }

    return events.running.load(.seq_cst);
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

fn pump(events: *Events) void {
    defer events.running.store(false, .seq_cst);

    while (events.running.load(.seq_cst)) {
        var event: pulse.Event = undefined;

        const received = events.connection.read_event(&event) catch {
            return;
        };

        if (!received) continue;

        assert(event.facility <= pulse.facility_mask);

        events.deliver(event.facility, event.change);
    }
}

fn deliver(events: *const Events, facility: u32, change: u32) void {
    assert(facility <= pulse.facility_mask);
    assert(change & ~pulse.change_mask == 0);

    const event = to_event(facility, change) orelse return;
    const handler = events.listener orelse return;
    const owner = events.context orelse return;

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
    var events: Events = undefined;

    events.init();

    try testing.expect(!events.is_subscribed());

    events.unsubscribe();

    try testing.expect(!events.is_subscribed());
}
