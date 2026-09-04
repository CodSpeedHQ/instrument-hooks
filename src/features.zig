const std = @import("std");

pub const Feature = enum(u64) {
    // When enabled, we will not call the CALLGRIND_START_INSTRUMENTATION and CALLGRIND_STOP_INSTRUMENTATION markers.
    // This is useful when you notice additional overhead from this library in microbenchmarks, but means you
    // have to manually call them in your code.
    disable_callgrind_markers = 0,
};

var features: u64 = 0;

pub fn set_feature(feature: Feature, enabled: bool) void {
    const bit = @as(u64, 1) << @intCast(@intFromEnum(feature));
    if (enabled) {
        _ = @atomicRmw(u64, &features, .Or, bit, .monotonic);
    } else {
        _ = @atomicRmw(u64, &features, .And, ~bit, .monotonic);
    }
}

pub fn is_feature_enabled(feature: Feature) bool {
    const bit = @as(u64, 1) << @intCast(@intFromEnum(feature));
    return @atomicLoad(u64, &features, .monotonic) & bit != 0;
}

test "set_feature and is_feature_enabled" {
    set_feature(Feature.disable_callgrind_markers, false);
    try std.testing.expect(!is_feature_enabled(Feature.disable_callgrind_markers));
    set_feature(Feature.disable_callgrind_markers, true);
    try std.testing.expect(is_feature_enabled(Feature.disable_callgrind_markers));
}
