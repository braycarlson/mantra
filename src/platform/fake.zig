const std = @import("std");

const device_module = @import("../device.zig");
const interface = @import("interface.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = interface.Listener;
const PlatformError = interface.PlatformError;
const RequestError = device_module.RequestError;

calls: [call_count]u32,
defaults: [direction_count]?u32,
entries: [entries_max]Entry,
entry_count: u32,
fault: Fault,
opened: bool,
subscriber: ?Listener,
subscriber_context: ?*anyopaque,

const Fake = @This();

pub const Call = enum(u8) {
    control_get_volume = 0,
    control_is_muted = 1,
    control_set_mute = 2,
    control_set_volume = 3,
    deinit = 4,
    devices_default = 5,
    devices_enumerate = 6,
    devices_set_default = 7,
    events_subscribe = 8,
    events_unsubscribe = 9,
    init = 10,
};

pub const Entry = struct {
    id: Device.Id,
    muted: bool,
    name: [device_module.name_bytes_max]u8,
    name_len: u16,
    volume: f32,

    pub fn get_name(entry: *const Entry) []const u8 {
        assert(entry.name_len <= device_module.name_bytes_max);

        return entry.name[0..entry.name_len];
    }
};

pub const Fault = struct {
    armed: ?Call,

    pub fn arm(fault: *Fault, call: Call) void {
        fault.armed = call;

        assert(fault.armed.? == call);
    }

    pub fn should_fail(fault: *Fault, call: Call) bool {
        const armed = fault.armed orelse return false;

        if (armed != call) {
            return false;
        }

        fault.armed = null;

        assert(fault.armed == null);

        return true;
    }
};

pub const Options = struct {
    fault: ?Call = null,
};

pub const call_count: u32 = @typeInfo(Call).@"enum".field_names.len;
pub const direction_count: u32 = 2;
pub const entries_max: u32 = device_module.count_max;
pub const volume_default: f32 = 0.5;

comptime {
    assert(entries_max > 0);
    assert(direction_count == 2);
    assert(call_count == 11);
    assert(volume_default >= interface.volume_fraction_min);
    assert(volume_default <= interface.volume_fraction_max);

    interface.assert_backend(Fake);
}

pub fn init(fake: *Fake, options: Options) PlatformError!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);

    fake.* = .{
        .calls = @splat(0),
        .defaults = @splat(null),
        .entries = undefined,
        .entry_count = 0,
        .fault = .{ .armed = options.fault },
        .opened = false,
        .subscriber = null,
        .subscriber_context = null,
    };

    fake.install_script();
    fake.record(.init);

    if (fake.fault.should_fail(.init)) {
        return error.ServiceUnavailable;
    }

    fake.opened = true;

    assert(fake.entry_count > 0);
    assert(!fake.events_is_subscribed());
}

pub fn deinit(fake: *Fake) void {
    assert(fake.opened);

    fake.record(.deinit);
    fake.set_subscriber(null, null);
    fake.opened = false;

    assert(!fake.events_is_subscribed());
}

pub fn devices_enumerate(
    fake: *Fake,
    list: *Device.List,
    direction: Direction,
) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());
    assert(fake.opened);

    fake.record(.devices_enumerate);

    if (fake.fault.should_fail(.devices_enumerate)) {
        return error.CallFailed;
    }

    try fake.fill(list, direction);
}

pub fn devices_default(
    fake: *Fake,
    direction: Direction,
) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());
    assert(fake.opened);

    fake.record(.devices_default);

    if (fake.fault.should_fail(.devices_default)) {
        return error.CallFailed;
    }

    const index = fake.default_index(direction) orelse return error.DefaultMissing;
    const result = fake.entry_at(index).id;

    assert(result.is_valid());
    assert(result.direction == direction);

    return result;
}

pub fn devices_set_default(fake: *Fake, id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(fake.opened);

    fake.record(.devices_set_default);

    if (fake.fault.should_fail(.devices_set_default)) {
        return error.CallFailed;
    }

    const index = fake.index_of(id) orelse return error.DeviceUnknown;

    fake.set_default_index(id.direction, index);

    assert(fake.default_index(id.direction).? == index);
}

