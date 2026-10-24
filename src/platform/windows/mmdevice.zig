const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");

const assert = std.debug.assert;

const GUID = com.GUID;
const HRESULT = com.HRESULT;
const PropVariant = com.PropVariant;
const PropertyKey = com.PropertyKey;

const Direction = device_module.Direction;

pub const DataFlow = enum(u32) {
    render = 0,
    capture = 1,
    all = 2,
    _,
};

pub const Role = enum(u32) {
    console = 0,
    multimedia = 1,
    communications = 2,
    _,
};

pub const DeviceStates = packed struct(u32) {
    active: bool = false,
    disabled: bool = false,
    not_present: bool = false,
    unplugged: bool = false,
    reserved: u28 = 0,
};

pub const roles = [_]Role{ .console, .multimedia, .communications };
pub const clsid_device_enumerator = com.guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
pub const clsid_policy_config = com.guid("294935CE-F637-4E7C-A41B-AB255460B862");
pub const iid_unknown = com.guid("00000000-0000-0000-C000-000000000046");
pub const iid_device_enumerator = com.guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
pub const iid_endpoint_volume = com.guid("5CDF2C82-841E-4546-9722-0CF74078229A");
pub const iid_notification_client = com.guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0");
pub const iid_policy_config = com.guid("568B9108-44BF-40B4-9006-86AFE5B5A620");

pub const key_friendly_name = PropertyKey{
    .fmtid = com.guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
    .pid = 14,
};

comptime {
    assert(roles.len == 3);
    assert(@sizeOf(DeviceStates) == @sizeOf(u32));
    assert(clsid_device_enumerator.data1 == 0xbcde0395);
    assert(iid_unknown.data4[7] == 0x46);
    assert(iid_device_enumerator.data2 == 0x9614);
    assert(key_friendly_name.pid == 14);
}

const IMMDeviceCollectionVtable = extern struct {
    base: com.IUnknownVtable,
    GetCount: *const fn (*IMMDeviceCollection, *u32) callconv(.winapi) HRESULT,
    Item: *const fn (
        *IMMDeviceCollection,
        u32,
        *?*IMMDevice,
    ) callconv(.winapi) HRESULT,
};

pub const IMMDeviceCollection = extern struct {
    vtable: *const IMMDeviceCollectionVtable,

    pub fn count(collection: *IMMDeviceCollection) com.Error!u32 {
        var result: u32 = 0;

        try com.check(collection.vtable.GetCount(collection, &result));

        return result;
    }

    pub fn item(collection: *IMMDeviceCollection, index: u32) com.Error!*IMMDevice {
        var device: ?*IMMDevice = null;

        try com.check(collection.vtable.Item(collection, index, &device));

        return device orelse Error.Failed;
    }

    pub fn release(collection: *IMMDeviceCollection) void {
        com.release(@ptrCast(collection));
    }
};

const IPropertyStoreVtable = extern struct {
    base: com.IUnknownVtable,
    GetCount: *const fn (*IPropertyStore, *u32) callconv(.winapi) HRESULT,
    GetAt: *const fn (*IPropertyStore, u32, *PropertyKey) callconv(.winapi) HRESULT,
    GetValue: *const fn (
        *IPropertyStore,
        *const PropertyKey,
        *PropVariant,
    ) callconv(.winapi) HRESULT,
    SetValue: *const anyopaque,
    Commit: *const anyopaque,
};

pub const IPropertyStore = extern struct {
    vtable: *const IPropertyStoreVtable,

    pub fn value(store: *IPropertyStore, key: *const PropertyKey) com.Error!PropVariant {
        var result = PropVariant{};

        try com.check(store.vtable.GetValue(store, key, &result));

        return result;
    }

    pub fn release(store: *IPropertyStore) void {
        com.release(@ptrCast(store));
    }
};

const IMMDeviceVtable = extern struct {
    base: com.IUnknownVtable,
    Activate: *const fn (
        *IMMDevice,
        *const GUID,
        u32,
        ?*PropVariant,
        *?*anyopaque,
    ) callconv(.winapi) HRESULT,

    OpenPropertyStore: *const fn (
        *IMMDevice,
        u32,
        *?*IPropertyStore,
    ) callconv(.winapi) HRESULT,
    GetId: *const fn (*IMMDevice, *?[*:0]u16) callconv(.winapi) HRESULT,
    GetState: *const fn (*IMMDevice, *DeviceStates) callconv(.winapi) HRESULT,
};

