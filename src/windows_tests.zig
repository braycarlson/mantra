const std = @import("std");

const mantra = @import("root.zig");

const com = @import("platform/windows/com.zig");
const mmdevice = @import("platform/windows/mmdevice.zig");
const runtime = @import("platform/windows/runtime.zig");
const text = @import("platform/windows/text.zig");

const DeviceId = mantra.DeviceId;
const DeviceList = mantra.DeviceList;
const Direction = mantra.Direction;

const testing = std.testing;

const yield_max: u32 = 1 << 22;

test {
    _ = @import("platform/windows/com.zig");
    _ = @import("platform/windows/control.zig");
    _ = @import("platform/windows/devices.zig");
    _ = @import("platform/windows/events.zig");
    _ = @import("platform/windows/mmdevice.zig");
    _ = @import("platform/windows/runtime.zig");
    _ = @import("platform/windows/sync.zig");
    _ = @import("platform/windows/text.zig");
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

fn default_of(direction: Direction) ?DeviceId {
    const result = mantra.devices.default(direction) catch {
        return null;
    };

    return result;
}

test "a GUID literal parses into the byte order the interface tables expect" {
    const value = com.guid("BCDE0395-E52F-467C-8E3D-C4579291692E");

    try testing.expectEqual(@as(u32, 0xbcde0395), value.data1);
    try testing.expectEqual(@as(u16, 0xe52f), value.data2);
    try testing.expectEqual(@as(u16, 0x467c), value.data3);

    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e },
        &value.data4,
    );

    try testing.expect(value.eql(&mmdevice.clsid_device_enumerator));
    try testing.expect(!value.eql(&mmdevice.iid_device_enumerator));
}

test "each direction maps to the endpoint half of the platform" {
    try testing.expectEqual(mmdevice.data_flow_capture, mmdevice.to_data_flow(.capture));
    try testing.expectEqual(mmdevice.data_flow_render, mmdevice.to_data_flow(.render));

    try testing.expectEqual(Direction.capture, mmdevice.to_direction(mmdevice.data_flow_capture).?);
    try testing.expectEqual(Direction.render, mmdevice.to_direction(mmdevice.data_flow_render).?);

    try testing.expect(mmdevice.to_direction(mmdevice.data_flow_all) == null);
}

test "the endpoint state mask covers each state exactly once" {
    const states = [_]u32{
        mmdevice.device_state_active,
        mmdevice.device_state_disabled,
        mmdevice.device_state_not_present,
        mmdevice.device_state_unplugged,
    };

    var union_of: u32 = 0;

    for (states) |state| {
        try testing.expectEqual(@as(u32, 0), union_of & state);

        union_of |= state;
    }

    try testing.expectEqual(mmdevice.device_state_all, union_of);
    try testing.expectEqual(@as(usize, 3), mmdevice.role_all.len);
    try testing.expectEqual(mmdevice.role_console, mmdevice.role_all[0]);
}

test "a failed result maps to the internal error set" {
    const denied: com.HRESULT = @bitCast(@as(u32, 0x80070005));
    const invalid: com.HRESULT = @bitCast(@as(u32, 0x80070057));
    const missing: com.HRESULT = @bitCast(@as(u32, 0x80070490));
    const stopped: com.HRESULT = @bitCast(@as(u32, 0x88890010));
    const unknown: com.HRESULT = @bitCast(@as(u32, 0x8000ffff));

    try testing.expectEqual(com.Error.Denied, com.to_error(denied));
    try testing.expectEqual(com.Error.Invalid, com.to_error(invalid));
    try testing.expectEqual(com.Error.NotFound, com.to_error(missing));
    try testing.expectEqual(com.Error.Unavailable, com.to_error(stopped));
    try testing.expectEqual(com.Error.Failed, com.to_error(unknown));

    try testing.expect(com.succeeded(com.s_ok));
    try testing.expect(com.succeeded(com.s_false));
    try testing.expect(com.failed(denied));
}