pub fn control_is_muted(fake: *Fake, id: *const Device.Id) (PlatformError || RequestError)!bool {
    assert(id.is_valid());

    fake.record(.control_is_muted);

    if (fake.fault.should_fail(.control_is_muted)) {
        return error.CallFailed;
    }

    const entry = try fake.lookup(id);
    return entry.muted;
}

pub fn control_set_mute(
    fake: *Fake,
    id: *const Device.Id,
    muted: bool,
) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    fake.record(.control_set_mute);

    if (fake.fault.should_fail(.control_set_mute)) {
        return error.CallFailed;
    }

    const entry = try fake.lookup(id);

    entry.muted = muted;

    assert(entry.muted == muted);
}

pub fn control_get_volume(fake: *Fake, id: *const Device.Id) (PlatformError || RequestError)!f32 {
    assert(id.is_valid());

    fake.record(.control_get_volume);

    if (fake.fault.should_fail(.control_get_volume)) {
        return error.CallFailed;
    }

    const entry = try fake.lookup(id);
    const result = interface.clamp_volume(entry.volume);

    assert(result >= interface.volume_fraction_min);
    assert(result <= interface.volume_fraction_max);

    return result;
}

pub fn control_set_volume(
    fake: *Fake,
    id: *const Device.Id,
    level: f32,
) (PlatformError || RequestError)!void {
    assert(id.is_valid());

    fake.record(.control_set_volume);

    if (fake.fault.should_fail(.control_set_volume)) {
        return error.CallFailed;
    }

    const entry = try fake.lookup(id);

    entry.volume = interface.clamp_volume(level);

    assert(entry.volume >= interface.volume_fraction_min);
    assert(entry.volume <= interface.volume_fraction_max);
}

pub fn events_subscribe(fake: *Fake, listener: Listener, context: *anyopaque) PlatformError!void {
    assert(fake.opened);
    assert(!fake.events_is_subscribed());

    fake.record(.events_subscribe);

    if (fake.fault.should_fail(.events_subscribe)) {
        return error.CallFailed;
    }

    fake.set_subscriber(listener, context);

    assert(fake.events_is_subscribed());
}

pub fn events_unsubscribe(fake: *Fake) void {
    fake.record(.events_unsubscribe);
    fake.set_subscriber(null, null);

    assert(!fake.events_is_subscribed());
}

pub fn events_is_subscribed(fake: *Fake) bool {
    if (fake.subscriber == null) assert(fake.subscriber_context == null);

    return fake.subscriber != null;
}

pub fn add(fake: *Fake, direction: Direction, id_text: []const u8, name: []const u8) void {
    assert(direction.is_valid());
    assert(id_text.len > 0);
    assert(fake.entry_count < entries_max);

    const id = Device.Id.init(direction, id_text) catch {
        return;
    };

    const length: u16 = @intCast(@min(name.len, device_module.name_bytes_max));

    var entry = Entry{
        .id = id,
        .muted = false,
        .name = @splat(0),
        .name_len = length,
        .volume = volume_default,
    };

    @memcpy(entry.name[0..length], name[0..length]);

    fake.entries[fake.entry_count] = entry;
    fake.entry_count += 1;

    assert(fake.entry_count <= entries_max);
}

pub fn remove(fake: *Fake, id: *const Device.Id) void {
    assert(id.is_valid());

    const index = fake.index_of(id) orelse return;

    assert(index < fake.entry_count);

    var cursor = index;

    while (cursor + 1 < fake.entry_count) : (cursor += 1) {
        assert(cursor + 1 < entries_max);

        fake.entries[cursor] = fake.entries[cursor + 1];
    }

    fake.entry_count -= 1;

    var slot: u32 = 0;

    while (slot < direction_count) : (slot += 1) {
        const current = fake.defaults[slot] orelse continue;

        if (current == index) {
            fake.defaults[slot] = null;

            continue;
        }

        if (current > index) {
            fake.defaults[slot] = current - 1;
        }
    }
}

pub fn emit(fake: *const Fake, event: Device.Event, direction: ?Direction) void {
    assert(event.is_valid());

    const listener = fake.subscriber orelse return;
    const context = fake.subscriber_context orelse return;

    listener(context, event, direction);
}

pub fn count(fake: *const Fake) u32 {
    assert(fake.entry_count <= entries_max);

    return fake.entry_count;
}

pub fn count_of(fake: *const Fake, call: Call) u32 {
    const index = @backingInt(call);

    assert(index < call_count);

    return fake.calls[index];
}

