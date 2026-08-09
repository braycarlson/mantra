const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const DeviceId = contract.DeviceId;
const DeviceList = contract.DeviceList;
const Direction = contract.Direction;

pub const Error = contract.DeviceError;

pub fn enumerate(direction: Direction, list: *DeviceList) Error!void {
    assert(direction.is_valid());

    state.record(.enumerate);

    if (!state.is_open()) {
        return Error.NotOpen;
    }

    if (state.should_fail(.enumerate)) {
        return Error.Failed;
    }

    try state.fill(direction, list);
}

pub fn default(direction: Direction) Error!DeviceId {
    assert(direction.is_valid());

    state.record(.default);

    if (!state.is_open()) {
        return Error.NotOpen;
    }

    if (state.should_fail(.default)) {
        return Error.Failed;
    }

    const index = state.default_index(direction) orelse {
        return Error.NotFound;
    };

    const result = state.entry_at(index).id;

    assert(result.is_valid());
    assert(result.direction == direction);

    return result;
}

pub fn set_default(id: *const DeviceId) Error!void {
    state.record(.set_default);

    if (!state.is_open()) {
        return Error.NotOpen;
    }

    if (!id.is_valid()) {
        return Error.Invalid;
    }

    if (state.should_fail(.set_default)) {
        return Error.Failed;
    }

    const index = state.index_of(id) orelse {
        return Error.NotFound;
    };

    state.set_default_index(id.direction, index);

    assert(state.default_index(id.direction).? == index);
}

const testing = std.testing;

test "enumeration is refused while the runtime is closed" {
    state.reset();
    defer state.clear();

    var list = DeviceList.init();

    try testing.expectError(Error.NotOpen, enumerate(.render, &list));
    try testing.expectError(Error.NotOpen, default(.render));
}

test "enumeration returns one direction at a time" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    var render = DeviceList.init();
    var capture = DeviceList.init();

    try enumerate(.render, &render);
    try enumerate(.capture, &capture);

    try testing.expectEqual(@as(u32, 2), render.count);
    try testing.expectEqual(@as(u32, 2), capture.count);
}

test "the default device follows whichever device was set" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    const first = try default(.render);
    const other = state.entry_at(3).id;

    try set_default(&other);

    const moved = try default(.render);

    try testing.expect(!moved.eql(&first));
    try testing.expect(moved.eql(&other));
}

test "a device the script never installed is reported as missing" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    const absent = try DeviceId.init(.render, "mock.absent");

    try testing.expectError(Error.NotFound, set_default(&absent));
}
