const builtin = @import("builtin");
const std = @import("std");

/// A yield-spinlock avoids std primitives that emit syscall asm or bake an
/// architecture-specific pthread_mutex_t size into the once-per-OS C output.
/// sched_yield is instead a plain libc call with a stable prototype.
pub const Lock = struct {
    state: u32 = 0,

    pub fn lock(self: *Lock) void {
        while (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) != null) {
            if (comptime builtin.os.tag == .windows) {
                std.atomic.spinLoopHint();
            } else {
                _ = std.c.sched_yield();
            }
        }
    }

    pub fn unlock(self: *Lock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }
};

test "lock serializes concurrent increments" {
    const Context = struct {
        const increment_count = 10_000;

        lock: Lock = .{},
        counter: usize = 0,

        fn increment(context: *@This()) void {
            for (0..increment_count) |_| {
                context.lock.lock();
                context.counter += 1;
                context.lock.unlock();
            }
        }
    };

    const thread_count = 8;
    var context: Context = .{};
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();

    while (spawned < threads.len) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, Context.increment, .{&context});
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(thread_count * Context.increment_count, context.counter);
}

test "unlock resets state and permits relocking" {
    var subject: Lock = .{};

    subject.lock();
    subject.unlock();
    try std.testing.expectEqual(@as(u32, 0), subject.state);

    subject.lock();
    subject.unlock();
    try std.testing.expectEqual(@as(u32, 0), subject.state);
}