pub fn entry_at(fake: *Fake, index: u32) *Entry {
    assert(index < fake.entry_count);
    assert(index < entries_max);

    return &fake.entries[index];
}

pub fn default_index(fake: *const Fake, direction: Direction) ?u32 {
    assert(direction.is_valid());

    return fake.defaults[@backingInt(direction)];
}

fn install_script(fake: *Fake) void {
    assert(fake.entry_count == 0);

    fake.add(.capture, "fake-capture-0", "Fake Microphone");
    fake.add(.capture, "fake-capture-1", "Fake Headset Microphone");
    fake.add(.render, "fake-render-0", "Fake Speakers");
    fake.add(.render, "fake-render-1", "Fake Headphones");

    fake.set_default_index(.capture, 0);
    fake.set_default_index(.render, 2);

    assert(fake.entry_count == 4);
}

fn record(fake: *Fake, call: Call) void {
    const index = @backingInt(call);

    assert(index < call_count);

    fake.calls[index] += 1;
}

fn fill(fake: *const Fake, list: *Device.List, direction: Direction) CapacityError!void {
    assert(direction.is_valid());

    list.clear();

    const chosen = fake.default_index(direction);

    var index: u32 = 0;

    while (index < fake.entry_count) : (index += 1) {
        assert(index < entries_max);

        const entry = &fake.entries[index];

        if (entry.id.direction != direction) {
            continue;
        }

        const is_default = chosen != null and chosen.? == index;

        try list.append(Device.init(entry.id, entry.get_name(), .{ .is_default = is_default }));
    }

    assert(list.count <= entries_max);
}

fn index_of(fake: *const Fake, id: *const Device.Id) ?u32 {
    assert(id.is_valid());

    var index: u32 = 0;

    while (index < fake.entry_count) : (index += 1) {
        assert(index < entries_max);

        if (fake.entries[index].id.eql(id)) {
            return index;
        }
    }

    return null;
}

fn lookup(fake: *Fake, id: *const Device.Id) RequestError!*Entry {
    assert(fake.opened);
    assert(id.is_valid());

    const index = fake.index_of(id) orelse return error.DeviceUnknown;
    return fake.entry_at(index);
}

fn set_default_index(fake: *Fake, direction: Direction, index: u32) void {
    assert(direction.is_valid());
    assert(index < fake.entry_count);

    fake.defaults[@backingInt(direction)] = index;
}

fn set_subscriber(fake: *Fake, listener: ?Listener, context: ?*anyopaque) void {
    if (listener != null) assert(context != null);
    if (listener == null) assert(context == null);

    fake.subscriber = listener;
    fake.subscriber_context = context;
}

const testing = std.testing;

test "init installs the script and opens the fake" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    try testing.expectEqual(@as(u32, 4), fake.count());
    try testing.expect(fake.opened);
    try testing.expectEqual(@as(u32, 1), fake.count_of(.init));
    try testing.expect(fake.default_index(.capture) != null);
    try testing.expect(fake.default_index(.render) != null);
}

test "removing an entry shifts the defaults that sat behind it" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const removed = fake.entry_at(0).id;

    fake.remove(&removed);

    try testing.expectEqual(@as(u32, 3), fake.count());
    try testing.expectEqual(@as(?u32, null), fake.default_index(.capture));
    try testing.expectEqual(@as(?u32, 1), fake.default_index(.render));
}

test "a scripted failure fires once, and only for its own call" {
    var fault: Fault = .{ .armed = null };

    fault.arm(.init);

    try testing.expect(!fault.should_fail(.deinit));
    try testing.expect(fault.should_fail(.init));
    try testing.expect(!fault.should_fail(.init));
}

test "lookup finds an installed device and names a missing one unknown" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const id = fake.entry_at(0).id;
    const found = try fake.lookup(&id);

    try testing.expect(found.id.eql(&id));

    const absent = try Device.Id.init(.render, "fake.absent");

    try testing.expectError(error.DeviceUnknown, fake.lookup(&absent));
}

test "fill returns one direction and marks exactly one default" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    var list = Device.List.init();

    try fake.fill(&list, .render);

    try testing.expectEqual(@as(u32, 2), list.count);

    var marked: u32 = 0;

    for (list.slice()) |device| {
        try testing.expectEqual(Direction.render, device.id.direction);

        if (device.is_default) marked += 1;
    }

    try testing.expectEqual(@as(u32, 1), marked);
}

