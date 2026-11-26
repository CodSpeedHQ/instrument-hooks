const std = @import("std");
const runner_fifo = @import("../runner_fifo.zig");
const shared = @import("../shared.zig");

/// Creates a complete FIFO-based instrument struct that validates a specific integration mode
pub fn FifoInstrument(comptime mode: shared.IntegrationMode, comptime error_type: anytype) type {
    return struct {
        fifo: runner_fifo.RunnerFifo,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            var fifo = try runner_fifo.RunnerFifo.init(allocator);

            // Ensure both the runner and integration FIFO are compatible
            fifo.validate_protocol_version() catch |err| {
                fifo.deinit();
                return err;
            };

            // Get the instrumentation mode from the runner
            const detected_mode = fifo.get_integration_mode() catch |err| {
                fifo.deinit();
                return err;
            };

            // Only accept if the runner is in the correct mode
            if (detected_mode != mode) {
                fifo.deinit();
                return error_type.ModeError;
            }

            return Self{ .fifo = fifo };
        }

        pub fn deinit(self: *Self) void {
            self.fifo.deinit();
        }

        pub fn send_version(self: *Self, protocol_version: u64) !void {
            try self.fifo.send_version(protocol_version);
        }

        pub fn start_benchmark(self: *Self) !void {
            try self.fifo.start_benchmark();
        }

        pub fn stop_benchmark(self: *Self) !void {
            try self.fifo.stop_benchmark();
        }

        pub fn set_executed_benchmark(self: *Self, pid: i32, uri: [*c]const u8) !void {
            try self.fifo.set_executed_benchmark(pid, uri);
        }

        pub fn set_integration(self: *Self, name: [*c]const u8, version: [*c]const u8) !void {
            try self.fifo.set_integration(name, version);
        }

        pub fn add_marker(self: *Self, pid: i32, marker: shared.MarkerType) !void {
            try self.fifo.add_marker(pid, marker);
        }
    };
}

test "init stops after the version ack times out" {
    const allocator = std.testing.allocator;
    const fifo = @import("../fifo/root.zig");

    try fifo.Pipe.create(shared.RUNNER_ACK_FIFO);
    try fifo.Pipe.create(shared.RUNNER_CTL_FIFO);

    // Hold the control FIFO open like a runner that never replies.
    var ctl = try fifo.Pipe.openRead(allocator, shared.RUNNER_CTL_FIFO);
    defer ctl.deinit();

    const Instrument = FifoInstrument(.Walltime, error{ModeError});
    try std.testing.expectError(error.AckTimeout, Instrument.init(allocator));

    // Only SetVersion was sent: init gave up before GetIntegrationMode.
    const cmd = try ctl.waitForResponse(null);
    defer cmd.deinit(allocator);
    try std.testing.expect(cmd == .SetVersion);
    try std.testing.expectError(error.AckTimeout, ctl.waitForResponse(std.time.ns_per_ms));
}
