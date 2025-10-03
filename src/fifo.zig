const bincode = @import("bincode.zig");
const std = @import("std");
const shared = @import("shared.zig");

const fs = std.fs;
const os = std.os;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Path = []const u8;
pub const Command = shared.Command;

extern "c" fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;

pub const UnixPipe = struct {
    pub const Reader = struct {
        file: fs.File,
        allocator: Allocator,

        pub fn init(file: fs.File, allocator: Allocator) Reader {
            return .{
                .file = file,
                .allocator = allocator,
            };
        }

        pub fn read(self: *Reader, buffer: []u8) !usize {
            return self.file.read(buffer);
        }

        pub fn readAll(self: *Reader, buffer: []u8) !usize {
            return self.file.readAll(buffer);
        }

        // IMPORTANT: Caller is responsible for freeing the returned command.
        pub fn recvCmd(self: *Reader) !Command {
            // First read the length (u32 = 4 bytes)
            var len_buffer: [4]u8 = undefined;
            const len_read = self.file.readAll(&len_buffer) catch |err| {
                // Convert blocking/broken pipe errors to something the timeout logic can handle
                return switch (err) {
                    error.WouldBlock, error.BrokenPipe => error.NotReady,
                    else => err,
                };
            };
            if (len_read < 4) {
                return error.UnexpectedEof;
            }
            const message_len = std.mem.readInt(u32, &len_buffer, std.builtin.Endian.little);

            // Read the message
            const buffer = try self.allocator.alloc(u8, message_len);
            defer self.allocator.free(buffer);

            const msg_read = self.file.readAll(buffer) catch |err| {
                return switch (err) {
                    error.WouldBlock, error.BrokenPipe => error.NotReady,
                    else => err,
                };
            };
            if (msg_read < message_len) {
                return error.UnexpectedEof;
            }

            var stream = std.io.fixedBufferStream(buffer);
            return try bincode.deserializeAlloc(stream.reader(), self.allocator, Command);
        }

        pub fn waitForResponse(self: *Reader, timeout_ns: ?u64) !Command {
            const start = std.time.nanoTimestamp();
            const timeout = timeout_ns orelse std.time.ns_per_s * 5; // Default 5 second timeout

            while (true) {
                const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
                if (elapsed > timeout) {
                    return error.AckTimeout;
                }

                const cmd = self.recvCmd() catch |err| {
                    // Only retry on transient errors, propagate fatal ones
                    switch (err) {
                        error.NotReady, error.UnexpectedEof => {
                            const utils = @import("utils.zig");
                            utils.sleep(std.time.ns_per_ms * 10);
                            continue;
                        },
                        else => return err,
                    }
                };

                return cmd;
            }
        }

        pub fn waitForAck(self: *Reader, timeout_ns: ?u64) !void {
            const response = try self.waitForResponse(timeout_ns);
            defer response.deinit(self.allocator);

            if (response == Command.Ack) {
                return;
            } else if (response == Command.Err) {
                return error.UnexpectedError;
            } else {
                return error.UnexpectedResponse;
            }
        }

        pub fn deinit(self: *Reader) void {
            self.file.close();
        }
    };

    pub const Writer = struct {
        file: fs.File,
        allocator: Allocator,

        pub fn init(file: fs.File, allocator: Allocator) Writer {
            return .{
                .file = file,
                .allocator = allocator,
            };
        }

        pub fn write(self: *Writer, buffer: []const u8) !usize {
            return self.file.write(buffer);
        }

        pub fn writeAll(self: *Writer, buffer: []const u8) !void {
            return self.file.writeAll(buffer);
        }

        pub fn sendCmd(self: *Writer, cmd: Command) !void {
            var buffer = std.ArrayList(u8).init(self.allocator);
            defer buffer.deinit();

            try bincode.serialize(buffer.writer(), cmd);

            const bytes = buffer.items;
            try self.file.writeAll(std.mem.asBytes(&@as(u32, @intCast(bytes.len))));
            try self.file.writeAll(bytes);
        }

        pub fn deinit(self: *Writer) void {
            self.file.close();
        }
    };

    /// Create a new named pipe at the given path
    pub fn create(path: [*:0]const u8) !void {
        // Remove the previous FIFO (if it exists)
        fs.deleteFileAbsolute(std.mem.span(path)) catch {};

        if (mkfifo(path, 0o700) != 0) {
            return error.FifoCreationFailed;
        }
    }

    fn openPipe(path: []const u8) !fs.File {
        try fs.accessAbsolute(path, .{ .mode = .read_write });
        const file = try fs.openFileAbsolute(path, .{
            .mode = .read_write,
        });

        // Zig doesn't set the nonblocking flag correctly, so we have to do it manually.
        const utils = @import("utils.zig");
        utils.setNonBlocking(file.handle);

        return file;
    }

    pub fn openRead(allocator: Allocator, path: []const u8) !Reader {
        const file = try openPipe(path);
        return Reader.init(file, allocator);
    }

    pub fn openWrite(allocator: Allocator, path: []const u8) !Writer {
        const file = try openPipe(path);
        return Writer.init(file, allocator);
    }
};

