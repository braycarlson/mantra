const contract = @import("contract.zig");

pub const control = @import("mock/control.zig");
pub const devices = @import("mock/devices.zig");
pub const events = @import("mock/events.zig");
pub const runtime = @import("mock/runtime.zig");
pub const state = @import("mock/state.zig");

pub const capabilities = contract.Capabilities{
    .default_selection = true,
    .events = true,
};
