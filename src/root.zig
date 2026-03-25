test "run all tests" {
    _ = @import("tests/deserialize_rust/rust_deser.zig");
    _ = @import("bincode.zig");
    _ = @import("environment.zig");
    _ = @import("fifo.zig");
    _ = @import("c.zig");
    _ = @import("utils.zig");
}
