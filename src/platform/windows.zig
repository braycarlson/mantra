const contract = @import("contract.zig");

pub const control = @import("windows/control.zig");
pub const devices = @import("windows/devices.zig");
pub const events = @import("windows/events.zig");
pub const runtime = @import("windows/runtime.zig");

pub const capabilities = contract.Capabilities{
    .default_selection = true,
    .events = true,
};
