const std = @import("std");

const device_module = @import("device.zig");
const platform = @import("platform.zig");

const assert = std.debug.assert;

const backend = platform.backend;

const Device = device_module.Device;
const Direction = device_module.Direction;

const testing = std.testing;

const yield_max: u32 = 1 << 22;

test {
    _ = @import("platform/linux/control.zig");
    _ = @import("platform/linux/devices.zig");
    _ = @import("platform/linux/events.zig");
    _ = @import("platform/linux/pulse.zig");
    _ = @import("platform/linux/runtime.zig");
    _ = @import("platform/linux/sync.zig");
    _ = @import("platform/linux/sys.zig");
    _ = @import("platform/linux/tag.zig");
}

fn open() !bool {
    backend.runtime.open() catch |err| switch (err) {
        error.ServiceUnavailable => return false,
        else => return err,
    };

    return true;
}

test "the runtime connects to the session sound server" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    try testing.expect(backend.runtime.is_open());
}

test "closing an unopened runtime is inert" {
    backend.runtime.close();

    try testing.expect(!backend.runtime.is_open());
}

test "enumeration returns named devices for both directions" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var render = Device.List.init();
    var capture = Device.List.init();

    try backend.devices.enumerate(&render, .render);
    try backend.devices.enumerate(&capture, .capture);

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
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var list = Device.List.init();

    try backend.devices.enumerate(&list, .render);

    const id = try backend.devices.default(.render);

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

test "the volume of the default render device reads inside the contract bounds" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const id = try backend.devices.default(.render);
    const level = try backend.control.get_volume(&id);

    try testing.expect(level >= platform.volume_fraction_min);
    try testing.expect(level <= platform.volume_fraction_max);
}

test "the volume of the default render device survives a round trip" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const id = try backend.devices.default(.render);
    const original = try backend.control.get_volume(&id);

    try backend.control.set_volume(&id, 0.42);

    const changed = try backend.control.get_volume(&id);

    try backend.control.set_volume(&id, original);

    const restored = try backend.control.get_volume(&id);

    try testing.expect(@abs(changed - 0.42) < 0.01);
    try testing.expect(@abs(restored - original) < 0.01);
}

test "the mute state of the default capture device toggles and restores" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const id = backend.devices.default(.capture) catch {
        return error.SkipZigTest;
    };

    const original = try backend.control.is_muted(&id);

    try backend.control.set_mute(&id, !original);

    const toggled = try backend.control.is_muted(&id);

    try backend.control.set_mute(&id, original);

    const restored = try backend.control.is_muted(&id);

    try testing.expectEqual(!original, toggled);
    try testing.expectEqual(original, restored);
}

test "a device the server does not know is unknown" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const absent = try Device.Id.init(.render, "mantra.no.such.sink");

    try testing.expectError(error.DeviceUnknown, backend.control.is_muted(&absent));
    try testing.expectError(error.DeviceUnknown, backend.devices.set_default(&absent));
}

test "setting the default render device to itself is accepted" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    const id = try backend.devices.default(.render);

    try backend.devices.set_default(&id);

    const again = try backend.devices.default(.render);

    try testing.expect(again.eql(&id));
}

test "a subscription starts, reports itself, and stops" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var seen = std.atomic.Value(u32).init(0);

    try testing.expect(!backend.events.is_subscribed());

    try backend.events.subscribe(count_event, &seen);

    try testing.expect(backend.events.is_subscribed());

    backend.events.unsubscribe();

    try testing.expect(!backend.events.is_subscribed());
}

test "a volume change reaches a live subscriber" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    defer backend.runtime.close();

    var seen = std.atomic.Value(u32).init(0);

    try backend.events.subscribe(count_event, &seen);
    defer backend.events.unsubscribe();

    const id = try backend.devices.default(.render);
    const original = try backend.control.get_volume(&id);

    try backend.control.set_volume(&id, if (original > 0.5) 0.3 else 0.7);

    var attempts: u32 = 0;

    while (attempts < yield_max) : (attempts += 1) {
        if (seen.load(.seq_cst) != 0) {
            break;
        }

        std.Thread.yield() catch continue;
    }

    try backend.control.set_volume(&id, original);

    try testing.expect(seen.load(.seq_cst) > 0);
}

fn count_event(context: *anyopaque, event: Device.Event, _: ?Direction) void {
    assert(event.is_valid());

    const seen: *std.atomic.Value(u32) = @ptrCast(@alignCast(context));

    _ = seen.fetchAdd(1, .seq_cst);
}
