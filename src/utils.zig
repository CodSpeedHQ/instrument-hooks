const std = @import("std");
const c = @cImport(@cInclude("time.h"));
const errno = @cImport(@cInclude("errno.h"));

extern "c" fn nanosleep(nanos: u64) c_int;

// Adaptation of [`std.Thread.sleep`](https://ziglang.org/documentation/0.14.0/std/#std.Thread.sleep)
// to ensure that the C code is architecture-independent. The stdlib implementation uses inline syscalls,
// which only works on a single architecture and is not portable.
pub fn sleep(nanoseconds: u64) void {
    const s = nanoseconds / std.time.ns_per_s;
    const ns = nanoseconds % std.time.ns_per_s;

    var req: c.struct_timespec = .{
        .tv_sec = std.math.cast(c.time_t, s) orelse std.math.maxInt(c.time_t),
        .tv_nsec = std.math.cast(c_long, ns) orelse std.math.maxInt(c_long),
    };
    var rem: c.struct_timespec = undefined;

    while (true) {
        const ret = c.nanosleep(&req, &rem);

        if (ret == errno.EINTR) {
            req = rem;
            continue;
        } else {
            return;
        }
    }
}

pub fn clock_gettime_monotonic() u64 {
    var ts: c.struct_timespec = undefined;
    const ret = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    if (ret != 0) {
        @panic("clock_gettime failed");
    }
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

test "sleep for at least 1 second" {
    const start = try std.time.Instant.now();
    sleep(1 * std.time.ns_per_s);
    const end = try std.time.Instant.now();

    const elapsed_ns: u64 = end.since(start);
    const elapsed_s = elapsed_ns / std.time.ns_per_s;

    std.debug.assert(elapsed_s >= 1);
    std.debug.assert(elapsed_s < 2);
}
