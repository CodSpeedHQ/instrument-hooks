const std = @import("std");
const c = @cImport(@cInclude("time.h"));
const errno = @cImport(@cInclude("errno.h"));
const fcntl_h = @cImport(@cInclude("fcntl.h"));

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

pub fn setNonBlocking(fd: std.posix.fd_t) void {
    const current_flags = fcntl_h.fcntl(fd, fcntl_h.F_GETFL, @as(c_int, 0));
    const new_flags = current_flags | fcntl_h.O_NONBLOCK;
    _ = fcntl_h.fcntl(fd, fcntl_h.F_SETFL, new_flags);
}

// Returns monotonic time since boot in nanoseconds.
//
// NOTE: Maximum representable timestamp is u64::MAX nanoseconds = 18,446,744,073,709,551,615 ns
//       which equals ~584.94 years from epoch (year 2554-07-21T23:34:33.709551615). Since CLOCK_MONOTONIC
//       measures time since boot, a system would need to run for ~585 years continuously to overflow this value.
pub fn clock_gettime_monotonic() u64 {
    const ts = std.posix.clock_gettime(std.posix.clockid_t.MONOTONIC) catch unreachable;

    const s = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s;
    const nsec: u64 = @intCast(ts.nsec);

    return s + nsec;
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