test "the internal error set maps onto the canonical contract sets" {
    try testing.expectEqual(
        mantra.RuntimeError.Unavailable,
        runtime.to_runtime_error(com.Error.Unavailable),
    );

    try testing.expectEqual(
        mantra.RuntimeError.Denied,
        runtime.to_runtime_error(com.Error.Denied),
    );

    try testing.expectEqual(
        mantra.RuntimeError.Failed,
        runtime.to_runtime_error(com.Error.Failed),
    );

    try testing.expectEqual(
        mantra.DeviceError.NotFound,
        runtime.to_device_error(com.Error.NotFound),
    );

    try testing.expectEqual(
        mantra.DeviceError.Failed,
        runtime.to_device_error(com.Error.Unavailable),
    );

    try testing.expectEqual(
        mantra.ControlError.Denied,
        runtime.to_control_error(com.Error.Denied),
    );

    try testing.expectEqual(
        mantra.ControlError.NotOpen,
        runtime.to_control_error(com.Error.NotOpen),
    );
}

test "a wide endpoint identifier survives a round trip through the seam" {
    const source = "{0.0.1.00000000}.{4c9a6e21-1b6f-4c5a-9f2d-8a7e3d4f5b6c}";

    var wide: [contract_id_max + 1]u16 = undefined;

    const encoded = try text.to_wide(source, &wide);

    try testing.expectEqual(source.len, encoded.len);
    try testing.expectEqual(@as(u16, 0), wide[encoded.len]);

    var narrow: [contract_id_max]u8 = undefined;

    const decoded = try text.from_wide(encoded.ptr, &narrow);

    try testing.expectEqualStrings(source, decoded);
}

test "a device name outside the basic plane survives a round trip" {
    const source = "Realtek \u{00ae} Audio \u{1f50a}";

    var wide: [contract_name_max]u16 = undefined;

    const encoded = try text.to_wide(source, &wide);

    var narrow: [contract_name_max]u8 = undefined;

    const decoded = try text.from_wide(encoded.ptr, &narrow);

    try testing.expectEqualStrings(source, decoded);
}

test "conversion refuses the empty string and anything past the bound" {
    var wide: [8]u16 = undefined;
    var narrow: [4]u8 = undefined;

    try testing.expectError(text.Error.Empty, text.to_wide("", &wide));
    try testing.expectError(text.Error.TooLong, text.to_wide("far too long", &wide));

    const source = std.unicode.utf8ToUtf16LeStringLiteral("abcdefgh");

    try testing.expectError(text.Error.TooLong, text.from_wide(source, &narrow));

    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");

    try testing.expectError(text.Error.Empty, text.from_wide(empty, &narrow));
}

test "an unpaired surrogate is rejected rather than decoded into garbage" {
    const storage = [_:0]u16{ 0xd800, 0x0041 };

    var narrow: [16]u8 = undefined;

    const source: [*:0]const u16 = &storage;

    try testing.expectError(text.Error.Invalid, text.from_wide(source, &narrow));
}

test "the runtime opens the endpoint service and reports a second open" {
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

test "a closed runtime refuses every operation" {
    try testing.expect(!mantra.runtime.is_open());

    var list = DeviceList.init();

    const id = try DeviceId.init(.capture, "mantra.no.such.endpoint");

    try testing.expectError(
        mantra.DeviceError.NotOpen,
        mantra.devices.enumerate(.capture, &list),
    );

    try testing.expectError(mantra.DeviceError.NotOpen, mantra.devices.default(.render));
    try testing.expectError(mantra.ControlError.NotOpen, mantra.control.is_muted(&id));
}

test "an invalid identifier is rejected before the runtime is consulted" {
    const id = DeviceId{};

    try testing.expectError(mantra.ControlError.Invalid, mantra.control.is_muted(&id));
    try testing.expectError(mantra.ControlError.Invalid, mantra.control.set_mute(&id, true));
    try testing.expectError(mantra.DeviceError.Invalid, mantra.devices.set_default(&id));
}

test "enumeration returns named endpoints for both directions" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    var render = DeviceList.init();
    var capture = DeviceList.init();

    try mantra.devices.enumerate(.render, &render);
    try mantra.devices.enumerate(.capture, &capture);

    for (render.slice()) |info| {
        try testing.expect(info.id.is_valid());
        try testing.expectEqual(Direction.render, info.id.direction);
        try testing.expect(info.get_name().len > 0);
    }

    for (capture.slice()) |info| {
        try testing.expect(info.id.is_valid());
        try testing.expectEqual(Direction.capture, info.id.direction);
        try testing.expect(info.get_name().len > 0);
    }
}

