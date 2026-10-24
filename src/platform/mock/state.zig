const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const Listener = contract.Listener;
const RequestError = device_module.RequestError;

pub const entries_max: u32 = device_module.device_count_max;
pub const direction_count: u32 = 2;
pub const volume_default: f32 = 0.5;

pub const Call = enum(u8) {
    close = 0,
    default = 1,
    enumerate = 2,
    get_volume = 3,
    is_muted = 4,
    open = 5,
    set_default = 6,
    set_mute = 7,
    set_volume = 8,
    subscribe = 9,
    unsubscribe = 10,
};

pub const call_count: u32 = @typeInfo(Call).@"enum".field_names.len;

comptime {
    assert(entries_max > 0);
    assert(direction_count == 2);
    assert(call_count == 11);
    assert(volume_default >= contract.volume_fraction_min);
    assert(volume_default <= contract.volume_fraction_max);
}

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

var counts: [call_count]u32 = @splat(0);
var defaults: [direction_count]?u32 = @splat(null);
var entries: [entries_max]Entry = undefined;
var entry_count: u32 = 0;
var failure: ?Call = null;
var opened: bool = false;
var subscriber: ?Listener = null;
var subscriber_context: ?*anyopaque = null;

pub fn reset() void {
    clear();
    install_script();

    assert(entry_count > 0);
    assert(!opened);
}

pub fn clear() void {
    counts = @splat(0);
    defaults = @splat(null);
    entry_count = 0;
    failure = null;
    opened = false;
    subscriber = null;
    subscriber_context = null;

    assert(entry_count == 0);
    assert(subscriber == null);
}

pub fn install_script() void {
    add(.capture, "mock-capture-0", "Mock Microphone");
    add(.capture, "mock-capture-1", "Mock Headset Microphone");
    add(.render, "mock-render-0", "Mock Speakers");
    add(.render, "mock-render-1", "Mock Headphones");

    set_default_index(.capture, 0);
    set_default_index(.render, 2);

    assert(entry_count == 4);
}

pub fn add(direction: Direction, id_text: []const u8, name: []const u8) void {
    assert(direction.is_valid());
    assert(id_text.len > 0);
    assert(entry_count < entries_max);

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

    entries[entry_count] = entry;
    entry_count += 1;

    assert(entry_count <= entries_max);
}

pub fn remove(id: *const Device.Id) void {
    assert(id.is_valid());

    const index = index_of(id) orelse return;

    assert(index < entry_count);

    var cursor = index;

    while (cursor + 1 < entry_count) : (cursor += 1) {
        assert(cursor + 1 < entries_max);

        entries[cursor] = entries[cursor + 1];
    }

    entry_count -= 1;

    var slot: u32 = 0;

    while (slot < direction_count) : (slot += 1) {
        const current = defaults[slot] orelse continue;

        if (current == index) {
            defaults[slot] = null;

            continue;
        }

        if (current > index) {
            defaults[slot] = current - 1;
        }
    }
}

pub fn count() u32 {
    assert(entry_count <= entries_max);

    return entry_count;
}

pub fn count_of(call: Call) u32 {
    const index = @backingInt(call);

    assert(index < call_count);

    return counts[index];
}

pub fn record(call: Call) void {
    const index = @backingInt(call);

    assert(index < call_count);

    counts[index] += 1;
}

pub fn fail_next(call: ?Call) void {
    failure = call;
}

pub fn should_fail(call: Call) bool {
    const pending = failure orelse return false;

    if (pending != call) {
        return false;
    }

    failure = null;

    return true;
}

pub fn is_open() bool {
    return opened;
}

pub fn mark_open() void {
    assert(!opened);

    opened = true;
}

pub fn mark_closed() void {
    opened = false;

    assert(!opened);
}

pub fn entry_at(index: u32) *Entry {
    assert(index < entry_count);
    assert(index < entries_max);

    return &entries[index];
}

pub fn index_of(id: *const Device.Id) ?u32 {
    assert(id.is_valid());

    var index: u32 = 0;

    while (index < entry_count) : (index += 1) {
        assert(index < entries_max);

        if (entries[index].id.eql(id)) {
            return index;
        }
    }

    return null;
}

