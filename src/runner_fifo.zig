const std = @import("std");
const fifo = @import("fifo/root.zig");
const shared = @import("shared.zig");
const Lock = @import("lock.zig").Lock;
const logger = @import("logger.zig");

// v1: Initial release
// v2: Added GetIntegrationMode
pub const PROTOCOL_VERSION: u64 = 2;

pub const RunnerFifo = struct {
    allocator: std.mem.Allocator,
    writer: fifo.Pipe.Writer,
    reader: fifo.Pipe.Reader,

    /// The runner FIFO paths are process-global, so every handle opens its own
    /// fds onto the same pipe pair: the lock has to be shared by all of them,
    /// not per instance.
    var pipe_lock: Lock = .{};

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .writer = try fifo.Pipe.openWrite(allocator, shared.RUNNER_CTL_FIFO),
            .reader = try fifo.Pipe.openRead(allocator, shared.RUNNER_ACK_FIFO),
        };
    }

    pub fn validate_protocol_version(self: *Self) !void {
        self.send_version(PROTOCOL_VERSION) catch |err| {
            switch (err) {
                // No runner present - silently continue as NOP
                error.AckTimeout => return,

                // Runner explicitly rejected version
                error.UnexpectedError => {
                    logger.err("instrument-hooks: CodSpeed runner rejected protocol version {}\n", .{PROTOCOL_VERSION});
                    logger.err("instrument-hooks: please update the CodSpeed action to the latest version\n", .{});
                    std.posix.exit(1);
                },

                // All other errors - log and exit
                else => {
                    logger.err("instrument-hooks: error {s} during version check\n", .{@errorName(err)});
                    std.posix.exit(1);
                },
            }
        };
    }

    /// Draining the acknowledgement FIFO must not race another handle's
    /// in-flight request, so teardown takes the same lock as an exchange.
    pub fn deinit(self: *Self) void {
        pipe_lock.lock();
        defer pipe_lock.unlock();

        self.writer.deinit();
        self.reader.deinit();
    }

    /// Every handle in the process shares the same two FIFO paths, so a
    /// request and its reply must not interleave with another handle's traffic.
    pub fn send_cmd(self: *Self, cmd: fifo.Command) !void {
        pipe_lock.lock();
        defer pipe_lock.unlock();

        try self.writer.sendCmd(cmd);
        try self.reader.waitForAck(null);
    }

    /// Like send_cmd, but for commands the runner answers with data instead of an Ack.
    pub fn request(self: *Self, cmd: fifo.Command) !fifo.Command {
        pipe_lock.lock();
        defer pipe_lock.unlock();

        try self.writer.sendCmd(cmd);
        return self.reader.waitForResponse(null);
    }

    pub fn ping_profiler(self: *Self) bool {
        self.send_cmd(fifo.Command.PingProfiler) catch {
            return false;
        };

        return true;
    }

    pub noinline fn start_benchmark(self: *Self) !void {
        @branchHint(.cold); // Prevent inline

        try self.send_cmd(fifo.Command.StartBenchmark);
    }

    pub noinline fn stop_benchmark(self: *Self) !void {
        @branchHint(.cold); // Prevent inline

        try self.send_cmd(fifo.Command.StopBenchmark);
    }

    pub fn set_executed_benchmark(self: *Self, pid: i32, uri: [*c]const u8) !void {
        try self.send_cmd(fifo.Command{ .ExecutedBenchmark = .{
            .pid = pid,
            .uri = std.mem.span(uri),
        } });
    }

    pub fn set_integration(self: *Self, name: [*c]const u8, version: [*c]const u8) !void {
        try self.send_cmd(fifo.Command{ .SetIntegration = .{
            .name = std.mem.span(name),
            .version = std.mem.span(version),
        } });
    }

    pub fn add_marker(self: *Self, pid: i32, marker: shared.MarkerType) !void {
        try self.send_cmd(fifo.Command{ .AddMarker = .{
            .pid = pid,
            .marker = marker,
        } });
    }

    pub fn send_version(self: *Self, protocol_version: u64) !void {
        try self.send_cmd(fifo.Command{ .SetVersion = protocol_version });
    }

    pub fn get_integration_mode(self: *Self) !shared.IntegrationMode {
        const response = try self.request(fifo.Command.GetIntegrationMode);
        defer response.deinit(self.allocator);

        if (response == .IntegrationModeResponse) {
            return response.IntegrationModeResponse;
        }
        return error.UnexpectedResponse;
    }
};

test "test runner fifo" {
    const allocator = std.testing.allocator;

    try fifo.Pipe.create(shared.RUNNER_ACK_FIFO);
    try fifo.Pipe.create(shared.RUNNER_CTL_FIFO);

    var ctl_fifo = try fifo.Pipe.openRead(allocator, shared.RUNNER_CTL_FIFO);
    defer ctl_fifo.deinit();

    var ack_fifo = try fifo.Pipe.openWrite(allocator, shared.RUNNER_ACK_FIFO);
    defer ack_fifo.deinit();

    const FifoTester = struct {
        allocator: std.mem.Allocator,
        ctl_pipe: *fifo.Pipe.Reader,
        ack_pipe: *fifo.Pipe.Writer,

        received_cmd: ?fifo.Command = null,
        error_occurred: bool = false,

        pub fn func(ctx: *@This()) void {
            const received_cmd = ctx.ctl_pipe.waitForResponse(null) catch |err| {
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

    var runner_fifo = try RunnerFifo.init(allocator);
    defer runner_fifo.deinit();

    const si_result = try tester.send(RunnerFifo.set_integration, .{ &runner_fifo, "zig", "0.10.0" });
    try std.testing.expect(si_result.equal(fifo.Command{ .SetIntegration = .{ .name = "zig", .version = "0.10.0" } }));
    si_result.deinit(allocator);

    const cb_result = try tester.send(RunnerFifo.set_executed_benchmark, .{ &runner_fifo, 42, "foo" });
    try std.testing.expect(cb_result.equal(fifo.Command{ .ExecutedBenchmark = .{ .pid = 42, .uri = "foo" } }));
    cb_result.deinit(allocator);

    const start_result = try tester.send(RunnerFifo.start_benchmark, .{&runner_fifo});
    try std.testing.expect(start_result.equal(fifo.Command.StartBenchmark));
    start_result.deinit(allocator);

    const stop_result = try tester.send(RunnerFifo.stop_benchmark, .{&runner_fifo});
    try std.testing.expect(stop_result.equal(fifo.Command.StopBenchmark));
    stop_result.deinit(allocator);
}
