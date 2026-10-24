const std = @import("std");

const contract = @import("../contract.zig");
const device_module = @import("../../device.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = contract.PlatformError;
const RequestError = device_module.RequestError;

pub fn enumerate(list: *Device.List, direction: Direction) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());
    assert(state.is_open());

    state.record(.enumerate);

    if (state.should_fail(.enumerate)) {
        return error.CallFailed;
    }

    try state.fill(list, direction);
}

pub fn default(direction: Direction) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());
    assert(state.is_open());

    state.record(.default);

    if (state.should_fail(.default)) {
        return error.CallFailed;
    }

    const index = state.default_index(direction) orelse return error.DefaultMissing;
    const result = state.entry_at(index).id;

    assert(result.is_valid());
    assert(result.direction == direction);

    return result;
}

pub fn set_default(id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(state.is_open());

    state.record(.set_default);

    if (state.should_fail(.set_default)) {
        return error.CallFailed;
    }

    const index = state.index_of(id) orelse return error.DeviceUnknown;

    state.set_default_index(id.direction, index);

    assert(state.default_index(id.direction).? == index);
}

const testing = std.testing;

test "enumeration returns one direction at a time" {
    state.reset();
    defer state.clear();

    state.mark_open();

    var render = Device.List.init();
    var capture = Device.List.init();

    try enumerate(&render, .render);
    try enumerate(&capture, .capture);

    try testing.expectEqual(@as(u32, 2), render.count);
    try testing.expectEqual(@as(u32, 2), capture.count);
}

test "the default device follows whichever device was set" {
    state.reset();
    defer state.clear();

    state.mark_open();

    const first = try default(.render);
    const other = state.entry_at(3).id;

    try set_default(&other);

    const moved = try default(.render);

    try testing.expect(!moved.eql(&first));
    try testing.expect(moved.eql(&other));
}

test "a device the script never installed is unknown" {
    state.reset();
    defer state.clear();

    state.mark_open();

    const absent = try Device.Id.init(.render, "mock.absent");

    try testing.expectError(error.DeviceUnknown, set_default(&absent));
}
