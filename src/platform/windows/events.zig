const std = @import("std");

const com = @import("com.zig");
const device_module = @import("../../device.zig");
const interface = @import("../interface.zig");
const mmdevice = @import("mmdevice.zig");
const sync = @import("sync.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = interface.Listener;

client: mmdevice.NotificationClient,
context: ?*anyopaque,
enumerator: ?*mmdevice.IMMDeviceEnumerator,
listener: ?Listener,
mutex: sync.Mutex,
references: std.atomic.Value(u32),

const Events = @This();

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

pub fn init(events: *Events) void {
    events.* = .{
        .client = .{ .vtable = &vtable },
        .context = null,
        .enumerator = null,
        .listener = null,
        .mutex = .{},
        .references = .init(1),
    };

    assert(events.client.vtable == &vtable);
    assert(events.enumerator == null);
}

pub fn subscribe(events: *Events, handler: Listener, owner: *anyopaque) com.Error!void {
    events.mutex.lock();
    defer events.mutex.unlock();

    assert(events.enumerator == null);

    const created = try mmdevice.create_enumerator();
    errdefer created.release();

    events.listener = handler;
    events.context = owner;
    errdefer {
        events.listener = null;
        events.context = null;
    }

    try created.register(&events.client);

    events.enumerator = created;

    assert(events.enumerator != null);
}

pub fn unsubscribe(events: *Events) void {
    events.mutex.lock();

    const registered = events.enumerator orelse {
        events.mutex.unlock();

        return;
    };

    events.enumerator = null;

    events.mutex.unlock();

    registered.unregister(&events.client);
    registered.release();

    events.mutex.lock();
    defer events.mutex.unlock();

    events.listener = null;
    events.context = null;

    assert(events.enumerator == null);
}

pub fn is_subscribed(events: *Events) bool {
    events.mutex.lock();
    defer events.mutex.unlock();

    return events.enumerator != null;
}

fn deliver(events: *const Events, event: Device.Event, direction: ?Direction) void {
    assert(event.is_valid());
    if (event != .default_changed) assert(direction == null);

    const handler = events.listener orelse return;
    const owner = events.context orelse return;

    handler(owner, event, direction);
}

fn from_client(this: *anyopaque) *Events {
    const client: *mmdevice.NotificationClient = @ptrCast(@alignCast(this));

    assert(client.vtable == &vtable);

    return @fieldParentPtr("client", client);
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

    _ = from_client(this).references.fetchAdd(1, .monotonic);

    return com.s_ok;
}

fn add_ref(this: *anyopaque) callconv(.winapi) u32 {
    return from_client(this).references.fetchAdd(1, .monotonic) + 1;
}

fn drop_ref(this: *anyopaque) callconv(.winapi) u32 {
    const previous = from_client(this).references.fetchSub(1, .monotonic);

    assert(previous > 0);

    return previous - 1;
}

fn on_device_state_changed(
    this: *anyopaque,
    id: ?[*:0]const u16,
    state: mmdevice.DeviceStates,
) callconv(.winapi) com.HRESULT {
    _ = id;
    _ = state;

    from_client(this).deliver(.state_changed, null);

    return com.s_ok;
}

fn on_device_added(this: *anyopaque, id: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
    _ = id;

    from_client(this).deliver(.added, null);

    return com.s_ok;
}

fn on_device_removed(this: *anyopaque, id: ?[*:0]const u16) callconv(.winapi) com.HRESULT {
    _ = id;

    from_client(this).deliver(.removed, null);

    return com.s_ok;
}

fn on_default_device_changed(
    this: *anyopaque,
    flow: mmdevice.DataFlow,
    role: mmdevice.Role,
    id: ?[*:0]const u16,
) callconv(.winapi) com.HRESULT {
    _ = id;

    if (role != .console) {
        return com.s_ok;
    }

    from_client(this).deliver(.default_changed, mmdevice.to_direction(flow));

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