test "the default render endpoint is one of the enumerated endpoints" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = default_of(.render) orelse {
        return error.SkipZigTest;
    };

    var list = DeviceList.init();

    try mantra.devices.enumerate(.render, &list);

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

test "the volume of the default render endpoint survives a round trip" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = default_of(.render) orelse {
        return error.SkipZigTest;
    };

    const original = try mantra.control.get_volume(&id);

    try testing.expect(original >= mantra.volume_min);
    try testing.expect(original <= mantra.volume_max);

    try mantra.control.set_volume(&id, 0.42);

    const changed = try mantra.control.get_volume(&id);

    try mantra.control.set_volume(&id, original);

    const restored = try mantra.control.get_volume(&id);

    try testing.expect(@abs(changed - 0.42) < 0.01);
    try testing.expect(@abs(restored - original) < 0.01);
}

test "a volume outside the contract bounds is clamped rather than refused" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = default_of(.render) orelse {
        return error.SkipZigTest;
    };

    const original = try mantra.control.get_volume(&id);

    try mantra.control.set_volume(&id, 4.0);

    try testing.expectEqual(mantra.volume_max, try mantra.control.get_volume(&id));

    try mantra.control.set_volume(&id, -1.0);

    try testing.expectEqual(mantra.volume_min, try mantra.control.get_volume(&id));

    try mantra.control.set_volume(&id, original);
}

test "the mute state of the default capture endpoint toggles and restores" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = default_of(.capture) orelse {
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

test "an endpoint the service does not know is reported as missing" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const absent = try DeviceId.init(.render, "{0.0.0.00000000}.{mantra-no-such-endpoint}");

    try testing.expectError(mantra.ControlError.NotFound, mantra.control.is_muted(&absent));
    try testing.expectError(mantra.DeviceError.NotFound, mantra.devices.set_default(&absent));
}

test "setting the default render endpoint to itself is accepted" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = default_of(.render) orelse {
        return error.SkipZigTest;
    };

    try mantra.devices.set_default(&id);

    const again = default_of(.render) orelse {
        return error.SkipZigTest;
    };

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

test "closing the runtime drops the subscriber" {
    if (!try open()) {
        return error.SkipZigTest;
    }

    try mantra.events.subscribe(count_event, null);

    mantra.runtime.close();

    try testing.expect(!mantra.events.is_subscribed());
}

test "a default change reaches a live subscriber" {
    if (!try open()) {
        return error.SkipZigTest;
    }
    defer mantra.runtime.close();

    const id = default_of(.render) orelse {
        return error.SkipZigTest;
    };

    seen.store(0, .seq_cst);

    try mantra.events.subscribe(count_event, null);
    defer mantra.events.unsubscribe();

    try mantra.devices.set_default(&id);

    var attempts: u32 = 0;

    while (attempts < yield_max and seen.load(.seq_cst) == 0) : (attempts += 1) {
        std.Thread.yield() catch continue;
    }

    try testing.expect(seen.load(.seq_cst) > 0);
}

const contract_id_max = mantra.id_bytes_max;
const contract_name_max = mantra.name_bytes_max;

var seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn count_event(_: mantra.DeviceEvent, _: ?Direction, _: ?*anyopaque) void {
    _ = seen.fetchAdd(1, .seq_cst);
}
