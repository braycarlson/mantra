const std = @import("std");

const contract = @import("../contract.zig");

const assert = std.debug.assert;

const ControlError = contract.ControlError;
const DeviceError = contract.DeviceError;
const DeviceEvent = contract.DeviceEvent;
const DeviceId = contract.DeviceId;
const DeviceInfo = contract.DeviceInfo;
const DeviceList = contract.DeviceList;
const Direction = contract.Direction;
const EventCallback = contract.EventCallback;

pub const entries_max: u32 = contract.devices_max;
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

pub const call_count: u32 = @typeInfo(Call).@"enum".fields.len;

comptime {
    assert(entries_max > 0);
    assert(direction_count == 2);
    assert(call_count == 11);
    assert(volume_default >= contract.volume_min);
    assert(volume_default <= contract.volume_max);
}

pub const Entry = struct {
    id: DeviceId = .{},
    muted: bool = false,
    name: [contract.name_bytes_max]u8 = [_]u8{0} ** contract.name_bytes_max,
    name_len: u16 = 0,
    volume: f32 = volume_default,

    pub fn get_name(entry: *const Entry) []const u8 {
        assert(entry.name_len <= contract.name_bytes_max);

        return entry.name[0..entry.name_len];
    }

    pub fn set_name(entry: *Entry, name: []const u8) void {
        const length: u16 = @intCast(@min(name.len, contract.name_bytes_max));

        @memcpy(entry.name[0..length], name[0..length]);

        entry.name_len = length;
    }
};

var counts: [call_count]u32 = [_]u32{0} ** call_count;
var defaults: [direction_count]?u32 = [_]?u32{null} ** direction_count;
var entries: [entries_max]Entry = [_]Entry{.{}} ** entries_max;
var entry_count: u32 = 0;
var failure: ?Call = null;
var opened: bool = false;
var subscriber: ?EventCallback = null;
var subscriber_context: ?*anyopaque = null;

pub fn reset() void {
    clear();
    install_script();

    assert(entry_count > 0);
    assert(!opened);
}

pub fn clear() void {
    counts = [_]u32{0} ** call_count;
    defaults = [_]?u32{null} ** direction_count;
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

    const id = DeviceId.init(direction, id_text) catch {
        return;
    };

    var entry = Entry{ .id = id };

    entry.set_name(name);

    entries[entry_count] = entry;
    entry_count += 1;

    assert(entry_count <= entries_max);
}

pub fn remove(id: *const DeviceId) void {
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
    const index = @intFromEnum(call);

    assert(index < call_count);

    return counts[index];
}

pub fn record(call: Call) void {
    const index = @intFromEnum(call);

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

pub fn set_open(value: bool) void {
    opened = value;

    assert(opened == value);
}

pub fn entry_at(index: u32) *Entry {
    assert(index < entry_count);
    assert(index < entries_max);

    return &entries[index];
}

pub fn index_of(id: *const DeviceId) ?u32 {
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

pub fn lookup(id: *const DeviceId) ControlError!*Entry {
    if (!opened) {
        return ControlError.NotOpen;
    }

    if (!id.is_valid()) {
        return ControlError.Invalid;
    }

    const index = index_of(id) orelse {
        return ControlError.NotFound;
    };

    return entry_at(index);
}

pub fn set_default_index(direction: Direction, index: u32) void {
    assert(direction.is_valid());
    assert(index < entry_count);

    defaults[@intFromEnum(direction)] = index;
}

pub fn clear_default(direction: Direction) void {
    assert(direction.is_valid());

    defaults[@intFromEnum(direction)] = null;
}

pub fn default_index(direction: Direction) ?u32 {
    assert(direction.is_valid());

    return defaults[@intFromEnum(direction)];
}

pub fn fill(direction: Direction, list: *DeviceList) DeviceError!void {
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

        try list.append(DeviceInfo.init(entry.id, entry.get_name(), is_default));
    }

    assert(list.count <= entries_max);
}

pub fn set_subscriber(callback: ?EventCallback, context: ?*anyopaque) void {
    subscriber = callback;
    subscriber_context = context;
}

pub fn has_subscriber() bool {
    return subscriber != null;
}

pub fn emit(event: DeviceEvent, direction: ?Direction) void {
    assert(event.is_valid());

    const callback = subscriber orelse return;

    callback(event, direction, subscriber_context);
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

test "lookup names the reason a device is unreachable" {
    reset();
    defer clear();

    const id = entry_at(0).id;

    try testing.expectError(ControlError.NotOpen, lookup(&id));

    set_open(true);

    const found = try lookup(&id);

    try testing.expect(found.id.eql(&id));

    const absent = try DeviceId.init(.render, "mock.absent");

    try testing.expectError(ControlError.NotFound, lookup(&absent));
}

test "fill returns one direction and marks exactly one default" {
    reset();
    defer clear();

    set_open(true);

    var list = DeviceList.init();

    try fill(.render, &list);

    try testing.expectEqual(@as(u32, 2), list.count);

    var marked: u32 = 0;

    for (list.slice()) |info| {
        try testing.expectEqual(Direction.render, info.id.direction);

        if (info.is_default) marked += 1;
    }

    try testing.expectEqual(@as(u32, 1), marked);
}

test "emit reaches the installed subscriber and stops once it is cleared" {
    reset();
    defer clear();

    Witness.seen = 0;

    try testing.expect(!has_subscriber());

    set_subscriber(Witness.observe, null);

    try testing.expect(has_subscriber());

    emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), Witness.seen);

    set_subscriber(null, null);

    emit(.added, .render);

    try testing.expectEqual(@as(u32, 1), Witness.seen);
}

const Witness = struct {
    var seen: u32 = 0;

    fn observe(_: DeviceEvent, _: ?Direction, _: ?*anyopaque) void {
        seen += 1;
    }
};
