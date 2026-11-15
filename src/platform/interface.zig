const std = @import("std");

const device_module = @import("../device.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const RequestError = device_module.RequestError;

pub const Listener = *const fn (*anyopaque, Device.Event, ?Direction) void;

pub const PlatformError = error{
    AccessDenied,
    CallFailed,
    ConnectionLost,
    ReplyInvalid,
    ServiceUnavailable,
    ThreadSpawnFailed,
};

pub const volume_fraction_max: f32 = 1.0;
pub const volume_fraction_min: f32 = 0.0;

comptime {
    assert(volume_fraction_min < volume_fraction_max);
    assert(@typeInfo(PlatformError).error_set.error_names.?.len == 6);
}

pub fn clamp_volume(level: f32) f32 {
    if (std.math.isNan(level)) {
        return volume_fraction_min;
    }

    const result = std.math.clamp(level, volume_fraction_min, volume_fraction_max);

    assert(result >= volume_fraction_min);
    assert(result <= volume_fraction_max);

    return result;
}

pub fn assert_backend(comptime Backend: type) void {
    comptime {
        assert_lifecycle(Backend);
        assert_devices(Backend);
        assert_control(Backend);
        assert_events(Backend);
    }
}

fn assert_lifecycle(comptime Backend: type) void {
    require_decl(Backend, "Options");

    switch (@typeInfo(Backend.Options)) {
        .@"struct" => {},
        else => @compileError(
            "mantra backend " ++ @typeName(Backend) ++ ".Options is not a struct",
        ),
    }

    require_method(Backend, "init", fn (*Backend, Backend.Options) PlatformError!void);
    require_method(Backend, "deinit", fn (*Backend) void);
}

fn assert_devices(comptime Backend: type) void {
    require_method(
        Backend,
        "devices_enumerate",
        fn (*Backend, *Device.List, Direction) (CapacityError || PlatformError)!void,
    );

    require_method(
        Backend,
        "devices_default",
        fn (*Backend, Direction) (CapacityError || PlatformError || RequestError)!Device.Id,
    );

    require_method(
        Backend,
        "devices_set_default",
        fn (*Backend, *const Device.Id) (PlatformError || RequestError)!void,
    );
}

fn assert_control(comptime Backend: type) void {
    const Fallible = PlatformError || RequestError;

    require_method(Backend, "control_is_muted", fn (*Backend, *const Device.Id) Fallible!bool);

    require_method(
        Backend,
        "control_set_mute",
        fn (*Backend, *const Device.Id, bool) Fallible!void,
    );

    require_method(Backend, "control_get_volume", fn (*Backend, *const Device.Id) Fallible!f32);

    require_method(
        Backend,
        "control_set_volume",
        fn (*Backend, *const Device.Id, f32) Fallible!void,
    );
}

fn assert_events(comptime Backend: type) void {
    require_method(
        Backend,
        "events_subscribe",
        fn (*Backend, Listener, *anyopaque) PlatformError!void,
    );

    require_method(Backend, "events_unsubscribe", fn (*Backend) void);
    require_method(Backend, "events_is_subscribed", fn (*Backend) bool);
}

fn require_decl(comptime Backend: type, comptime name: []const u8) void {
    assert(name.len > 0);
    assert(std.mem.findScalar(u8, name, '.') == null);

    if (!@hasDecl(Backend, name)) {
        @compileError("mantra backend " ++ @typeName(Backend) ++ " is missing '" ++ name ++ "'");
    }
}

fn require_method(
    comptime Backend: type,
    comptime name: []const u8,
    comptime Signature: type,
) void {
    assert(name.len > 0);
    assert(@typeInfo(Signature) == .@"fn");

    require_decl(Backend, name);

    const Actual = @TypeOf(@field(Backend, name));

    if (Actual != Signature) {
        @compileError(
            "mantra backend " ++ @typeName(Backend) ++ "." ++ name ++ " has type " ++
                @typeName(Actual) ++ ", expected " ++ @typeName(Signature),
        );
    }
}

const testing = std.testing;

test clamp_volume {
    try testing.expectEqual(volume_fraction_min, clamp_volume(-1.0));
    try testing.expectEqual(volume_fraction_max, clamp_volume(2.5));
    try testing.expectEqual(@as(f32, 0.25), clamp_volume(0.25));
    try testing.expectEqual(volume_fraction_min, clamp_volume(std.math.nan(f32)));
    try testing.expectEqual(volume_fraction_max, clamp_volume(std.math.inf(f32)));
}

test "a clamped level is a fixed point of the clamp" {
    const levels = [_]f32{ -3.0, -0.0, 0.0, 0.125, 0.5, 0.999, 1.0, 7.5 };

    for (levels) |level| {
        const once = clamp_volume(level);

        try testing.expectEqual(once, clamp_volume(once));
    }
}