pub const IMMDevice = extern struct {
    vtable: *const IMMDeviceVtable,

    pub fn endpoint_volume(device: *IMMDevice) com.Error!*IAudioEndpointVolume {
        var object: ?*anyopaque = null;

        const status = device.vtable.Activate(
            device,
            &iid_endpoint_volume,
            com.clsctx_all,
            null,
            &object,
        );

        try com.check(status);

        const raw = object orelse {
            return Error.Failed;
        };

        return @ptrCast(@alignCast(raw));
    }

    pub fn property_store(device: *IMMDevice) com.Error!*IPropertyStore {
        var store: ?*IPropertyStore = null;

        try com.check(device.vtable.OpenPropertyStore(device, com.storage_read, &store));

        return store orelse Error.Failed;
    }

    pub fn id(device: *IMMDevice) com.Error![*:0]u16 {
        var raw: ?[*:0]u16 = null;

        try com.check(device.vtable.GetId(device, &raw));

        return raw orelse Error.Failed;
    }

    pub fn state(device: *IMMDevice) com.Error!DeviceStates {
        var result = DeviceStates{};

        try com.check(device.vtable.GetState(device, &result));

        return result;
    }

    pub fn release(device: *IMMDevice) void {
        com.release(@ptrCast(device));
    }
};

const IMMDeviceEnumeratorVtable = extern struct {
    base: com.IUnknownVtable,
    EnumAudioEndpoints: *const fn (
        *IMMDeviceEnumerator,
        DataFlow,
        DeviceStates,
        *?*IMMDeviceCollection,
    ) callconv(.winapi) HRESULT,

    GetDefaultAudioEndpoint: *const fn (
        *IMMDeviceEnumerator,
        DataFlow,
        Role,
        *?*IMMDevice,
    ) callconv(.winapi) HRESULT,

    GetDevice: *const fn (
        *IMMDeviceEnumerator,
        [*:0]const u16,
        *?*IMMDevice,
    ) callconv(.winapi) HRESULT,

    RegisterEndpointNotificationCallback: *const fn (
        *IMMDeviceEnumerator,
        *anyopaque,
    ) callconv(.winapi) HRESULT,

    UnregisterEndpointNotificationCallback: *const fn (
        *IMMDeviceEnumerator,
        *anyopaque,
    ) callconv(.winapi) HRESULT,
};

pub const IMMDeviceEnumerator = extern struct {
    vtable: *const IMMDeviceEnumeratorVtable,

    pub fn endpoints(
        enumerator: *IMMDeviceEnumerator,
        flow: DataFlow,
        states: DeviceStates,
    ) com.Error!*IMMDeviceCollection {
        var collection: ?*IMMDeviceCollection = null;

        const status = enumerator.vtable.EnumAudioEndpoints(enumerator, flow, states, &collection);

        try com.check(status);

        return collection orelse Error.Failed;
    }

    pub fn default_endpoint(
        enumerator: *IMMDeviceEnumerator,
        flow: DataFlow,
        role: Role,
    ) com.Error!*IMMDevice {
        var found: ?*IMMDevice = null;

        const status = enumerator.vtable.GetDefaultAudioEndpoint(enumerator, flow, role, &found);

        try com.check(status);

        return found orelse Error.NotFound;
    }

    pub fn device(enumerator: *IMMDeviceEnumerator, target: [*:0]const u16) com.Error!*IMMDevice {
        var found: ?*IMMDevice = null;

        try com.check(enumerator.vtable.GetDevice(enumerator, target, &found));

        return found orelse Error.NotFound;
    }

    pub fn register(enumerator: *IMMDeviceEnumerator, client: *anyopaque) com.Error!void {
        const status = enumerator.vtable.RegisterEndpointNotificationCallback(enumerator, client);

        try com.check(status);
    }

    pub fn unregister(enumerator: *IMMDeviceEnumerator, client: *anyopaque) void {
        _ = enumerator.vtable.UnregisterEndpointNotificationCallback(enumerator, client);
    }

    pub fn release(enumerator: *IMMDeviceEnumerator) void {
        com.release(@ptrCast(enumerator));
    }
};

const IAudioEndpointVolumeVtable = extern struct {
    base: com.IUnknownVtable,
    RegisterControlChangeNotify: *const anyopaque,
    UnregisterControlChangeNotify: *const anyopaque,
    GetChannelCount: *const anyopaque,
    SetMasterVolumeLevel: *const anyopaque,
    SetMasterVolumeLevelScalar: *const fn (
        *IAudioEndpointVolume,
        f32,
        ?*const GUID,
    ) callconv(.winapi) HRESULT,
    GetMasterVolumeLevel: *const anyopaque,
    GetMasterVolumeLevelScalar: *const fn (
        *IAudioEndpointVolume,
        *f32,
    ) callconv(.winapi) HRESULT,
    SetChannelVolumeLevel: *const anyopaque,
    SetChannelVolumeLevelScalar: *const anyopaque,
    GetChannelVolumeLevel: *const anyopaque,
    GetChannelVolumeLevelScalar: *const anyopaque,
    SetMute: *const fn (
        *IAudioEndpointVolume,
        com.BOOL,
        ?*const GUID,
    ) callconv(.winapi) HRESULT,
    GetMute: *const fn (*IAudioEndpointVolume, *com.BOOL) callconv(.winapi) HRESULT,
    GetVolumeStepInfo: *const anyopaque,
    VolumeStepUp: *const anyopaque,
    VolumeStepDown: *const anyopaque,
    QueryHardwareSupport: *const anyopaque,
    GetVolumeRange: *const anyopaque,
};

