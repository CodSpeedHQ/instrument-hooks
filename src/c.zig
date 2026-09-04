const instrument_hooks = @import("./instrument_hooks.zig");
const InstrumentHooks = instrument_hooks.InstrumentHooks;
const builtin = @import("builtin");
const features = @import("./features.zig");
const shared = @import("./shared.zig");
const std = @import("std");
const utils = @import("./utils.zig");
const valgrind_helper = @import("./helpers/valgrind.zig");

pub const panic = if (builtin.is_test) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.no_panic;
const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

/// Cast a C char pointer to a u8 pointer for internal Zig usage.
fn toU8(ptr: [*c]const c_char) [*c]const u8 {
    return @ptrCast(ptr);
}

pub export fn instrument_hooks_set_feature(feature: u64, enabled: bool) void {
    const feature_enum = @as(features.Feature, @enumFromInt(feature));
    features.set_feature(feature_enum, enabled);
}

pub export fn instrument_hooks_init() ?*InstrumentHooks {
    const hooks = allocator.create(InstrumentHooks) catch {
        return null;
    };

    hooks.* = InstrumentHooks.init(allocator) catch {
        allocator.destroy(hooks);
        return null;
    };

    return hooks;
}

pub export fn instrument_hooks_deinit(hooks: ?*InstrumentHooks) void {
    if (hooks) |h| {
        h.deinit();
        allocator.destroy(h);
    }
}

pub export fn instrument_hooks_is_instrumented(hooks: ?*InstrumentHooks) bool {
    if (hooks) |h| {
        return h.instrument.is_instrumented();
    }
    return false;
}

pub export fn instrument_hooks_start_benchmark(hooks: ?*InstrumentHooks) u8 {
    if (hooks) |h| {
        h.instrument.start_benchmark() catch {
            return 1;
        };
    }
    return 0;
}

pub export fn instrument_hooks_stop_benchmark(hooks: ?*InstrumentHooks) u8 {
    if (hooks) |h| {
        h.instrument.stop_benchmark() catch {
            return 1;
        };
    }
    return 0;
}

pub export fn instrument_hooks_set_executed_benchmark(hooks: ?*InstrumentHooks, pid: i32, uri: [*c]const c_char) u8 {
    if (hooks) |h| {
        h.instrument.set_executed_benchmark(pid, toU8(uri)) catch {
            return 1;
        };
    }
    return 0;
}

// Deprecated: use instrument_hooks_set_executed_benchmark instead
pub export fn instrument_hooks_executed_benchmark(hooks: ?*InstrumentHooks, pid: i32, uri: [*c]const c_char) u8 {
    return instrument_hooks_set_executed_benchmark(hooks, pid, uri);
}

pub export fn instrument_hooks_set_integration(hooks: ?*InstrumentHooks, name: [*c]const c_char, version: [*c]const c_char) u8 {
    if (hooks) |h| {
        h.instrument.set_integration(toU8(name), toU8(version)) catch {
            return 1;
        };
    }
    return 0;
}

pub const MARKER_TYPE_SAMPLE_START: u8 = 0;
pub const MARKER_TYPE_SAMPLE_END: u8 = 1;
pub const MARKER_TYPE_BENCHMARK_START: u8 = 2;
pub const MARKER_TYPE_BENCHMARK_END: u8 = 3;

pub export fn instrument_hooks_add_marker(hooks: ?*InstrumentHooks, pid: i32, marker_type: u8, timestamp: u64) u8 {
    if (hooks) |h| {
        const marker_enum = switch (marker_type) {
            MARKER_TYPE_SAMPLE_START => shared.MarkerType{ .SampleStart = timestamp },
            MARKER_TYPE_SAMPLE_END => shared.MarkerType{ .SampleEnd = timestamp },
            MARKER_TYPE_BENCHMARK_START => shared.MarkerType{ .BenchmarkStart = timestamp },
            MARKER_TYPE_BENCHMARK_END => shared.MarkerType{ .BenchmarkEnd = timestamp },
            else => return 2, // Invalid marker type
        };
        h.instrument.add_marker(pid, marker_enum) catch {
            return 1;
        };
    }
    return 0;
}

