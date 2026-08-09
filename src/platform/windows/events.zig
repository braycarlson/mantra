const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const mmdevice = @import("mmdevice.zig");
const runtime = @import("runtime.zig");
const sync = @import("sync.zig");

const assert = std.debug.assert;

const DeviceEvent = contract.DeviceEvent;
const Direction = contract.Direction;
const EventCallback = contract.EventCallback;

pub const Error = contract.EventError;

var callback: ?EventCallback = null;
var context: ?*anyopaque = null;
var enumerator: ?*mmdevice.IMMDeviceEnumerator = null;
var lock: sync.Mutex = .{};
var references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

const vtable = mmdevice.NotificationVtable{
    .QueryInterface = &query_interface,
    .AddRef = &add_ref,
    .Release = &drop_ref,
    .OnDeviceStateChanged = &on_device_state_changed,
    .OnDeviceAdded = &on_device_added,
    .OnDeviceRemoved = &on_device_removed,
    .OnDefaultDeviceChanged = &on_default_device_changed,
    .OnPropertyValueChanged = &on_property_value_changed,
};

var client = mmdevice.NotificationClient{ .vtable = &vtable };

pub fn subscribe(handler: EventCallback, handler_context: ?*anyopaque) Error!void {
    if (!runtime.is_open()) {
        return Error.NotOpen;
    }

    lock.lock();
    defer lock.unlock();

    if (enumerator != null) {
        return Error.AlreadySubscribed;
    }

    const created = mmdevice.create_enumerator() catch {
        return Error.Failed;
    };

    errdefer com.release(created);

    callback = handler;
    context = handler_context;
    errdefer {
        callback = null;
        context = null;
    }

    created.register(@ptrCast(&client)) catch {
        return Error.Failed;
    };

    enumerator = created;

    assert(enumerator != null);
}

pub fn unsubscribe() void {
    lock.lock();

    const registered = enumerator orelse {
        lock.unlock();

        return;
    };

    enumerator = null;

    lock.unlock();

    registered.unregister(@ptrCast(&client));

    com.release(registered);

    lock.lock();
    defer lock.unlock();

    callback = null;
    context = null;

    assert(enumerator == null);
}

pub fn is_subscribed() bool {
    lock.lock();
    defer lock.unlock();

    return enumerator != null;
}

fn deliver(event: DeviceEvent, direction: ?Direction) void {
    assert(event.is_valid());

    const handler = callback orelse {
        return;
    };

    handler(event, direction, context);
}

fn query_interface(
    this: *anyopaque,
    iid: *const com.GUID,
    out: *?*anyopaque,
) callconv(.winapi) com.HRESULT {
    const wanted = iid.eql(&mmdevice.iid_unknown) or
        iid.eql(&mmdevice.iid_notification_client);

    if (!wanted) {
        out.* = null;

        return com.e_no_interface;
    }

    out.* = this;

    _ = references.fetchAdd(1, .monotonic);

    return com.s_ok;
}

fn add_ref(this: *anyopaque) callconv(.winapi) u32 {
    _ = this;

    return references.fetchAdd(1, .monotonic) + 1;
}

fn drop_ref(this: *anyopaque) callconv(.winapi) u32 {
    _ = this;

    const previous = references.fetchSub(1, .monotonic);

    assert(previous > 0);

    return previous - 1;
}

fn on_device_state_changed(
    this: *anyopaque,
    id: ?[*:0]const u16,
    state: u32,
) callconv(.winapi) com.HRESULT {
    _ = this;
    _ = id;
    _ = state;

    deliver(.state_changed, null);

    return com.s_ok;
}

fn on_device_added(this: *anyopaque, id: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
    _ = this;
    _ = id;

    deliver(.added, null);

    return com.s_ok;
}

fn on_device_removed(this: *anyopaque, id: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
    _ = this;
    _ = id;

    deliver(.removed, null);

    return com.s_ok;
}

fn on_default_device_changed(
    this: *anyopaque,
    flow: u32,
    role: u32,
    id: ?[*:0]const u16,
) callconv(.winapi) com.HRESULT {
    _ = this;
    _ = id;

    if (role != mmdevice.role_console) {
        return com.s_ok;
    }

    deliver(.default_changed, mmdevice.to_direction(flow));

    return com.s_ok;
}

fn on_property_value_changed(
    this: *anyopaque,
    id: ?[*:0]const u16,
    key: com.PropertyKey,
) callconv(.winapi) com.HRESULT {
    _ = this;
    _ = id;
    _ = key;

    return com.s_ok;
}