pub fn sendCmd(allocator: Allocator, cmd: Command) !void {
    var writer = try UnixPipe.openWrite(allocator, shared.RUNNER_CTL_FIFO);
    defer writer.deinit();
    try writer.sendCmd(cmd);

    var reader = try UnixPipe.openRead(allocator, shared.RUNNER_ACK_FIFO);
    defer reader.deinit();
    try reader.waitForAck(null);
}

pub fn sendVersion(allocator: Allocator, protocol_version: u64) !void {
    const cmd = Command{ .SetVersion = protocol_version };
    try sendCmd(allocator, cmd);
}

test "fail if doesn't exist" {
    const allocator = std.testing.allocator;

    const nonexistent_path = "/tmp/nonexistent_pipe_test.fifo";

    // Ensure it doesn't exist
    fs.deleteFileAbsolute(nonexistent_path) catch {};

    // Attempt to open for reading should fail
    const reader_result = UnixPipe.openRead(allocator, nonexistent_path);
    try std.testing.expectError(error.FileNotFound, reader_result);

    // Attempt to open for writing should fail
    const writer_result = UnixPipe.openWrite(allocator, nonexistent_path);
    try std.testing.expectError(error.FileNotFound, writer_result);

    // Attempt to send cmd to runner fifo
    fs.deleteFileAbsolute(shared.RUNNER_ACK_FIFO) catch {};
    fs.deleteFileAbsolute(shared.RUNNER_CTL_FIFO) catch {};

    const sendcmd_result = sendCmd(allocator, Command.StartBenchmark);
    try std.testing.expectError(error.FileNotFound, sendcmd_result);
}

test "unix pipe write read" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test1.fifo";

    try UnixPipe.create(test_path);

    var reader = try UnixPipe.openRead(allocator, test_path);
    defer reader.deinit();

    var writer = try UnixPipe.openWrite(allocator, test_path);
    defer writer.deinit();

    const message = "Hello";
    try writer.writeAll(message);

    var buffer: [5]u8 = undefined;
    _ = try reader.readAll(&buffer);

    try std.testing.expectEqualStrings(message, &buffer);
}

test "unix pipe send recv cmd" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test2.fifo";

    try UnixPipe.create(test_path);

    var reader = try UnixPipe.openRead(allocator, test_path);
    defer reader.deinit();

    var writer = try UnixPipe.openWrite(allocator, test_path);
    defer writer.deinit();

    try writer.sendCmd(Command.StartBenchmark);
    const cmd = try reader.recvCmd();
    defer cmd.deinit(writer.allocator);

    try std.testing.expectEqual(Command.StartBenchmark, cmd);
}

test "unix pipe send without ack" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test_no_ack.fifo";

    try UnixPipe.create(test_path);

    // Open both reader and writer so they don't block on open
    var reader = try UnixPipe.openRead(allocator, test_path);
    defer reader.deinit();

    var writer = try UnixPipe.openWrite(allocator, test_path);
    defer writer.deinit();

    // Writer doesn't send anything, so waitForResponse should timeout
    const result = reader.waitForResponse(std.time.ns_per_ms * 100);
    try std.testing.expectError(error.AckTimeout, result);
}
