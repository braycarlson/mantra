const std = @import("std");

const com = @import("com.zig");
const contract = @import("../contract.zig");
const events = @import("events.zig");
const mmdevice = @import("mmdevice.zig");
const sync = @import("sync.zig");

const assert = std.debug.assert;

pub const Error = contract.RuntimeError;

var apartment: com.Apartment = .borrowed;
var lock: sync.Mutex = .{};
var opened: bool = false;
var owner: u32 = 0;

pub fn open() Error!void {
    lock.lock();
    defer lock.unlock();

    if (opened) {
        return Error.AlreadyOpen;
    }

    apartment = com.initialize() catch |err| {
        return to_runtime_error(err);
    };

    errdefer com.uninitialize(apartment);

    const probe = mmdevice.create_enumerator() catch |err| {
        return to_runtime_error(err);
    };

    com.release(probe);

    opened = true;
    owner = com.thread_id();

    assert(opened);
    assert(owner != 0);
}

pub fn close() void {
    events.unsubscribe();

    lock.lock();
    defer lock.unlock();

    if (!opened) {
        return;
    }

    assert(owner == com.thread_id());

    opened = false;

    com.uninitialize(apartment);

    apartment = .borrowed;
    owner = 0;

    assert(!opened);
}

pub fn is_open() bool {
    lock.lock();
    defer lock.unlock();

    return opened;
}

pub fn to_runtime_error(err: com.Error) Error {
    const result: Error = switch (err) {
        com.Error.Denied => Error.Denied,
        com.Error.NotOpen => Error.Unavailable,
        com.Error.Unavailable => Error.Unavailable,
        else => Error.Failed,
    };

    return result;
}

pub fn to_device_error(err: com.Error) contract.DeviceError {
    const result: contract.DeviceError = switch (err) {
        com.Error.Invalid => contract.DeviceError.Invalid,
        com.Error.NotFound => contract.DeviceError.NotFound,
        com.Error.NotOpen => contract.DeviceError.NotOpen,
        else => contract.DeviceError.Failed,
    };

    return result;
}

pub fn to_control_error(err: com.Error) contract.ControlError {
    const result: contract.ControlError = switch (err) {
        com.Error.Denied => contract.ControlError.Denied,
        com.Error.Invalid => contract.ControlError.Invalid,
        com.Error.NotFound => contract.ControlError.NotFound,
        com.Error.NotOpen => contract.ControlError.NotOpen,
        else => contract.ControlError.Failed,
    };

    return result;
}
