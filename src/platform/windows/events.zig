const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const mmdevice = @import("mmdevice.zig");
const runtime = @import("runtime.zig");
const sync = @import("sync.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = contract.Listener;
const PlatformError = contract.PlatformError;

var context: ?*anyopaque = null;
var enumerator: ?*mmdevice.IMMDeviceEnumerator = null;
var listener: ?Listener = null;
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

pub fn subscribe(handler: Listener, owner: *anyopaque) PlatformError!void {
    assert(runtime.is_open());

    lock.lock();
    defer lock.unlock();

    assert(enumerator == null);

    const created = mmdevice.create_enumerator() catch |err| {
        return runtime.to_platform_error(err);
    };

    errdefer created.release();

    listener = handler;
    context = owner;
    errdefer {
        listener = null;
        context = null;
    }

    created.register(@ptrCast(&client)) catch |err| {
        return runtime.to_platform_error(err);
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
    registered.release();

    lock.lock();
    defer lock.unlock();

    listener = null;
    context = null;

    assert(enumerator == null);
}

pub fn is_subscribed() bool {
    lock.lock();
    defer lock.unlock();

    return enumerator != null;
}

fn deliver(event: Device.Event, direction: ?Direction) void {
    assert(event.is_valid());

    const handler = listener orelse return;
    const owner = context orelse return;

    handler(owner, event, direction);
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
    state: mmdevice.DeviceStates,
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
    flow: mmdevice.DataFlow,
    role: mmdevice.Role,
    id: ?[*:0]const u16,
) callconv(.winapi) com.HRESULT {
    _ = this;
    _ = id;

    if (role != .console) {
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
