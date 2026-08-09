const platform = @import("platform.zig");

pub const Capabilities = platform.Capabilities;
pub const ControlError = platform.ControlError;
pub const DeviceError = platform.DeviceError;
pub const DeviceEvent = platform.DeviceEvent;
pub const DeviceId = platform.DeviceId;
pub const DeviceInfo = platform.DeviceInfo;
pub const DeviceList = platform.DeviceList;
pub const Direction = platform.Direction;
pub const EventCallback = platform.EventCallback;
pub const EventError = platform.EventError;
pub const RuntimeError = platform.RuntimeError;

pub const capabilities = platform.capabilities;

pub const mock = platform.mock;

pub const devices_max = platform.devices_max;
pub const id_bytes_max = platform.id_bytes_max;
pub const name_bytes_max = platform.name_bytes_max;
pub const volume_max = platform.volume_max;
pub const volume_min = platform.volume_min;

pub const runtime = struct {
    pub const Error = RuntimeError;

    pub fn open() Error!void {
        try platform.backend.runtime.open();
    }

    pub fn close() void {
        platform.backend.runtime.close();
    }

    pub fn is_open() bool {
        return platform.backend.runtime.is_open();
    }
};

pub const devices = struct {
    pub const Error = DeviceError;

    pub fn enumerate(direction: Direction, list: *DeviceList) Error!void {
        try platform.backend.devices.enumerate(direction, list);
    }

    pub fn default(direction: Direction) Error!DeviceId {
        return try platform.backend.devices.default(direction);
    }

    pub fn set_default(id: *const DeviceId) Error!void {
        try platform.backend.devices.set_default(id);
    }
};

pub const control = struct {
    pub const Error = ControlError;

    pub fn is_muted(id: *const DeviceId) Error!bool {
        return try platform.backend.control.is_muted(id);
    }

    pub fn set_mute(id: *const DeviceId, muted: bool) Error!void {
        try platform.backend.control.set_mute(id, muted);
    }

    pub fn get_volume(id: *const DeviceId) Error!f32 {
        return try platform.backend.control.get_volume(id);
    }

    pub fn set_volume(id: *const DeviceId, level: f32) Error!void {
        try platform.backend.control.set_volume(id, level);
    }
};

pub const events = struct {
    pub const Error = EventError;
    pub const Callback = EventCallback;

    pub fn subscribe(callback: Callback, context: ?*anyopaque) Error!void {
        try platform.backend.events.subscribe(callback, context);
    }

    pub fn unsubscribe() void {
        platform.backend.events.unsubscribe();
    }

    pub fn is_subscribed() bool {
        return platform.backend.events.is_subscribed();
    }
};