// macOS uses Mach absolute time with timebase scaling (mirrors scripts/stub.c).
const MachTimebaseInfo = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_absolute_time() u64;
extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;

// Returns monotonic time since boot in nanoseconds.
//
// NOTE: Maximum representable timestamp is u64::MAX nanoseconds = 18,446,744,073,709,551,615 ns
//       which equals ~584.94 years from epoch. Since CLOCK_MONOTONIC measures time since boot,
//       a system would need to run for ~585 years continuously to overflow this value.
pub export fn instrument_hooks_current_timestamp() u64 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const ts = std.posix.clock_gettime(std.posix.clockid_t.MONOTONIC) catch unreachable;
            const s = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s;
            const nsec: u64 = @intCast(ts.nsec);
            break :blk s + nsec;
        },
        .macos => blk: {
            const S = struct {
                var cached: MachTimebaseInfo = .{ .numer = 0, .denom = 0 };
                var once = std.once(init);
                fn init() void {
                    var info: MachTimebaseInfo = undefined;
                    if (mach_timebase_info(&info) != 0 or info.denom == 0) {
                        info = .{ .numer = 1, .denom = 1 };
                    }
                    cached = info;
                }
            };
            S.once.call();
            break :blk mach_absolute_time() * S.cached.numer / S.cached.denom;
        },
        .windows => 0,
        else => @compileError("unsupported OS for instrument_hooks_current_timestamp"),
    };
}

pub export fn instrument_hooks_set_environment(
    hooks: ?*InstrumentHooks,
    section_name: [*c]const c_char,
    key: [*c]const c_char,
    value: [*c]const c_char,
) u8 {
    if (section_name == null or key == null or value == null) return 1;
    if (hooks) |h| {
        h.environment.setIntegrationEnvironment(std.mem.span(toU8(section_name)), std.mem.span(toU8(key)), std.mem.span(toU8(value))) catch return 1;
        return 0;
    }
    return 1;
}

pub export fn instrument_hooks_set_environment_list(
    hooks: ?*InstrumentHooks,
    section_name: [*c]const c_char,
    key: [*c]const c_char,
    values: [*c]const [*c]const c_char,
    count: u32,
) u8 {
    if (section_name == null or key == null or values == null) return 1;
    if (hooks) |h| {
        const slices = allocator.alloc([]const u8, count) catch return 1;
        defer allocator.free(slices);
        const u8_values: [*c]const [*c]const u8 = @ptrCast(values);
        for (0..count) |i| {
            if (u8_values[i] == null) return 1;
            slices[i] = std.mem.span(u8_values[i]);
        }
        h.environment.setIntegrationEnvironmentList(std.mem.span(toU8(section_name)), std.mem.span(toU8(key)), slices) catch return 1;
        return 0;
    }
    return 1;
}

pub export fn instrument_hooks_callgrind_add_obj_skip(path: [*c]const c_char) u8 {
    if (path == null) return 1;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return 0;

    // Callgrind matches obj-skip entries via exact strcmp against the name
    // Valgrind recorded in obj_node, which comes from its debuginfo reader
    // and is the realpath of the mapped file.
    const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
    var real_path: [std.fs.max_path_bytes + 1]u8 = @splat(0);
    _ = std.fs.realpath(path_slice, real_path[0..std.fs.max_path_bytes]) catch return 0;

    valgrind_helper.callgrind_add_obj_skip(@ptrCast(&real_path[0]));
    return 0;
}

pub export fn instrument_hooks_write_environment(hooks: ?*InstrumentHooks, pid: i32) u8 {
    if (hooks) |h| {
        return h.environment.writeEnvironment(pid);
    }
    return 0;
}

