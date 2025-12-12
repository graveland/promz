const std = @import("std");

/// A simple, non-thread-safe sample storing a single metric value
/// For thread-safe samples, see atomic_sample.zig and locked_sample.zig
/// Generic over V - the value type (u32, u64, f32, f64, etc.)
pub fn Sample(comptime V: type) type {
    assertSampleType(V);

    return struct {
        const Self = @This();

        value: V,

        /// Initialize a sample with the given value
        pub fn init(initial_value: V) Self {
            return .{ .value = initial_value };
        }

        /// Add a delta to the sample value
        pub fn add(self: *Self, delta: V) void {
            self.value += delta;
        }

        /// Subtract a delta from the sample value
        pub fn sub(self: *Self, delta: V) void {
            self.value -= delta;
        }

        /// Set the sample to an absolute value
        pub fn set(self: *Self, new_value: V) void {
            self.value = new_value;
        }

        /// Get the current sample value
        pub fn get(self: *const Self) V {
            return self.value;
        }
    };
}

/// Validate that V is a supported numeric type
fn assertSampleType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => return,
        .int => return,
        else => {},
    }
    @compileError("Sample requires an integer or float type, got: " ++ @typeName(T));
}

test "Sample(f64): init" {
    const sample = Sample(f64).init(42.0);
    try std.testing.expectEqual(42.0, sample.value);
}

test "Sample(f64): add" {
    var sample = Sample(f64).init(10.0);
    sample.add(5.0);
    try std.testing.expectEqual(15.0, sample.get());

    sample.add(2.5);
    try std.testing.expectEqual(17.5, sample.get());
}

test "Sample(f64): sub" {
    var sample = Sample(f64).init(10.0);
    sample.sub(3.0);
    try std.testing.expectEqual(7.0, sample.get());

    sample.sub(2.5);
    try std.testing.expectEqual(4.5, sample.get());
}

test "Sample(f64): set" {
    var sample = Sample(f64).init(10.0);
    sample.set(100.0);
    try std.testing.expectEqual(100.0, sample.get());

    sample.set(0.0);
    try std.testing.expectEqual(0.0, sample.get());
}

test "Sample(f64): get" {
    const sample = Sample(f64).init(42.5);
    try std.testing.expectEqual(42.5, sample.get());
}

test "Sample(f64): negative values" {
    var sample = Sample(f64).init(-10.0);
    try std.testing.expectEqual(-10.0, sample.get());

    sample.add(-5.0);
    try std.testing.expectEqual(-15.0, sample.get());

    sample.sub(-10.0);
    try std.testing.expectEqual(-5.0, sample.get());
}

test "Sample(u64): init and add" {
    var sample = Sample(u64).init(10);
    sample.add(5);
    try std.testing.expectEqual(15, sample.get());
}

test "Sample(u32): init and add" {
    var sample = Sample(u32).init(100);
    sample.add(50);
    try std.testing.expectEqual(150, sample.get());
}

test "Sample(i64): negative values" {
    var sample = Sample(i64).init(-10);
    sample.add(-5);
    try std.testing.expectEqual(-15, sample.get());
    sample.sub(-20);
    try std.testing.expectEqual(5, sample.get());
}