pub fn lookup(id: *const Device.Id) RequestError!*Entry {
    assert(opened);
    assert(id.is_valid());

    const index = index_of(id) orelse return error.DeviceUnknown;
    return entry_at(index);
}

pub fn set_default_index(direction: Direction, index: u32) void {
    assert(direction.is_valid());
    assert(index < entry_count);

    defaults[@backingInt(direction)] = index;
}

pub fn default_index(direction: Direction) ?u32 {
    assert(direction.is_valid());

    return defaults[@backingInt(direction)];
}

pub fn fill(list: *Device.List, direction: Direction) CapacityError!void {
    assert(direction.is_valid());

    list.clear();

    const chosen = default_index(direction);

    var index: u32 = 0;

    while (index < entry_count) : (index += 1) {
        assert(index < entries_max);

        const entry = &entries[index];

        if (entry.id.direction != direction) {
            continue;
        }

        const is_default = chosen != null and chosen.? == index;

        try list.append(Device.init(entry.id, entry.get_name(), .{ .is_default = is_default }));
    }

    assert(list.count <= entries_max);
}

pub fn set_subscriber(listener: ?Listener, context: ?*anyopaque) void {
    subscriber = listener;
    subscriber_context = context;
}

pub fn has_subscriber() bool {
    return subscriber != null;
}

pub fn emit(event: Device.Event, direction: ?Direction) void {
    assert(event.is_valid());

    const listener = subscriber orelse return;
    const context = subscriber_context orelse return;

    listener(context, event, direction);
}

const testing = std.testing;

test "reset installs the script and leaves the runtime closed" {
    reset();
    defer clear();

    try testing.expectEqual(@as(u32, 4), count());
    try testing.expect(!is_open());
    try testing.expectEqual(@as(u32, 0), count_of(.open));
    try testing.expect(default_index(.capture) != null);
    try testing.expect(default_index(.render) != null);
}

test "removing an entry shifts the defaults that sat behind it" {
    reset();
    defer clear();

    const removed = entry_at(0).id;

    remove(&removed);

    try testing.expectEqual(@as(u32, 3), count());
    try testing.expectEqual(@as(?u32, null), default_index(.capture));
    try testing.expectEqual(@as(?u32, 1), default_index(.render));
}

test "a scripted failure fires once, and only for its own call" {
    reset();
    defer clear();

    fail_next(.open);

    try testing.expect(!should_fail(.close));
    try testing.expect(should_fail(.open));
    try testing.expect(!should_fail(.open));
}

test "lookup finds an installed device and names a missing one unknown" {
    reset();
    defer clear();

    mark_open();

    const id = entry_at(0).id;
    const found = try lookup(&id);

    try testing.expect(found.id.eql(&id));

    const absent = try Device.Id.init(.render, "mock.absent");

    try testing.expectError(error.DeviceUnknown, lookup(&absent));
}

test "fill returns one direction and marks exactly one default" {
    reset();
    defer clear();

    var list = Device.List.init();

    try fill(&list, .render);

    try testing.expectEqual(@as(u32, 2), list.count);

    var marked: u32 = 0;

    for (list.slice()) |device| {
        try testing.expectEqual(Direction.render, device.id.direction);

        if (device.is_default) marked += 1;
    }

    try testing.expectEqual(@as(u32, 1), marked);
}

test "emit reaches the installed subscriber and stops once it is cleared" {
    reset();
    defer clear();

    var witness = Witness{};

    try testing.expect(!has_subscriber());

    set_subscriber(Witness.observe, &witness);

    try testing.expect(has_subscriber());

    emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), witness.seen);

    set_subscriber(null, null);

    emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), witness.seen);
}

const Witness = struct {
    seen: u32 = 0,

    fn observe(context: *anyopaque, _: Device.Event, _: ?Direction) void {
        const witness: *Witness = @ptrCast(@alignCast(context));

        witness.seen += 1;
    }
};
