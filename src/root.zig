const std = @import("std");

const device_module = @import("device.zig");
const mixer_module = @import("mixer.zig");
const platform = @import("platform.zig");

pub const CapacityError = device_module.CapacityError;
pub const Device = device_module.Device;
pub const Direction = device_module.Direction;
pub const Error = CapacityError || PlatformError || RequestError;
pub const Fake = platform.Fake;
pub const Mixer = MixerType(platform.Native);
pub const MixerType = mixer_module.MixerType;
pub const PlatformError = platform.PlatformError;
pub const RequestError = device_module.RequestError;

pub const limits = struct {
    pub const device_count_max = device_module.count_max;
    pub const id_bytes_max = device_module.id_bytes_max;
    pub const name_bytes_max = device_module.name_bytes_max;
    pub const volume_fraction_max = platform.volume_fraction_max;
    pub const volume_fraction_min = platform.volume_fraction_min;
};

const testing = std.testing;

test Error {
    var mixer: MixerType(Fake) = undefined;

    try mixer.init(.{});
    defer mixer.deinit();

    const absent = try Device.Id.init(.capture, "absent");
    const asked: RequestError = error.DeviceUnknown;
    const failure: Error = asked;

    try testing.expectError(asked, mixer.mute(&absent));
    try testing.expectError(failure, mixer.is_muted(&absent));

    mixer.platform.fault.arm(.devices_enumerate);

    var list = Device.List.init();

    const refused: PlatformError = error.CallFailed;

    try testing.expectError(refused, mixer.enumerate(&list, .render));
}

test limits {
    try testing.expect(limits.name_bytes_max < limits.id_bytes_max);
    try testing.expect(limits.device_count_max > 0);
    try testing.expect(limits.volume_fraction_min < limits.volume_fraction_max);
}

test "the root surface resolves on the native and the fake backend" {
    testing.refAllDecls(@This());
    testing.refAllDecls(limits);
    testing.refAllDecls(Mixer);
    testing.refAllDecls(MixerType(Fake));
}
