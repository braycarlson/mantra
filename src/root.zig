const std = @import("std");

const control_module = @import("control.zig");
const device_module = @import("device.zig");
const devices_module = @import("devices.zig");
const events_module = @import("events.zig");
const platform = @import("platform.zig");
const runtime_module = @import("runtime.zig");

pub const CapacityError = device_module.CapacityError;
pub const Device = device_module.Device;
pub const Direction = device_module.Direction;
pub const Error = CapacityError || PlatformError || RequestError;
pub const PlatformError = platform.PlatformError;
pub const RequestError = device_module.RequestError;

pub const control = struct {
    pub const get_volume = control_module.get_volume;
    pub const is_muted = control_module.is_muted;
    pub const mute = control_module.mute;
    pub const set_volume = control_module.set_volume;
    pub const unmute = control_module.unmute;
};

pub const devices = struct {
    pub const default = devices_module.default;
    pub const enumerate = devices_module.enumerate;
    pub const set_default = devices_module.set_default;
};

pub const events = struct {
    pub const is_subscribed = events_module.is_subscribed;
    pub const subscribe = events_module.subscribe;
    pub const unsubscribe = events_module.unsubscribe;
};

pub const mock = platform.mock;

pub const runtime = struct {
    pub const close = runtime_module.close;
    pub const open = runtime_module.open;
};

pub const limits = struct {
    pub const device_count_max = device_module.device_count_max;
    pub const id_bytes_max = device_module.id_bytes_max;
    pub const name_bytes_max = device_module.name_bytes_max;
    pub const volume_fraction_max = platform.volume_fraction_max;
    pub const volume_fraction_min = platform.volume_fraction_min;
};

const testing = std.testing;

test Error {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const absent = try Device.Id.init(.capture, "absent");
    const asked: RequestError = error.DeviceUnknown;
    const failure: Error = asked;

    try testing.expectError(asked, control.mute(&absent));
    try testing.expectError(failure, control.is_muted(&absent));

    mock.state.fail_next(.enumerate);

    var list = Device.List.init();

    const refused: PlatformError = error.CallFailed;

    try testing.expectError(refused, devices.enumerate(&list, .render));
}

test limits {
    try testing.expect(limits.name_bytes_max < limits.id_bytes_max);
    try testing.expect(limits.device_count_max > 0);
    try testing.expect(limits.volume_fraction_min < limits.volume_fraction_max);
}

test "the root surface resolves on the mock backend" {
    testing.refAllDecls(@This());
    testing.refAllDecls(control);
    testing.refAllDecls(devices);
    testing.refAllDecls(events);
    testing.refAllDecls(limits);
    testing.refAllDecls(runtime);
}
