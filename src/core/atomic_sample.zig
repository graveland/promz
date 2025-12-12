const std = @import("std");

/// Thread-safe atomic sample using atomic operations
/// Best for counters and simple gauges with basic operations
/// Generic over V - supports integers (u32, u64, i32, i64) and floats (f32, f64)
pub fn AtomicSample(comptime V: type) type {
    assertAtomicType(V);

    // Determine the bit storage type for atomic operations
    const BitType = switch (@typeInfo(V)) {
        .int => V,
        .float => |f| std.meta.Int(.unsigned, f.bits),
        else => unreachable,
    };

    const is_integer = @typeInfo(V) == .int;

    return struct {
        const Self = @This();

        value: std.atomic.Value(BitType),

        pub fn init() Self {
            const zero: V = if (is_integer) 0 else 0.0;
            return Self{
                .value = std.atomic.Value(BitType).init(@as(BitType, @bitCast(zero))),
            };
        }

        /// Add to the sample (for counters)
        pub fn add(self: *Self, delta: V) void {
            if (is_integer) {
                // Direct atomic add for integers - much faster
                _ = self.value.fetchAdd(@bitCast(delta), .monotonic);
            } else {
                // CAS loop for floats
                var current_bits = self.value.load(.monotonic);
                while (true) {
                    const current_value: V = @bitCast(current_bits);
                    const new_value = current_value + delta;
                    const new_bits: BitType = @bitCast(new_value);

                    const result = self.value.cmpxchgWeak(current_bits, new_bits, .monotonic, .monotonic);
                    if (result) |actual| {
                        current_bits = actual;
                    } else {
                        return;
                    }
                }
            }
        }

        /// Subtract from the sample (for gauges)
        pub fn sub(self: *Self, delta: V) void {
            if (is_integer) {
                // Direct atomic sub for integers
                _ = self.value.fetchSub(@bitCast(delta), .monotonic);
            } else {
                // CAS loop for floats
                var current_bits = self.value.load(.monotonic);
                while (true) {
                    const current_value: V = @bitCast(current_bits);
                    const new_value = current_value - delta;
                    const new_bits: BitType = @bitCast(new_value);

                    const result = self.value.cmpxchgWeak(current_bits, new_bits, .monotonic, .monotonic);
                    if (result) |actual| {
                        current_bits = actual;
                    } else {
                        return;
                    }
                }
            }
        }

        /// Set the sample to a specific value
        pub fn set(self: *Self, value: V) void {
            const value_bits: BitType = @bitCast(value);
            self.value.store(value_bits, .monotonic);
        }

        /// Get the current value
        pub fn get(self: *const Self) V {
            const bits = self.value.load(.monotonic);
            return @bitCast(bits);
        }
    };
}

/// Validate that V is a supported atomic numeric type (32 or 64 bit)
fn assertAtomicType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => |f| {
            if (f.bits == 32 or f.bits == 64) return;
        },
        .int => |int| {
            if (int.bits == 32 or int.bits == 64) return;
        },
        else => {},
    }
    @compileError("AtomicSample requires u32, u64, i32, i64, f32, or f64, got: " ++ @typeName(T));
}

test "AtomicSample(f64): init and get" {
    var sample = AtomicSample(f64).init();
    try std.testing.expectEqual(0.0, sample.get());
}

test "AtomicSample(f64): add" {
    var sample = AtomicSample(f64).init();
    sample.add(5.0);
    sample.add(3.0);
    try std.testing.expectEqual(8.0, sample.get());
}

test "AtomicSample(f64): sub" {
    var sample = AtomicSample(f64).init();
    sample.add(10.0);
    sample.sub(3.0);
    try std.testing.expectEqual(7.0, sample.get());
}

test "AtomicSample(f64): set" {
    var sample = AtomicSample(f64).init();
    sample.set(42.5);
    try std.testing.expectEqual(42.5, sample.get());
}

test "AtomicSample(u64): init and add" {
    var sample = AtomicSample(u64).init();
    try std.testing.expectEqual(0, sample.get());
    sample.add(5);
    sample.add(3);
    try std.testing.expectEqual(8, sample.get());
}

test "AtomicSample(u64): sub" {
    var sample = AtomicSample(u64).init();
    sample.add(10);
    sample.sub(3);
    try std.testing.expectEqual(7, sample.get());
}

test "AtomicSample(u64): set" {
    var sample = AtomicSample(u64).init();
    sample.set(42);
    try std.testing.expectEqual(42, sample.get());
}

test "AtomicSample(u32): operations" {
    var sample = AtomicSample(u32).init();
    sample.add(100);
    sample.add(50);
    try std.testing.expectEqual(150, sample.get());
    sample.sub(25);
    try std.testing.expectEqual(125, sample.get());
}

test "AtomicSample(i64): signed operations" {
    var sample = AtomicSample(i64).init();
    sample.add(-5);
    sample.add(-3);
    try std.testing.expectEqual(-8, sample.get());
    sample.sub(-10);
    try std.testing.expectEqual(2, sample.get());
}

test "AtomicSample(f32): operations" {
    var sample = AtomicSample(f32).init();
    sample.add(5.5);
    sample.add(2.5);
    try std.testing.expectEqual(8.0, sample.get());
}
