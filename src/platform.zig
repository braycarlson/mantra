const builtin = @import("builtin");

const interface = @import("platform/interface.zig");

pub const Fake = @import("platform/fake.zig");
pub const Listener = interface.Listener;
pub const PlatformError = interface.PlatformError;
pub const volume_fraction_max = interface.volume_fraction_max;
pub const volume_fraction_min = interface.volume_fraction_min;

pub const Native = switch (builtin.target.os.tag) {
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("mantra: unsupported target OS"),
};