test "emit reaches the installed subscriber and stops once it is cleared" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    var witness = Witness{};

    try testing.expect(!fake.events_is_subscribed());

    fake.set_subscriber(Witness.observe, &witness);

    try testing.expect(fake.events_is_subscribed());

    fake.emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), witness.seen);

    fake.set_subscriber(null, null);

    fake.emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), witness.seen);
}

test "the fake records both halves of the lifecycle" {
    var fake: Fake = undefined;

    try fake.init(.{});

    try testing.expect(fake.opened);

    fake.deinit();

    try testing.expect(!fake.opened);
    try testing.expectEqual(@as(u32, 1), fake.count_of(.init));
    try testing.expectEqual(@as(u32, 1), fake.count_of(.deinit));
}

test "a scripted failure leaves the fake closed" {
    var fake: Fake = undefined;

    try testing.expectError(error.ServiceUnavailable, fake.init(.{ .fault = .init }));
    try testing.expect(!fake.opened);
}

test "deinit drops whatever subscriber was installed" {
    var fake: Fake = undefined;

    try fake.init(.{});

    var witness = Witness{};

    fake.set_subscriber(Witness.observe, &witness);

    try testing.expect(fake.events_is_subscribed());

    fake.deinit();

    try testing.expect(!fake.events_is_subscribed());
}

test "enumeration returns one direction at a time" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    var render = Device.List.init();
    var capture = Device.List.init();

    try fake.devices_enumerate(&render, .render);
    try fake.devices_enumerate(&capture, .capture);

    try testing.expectEqual(@as(u32, 2), render.count);
    try testing.expectEqual(@as(u32, 2), capture.count);
}

test "the default device follows whichever device was set" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const first = try fake.devices_default(.render);
    const other = fake.entry_at(3).id;

    try fake.devices_set_default(&other);

    const moved = try fake.devices_default(.render);

    try testing.expect(!moved.eql(&first));
    try testing.expect(moved.eql(&other));
}

test "a device the script never installed is unknown" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const absent = try Device.Id.init(.render, "fake.absent");

    try testing.expectError(error.DeviceUnknown, fake.devices_set_default(&absent));
}

test "mute and volume round trip through the entry" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const id = fake.entry_at(0).id;

    try fake.control_set_mute(&id, true);
    try testing.expect(try fake.control_is_muted(&id));

    try fake.control_set_volume(&id, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.25), try fake.control_get_volume(&id), 0.001);
}

test "a level outside the interface bounds is clamped on the way in" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const id = fake.entry_at(0).id;

    try fake.control_set_volume(&id, 4.0);

    try testing.expectApproxEqAbs(
        interface.volume_fraction_max,
        try fake.control_get_volume(&id),
        0.001,
    );

    try fake.control_set_volume(&id, -1.0);

    try testing.expectApproxEqAbs(
        interface.volume_fraction_min,
        try fake.control_get_volume(&id),
        0.001,
    );
}

test "a scripted failure surfaces before the entry is touched" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    const id = fake.entry_at(0).id;

    fake.fault.arm(.control_is_muted);

    try testing.expectError(error.CallFailed, fake.control_is_muted(&id));
    try testing.expect(!try fake.control_is_muted(&id));
}

test "one subscriber at a time, and unsubscribe clears it" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    var witness = Witness{};

    try fake.events_subscribe(Witness.observe, &witness);

    try testing.expect(fake.events_is_subscribed());

    fake.emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), witness.seen);

    fake.events_unsubscribe();

    try testing.expect(!fake.events_is_subscribed());
}

test "a scripted failure leaves no subscriber behind" {
    var fake: Fake = undefined;

    try fake.init(.{});
    defer fake.deinit();

    fake.fault.arm(.events_subscribe);

    var witness = Witness{};

    try testing.expectError(error.CallFailed, fake.events_subscribe(Witness.observe, &witness));
    try testing.expect(!fake.events_is_subscribed());
}

const Witness = struct {
    seen: u32 = 0,

    fn observe(context: *anyopaque, event: Device.Event, _: ?Direction) void {
        assert(event.is_valid());

        const witness: *Witness = @ptrCast(@alignCast(context));

        witness.seen += 1;
    }
};
