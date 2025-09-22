const std = @import("std");
const fifo = @import("../fifo.zig");
const shared = @import("../shared.zig");

pub const PerfInstrument = struct {
    allocator: std.mem.Allocator,
    writer: fifo.UnixPipe.Writer,
    reader: fifo.UnixPipe.Reader,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .writer = try fifo.UnixPipe.openWrite(allocator, shared.RUNNER_CTL_FIFO),
            .reader = try fifo.UnixPipe.openRead(allocator, shared.RUNNER_ACK_FIFO),
        };
    }

    pub fn deinit(self: *Self) void {
        self.writer.deinit();
        self.reader.deinit();
    }

    pub fn send_cmd(self: *Self, cmd: fifo.Command) !void {
        try self.writer.sendCmd(cmd);
        try self.reader.waitForAck(null);
    }

    pub fn is_instrumented(self: *Self) bool {
        self.send_cmd(fifo.Command.PingPerf) catch {
            return false;
        };

        return true;
    }

    pub noinline fn start_benchmark(self: *Self) !void {
        @branchHint(.cold); // Prevent inline

        try self.writer.sendCmd(fifo.Command.StartBenchmark);
        try self.reader.waitForAck(null);
    }

    pub noinline fn stop_benchmark(self: *Self) !void {
        @branchHint(.cold); // Prevent inline

        try self.writer.sendCmd(fifo.Command.StopBenchmark);
        try self.reader.waitForAck(null);
    }

    pub fn set_executed_benchmark(self: *Self, pid: u32, uri: [*c]const u8) !void {
        try self.writer.sendCmd(fifo.Command{ .ExecutedBenchmark = .{
            .pid = pid,
            .uri = std.mem.span(uri),
        } });
        try self.reader.waitForAck(null);
    }

    pub fn set_integration(self: *Self, name: [*c]const u8, version: [*c]const u8) !void {
        try self.writer.sendCmd(fifo.Command{ .SetIntegration = .{
            .name = std.mem.span(name),
            .version = std.mem.span(version),
        } });
        try self.reader.waitForAck(null);
    }

    pub fn add_marker(self: *Self, pid: u32, marker: shared.MarkerType) !void {
        try self.writer.sendCmd(fifo.Command{ .AddMarker = .{
            .pid = pid,
            .marker = marker,
        } });
        try self.reader.waitForAck(null);
    }
};

test "perf integration" {
    const allocator = std.testing.allocator;

    try fifo.UnixPipe.create(shared.RUNNER_ACK_FIFO);
    try fifo.UnixPipe.create(shared.RUNNER_CTL_FIFO);

    var ctl_fifo = try fifo.UnixPipe.openRead(allocator, shared.RUNNER_CTL_FIFO);
    defer ctl_fifo.deinit();

    var ack_fifo = try fifo.UnixPipe.openWrite(allocator, shared.RUNNER_ACK_FIFO);
    defer ack_fifo.deinit();

    const FifoTester = struct {
        allocator: std.mem.Allocator,
        ctl_pipe: *fifo.UnixPipe.Reader,
        ack_pipe: *fifo.UnixPipe.Writer,

        received_cmd: ?fifo.Command = null,
        error_occurred: bool = false,

        pub fn func(ctx: *@This()) void {
            const received_cmd = ctx.ctl_pipe.recvCmd() catch |err| {
                std.debug.print("Failed to receive command: {}\n", .{err});
                ctx.error_occurred = true;
                return;
            };
            ctx.received_cmd = received_cmd;

            ctx.ack_pipe.sendCmd(fifo.Command.Ack) catch |err| {
                std.debug.print("Failed to send ACK: {}\n", .{err});
                ctx.error_occurred = true;
            };
        }

        pub fn send(self: *@This(), comptime f: anytype, args: anytype) !fifo.Command {
            // 1. Create the thread which handles the command
            // 2. Execute the callback
            // 3. Wait for the thread to finish
            //
            const receiver_thread = try std.Thread.spawn(.{}, @This().func, .{self});
            try @call(.auto, f, args);
            receiver_thread.join();

            if (self.error_occurred) {
                return error.IntegrationError;
            }
            self.error_occurred = false;

            return self.received_cmd.?;
        }
    };

    var tester = FifoTester{
        .allocator = allocator,
        .ctl_pipe = &ctl_fifo,
        .ack_pipe = &ack_fifo,
    };

    var perf = try PerfInstrument.init(allocator);
    defer perf.deinit();

    const si_result = try tester.send(PerfInstrument.set_integration, .{ &perf, "zig", "0.10.0" });
    try std.testing.expect(si_result.equal(fifo.Command{ .SetIntegration = .{ .name = "zig", .version = "0.10.0" } }));
    si_result.deinit(allocator);

    const cb_result = try tester.send(PerfInstrument.set_executed_benchmark, .{ &perf, 42, "foo" });
    try std.testing.expect(cb_result.equal(fifo.Command{ .ExecutedBenchmark = .{ .pid = 42, .uri = "foo" } }));
    cb_result.deinit(allocator);

    const start_result = try tester.send(PerfInstrument.start_benchmark, .{&perf});
    try std.testing.expect(start_result.equal(fifo.Command.StartBenchmark));
    start_result.deinit(allocator);

    const stop_result = try tester.send(PerfInstrument.stop_benchmark, .{&perf});
    try std.testing.expect(stop_result.equal(fifo.Command.StopBenchmark));
    stop_result.deinit(allocator);
}
