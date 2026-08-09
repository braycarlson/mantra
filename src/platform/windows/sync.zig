const std = @import("std");

const assert = std.debug.assert;

pub const SrwLock = extern struct {
    ptr: ?*anyopaque = null,
};

pub const srwlock_init = SrwLock{ .ptr = null };

comptime {
    assert(@sizeOf(SrwLock) == @sizeOf(usize));
}

extern "kernel32" fn AcquireSRWLockExclusive(handle: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(handle: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn TryAcquireSRWLockExclusive(handle: *SrwLock) callconv(.winapi) u8;

pub const Mutex = struct {
    handle: SrwLock = srwlock_init,

    pub fn try_lock(mutex: *Mutex) bool {
        return TryAcquireSRWLockExclusive(&mutex.handle) != 0;
    }

    pub fn lock(mutex: *Mutex) void {
        AcquireSRWLockExclusive(&mutex.handle);
    }

    pub fn unlock(mutex: *Mutex) void {
        ReleaseSRWLockExclusive(&mutex.handle);
    }
};
