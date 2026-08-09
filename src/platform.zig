const build_options = @import("build_options");
const builtin = @import("builtin");

const contract = @import("platform/contract.zig");

pub const Capabilities = contract.Capabilities;
pub const ControlError = contract.ControlError;
pub const DeviceError = contract.DeviceError;
pub const DeviceEvent = contract.DeviceEvent;
pub const DeviceId = contract.DeviceId;
pub const DeviceInfo = contract.DeviceInfo;
pub const DeviceList = contract.DeviceList;
pub const Direction = contract.Direction;
pub const EventCallback = contract.EventCallback;
pub const EventError = contract.EventError;
pub const RuntimeError = contract.RuntimeError;

pub const devices_max = contract.devices_max;
pub const id_bytes_max = contract.id_bytes_max;
pub const name_bytes_max = contract.name_bytes_max;
pub const volume_max = contract.volume_max;
pub const volume_min = contract.volume_min;

pub const backend = if (build_options.backend_mock)
    @import("platform/mock.zig")
else switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("mantra: unsupported target OS"),
};

pub const mock = if (build_options.backend_mock)
    backend
else
    @compileError("mantra: mock surface requires -Dbackend=mock");

pub const capabilities: Capabilities = backend.capabilities;

comptime {
    contract.assert_backend(backend);
}
