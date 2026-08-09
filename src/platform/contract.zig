const std = @import("std");

const assert = std.debug.assert;

pub const devices_max: u32 = 32;
pub const id_bytes_max: u32 = 512;
pub const name_bytes_max: u32 = 256;

pub const volume_min: f32 = 0.0;
pub const volume_max: f32 = 1.0;

comptime {
    assert(devices_max > 0);
    assert(id_bytes_max > name_bytes_max);
    assert(name_bytes_max > 0);
    assert(volume_min < volume_max);
}

pub const Capabilities = struct {
    default_selection: bool,
    events: bool,
};

pub const capability_count: u8 = @typeInfo(Capabilities).@"struct".fields.len;

pub const Direction = enum(u8) {
    capture = 0,
    render = 1,

    pub fn is_valid(direction: Direction) bool {
        return @intFromEnum(direction) <= @intFromEnum(Direction.render);
    }

    pub fn to_string(direction: Direction) []const u8 {
        const result = switch (direction) {
            .capture => "capture",
            .render => "render",
        };

        assert(result.len > 0);

        return result;
    }
};

pub const DeviceEvent = enum(u8) {
    added = 0,
    removed = 1,
    state_changed = 2,
    default_changed = 3,

    pub fn is_valid(event: DeviceEvent) bool {
        return @intFromEnum(event) <= @intFromEnum(DeviceEvent.default_changed);
    }

    pub fn to_string(event: DeviceEvent) []const u8 {
        const result = switch (event) {
            .added => "added",
            .removed => "removed",
            .state_changed => "state_changed",
            .default_changed => "default_changed",
        };

        assert(result.len > 0);

        return result;
    }
};

pub const DeviceId = struct {
    bytes: [id_bytes_max]u8 = [_]u8{0} ** id_bytes_max,
    direction: Direction = .capture,
    len: u16 = 0,

    pub fn init(direction: Direction, text: []const u8) DeviceError!DeviceId {
        assert(direction.is_valid());

        if (text.len == 0 or text.len > id_bytes_max) {
            return DeviceError.Invalid;
        }

        var result = DeviceId{ .direction = direction, .len = @intCast(text.len) };

        @memcpy(result.bytes[0..text.len], text);

        assert(result.is_valid());

        return result;
    }

    pub fn eql(id: *const DeviceId, other: *const DeviceId) bool {
        if (id.direction != other.direction) {
            return false;
        }

        return std.mem.eql(u8, id.slice(), other.slice());
    }

    pub fn is_valid(id: *const DeviceId) bool {
        if (!id.direction.is_valid()) {
            return false;
        }

        return id.len > 0 and id.len <= id_bytes_max;
    }

    pub fn slice(id: *const DeviceId) []const u8 {
        assert(id.len <= id_bytes_max);

        return id.bytes[0..id.len];
    }
};

pub const DeviceInfo = struct {
    id: DeviceId = .{},
    is_default: bool = false,
    name: [name_bytes_max]u8 = [_]u8{0} ** name_bytes_max,
    name_len: u16 = 0,

    pub fn init(id: DeviceId, name: []const u8, is_default: bool) DeviceInfo {
        assert(id.is_valid());

        var result = DeviceInfo{ .id = id, .is_default = is_default };

        result.set_name(name);

        assert(result.is_valid());

        return result;
    }

    pub fn get_name(info: *const DeviceInfo) []const u8 {
        assert(info.name_len <= name_bytes_max);

        return info.name[0..info.name_len];
    }

    pub fn is_valid(info: *const DeviceInfo) bool {
        if (!info.id.is_valid()) {
            return false;
        }

        return info.name_len <= name_bytes_max;
    }

    pub fn set_name(info: *DeviceInfo, name: []const u8) void {
        const length: u16 = @intCast(@min(name.len, name_bytes_max));

        @memcpy(info.name[0..length], name[0..length]);

        info.name_len = length;

        assert(info.name_len <= name_bytes_max);
    }
};

