const std = @import("std");

/// Thread-safe sample using mutex locks
/// Required for histograms and complex operations that need consistency
/// Generic over V - the value type (u32, u64, f32, f64, etc.)
pub fn LockedSample(comptime V: type) type {
    assertSampleType(V);

    const is_integer = @typeInfo(V) == .int;

    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex,
        value: V,

        pub fn init() Self {
            return Self{
                .mutex = .{},
                .value = if (is_integer) 0 else 0.0,
            };
        }

        /// Add to the sample
        pub fn add(self: *Self, delta: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value += delta;
        }

        /// Subtract from the sample
        pub fn sub(self: *Self, delta: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value -= delta;
        }

        /// Set the sample to a specific value
        pub fn set(self: *Self, value: V) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value = value;
        }

        /// Get the current value
        pub fn get(self: *const Self) V {
            // Note: Zig mutexes require *Mutex not *const Mutex for lock()
            // so we cast away const here - this is safe for read locks
            const self_mut = @constCast(self);
            self_mut.mutex.lock();
            defer self_mut.mutex.unlock();
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
    @compileError("LockedSample requires an integer or float type, got: " ++ @typeName(T));
}

test "LockedSample(f64): init and get" {
    var sample = LockedSample(f64).init();
    try std.testing.expectEqual(0.0, sample.get());
}

test "LockedSample(f64): add" {
    var sample = LockedSample(f64).init();
    sample.add(5.0);
    sample.add(3.0);
    try std.testing.expectEqual(8.0, sample.get());
}

test "LockedSample(f64): sub" {
    var sample = LockedSample(f64).init();
    sample.add(10.0);
    sample.sub(3.0);
    try std.testing.expectEqual(7.0, sample.get());
}

test "LockedSample(f64): set" {
    var sample = LockedSample(f64).init();
    sample.set(42.5);
    try std.testing.expectEqual(42.5, sample.get());
}

test "LockedSample(u64): init and add" {
    var sample = LockedSample(u64).init();
    try std.testing.expectEqual(0, sample.get());
    sample.add(5);
    sample.add(3);
    try std.testing.expectEqual(8, sample.get());
}

test "LockedSample(u32): operations" {
    var sample = LockedSample(u32).init();
    sample.add(100);
    sample.sub(25);
    try std.testing.expectEqual(75, sample.get());
}

test "LockedSample(i64): signed operations" {
    var sample = LockedSample(i64).init();
    sample.add(-10);
    sample.sub(-5);
    try std.testing.expectEqual(-5, sample.get());
}
