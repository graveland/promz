const std = @import("std");

/// A simple, non-thread-safe sample storing a single metric value
/// For thread-safe samples, see src/sync/atomic_sample.zig and src/sync/locked_sample.zig
pub const Sample = struct {
    value: f64,

    /// Initialize a sample with the given value
    pub fn init(initial_value: f64) Sample {
        return .{ .value = initial_value };
    }

    /// Add a delta to the sample value
    pub fn add(self: *Sample, delta: f64) void {
        self.value += delta;
    }

    /// Subtract a delta from the sample value
    pub fn sub(self: *Sample, delta: f64) void {
        self.value -= delta;
    }

    /// Set the sample to an absolute value
    pub fn set(self: *Sample, new_value: f64) void {
        self.value = new_value;
    }

    /// Get the current sample value
    pub fn get(self: *const Sample) f64 {
        return self.value;
    }
};

test "Sample: init" {
    const sample = Sample.init(42.0);
    try std.testing.expectEqual(42.0, sample.value);
}

test "Sample: add" {
    var sample = Sample.init(10.0);
    sample.add(5.0);
    try std.testing.expectEqual(15.0, sample.get());

    sample.add(2.5);
    try std.testing.expectEqual(17.5, sample.get());
}

test "Sample: sub" {
    var sample = Sample.init(10.0);
    sample.sub(3.0);
    try std.testing.expectEqual(7.0, sample.get());

    sample.sub(2.5);
    try std.testing.expectEqual(4.5, sample.get());
}

test "Sample: set" {
    var sample = Sample.init(10.0);
    sample.set(100.0);
    try std.testing.expectEqual(100.0, sample.get());

    sample.set(0.0);
    try std.testing.expectEqual(0.0, sample.get());
}

test "Sample: get" {
    const sample = Sample.init(42.5);
    try std.testing.expectEqual(42.5, sample.get());
}

test "Sample: negative values" {
    var sample = Sample.init(-10.0);
    try std.testing.expectEqual(-10.0, sample.get());

    sample.add(-5.0);
    try std.testing.expectEqual(-15.0, sample.get());

    sample.sub(-10.0);
    try std.testing.expectEqual(-5.0, sample.get());
}