pub const DeviceList = struct {
    count: u32 = 0,
    items: [devices_max]DeviceInfo = [_]DeviceInfo{.{}} ** devices_max,

    pub fn init() DeviceList {
        const result = DeviceList{};

        assert(result.is_empty());

        return result;
    }

    pub fn append(list: *DeviceList, info: DeviceInfo) DeviceError!void {
        assert(info.is_valid());

        if (list.count >= devices_max) {
            return DeviceError.TooMany;
        }

        list.items[list.count] = info;
        list.count += 1;

        assert(list.count <= devices_max);
    }

    pub fn clear(list: *DeviceList) void {
        list.count = 0;

        assert(list.is_empty());
    }

    pub fn find(list: *const DeviceList, id: *const DeviceId) ?*const DeviceInfo {
        assert(id.is_valid());

        var index: u32 = 0;

        while (index < list.count) : (index += 1) {
            assert(index < devices_max);

            if (list.items[index].id.eql(id)) {
                return &list.items[index];
            }
        }

        return null;
    }

    pub fn is_empty(list: *const DeviceList) bool {
        return list.count == 0;
    }

    pub fn slice(list: *const DeviceList) []const DeviceInfo {
        assert(list.count <= devices_max);

        return list.items[0..list.count];
    }
};

pub const EventCallback = *const fn (DeviceEvent, ?Direction, ?*anyopaque) void;

pub const RuntimeError = error{
    AlreadyOpen,
    Denied,
    Failed,
    Unavailable,
};

pub const DeviceError = error{
    Failed,
    Invalid,
    NotFound,
    NotOpen,
    TooMany,
};

pub const ControlError = error{
    Denied,
    Failed,
    Invalid,
    NotFound,
    NotOpen,
};

pub const EventError = error{
    AlreadySubscribed,
    Failed,
    NotOpen,
};

pub fn clamp_volume(level: f32) f32 {
    if (std.math.isNan(level)) {
        return volume_min;
    }

    const result = std.math.clamp(level, volume_min, volume_max);

    assert(result >= volume_min);
    assert(result <= volume_max);

    return result;
}

pub fn assert_backend(comptime backend: type) void {
    comptime {
        require_decl(backend, "capabilities", "backend");

        const capabilities = backend.capabilities;

        if (@TypeOf(capabilities) != Capabilities) {
            @compileError("mantra backend capabilities must be a Capabilities value");
        }

        assert_runtime(backend);
        assert_devices(backend);
        assert_control(backend);
        assert_events(backend);
    }
}

fn assert_runtime(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "runtime", "backend");

    require_error_set(scope, "Error", RuntimeError, "runtime");

    require_fn(scope, "open", fn () RuntimeError!void, "runtime");
    require_fn(scope, "close", fn () void, "runtime");
    require_fn(scope, "is_open", fn () bool, "runtime");
}

fn assert_devices(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "devices", "backend");

    require_error_set(scope, "Error", DeviceError, "devices");

    require_fn(
        scope,
        "enumerate",
        fn (Direction, *DeviceList) DeviceError!void,
        "devices",
    );

    require_fn(scope, "default", fn (Direction) DeviceError!DeviceId, "devices");
    require_fn(scope, "set_default", fn (*const DeviceId) DeviceError!void, "devices");
}

fn assert_control(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "control", "backend");

    require_error_set(scope, "Error", ControlError, "control");

    require_fn(scope, "is_muted", fn (*const DeviceId) ControlError!bool, "control");
    require_fn(scope, "set_mute", fn (*const DeviceId, bool) ControlError!void, "control");
    require_fn(scope, "get_volume", fn (*const DeviceId) ControlError!f32, "control");
    require_fn(scope, "set_volume", fn (*const DeviceId, f32) ControlError!void, "control");
}

fn assert_events(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "events", "backend");

    require_error_set(scope, "Error", EventError, "events");

    require_fn(
        scope,
        "subscribe",
        fn (EventCallback, ?*anyopaque) EventError!void,
        "events",
    );

    require_fn(scope, "unsubscribe", fn () void, "events");
    require_fn(scope, "is_subscribed", fn () bool, "events");
}

fn RequiredNamespaceType(
    comptime scope: type,
    comptime name: []const u8,
    comptime label: []const u8,
) type {
    require_decl(scope, name, label);

    const Namespace = @field(scope, name);

    if (@TypeOf(Namespace) != type) {
        @compileError(
            "mantra backend " ++ label ++ "." ++ name ++ " must be a namespace, found " ++
                @typeName(@TypeOf(Namespace)),
        );
    }

    return Namespace;
}

fn require_decl(comptime scope: type, comptime name: []const u8, comptime label: []const u8) void {
    if (!@hasDecl(scope, name)) {
        @compileError("mantra backend " ++ label ++ " is missing declaration '" ++ name ++ "'");
    }
}

