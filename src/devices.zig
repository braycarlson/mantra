const std = @import("std");

const device_module = @import("device.zig");
const platform = @import("platform.zig");
const runtime = @import("runtime.zig");

const assert = std.debug.assert;

const backend = platform.backend.devices;

const CapacityError = device_module.CapacityError;
const Device = device_module.Device;
const Direction = device_module.Direction;
const PlatformError = platform.PlatformError;
const RequestError = device_module.RequestError;

pub fn enumerate(list: *Device.List, direction: Direction) (CapacityError || PlatformError)!void {
    assert(direction.is_valid());
    assert(runtime.is_open());

    try backend.enumerate(list, direction);

    assert(list.count <= device_module.device_count_max);
}

pub fn default(direction: Direction) (CapacityError || PlatformError || RequestError)!Device.Id {
    assert(direction.is_valid());
    assert(runtime.is_open());

    const result = try backend.default(direction);

    assert(result.is_valid());
    assert(result.direction == direction);

    return result;
}

pub fn set_default(id: *const Device.Id) (PlatformError || RequestError)!void {
    assert(id.is_valid());
    assert(runtime.is_open());

    try backend.set_default(id);
}

const testing = std.testing;

const mock = platform.mock;

test enumerate {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    var list = Device.List.init();

    try enumerate(&list, .capture);

    try testing.expectEqual(@as(u32, 2), list.count);
    try testing.expectEqualStrings("Mock Microphone", list.slice()[0].get_name());
    try testing.expect(list.slice()[0].is_default);
}

test default {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const id = try default(.render);

    try testing.expectEqualStrings("mock-render-0", id.slice());
    try testing.expectEqual(Direction.render, id.direction);
}

test set_default {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const headphones = try Device.Id.init(.render, "mock-render-1");

    try set_default(&headphones);

    const id = try default(.render);

    try testing.expect(id.eql(&headphones));
}

test "a device that is not present is unknown to every call" {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const absent = try Device.Id.init(.capture, "absent");

    try testing.expectError(error.DeviceUnknown, set_default(&absent));
}

test "a direction with no default device reports the default missing" {
    mock.state.reset();

    try runtime.open();
    defer runtime.close();

    const id = try default(.capture);

    mock.state.remove(&id);

    try testing.expectError(error.DefaultMissing, default(.capture));
}
