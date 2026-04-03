const instrument_hooks = @import("./instrument_hooks.zig");
const InstrumentHooks = instrument_hooks.InstrumentHooks;
const builtin = @import("builtin");
const features = @import("./features.zig");
const shared = @import("./shared.zig");
const std = @import("std");
const utils = @import("./utils.zig");

pub const panic = if (builtin.is_test) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.no_panic;
const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

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

pub export fn instrument_hooks_set_executed_benchmark(hooks: ?*InstrumentHooks, pid: u32, uri: [*c]const u8) u8 {
    if (hooks) |h| {
        h.instrument.set_executed_benchmark(pid, uri) catch {
            return 1;
        };
    }
    return 0;
}

// Deprecated: use instrument_hooks_set_executed_benchmark instead
pub export fn instrument_hooks_executed_benchmark(hooks: ?*InstrumentHooks, pid: u32, uri: [*c]const u8) u8 {
    return instrument_hooks_set_executed_benchmark(hooks, pid, uri);
}

pub export fn instrument_hooks_set_integration(hooks: ?*InstrumentHooks, name: [*c]const u8, version: [*c]const u8) u8 {
    if (hooks) |h| {
        h.instrument.set_integration(name, version) catch {
            return 1;
        };
    }
    return 0;
}

pub const MARKER_TYPE_SAMPLE_START: u8 = 0;
pub const MARKER_TYPE_SAMPLE_END: u8 = 1;
pub const MARKER_TYPE_BENCHMARK_START: u8 = 2;
pub const MARKER_TYPE_BENCHMARK_END: u8 = 3;

pub export fn instrument_hooks_add_marker(hooks: ?*InstrumentHooks, pid: u32, marker_type: u8, timestamp: u64) u8 {
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

pub export fn instrument_hooks_current_timestamp() u64 {
    return utils.clock_gettime_monotonic();
}

pub export fn instrument_hooks_set_environment(
    hooks: ?*InstrumentHooks,
    section_name: [*c]const u8,
    key: [*c]const u8,
    value: [*c]const u8,
) u8 {
    if (section_name == null or key == null or value == null) return 1;
    if (hooks) |h| {
        h.environment.setIntegrationEnvironment(std.mem.span(section_name), std.mem.span(key), std.mem.span(value)) catch return 1;
        return 0;
    }
    return 1;
}

pub export fn instrument_hooks_set_environment_list(
    hooks: ?*InstrumentHooks,
    section_name: [*c]const u8,
    key: [*c]const u8,
    values: [*c]const [*c]const u8,
    count: u32,
) u8 {
    if (section_name == null or key == null or values == null) return 1;
    if (hooks) |h| {
        const slices = allocator.alloc([]const u8, count) catch return 1;
        defer allocator.free(slices);
        for (0..count) |i| {
            if (values[i] == null) return 1;
            slices[i] = std.mem.span(values[i]);
        }
        h.environment.setIntegrationEnvironmentList(std.mem.span(section_name), std.mem.span(key), slices) catch return 1;
        return 0;
    }
    return 1;
}

pub export fn instrument_hooks_write_environment(hooks: ?*InstrumentHooks, pid: u32) u8 {
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
    try std.testing.expectEqual(0, instrument_hooks_executed_benchmark(instance, 0, "test"));
    try std.testing.expectEqual(0, instrument_hooks_set_integration(instance, "pytest-codspeed", "1.0"));
}