test "no crash when not instrumented" {
    const instance = instrument_hooks_init();
    defer instrument_hooks_deinit(instance);

    _ = instrument_hooks_is_instrumented(instance);
    _ = instrument_hooks_set_feature(0, true);
    try std.testing.expectEqual(0, instrument_hooks_start_benchmark(instance));
    try std.testing.expectEqual(0, instrument_hooks_stop_benchmark(instance));
    try std.testing.expectEqual(0, instrument_hooks_executed_benchmark(instance, 0, @ptrCast("test")));
    try std.testing.expectEqual(0, instrument_hooks_set_integration(instance, @ptrCast("pytest-codspeed"), @ptrCast("1.0")));
}

test "callgrind_add_obj_skip is a no-op outside valgrind" {
    // Outside valgrind the macro expands to nothing; we only assert that the
    // realpath handling and null guard don't crash.
    try std.testing.expectEqual(@as(u8, 1), instrument_hooks_callgrind_add_obj_skip(null));
    try std.testing.expectEqual(@as(u8, 0), instrument_hooks_callgrind_add_obj_skip(@ptrCast("/nonexistent/path/that/will/not/resolve")));
    try std.testing.expectEqual(@as(u8, 0), instrument_hooks_callgrind_add_obj_skip(@ptrCast("/")));
}

test "concurrent exports keep runner request/ack pairing" {
    const fifo = @import("./fifo/root.zig");
    const thread_count = 4;
    const markers_per_thread = 50;

    try fifo.Pipe.create(shared.RUNNER_ACK_FIFO);
    try fifo.Pipe.create(shared.RUNNER_CTL_FIFO);

    var ctl = try fifo.Pipe.openRead(allocator, shared.RUNNER_CTL_FIFO);
    defer ctl.deinit();
    var ack = try fifo.Pipe.openWrite(allocator, shared.RUNNER_ACK_FIFO);
    defer ack.deinit();

    // Answers every command strictly one at a time: a torn or interleaved
    // request/ack sequence surfaces as an unexpected response on the client side.
    const Runner = struct {
        ctl: *fifo.Pipe.Reader,
        ack: *fifo.Pipe.Writer,
        markers_seen: usize = 0,
        failed: bool = false,

        fn run(self: *@This()) void {
            while (self.markers_seen < thread_count * markers_per_thread) {
                const cmd = self.ctl.waitForResponse(5 * std.time.ns_per_s) catch {
                    self.failed = true;
                    return;
                };
                defer cmd.deinit(allocator);

                const reply: fifo.Command = switch (cmd) {
                    .GetIntegrationMode => .{ .IntegrationModeResponse = .Analysis },
                    .AddMarker => blk: {
                        self.markers_seen += 1;
                        break :blk .Ack;
                    },
                    else => .Ack,
                };
                self.ack.sendCmd(reply) catch {
                    self.failed = true;
                    return;
                };
            }
        }
    };

    // Each worker owns an instance so init negotiation (whose response is not
    // an Ack) races against other instances' traffic on the same FIFOs.
    const Worker = struct {
        instrumented: bool = false,
        failures: usize = 0,

        fn run(self: *@This()) void {
            const instance = instrument_hooks_init();
            defer instrument_hooks_deinit(instance);
            self.instrumented = instance != null and instance.?.instrument == .analysis;

            for (0..markers_per_thread) |i| {
                if (instrument_hooks_add_marker(instance, 0, MARKER_TYPE_SAMPLE_START, @intCast(i)) != 0) {
                    self.failures += 1;
                }
            }
        }
    };

    var runner = Runner{ .ctl = &ctl, .ack = &ack };
    const runner_thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});

    var workers: [thread_count]Worker = @splat(.{});
    var threads: [thread_count]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (threads) |thread| thread.join();
    runner_thread.join();

    try std.testing.expect(!runner.failed);
    try std.testing.expectEqual(thread_count * markers_per_thread, runner.markers_seen);
    for (workers) |worker| {
        try std.testing.expect(worker.instrumented);
        try std.testing.expectEqual(@as(usize, 0), worker.failures);
    }
}
