const contract = @import("contract.zig");

pub const control = @import("linux/control.zig");
pub const devices = @import("linux/devices.zig");
pub const events = @import("linux/events.zig");
pub const runtime = @import("linux/runtime.zig");

pub const capabilities = contract.Capabilities{
    .default_selection = true,
    .events = true,
};
