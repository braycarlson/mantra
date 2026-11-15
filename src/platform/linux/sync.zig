const std = @import("std");

const assert = std.debug.assert;

const linux = std.os.linux;

pub const Mutex = struct {
    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    pub fn try_lock(mutex: *Mutex) bool {
        return mutex.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn lock(mutex: *Mutex) void {
        if (mutex.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null) {
            return;
        }

        while (mutex.state.swap(contended, .acquire) != unlocked) {
            futex_wait(&mutex.state.raw);
        }
    }

    pub fn unlock(mutex: *Mutex) void {
        const previous = mutex.state.swap(unlocked, .release);

        assert(previous != unlocked);

        if (previous == contended) {
            futex_wake(&mutex.state.raw);
        }
    }
};

fn futex_wait(address: *const u32) void {
    _ = linux.futex_3arg(address, .{ .cmd = .WAIT, .private = true }, Mutex.contended);
}

fn futex_wake(address: *const u32) void {
    _ = linux.futex_3arg(address, .{ .cmd = .WAKE, .private = true }, 1);
}

const testing = std.testing;

test "a mutex locks, refuses a second acquire, and releases" {
    var mutex = Mutex{};

    try testing.expect(mutex.try_lock());
    try testing.expect(!mutex.try_lock());

    mutex.unlock();

    mutex.lock();
    mutex.unlock();

    try testing.expect(mutex.try_lock());

    mutex.unlock();
}
