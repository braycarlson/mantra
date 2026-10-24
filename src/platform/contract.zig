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

pub fn assert_backend(comptime backend: type) void {
    comptime {
        assert_runtime(backend);
        assert_devices(backend);
        assert_control(backend);
        assert_events(backend);
    }
}

fn assert_runtime(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "runtime", "backend");

    require_fn(scope, "open", fn () PlatformError!void, "runtime");
    require_fn(scope, "close", fn () void, "runtime");
    require_fn(scope, "is_open", fn () bool, "runtime");
}

fn assert_devices(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "devices", "backend");

    require_fn(
        scope,
        "enumerate",
        fn (*Device.List, Direction) (CapacityError || PlatformError)!void,
        "devices",
    );

    require_fn(
        scope,
        "default",
        fn (Direction) (CapacityError || PlatformError || RequestError)!Device.Id,
        "devices",
    );

    require_fn(
        scope,
        "set_default",
        fn (*const Device.Id) (PlatformError || RequestError)!void,
        "devices",
    );
}

fn assert_control(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "control", "backend");
    const Fallible = PlatformError || RequestError;

    require_fn(scope, "is_muted", fn (*const Device.Id) Fallible!bool, "control");
    require_fn(scope, "set_mute", fn (*const Device.Id, bool) Fallible!void, "control");
    require_fn(scope, "get_volume", fn (*const Device.Id) Fallible!f32, "control");
    require_fn(scope, "set_volume", fn (*const Device.Id, f32) Fallible!void, "control");
}

fn assert_events(comptime backend: type) void {
    const scope = RequiredNamespaceType(backend, "events", "backend");

    require_fn(scope, "subscribe", fn (Listener, *anyopaque) PlatformError!void, "events");
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
