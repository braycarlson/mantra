const std = @import("std");

const mantra = @import("root.zig");

const DeviceId = mantra.DeviceId;
const DeviceList = mantra.DeviceList;
const Direction = mantra.Direction;

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
    mantra.runtime.open() catch |err| {
        if (err == mantra.RuntimeError.Unavailable) {
            return false;
        }

        return err;
    };

    return true;
}

test "the runtime connects to the session sound server" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    try testing.expect(mantra.runtime.is_open());
    try testing.expectError(mantra.RuntimeError.AlreadyOpen, mantra.runtime.open());
}

test "closing an unopened runtime is inert" {
    mantra.runtime.close();

    try testing.expect(!mantra.runtime.is_open());
}

test "enumeration returns named devices for both directions" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    var render = DeviceList.init();
    var capture = DeviceList.init();

    try mantra.devices.enumerate(.render, &render);
    try mantra.devices.enumerate(.capture, &capture);

    try testing.expect(!render.is_empty());

    for (render.slice()) |info| {
        try testing.expect(info.id.is_valid());
        try testing.expectEqual(Direction.render, info.id.direction);
        try testing.expect(info.get_name().len > 0);
    }

    for (capture.slice()) |info| {
        try testing.expect(info.id.is_valid());
        try testing.expectEqual(Direction.capture, info.id.direction);
    }
}

test "the default render device is one of the enumerated devices" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    var list = DeviceList.init();

    try mantra.devices.enumerate(.render, &list);

    const id = try mantra.devices.default(.render);

    try testing.expect(list.find(&id) != null);

    var marked: u32 = 0;

    for (list.slice()) |info| {
        if (info.is_default) {
            marked += 1;

            try testing.expect(info.id.eql(&id));
        }
    }

    try testing.expectEqual(@as(u32, 1), marked);
}

test "the volume of the default render device reads inside the contract bounds" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = try mantra.devices.default(.render);
    const level = try mantra.control.get_volume(&id);

    try testing.expect(level >= mantra.volume_min);
    try testing.expect(level <= mantra.volume_max);
}

test "the volume of the default render device survives a round trip" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = try mantra.devices.default(.render);
    const original = try mantra.control.get_volume(&id);

    try mantra.control.set_volume(&id, 0.42);

    const changed = try mantra.control.get_volume(&id);

    try mantra.control.set_volume(&id, original);

    const restored = try mantra.control.get_volume(&id);

    try testing.expect(@abs(changed - 0.42) < 0.01);
    try testing.expect(@abs(restored - original) < 0.01);
}

test "the mute state of the default capture device toggles and restores" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = mantra.devices.default(.capture) catch {
        return error.SkipZigTest;
    };

    const original = try mantra.control.is_muted(&id);

    try mantra.control.set_mute(&id, !original);

    const toggled = try mantra.control.is_muted(&id);

    try mantra.control.set_mute(&id, original);

    const restored = try mantra.control.is_muted(&id);

    try testing.expectEqual(!original, toggled);
    try testing.expectEqual(original, restored);
}

test "a device the server does not know is reported as missing" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const absent = try DeviceId.init(.render, "mantra.no.such.sink");

    try testing.expectError(mantra.ControlError.NotFound, mantra.control.is_muted(&absent));
}

test "setting the default render device to itself is accepted" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = try mantra.devices.default(.render);

    try mantra.devices.set_default(&id);

    const again = try mantra.devices.default(.render);

    try testing.expect(again.eql(&id));
}

test "a subscription starts, reports itself, and stops" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    try testing.expect(!mantra.events.is_subscribed());

    try mantra.events.subscribe(count_event, null);

    try testing.expect(mantra.events.is_subscribed());

    try testing.expectError(
        mantra.EventError.AlreadySubscribed,
        mantra.events.subscribe(count_event, null),
    );

    mantra.events.unsubscribe();

    try testing.expect(!mantra.events.is_subscribed());
}

test "a volume change reaches a live subscriber" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    seen.store(0, .seq_cst);

    try mantra.events.subscribe(count_event, null);
    defer mantra.events.unsubscribe();

    const id = try mantra.devices.default(.render);
    const original = try mantra.control.get_volume(&id);

    try mantra.control.set_volume(&id, if (original > 0.5) 0.3 else 0.7);

    var attempts: u32 = 0;

    while (attempts < yield_max and seen.load(.seq_cst) == 0) : (attempts += 1) {
        std.Thread.yield() catch continue;
    }

    try mantra.control.set_volume(&id, original);

    try testing.expect(seen.load(.seq_cst) > 0);
}

var seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn count_event(_: mantra.DeviceEvent, _: ?Direction, _: ?*anyopaque) void {
    _ = seen.fetchAdd(1, .seq_cst);
}
