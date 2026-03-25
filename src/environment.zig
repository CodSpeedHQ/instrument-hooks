const std = @import("std");
const fs = std.fs;
const logger = @import("logger.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const SectionEntries = std.json.ArrayHashMap([]const u8);
const SectionsMap = std.json.ArrayHashMap(SectionEntries);

const EnvironmentJson = struct {
    sections: SectionsMap = .{},
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    data: EnvironmentJson = .{},

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .allocator = alloc };
    }

    pub fn deinit(self: *Self) void {
        var sec_it = self.data.sections.map.iterator();
        while (sec_it.next()) |sec_entry| {
            var entry_it = sec_entry.value_ptr.map.iterator();
            while (entry_it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                self.allocator.free(kv.value_ptr.*);
            }
            sec_entry.value_ptr.map.deinit(self.allocator);
            self.allocator.free(sec_entry.key_ptr.*);
        }
        self.data.sections.map.deinit(self.allocator);
    }

    pub fn setSection(self: *Self, section_name: []const u8, key: []const u8, value: []const u8) !void {
        const sec_gop = try self.data.sections.map.getOrPut(self.allocator, section_name);
        if (!sec_gop.found_existing) {
            sec_gop.key_ptr.* = try self.allocator.dupe(u8, section_name);
            sec_gop.value_ptr.* = .{};
        }

        const entry_gop = try sec_gop.value_ptr.map.getOrPut(self.allocator, key);
        if (entry_gop.found_existing) {
            self.allocator.free(entry_gop.value_ptr.*);
        } else {
            entry_gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        entry_gop.value_ptr.* = try self.allocator.dupe(u8, value);
    }

    pub fn writeEnvironment(self: *Self, pid: u32) u8 {
        if (self.data.sections.map.count() == 0) return 0;

        const profile_folder = getenv("CODSPEED_PROFILE_FOLDER") orelse {
            return 0;
        };

        const folder_slice = std.mem.span(profile_folder);

        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/environment-{d}.json", .{ folder_slice, pid }) catch {
            logger.err("instrument-hooks: profile folder path too long\n", .{});
            return 1;
        };

        // Serialize and write
        const json = std.json.stringifyAlloc(self.allocator, self.data, .{ .whitespace = .indent_2 }) catch {
            logger.err("instrument-hooks: failed to serialize environment JSON\n", .{});
            return 1;
        };
        defer self.allocator.free(json);

        const file = fs.createFileAbsolute(path, .{}) catch {
            logger.err("instrument-hooks: failed to write environment.json\n", .{});
            return 1;
        };
        defer file.close();

        file.writeAll(json) catch {
            logger.err("instrument-hooks: failed to write environment.json\n", .{});
            return 1;
        };

        return 0;
    }
};

// --- Tests ---

test "set and retrieve section entries" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setSection("gcc", "version", "14.2.0");
    try env.setSection("gcc", "build", "g++ (Ubuntu 14.2.0-4ubuntu2) 14.2.0");
    try env.setSection("clang", "version", "18.1.0");

    try std.testing.expectEqual(@as(usize, 2), env.data.sections.map.count());
    try std.testing.expectEqual(@as(usize, 2), env.data.sections.map.get("gcc").?.map.count());
    try std.testing.expectEqual(@as(usize, 1), env.data.sections.map.get("clang").?.map.count());
}

test "overwrite existing entry" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setSection("gcc", "version", "13.0.0");
    try env.setSection("gcc", "version", "14.2.0");

    try std.testing.expectEqual(@as(usize, 1), env.data.sections.map.count());
    try std.testing.expectEqualStrings("14.2.0", env.data.sections.map.get("gcc").?.map.get("version").?);
}

test "json serialization" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setSection("gcc", "version", "14.2.0");
    try env.setSection("gcc", "build", "g++ (Ubuntu 14.2.0)");
    try env.setSection("clang", "version", "18.1.0");

    const json = try std.json.stringifyAlloc(std.testing.allocator, env.data, .{ .whitespace = .indent_2 });
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(EnvironmentJson, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const gcc = parsed.value.sections.map.get("gcc").?;
    try std.testing.expectEqualStrings("14.2.0", gcc.map.get("version").?);
    try std.testing.expectEqualStrings("g++ (Ubuntu 14.2.0)", gcc.map.get("build").?);

    const clang = parsed.value.sections.map.get("clang").?;
    try std.testing.expectEqualStrings("18.1.0", clang.map.get("version").?);
}

test "empty sections" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    const json = try std.json.stringifyAlloc(std.testing.allocator, env.data, .{ .whitespace = .indent_2 });
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(EnvironmentJson, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.sections.map.count());
}

test "json escaping" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setSection("test", "path", "C:\\Program Files\\gcc");

    const json = try std.json.stringifyAlloc(std.testing.allocator, env.data, .{ .whitespace = .indent_2 });
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(EnvironmentJson, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const test_sec = parsed.value.sections.map.get("test").?;
    try std.testing.expectEqualStrings("C:\\Program Files\\gcc", test_sec.map.get("path").?);
}

test "merge preserves existing and adds new" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    // Simulate existing data parsed from file
    try env.setSection("python", "version", "3.12.0");

    // Add new section
    try env.setSection("cpp", "version", "14.2.0");

    try std.testing.expectEqual(@as(usize, 2), env.data.sections.map.count());

    const json = try std.json.stringifyAlloc(std.testing.allocator, env.data, .{ .whitespace = .indent_2 });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"python\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"3.12.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"14.2.0\"") != null);
}

test "new entries override existing on merge" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    try env.setSection("python", "version", "3.12.0");
    try env.setSection("python", "version", "3.13.0");

    try std.testing.expectEqual(@as(usize, 1), env.data.sections.map.count());
    try std.testing.expectEqualStrings("3.13.0", env.data.sections.map.get("python").?.map.get("version").?);
}
