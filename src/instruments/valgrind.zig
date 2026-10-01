const std = @import("std");
const valgrind = @import("../helpers/valgrind.zig");
const features = @import("../features.zig");

pub const ValgrindInstrument = struct {
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        if (!ValgrindInstrument.is_instrumented()) {
            return error.NotInstrumented;
        }

        return Self{
            .allocator = allocator,
        };
    }

    pub inline fn is_instrumented() bool {
        return valgrind.running_on_valgrind() > 0;
    }

    pub inline fn set_integration(self: Self, name: [*c]const u8, version: [*c]const u8) !void {
        const metadata = try std.fmt.allocPrintZ(
            self.allocator,
            "Metadata: {s} {s}",
            .{ name, version },
        );
        defer self.allocator.free(metadata);

        valgrind.callgrind_dump_stats_at(metadata.ptr);
    }

    pub inline fn start_benchmark() void {
        if (!features.is_feature_enabled(.disable_callgrind_markers)) {
            valgrind.callgrind_zero_stats();
            valgrind.callgrind_start_instrumentation();
        }
    }

    pub inline fn stop_benchmark() void {
        if (!features.is_feature_enabled(.disable_callgrind_markers)) {
            valgrind.callgrind_stop_instrumentation();
        }
    }

    pub inline fn set_executed_benchmark(pid: i32, uri: [*c]const u8) void {
        // The benchmark's pid is declared in the part's header, so when it ran
        // in another process, this process's own cost in the part can be told
        // apart.
        var buf: [32]u8 = undefined;
        const desc = std.fmt.bufPrintZ(&buf, "Benchmark pid: {d}", .{pid}) catch unreachable;
        valgrind.callgrind_add_desc(desc.ptr);

        valgrind.callgrind_dump_stats_at(uri);
    }
};
