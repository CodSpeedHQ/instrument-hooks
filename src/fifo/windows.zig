const bincode = @import("../bincode.zig");
const std = @import("std");
const shared = @import("../shared.zig");

const fs = std.fs;
const Allocator = std.mem.Allocator;
pub const Command = shared.Command;

pub const Pipe = struct {
    pub const Reader = struct {
        file: fs.File,
        allocator: Allocator,
        buffer: std.ArrayList(u8),

        pub fn init(file: fs.File, allocator: Allocator) Reader {
            return .{
                .file = file,
                .allocator = allocator,
                .buffer = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn read(self: *Reader, buffer: []u8) !usize {
            return self.file.read(buffer);
        }

        pub fn readAll(self: *Reader, buffer: []u8) !usize {
            return self.file.readAll(buffer);
        }

        pub fn recvCmd(self: *Reader) !Command {
            var len_buffer: [4]u8 = undefined;
            if (try self.file.readAll(&len_buffer) < len_buffer.len) return error.UnexpectedEof;

            const message_len = std.mem.readInt(u32, &len_buffer, .little);
            try self.buffer.resize(message_len);
            if (try self.file.readAll(self.buffer.items) < message_len) return error.UnexpectedEof;

            var stream = std.io.fixedBufferStream(self.buffer.items);
            return bincode.deserializeAlloc(stream.reader(), self.allocator, Command);
        }

        pub fn waitForResponse(self: *Reader, _: ?u64) anyerror!Command {
            return self.recvCmd();
        }

        pub fn waitForAck(self: *Reader, timeout_ns: ?u64) !void {
            const response = try self.waitForResponse(timeout_ns);
            defer response.deinit(self.allocator);

            switch (response) {
                .Ack => return,
                .Err => return error.UnexpectedError,
                else => return error.UnexpectedResponse,
            }
        }

        pub fn deinit(self: *Reader) void {
            self.buffer.deinit();
            self.file.close();
        }
    };

    pub const Writer = struct {
        file: fs.File,
        allocator: Allocator,
        buffer: std.ArrayList(u8),

        pub fn init(file: fs.File, allocator: Allocator) Writer {
            return .{
                .file = file,
                .allocator = allocator,
                .buffer = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn write(self: *Writer, buffer: []const u8) !usize {
            return self.file.write(buffer);
        }

        pub fn writeAll(self: *Writer, buffer: []const u8) !void {
            try self.file.writeAll(buffer);
        }

        pub fn sendCmd(self: *Writer, cmd: Command) !void {
            self.buffer.clearRetainingCapacity();
            try bincode.serialize(self.buffer.writer(), cmd);
            try self.file.writeAll(std.mem.asBytes(&@as(u32, @intCast(self.buffer.items.len))));
            try self.file.writeAll(self.buffer.items);
        }

        pub fn deinit(self: *Writer) void {
            self.buffer.deinit();
            self.file.close();
        }
    };

    pub fn create(_: [*:0]const u8) !void {}

    fn openPipe(path: []const u8) !fs.File {
        return fs.openFileAbsolute(path, .{ .mode = .read_write });
    }

    pub fn openRead(allocator: Allocator, path: []const u8) !Reader {
        return .init(try openPipe(path), allocator);
    }

    pub fn openWrite(allocator: Allocator, path: []const u8) !Writer {
        return .init(try openPipe(path), allocator);
    }
};

pub fn sendCmd(allocator: Allocator, cmd: Command) !void {
    var writer = try Pipe.openWrite(allocator, shared.RUNNER_CTL_FIFO);
    defer writer.deinit();
    try writer.sendCmd(cmd);
}

pub fn sendVersion(allocator: Allocator, version: u64) !void {
    try sendCmd(allocator, .{ .SetVersion = version });
}
