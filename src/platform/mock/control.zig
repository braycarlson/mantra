const std = @import("std");

const contract = @import("../contract.zig");
const state = @import("state.zig");

const assert = std.debug.assert;

const DeviceId = contract.DeviceId;

pub const Error = contract.ControlError;

pub fn is_muted(id: *const DeviceId) Error!bool {
    state.record(.is_muted);

    if (state.should_fail(.is_muted)) {
        return Error.Failed;
    }

    const entry = try state.lookup(id);

    return entry.muted;
}

pub fn set_mute(id: *const DeviceId, muted: bool) Error!void {
    state.record(.set_mute);

    if (state.should_fail(.set_mute)) {
        return Error.Failed;
    }

    const entry = try state.lookup(id);

    entry.muted = muted;

    assert(entry.muted == muted);
}

pub fn get_volume(id: *const DeviceId) Error!f32 {
    state.record(.get_volume);

    if (state.should_fail(.get_volume)) {
        return Error.Failed;
    }

    const entry = try state.lookup(id);
    const result = contract.clamp_volume(entry.volume);

    assert(result >= contract.volume_min);
    assert(result <= contract.volume_max);

    return result;
}

pub fn set_volume(id: *const DeviceId, level: f32) Error!void {
    state.record(.set_volume);

    if (state.should_fail(.set_volume)) {
        return Error.Failed;
    }

    const entry = try state.lookup(id);

    entry.volume = contract.clamp_volume(level);

    assert(entry.volume >= contract.volume_min);
    assert(entry.volume <= contract.volume_max);
}

const testing = std.testing;

test "every control call is refused while the runtime is closed" {
    state.reset();
    defer state.clear();

    const id = state.entry_at(0).id;

    try testing.expectError(Error.NotOpen, is_muted(&id));
    try testing.expectError(Error.NotOpen, get_volume(&id));
    try testing.expectError(Error.NotOpen, set_mute(&id, true));
    try testing.expectError(Error.NotOpen, set_volume(&id, 0.5));
}

test "mute and volume round trip through the entry" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    const id = state.entry_at(0).id;

    try set_mute(&id, true);
    try testing.expect(try is_muted(&id));

    try set_volume(&id, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.25), try get_volume(&id), 0.001);
}

test "a level outside the contract bounds is clamped on the way in" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    const id = state.entry_at(0).id;

    try set_volume(&id, 4.0);
    try testing.expectApproxEqAbs(contract.volume_max, try get_volume(&id), 0.001);

    try set_volume(&id, -1.0);
    try testing.expectApproxEqAbs(contract.volume_min, try get_volume(&id), 0.001);
}

test "a scripted failure surfaces before the entry is touched" {
    state.reset();
    defer state.clear();

    state.set_open(true);

    const id = state.entry_at(0).id;

    state.fail_next(.is_muted);

    try testing.expectError(Error.Failed, is_muted(&id));
    try testing.expect(!try is_muted(&id));
}