pub const IAudioEndpointVolume = extern struct {
    vtable: *const IAudioEndpointVolumeVtable,

    pub fn is_muted(volume: *IAudioEndpointVolume) com.Error!bool {
        var raw: com.BOOL = 0;

        try com.check(volume.vtable.GetMute(volume, &raw));

        return raw != 0;
    }

    pub fn set_mute(volume: *IAudioEndpointVolume, muted: bool) com.Error!void {
        const raw: com.BOOL = if (muted) 1 else 0;

        try com.check(volume.vtable.SetMute(volume, raw, null));
    }

    pub fn level(volume: *IAudioEndpointVolume) com.Error!f32 {
        var raw: f32 = 0.0;

        try com.check(volume.vtable.GetMasterVolumeLevelScalar(volume, &raw));

        return raw;
    }

    pub fn set_level(volume: *IAudioEndpointVolume, value: f32) com.Error!void {
        assert(value >= contract.volume_fraction_min);
        assert(value <= contract.volume_fraction_max);

        try com.check(volume.vtable.SetMasterVolumeLevelScalar(volume, value, null));
    }

    pub fn release(volume: *IAudioEndpointVolume) void {
        com.release(@ptrCast(volume));
    }
};

const IPolicyConfigVtable = extern struct {
    base: com.IUnknownVtable,
    GetMixFormat: *const anyopaque,
    GetDeviceFormat: *const anyopaque,
    SetDeviceFormat: *const anyopaque,
    GetProcessingPeriod: *const anyopaque,
    SetProcessingPeriod: *const anyopaque,
    GetShareMode: *const anyopaque,
    SetShareMode: *const anyopaque,
    GetPropertyValue: *const anyopaque,
    SetPropertyValue: *const anyopaque,
    SetDefaultEndpoint: *const fn (
        *IPolicyConfig,
        [*:0]const u16,
        Role,
    ) callconv(.winapi) HRESULT,
    SetEndpointVisibility: *const anyopaque,
};

pub const IPolicyConfig = extern struct {
    vtable: *const IPolicyConfigVtable,

    pub fn set_default(config: *IPolicyConfig, target: [*:0]const u16, role: Role) com.Error!void {
        try com.check(config.vtable.SetDefaultEndpoint(config, target, role));
    }

    pub fn set_default_all(config: *IPolicyConfig, target: [*:0]const u16) com.Error!void {
        for (roles) |role| {
            try config.set_default(target, role);
        }
    }

    pub fn release(config: *IPolicyConfig) void {
        com.release(@ptrCast(config));
    }
};

pub const NotificationVtable = extern struct {
    QueryInterface: *const fn (
        *anyopaque,
        *const GUID,
        *?*anyopaque,
    ) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    OnDeviceStateChanged: *const fn (
        *anyopaque,
        ?[*:0]const u16,
        DeviceStates,
    ) callconv(.winapi) HRESULT,
    OnDeviceAdded: *const fn (*anyopaque, ?[*:0]const u16) callconv(.winapi) HRESULT,
    OnDeviceRemoved: *const fn (*anyopaque, ?[*:0]const u16) callconv(.winapi) HRESULT,
    OnDefaultDeviceChanged: *const fn (
        *anyopaque,
        DataFlow,
        Role,
        ?[*:0]const u16,
    ) callconv(.winapi) HRESULT,

    OnPropertyValueChanged: *const fn (
        *anyopaque,
        ?[*:0]const u16,
        PropertyKey,
    ) callconv(.winapi) HRESULT,
};

pub const NotificationClient = extern struct {
    vtable: *const NotificationVtable,
};

const Error = com.Error;

pub fn create_enumerator() com.Error!*IMMDeviceEnumerator {
    return try com.create(
        IMMDeviceEnumerator,
        &clsid_device_enumerator,
        &iid_device_enumerator,
    );
}

pub fn create_policy() com.Error!*IPolicyConfig {
    return try com.create(IPolicyConfig, &clsid_policy_config, &iid_policy_config);
}

pub fn to_data_flow(direction: Direction) DataFlow {
    assert(direction.is_valid());

    const result: DataFlow = switch (direction) {
        .capture => .capture,
        .render => .render,
    };

    return result;
}

pub fn to_direction(flow: DataFlow) ?Direction {
    const result: ?Direction = switch (flow) {
        .capture => .capture,
        .render => .render,
        else => null,
    };

    return result;
}
