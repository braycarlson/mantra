const build_options = @import("build_options");
const builtin = @import("builtin");

const contract = @import("platform/contract.zig");

pub const Listener = contract.Listener;
pub const PlatformError = contract.PlatformError;

pub const volume_fraction_max = contract.volume_fraction_max;
pub const volume_fraction_min = contract.volume_fraction_min;

pub const backend = if (build_options.backend_mock)
    @import("platform/mock.zig")
else switch (builtin.target.os.tag) {
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("mantra: unsupported target OS"),
};

pub const mock = if (build_options.backend_mock)
    backend
else
    @compileError("mantra: mock surface requires -Dbackend=mock");

comptime {
    contract.assert_backend(backend);
}
