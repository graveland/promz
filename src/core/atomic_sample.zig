const std = @import("std");

/// Thread-safe atomic sample using atomic operations
/// Best for counters and simple gauges with basic operations
pub const AtomicSample = struct {
    value: std.atomic.Value(u64),

    pub fn init() AtomicSample {
        return AtomicSample{
            .value = std.atomic.Value(u64).init(@as(u64, @bitCast(@as(f64, 0.0)))),
        };
    }

    /// Add to the sample (for counters) using compare-and-swap for proper float addition
    pub fn add(self: *AtomicSample, delta: f64) void {
        var current_bits = self.value.load(.monotonic);
        while (true) {
            const current_value: f64 = @bitCast(current_bits);
            const new_value = current_value + delta;
            const new_bits: u64 = @bitCast(new_value);

            const result = self.value.cmpxchgWeak(current_bits, new_bits, .monotonic, .monotonic);
            if (result) |actual| {
                current_bits = actual;
            } else {
                return;
            }
        }
    }

    /// Subtract from the sample (for gauges) using compare-and-swap for proper float subtraction
    pub fn sub(self: *AtomicSample, delta: f64) void {
        var current_bits = self.value.load(.monotonic);
        while (true) {
            const current_value: f64 = @bitCast(current_bits);
            const new_value = current_value - delta;
            const new_bits: u64 = @bitCast(new_value);

            const result = self.value.cmpxchgWeak(current_bits, new_bits, .monotonic, .monotonic);
            if (result) |actual| {
                current_bits = actual;
            } else {
                return;
            }
        }
    }

    /// Set the sample to a specific value
    pub fn set(self: *AtomicSample, value: f64) void {
        const value_bits: u64 = @bitCast(value);
        self.value.store(value_bits, .monotonic);
    }

    /// Get the current value
    pub fn get(self: *const AtomicSample) f64 {
        const bits = self.value.load(.monotonic);
        return @bitCast(bits);
    }
};

test "AtomicSample: init and get" {
    var sample = AtomicSample.init();
    try std.testing.expectEqual(0.0, sample.get());
}

test "AtomicSample: add" {
    var sample = AtomicSample.init();
    sample.add(5.0);
    sample.add(3.0);
    try std.testing.expectEqual(8.0, sample.get());
}

test "AtomicSample: sub" {
    var sample = AtomicSample.init();
    sample.add(10.0);
    sample.sub(3.0);
    try std.testing.expectEqual(7.0, sample.get());
}

test "AtomicSample: set" {
    var sample = AtomicSample.init();
    sample.set(42.5);
    try std.testing.expectEqual(42.5, sample.get());
}
