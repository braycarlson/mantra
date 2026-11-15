const std = @import("std");

const assert = std.debug.assert;

pub const SrwLock = extern struct {
    ptr: ?*anyopaque = null,
};

pub const srwlock_init = SrwLock{ .ptr = null };

comptime {
    assert(@sizeOf(SrwLock) == @sizeOf(usize));
}

extern "kernel32" fn AcquireSRWLockExclusive(srwlock: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(srwlock: *SrwLock) callconv(.winapi) void;
extern "kernel32" fn TryAcquireSRWLockExclusive(srwlock: *SrwLock) callconv(.winapi) u8;

pub const Mutex = struct {
    srwlock: SrwLock = srwlock_init,

    pub fn try_lock(mutex: *Mutex) bool {
        return TryAcquireSRWLockExclusive(&mutex.srwlock) != 0;
    }

    pub fn lock(mutex: *Mutex) void {
        AcquireSRWLockExclusive(&mutex.srwlock);
    }

    pub fn unlock(mutex: *Mutex) void {
        ReleaseSRWLockExclusive(&mutex.srwlock);
    }
};
