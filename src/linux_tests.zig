const std = @import("std");

const device_module = @import("device.zig");
const platform = @import("platform.zig");

const Linux = @import("platform/linux.zig");

const assert = std.debug.assert;

const Device = device_module.Device;
const Direction = device_module.Direction;

const testing = std.testing;

const yield_max: u32 = 1 << 22;

test {
    _ = @import("platform/linux.zig");
    _ = @import("platform/linux/events.zig");
    _ = @import("platform/linux/pulse.zig");
    _ = @import("platform/linux/sync.zig");
    _ = @import("platform/linux/sys.zig");
    _ = @import("platform/linux/tag.zig");
    _ = @import("platform/linux/tag_fuzz.zig");
}

fn open(linux: *Linux) !bool {
    linux.init(.{}) catch |err| switch (err) {
        error.ServiceUnavailable => return false,
        else => return err,
    };

    return true;
}

test "the backend connects to the session sound server" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    try testing.expect(linux.connection.is_open());
}

test "deinit leaves the connection closed" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    linux.deinit();

    try testing.expect(!linux.connection.is_open());
}

test "enumeration returns named devices for both directions" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    var render = Device.List.init();
    var capture = Device.List.init();

    try linux.devices_enumerate(&render, .render);
    try linux.devices_enumerate(&capture, .capture);

    try testing.expect(!render.is_empty());

    for (render.slice()) |device| {
        try testing.expect(device.id.is_valid());
        try testing.expectEqual(Direction.render, device.id.direction);
        try testing.expect(device.get_name().len > 0);
    }

    for (capture.slice()) |device| {
        try testing.expect(device.id.is_valid());
        try testing.expectEqual(Direction.capture, device.id.direction);
    }
}

test "the default render device is one of the enumerated devices" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    var list = Device.List.init();

    try linux.devices_enumerate(&list, .render);

    const id = try linux.devices_default(.render);

    try testing.expect(list.find(&id) != null);

    var marked: u32 = 0;

    for (list.slice()) |device| {
        if (device.is_default) {
            marked += 1;

            try testing.expect(device.id.eql(&id));
        }
    }

    try testing.expectEqual(@as(u32, 1), marked);
}

test "the volume of the default render device reads inside the interface bounds" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    const id = try linux.devices_default(.render);
    const level = try linux.control_get_volume(&id);

    try testing.expect(level >= platform.volume_fraction_min);
    try testing.expect(level <= platform.volume_fraction_max);
}

test "the volume of the default render device survives a round trip" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    const id = try linux.devices_default(.render);
    const original = try linux.control_get_volume(&id);

    try linux.control_set_volume(&id, 0.42);

    const changed = try linux.control_get_volume(&id);

    try linux.control_set_volume(&id, original);

    const restored = try linux.control_get_volume(&id);

    try testing.expect(@abs(changed - 0.42) < 0.01);
    try testing.expect(@abs(restored - original) < 0.01);
}

test "a NaN volume on the default render device clamps to the minimum" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    const id = try linux.devices_default(.render);
    const original = try linux.control_get_volume(&id);

    try linux.control_set_volume(&id, std.math.nan(f32));

    const changed = try linux.control_get_volume(&id);

    try linux.control_set_volume(&id, original);

    const restored = try linux.control_get_volume(&id);

    try testing.expectEqual(platform.volume_fraction_min, changed);
    try testing.expect(@abs(restored - original) < 0.01);
}

test "the mute state of the default capture device toggles and restores" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    const id = linux.devices_default(.capture) catch {
        return error.SkipZigTest;
    };

    const original = try linux.control_is_muted(&id);

    try linux.control_set_mute(&id, !original);

    const toggled = try linux.control_is_muted(&id);

    try linux.control_set_mute(&id, original);

    const restored = try linux.control_is_muted(&id);

    try testing.expectEqual(!original, toggled);
    try testing.expectEqual(original, restored);
}

test "a device the server does not know is unknown" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    const absent = try Device.Id.init(.render, "mantra.no.such.sink");

    try testing.expectError(error.DeviceUnknown, linux.control_is_muted(&absent));
    try testing.expectError(error.DeviceUnknown, linux.devices_set_default(&absent));
}

test "setting the default render device to itself is accepted" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    const id = try linux.devices_default(.render);

    try linux.devices_set_default(&id);

    const again = try linux.devices_default(.render);

    try testing.expect(again.eql(&id));
}

test "a subscription starts, reports itself, and stops" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    var seen = std.atomic.Value(u32).init(0);

    try testing.expect(!linux.events_is_subscribed());

    try linux.events_subscribe(count_event, &seen);

    try testing.expect(linux.events_is_subscribed());

    linux.events_unsubscribe();

    try testing.expect(!linux.events_is_subscribed());
}

test "a volume change reaches a live subscriber" {
    var linux: Linux = undefined;

    if (!try open(&linux)) {
        return error.SkipZigTest;
    }

    defer linux.deinit();

    var seen = std.atomic.Value(u32).init(0);

    try linux.events_subscribe(count_event, &seen);
    defer linux.events_unsubscribe();

    const id = try linux.devices_default(.render);
    const original = try linux.control_get_volume(&id);

    try linux.control_set_volume(&id, if (original > 0.5) 0.3 else 0.7);

    var attempts: u32 = 0;

    while (attempts < yield_max) : (attempts += 1) {
        if (seen.load(.seq_cst) != 0) {
            break;
        }

        std.Thread.yield() catch continue;
    }

    try linux.control_set_volume(&id, original);

    try testing.expect(seen.load(.seq_cst) > 0);
}

fn count_event(context: *anyopaque, event: Device.Event, _: ?Direction) void {
    assert(event.is_valid());

    const seen: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));

    _ = seen.fetchAdd(1, .seq_cst);
}
