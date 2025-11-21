const std = @import("std");
const fifo = @import("../fifo.zig");
const shared = @import("../shared.zig");
const runner_fifo = @import("../runner_fifo.zig");

pub const PerfInstrument = runner_fifo.RunnerFifo;
