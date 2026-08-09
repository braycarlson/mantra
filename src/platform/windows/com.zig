const std = @import("std");

const assert = std.debug.assert;

pub const BOOL = i32;
pub const HRESULT = i32;

pub const Error = error{
    Denied,
    Failed,
    Invalid,
    NotFound,
    NotOpen,
    Unavailable,
};

pub const s_ok: HRESULT = 0;
pub const s_false: HRESULT = 1;
pub const e_no_interface: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const clsctx_all: u32 = 0x17;
pub const coinit_multi_threaded: u32 = 0x0;
pub const coinit_apartment_threaded: u32 = 0x2;

pub const storage_read: u32 = 0x0;

pub const vt_empty: u16 = 0;
pub const vt_lpwstr: u16 = 31;

const code_access_denied: u32 = 0x80070005;
const code_changed_mode: u32 = 0x80010106;
const code_class_not_registered: u32 = 0x80040154;
const code_device_invalidated: u32 = 0x88890004;
const code_file_not_found: u32 = 0x80070002;
const code_invalid_argument: u32 = 0x80070057;
const code_no_interface: u32 = 0x80004002;
const code_not_found: u32 = 0x80070490;
const code_not_initialized: u32 = 0x800401f0;
const code_out_of_memory: u32 = 0x8007000e;
const code_pointer: u32 = 0x80004003;
const code_service_not_running: u32 = 0x88890010;

comptime {
    assert(clsctx_all == 0x17);
    assert(coinit_multi_threaded == 0);
    assert(coinit_apartment_threaded == 2);
    assert(vt_lpwstr == 31);
    assert(s_ok == 0);
}

pub const GUID = extern struct {
    data1: u32 = 0,
    data2: u16 = 0,
    data3: u16 = 0,
    data4: [8]u8 = [_]u8{0} ** 8,

    pub fn eql(value: *const GUID, other: *const GUID) bool {
        if (value.data1 != other.data1) {
            return false;
        }

        if (value.data2 != other.data2 or value.data3 != other.data3) {
            return false;
        }

        return std.mem.eql(u8, &value.data4, &other.data4);
    }
};

pub fn guid(comptime text: []const u8) GUID {
    const result = comptime block: {
        if (text.len != 36) {
            @compileError("a GUID literal must be exactly 36 characters");
        }

        break :block GUID{
            .data1 = digits(u32, text[0..8]),
            .data2 = digits(u16, text[9..13]),
            .data3 = digits(u16, text[14..18]),
            .data4 = .{
                digits(u8, text[19..21]),
                digits(u8, text[21..23]),
                digits(u8, text[24..26]),
                digits(u8, text[26..28]),
                digits(u8, text[28..30]),
                digits(u8, text[30..32]),
                digits(u8, text[32..34]),
                digits(u8, text[34..36]),
            },
        };
    };

    return result;
}

fn digits(comptime T: type, comptime source: []const u8) T {
    const result = comptime block: {
        var value: T = 0;

        for (source) |byte| {
            const digit: T = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => @compileError("a GUID literal must be hexadecimal"),
            };

            value = value * 16 + digit;
        }

        break :block value;
    };

    return result;
}

pub const IUnknownVtable = extern struct {
    QueryInterface: *const fn (
        *IUnknown,
        *const GUID,
        *?*anyopaque,
    ) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
    Release: *const fn (*IUnknown) callconv(.winapi) u32,
};

pub const IUnknown = extern struct {
    vtable: *const IUnknownVtable,
};

pub const PropertyKey = extern struct {
    fmtid: GUID = .{},
    pid: u32 = 0,
};

pub const Blob = extern struct {
    count: u32 = 0,
    items: ?[*]u8 = null,
};

pub const PropVariant = extern struct {
    vt: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    data: extern union {
        int32: i32,
        uint32: u32,
        int64: i64,
        uint64: u64,
        real32: f32,
        real64: f64,
        text: ?[*:0]u16,
        blob: Blob,
    } = .{ .uint64 = 0 },
};

comptime {
    assert(@offsetOf(PropVariant, "data") == 8);
    assert(@sizeOf(PropVariant) >= 16);
    assert(@sizeOf(PropertyKey) == 20);
}

pub const Apartment = enum(u8) {
    borrowed = 0,
    owned = 1,
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*IUnknown,
    context: u32,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;

extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn PropVariantClear(value: *PropVariant) callconv(.winapi) HRESULT;

extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

pub fn initialize() Error!Apartment {
    const status = CoInitializeEx(null, coinit_multi_threaded);

    if (succeeded(status)) {
        return .owned;
    }

    if (to_code(status) == code_changed_mode) {
        return .borrowed;
    }

    return to_error(status);
}

pub fn uninitialize(apartment: Apartment) void {
    if (apartment == .borrowed) {
        return;
    }

    CoUninitialize();
}

pub fn create(comptime Interface: type, clsid: *const GUID, iid: *const GUID) Error!*Interface {
    var object: ?*anyopaque = null;

    const status = CoCreateInstance(clsid, null, clsctx_all, iid, &object);

    if (failed(status)) {
        return to_error(status);
    }

    const raw = object orelse {
        return Error.Failed;
    };

    return @ptrCast(@alignCast(raw));
}

pub fn release(object: anytype) void {
    const unknown: *IUnknown = @ptrCast(object);

    _ = unknown.vtable.Release(unknown);
}

pub fn free(memory: ?*anyopaque) void {
    CoTaskMemFree(memory);
}

pub fn clear(value: *PropVariant) void {
    _ = PropVariantClear(value);
}

pub fn thread_id() u32 {
    return GetCurrentThreadId();
}

pub fn succeeded(status: HRESULT) bool {
    return status >= 0;
}

pub fn failed(status: HRESULT) bool {
    return status < 0;
}

pub fn to_code(status: HRESULT) u32 {
    const result: u32 = @bitCast(status);

    return result;
}

pub fn to_error(status: HRESULT) Error {
    assert(failed(status));

    const result: Error = switch (to_code(status)) {
        code_access_denied => Error.Denied,
        code_class_not_registered => Error.Unavailable,
        code_device_invalidated => Error.NotFound,
        code_file_not_found => Error.NotFound,
        code_invalid_argument => Error.Invalid,
        code_no_interface => Error.Unavailable,
        code_not_found => Error.NotFound,
        code_not_initialized => Error.NotOpen,
        code_out_of_memory => Error.Failed,
        code_pointer => Error.Invalid,
        code_service_not_running => Error.Unavailable,
        else => Error.Failed,
    };

    return result;
}

pub fn check(status: HRESULT) Error!void {
    if (failed(status)) {
        return to_error(status);
    }
}