fn require_fn(
    comptime scope: type,
    comptime name: []const u8,
    comptime Signature: type,
    comptime label: []const u8,
) void {
    require_decl(scope, name, label);

    const Actual = @TypeOf(@field(scope, name));

    if (Actual != Signature) {
        @compileError(
            "mantra backend " ++ label ++ "." ++ name ++ " has type " ++ @typeName(Actual) ++
                ", expected " ++ @typeName(Signature),
        );
    }
}

fn require_error_set(
    comptime scope: type,
    comptime name: []const u8,
    comptime Expected: type,
    comptime label: []const u8,
) void {
    require_decl(scope, name, label);

    const Actual = @field(scope, name);

    if (Actual != Expected) {
        @compileError(
            "mantra backend " ++ label ++ "." ++ name ++ " is " ++ @typeName(Actual) ++
                ", expected the canonical set " ++ @typeName(Expected),
        );
    }
}

const testing = std.testing;

test "the capability set is fixed" {
    try testing.expectEqual(@as(u8, 2), capability_count);
}

test "every direction and event names itself" {
    try testing.expectEqualStrings("capture", Direction.capture.to_string());
    try testing.expectEqualStrings("render", Direction.render.to_string());
    try testing.expectEqualStrings("added", DeviceEvent.added.to_string());
    try testing.expectEqualStrings("default_changed", DeviceEvent.default_changed.to_string());
    try testing.expect(Direction.capture.is_valid());
    try testing.expect(DeviceEvent.removed.is_valid());
}

test "an identifier carries its direction and rejects the empty name" {
    const id = try DeviceId.init(.render, "alsa_output.pci-0000_00_1f.3.analog-stereo");

    try testing.expect(id.is_valid());
    try testing.expectEqual(Direction.render, id.direction);
    try testing.expectEqualStrings("alsa_output.pci-0000_00_1f.3.analog-stereo", id.slice());

    try testing.expectError(DeviceError.Invalid, DeviceId.init(.render, ""));
}

test "an identifier longer than the field is rejected rather than truncated" {
    const text = "x" ** (id_bytes_max + 1);

    try testing.expectError(DeviceError.Invalid, DeviceId.init(.capture, text));
}

test "identifiers of different directions never compare equal" {
    const capture = try DeviceId.init(.capture, "shared");
    const render = try DeviceId.init(.render, "shared");
    const same = try DeviceId.init(.capture, "shared");

    try testing.expect(!capture.eql(&render));
    try testing.expect(capture.eql(&same));
}

test "a device name longer than the field is truncated rather than overflowing" {
    const id = try DeviceId.init(.capture, "id");
    const name = "n" ** (name_bytes_max + 64);

    const info = DeviceInfo.init(id, name, false);

    try testing.expectEqual(@as(u16, name_bytes_max), info.name_len);
    try testing.expectEqual(@as(usize, name_bytes_max), info.get_name().len);
}

test "a list fills to its bound and then reports the overflow" {
    var list = DeviceList.init();

    try testing.expect(list.is_empty());

    var index: u32 = 0;

    while (index < devices_max) : (index += 1) {
        var text: [16]u8 = undefined;

        const name = try std.fmt.bufPrint(&text, "device-{d}", .{index});
        const id = try DeviceId.init(.capture, name);

        try list.append(DeviceInfo.init(id, name, false));
    }

    try testing.expectEqual(devices_max, list.count);
    try testing.expectEqual(@as(usize, devices_max), list.slice().len);

    const extra = try DeviceId.init(.capture, "one-too-many");

    try testing.expectError(
        DeviceError.TooMany,
        list.append(DeviceInfo.init(extra, "one-too-many", false)),
    );

    list.clear();

    try testing.expect(list.is_empty());
}

test "a list finds by identifier and reports a miss" {
    var list = DeviceList.init();

    const first = try DeviceId.init(.render, "first");
    const second = try DeviceId.init(.render, "second");
    const absent = try DeviceId.init(.render, "absent");

    try list.append(DeviceInfo.init(first, "First", true));
    try list.append(DeviceInfo.init(second, "Second", false));

    const found = list.find(&second) orelse return error.MissingDevice;

    try testing.expectEqualStrings("Second", found.get_name());
    try testing.expect(list.find(&absent) == null);
}

test "volume clamping keeps every input inside the contract bounds" {
    try testing.expectEqual(volume_min, clamp_volume(-1.0));
    try testing.expectEqual(volume_max, clamp_volume(2.5));
    try testing.expectEqual(@as(f32, 0.25), clamp_volume(0.25));
    try testing.expectEqual(volume_min, clamp_volume(std.math.nan(f32)));
    try testing.expectEqual(volume_max, clamp_volume(std.math.inf(f32)));
}
