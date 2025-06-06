const instruments = @import("./instruments/root.zig");
const InstrumentHooks = instruments.InstrumentHooks;
const builtin = @import("builtin");
const std = @import("std");

pub const panic = if (builtin.is_test) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.no_panic;
const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

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
        return h.is_instrumented();
    }
    return false;
}

pub export fn instrument_hooks_start_benchmark(hooks: ?*InstrumentHooks) u8 {
    if (hooks) |h| {
        h.start_benchmark() catch {
            return 1;
        };
    }
    return 0;
}

pub export fn instrument_hooks_stop_benchmark(hooks: ?*InstrumentHooks) u8 {
    if (hooks) |h| {
        h.stop_benchmark() catch {
            return 1;
        };
    }
    return 0;
}

pub export fn instrument_hooks_executed_benchmark(hooks: ?*InstrumentHooks, pid: u32, uri: [*c]const u8) u8 {
    if (hooks) |h| {
        h.set_executed_benchmark(pid, uri) catch {
            return 1;
        };
    }
    return 0;
}

pub export fn instrument_hooks_set_integration(hooks: ?*InstrumentHooks, name: [*c]const u8, version: [*c]const u8) u8 {
    if (hooks) |h| {
        h.set_integration(name, version) catch {
            return 1;
        };
    }
    return 0;
}

test "no crash when not instrumented" {
    const instance = instrument_hooks_init();
    defer instrument_hooks_deinit(instance);

    _ = instrument_hooks_is_instrumented(instance);
    try std.testing.expectEqual(0, instrument_hooks_start_benchmark(instance));
    try std.testing.expectEqual(0, instrument_hooks_stop_benchmark(instance));
    try std.testing.expectEqual(0, instrument_hooks_executed_benchmark(instance, 0, "test"));
    try std.testing.expectEqual(0, instrument_hooks_set_integration(instance, "pytest-codspeed", "1.0"));
}
