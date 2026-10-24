const std = @import("std");

const assert = std.debug.assert;

pub const Device = struct {
    id: Id,
    is_default: bool,
    name: [name_bytes_max]u8,
    name_len: u16,

    pub const Event = enum(u8) {
        added = 0,
        removed = 1,
        state_changed = 2,
        default_changed = 3,

        pub fn is_valid(event: Event) bool {
            return @backingInt(event) <= @backingInt(Event.default_changed);
        }

        pub fn to_string(event: Event) []const u8 {
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

    pub const Id = struct {
        bytes: [id_bytes_max]u8,
        direction: Direction,
        len: u16,

        pub fn init(direction: Direction, text: []const u8) (CapacityError || RequestError)!Id {
            assert(direction.is_valid());

            if (text.len == 0) return error.IdEmpty;
            if (text.len > id_bytes_max) return error.IdTooLong;

            var result = Id{
                .bytes = @splat(0),
                .direction = direction,
                .len = @intCast(text.len),
            };

            @memcpy(result.bytes[0..text.len], text);

            assert(result.is_valid());

            return result;
        }

        pub fn eql(id: *const Id, other: *const Id) bool {
            assert(id.is_valid());
            assert(other.is_valid());

            if (id.direction != other.direction) {
                return false;
            }

            return std.mem.eql(u8, id.slice(), other.slice());
        }

        pub fn is_valid(id: *const Id) bool {
            if (!id.direction.is_valid()) {
                return false;
            }

            return id.len > 0 and id.len <= id_bytes_max;
        }

        pub fn slice(id: *const Id) []const u8 {
            assert(id.len <= id_bytes_max);

            return id.bytes[0..id.len];
        }
    };

    pub const List = struct {
        count: u32,
        items: [device_count_max]Device,

        pub fn init() List {
            const result = List{ .count = 0, .items = undefined };

            assert(result.is_empty());

            return result;
        }

        pub fn append(list: *List, device: Device) CapacityError!void {
            assert(device.is_valid());
            assert(list.count <= device_count_max);

            if (list.count == device_count_max) return error.DevicesExhausted;

            list.items[list.count] = device;
            list.count += 1;

            assert(list.count <= device_count_max);
        }

        pub fn clear(list: *List) void {
            list.count = 0;

            assert(list.is_empty());
        }

        pub fn find(list: *const List, id: *const Id) ?*const Device {
            assert(id.is_valid());

            for (list.slice()) |*device| {
                if (device.id.eql(id)) {
                    return device;
                }
            }

            return null;
        }

        pub fn is_empty(list: *const List) bool {
            return list.count == 0;
        }

        pub fn slice(list: *const List) []const Device {
            assert(list.count <= device_count_max);

            return list.items[0..list.count];
        }
    };

    pub const Options = struct {
        is_default: bool = false,
    };

    pub fn init(id: Id, name: []const u8, options: Options) Device {
        assert(id.is_valid());

        const length: u16 = @intCast(@min(name.len, name_bytes_max));

        var result = Device{
            .id = id,
            .is_default = options.is_default,
            .name = @splat(0),
            .name_len = length,
        };

        @memcpy(result.name[0..length], name[0..length]);

        assert(result.is_valid());

        return result;
    }

    pub fn get_name(device: *const Device) []const u8 {
        assert(device.name_len <= name_bytes_max);

        return device.name[0..device.name_len];
    }

    pub fn is_valid(device: *const Device) bool {
        if (!device.id.is_valid()) {
            return false;
        }

        return device.name_len <= name_bytes_max;
    }
};

pub const Direction = enum(u8) {
    capture = 0,
    render = 1,

    pub fn is_valid(direction: Direction) bool {
        return @backingInt(direction) <= @backingInt(Direction.render);
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

pub const CapacityError = error{
    DevicesExhausted,
    IdTooLong,
};

pub const RequestError = error{
    DefaultMissing,
    DeviceUnknown,
    IdEmpty,
};

pub const device_count_max: u32 = 32;
pub const id_bytes_max: u32 = 512;
pub const name_bytes_max: u32 = 256;

comptime {
    assert(device_count_max > 0);
    assert(id_bytes_max > name_bytes_max);
    assert(id_bytes_max <= std.math.maxInt(u16));
    assert(name_bytes_max > 0);
}

const testing = std.testing;

test Device {
    var list = Device.List.init();

    const speakers = try Device.Id.init(.render, "alsa_output.pci-0000_00_1f.3.analog-stereo");
    const headphones = try Device.Id.init(.render, "bluez_output.headphones");

    try list.append(Device.init(speakers, "Speakers", .{ .is_default = true }));
    try list.append(Device.init(headphones, "Headphones", .{}));

    const found = list.find(&headphones) orelse return error.DeviceMissing;

    try testing.expectEqualStrings("Headphones", found.get_name());
    try testing.expect(list.slice()[0].is_default);
    try testing.expect(!found.is_default);
    try testing.expect(found.id.eql(&headphones));
}

test Direction {
    try testing.expectEqualStrings("capture", Direction.capture.to_string());
    try testing.expectEqualStrings("render", Direction.render.to_string());
    try testing.expect(Direction.capture.is_valid());
    try testing.expect(Direction.render.is_valid());
}

test CapacityError {
    const text: [id_bytes_max + 1]u8 = @splat('x');

    try testing.expectError(error.IdTooLong, Device.Id.init(.capture, &text));

    var list = Device.List.init();

    const id = try Device.Id.init(.capture, "microphone");

    for (0..device_count_max) |_| {
        try list.append(Device.init(id, "Microphone", .{}));
    }

    const overflow = list.append(Device.init(id, "One", .{}));

    try testing.expectError(error.DevicesExhausted, overflow);
    try testing.expectEqual(device_count_max, list.count);
}

test RequestError {
    try testing.expectError(error.IdEmpty, Device.Id.init(.render, ""));
}

test "every event names itself" {
    try testing.expectEqualStrings("added", Device.Event.added.to_string());
    try testing.expectEqualStrings("removed", Device.Event.removed.to_string());
    try testing.expectEqualStrings("state_changed", Device.Event.state_changed.to_string());
    try testing.expectEqualStrings("default_changed", Device.Event.default_changed.to_string());
    try testing.expect(Device.Event.removed.is_valid());
}

test "an identifier carries its direction and its text" {
    const id = try Device.Id.init(.render, "alsa_output.pci-0000_00_1f.3.analog-stereo");

    try testing.expect(id.is_valid());
    try testing.expectEqual(Direction.render, id.direction);
    try testing.expectEqualStrings("alsa_output.pci-0000_00_1f.3.analog-stereo", id.slice());
}

test "identifiers of different directions never compare equal" {
    const capture = try Device.Id.init(.capture, "shared");
    const render = try Device.Id.init(.render, "shared");
    const same = try Device.Id.init(.capture, "shared");

    try testing.expect(!capture.eql(&render));
    try testing.expect(capture.eql(&same));
}

test "a device name longer than the field is truncated rather than overflowing" {
    const id = try Device.Id.init(.capture, "id");
    const name: [name_bytes_max + 64]u8 = @splat('n');
    const device = Device.init(id, &name, .{});

    try testing.expectEqual(@as(u16, name_bytes_max), device.name_len);
    try testing.expectEqual(@as(usize, name_bytes_max), device.get_name().len);
}

test "a list reports a miss and empties on clear" {
    var list = Device.List.init();

    const first = try Device.Id.init(.render, "first");
    const absent = try Device.Id.init(.render, "absent");

    try list.append(Device.init(first, "First", .{ .is_default = true }));

    try testing.expect(list.find(&absent) == null);
    try testing.expect(!list.is_empty());

    list.clear();

    try testing.expect(list.is_empty());
    try testing.expectEqual(@as(usize, 0), list.slice().len);
}
