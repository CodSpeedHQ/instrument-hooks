const std = @import("std");
const builtin = @import("builtin");
const perf = @import("perf.zig");
const valgrind = @import("valgrind.zig");
const shared = @import("../shared.zig");
const ValgrindInstrument = valgrind.ValgrindInstrument;

pub const InstrumentHooks = union(enum) {
    valgrind: ValgrindInstrument,
    perf: perf.PerfInstrument,
    none: void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        if (ValgrindInstrument.is_instrumented()) {
            return Self{ .valgrind = ValgrindInstrument.init(allocator) };
        }

        var perf_inst = perf.PerfInstrument.init(allocator) catch {
            return Self{ .none = {} };
        };
        if (perf_inst.is_instrumented()) {
            return Self{ .perf = perf_inst };
        }

        return Self{ .none = {} };
    }

    pub inline fn deinit(self: *Self) void {
        switch (self.*) {
            .valgrind => {},
            .perf => self.perf.deinit(),
            .none => {},
        }
    }

    pub inline fn is_instrumented(self: *Self) bool {
        return switch (self.*) {
            .valgrind => ValgrindInstrument.is_instrumented(),
            .perf => |perf_inst| {
                var mutable_perf = perf_inst;
                return mutable_perf.is_instrumented();
            },
            .none => false,
        };
    }

    pub inline fn start_benchmark(self: *Self) !void {
        if (self.* == .perf) {
            return self.perf.start_benchmark();
        } else if (self.* == .valgrind) {
            return ValgrindInstrument.start_benchmark();
        }
    }

    pub inline fn stop_benchmark(self: *Self) !void {
        if (self.* == .valgrind) {
            return ValgrindInstrument.stop_benchmark();
        } else if (self.* == .perf) {
            return self.perf.stop_benchmark();
        }
    }

    pub inline fn set_executed_benchmark(self: *Self, pid: u32, uri: [*c]const u8) !void {
        switch (self.*) {
            .valgrind => ValgrindInstrument.set_executed_benchmark(pid, uri),
            .perf => try self.perf.set_executed_benchmark(pid, uri),
            .none => {},
        }
    }

    pub inline fn set_integration(self: *Self, name: [*c]const u8, version: [*c]const u8) !void {
        switch (self.*) {
            .valgrind => try self.valgrind.set_integration(name, version),
            .perf => try self.perf.set_integration(name, version),
            .none => {},
        }
    }

    pub inline fn add_marker(self: *Self, pid: u32, marker: shared.MarkerType) !void {
        if (self.* == .perf) {
            return self.perf.add_marker(pid, marker);
        }
    }
};
