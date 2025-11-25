const std = @import("std");

/// Thread-safe sample using mutex locks
/// Required for histograms and complex operations that need consistency
pub const LockedSample = struct {
    mutex: std.Thread.Mutex,
    value: f64,

    pub fn init() LockedSample {
        return LockedSample{
            .mutex = .{},
            .value = 0.0,
        };
    }

    /// Add to the sample
    pub fn add(self: *LockedSample, delta: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += delta;
    }

    /// Subtract from the sample
    pub fn sub(self: *LockedSample, delta: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value -= delta;
    }

    /// Set the sample to a specific value
    pub fn set(self: *LockedSample, value: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value = value;
    }

    /// Get the current value
    pub fn get(self: *const LockedSample) f64 {
        // Note: Zig mutexes require *Mutex not *const Mutex for lock()
        // so we cast away const here - this is safe for read locks
        const self_mut = @constCast(self);
        self_mut.mutex.lock();
        defer self_mut.mutex.unlock();
        return self.value;
    }
};

test "LockedSample: init and get" {
    var sample = LockedSample.init();
    try std.testing.expectEqual(0.0, sample.get());
}

test "LockedSample: add" {
    var sample = LockedSample.init();
    sample.add(5.0);
    sample.add(3.0);
    try std.testing.expectEqual(8.0, sample.get());
}

test "LockedSample: sub" {
    var sample = LockedSample.init();
    sample.add(10.0);
    sample.sub(3.0);
    try std.testing.expectEqual(7.0, sample.get());
}

test "LockedSample: set" {
    var sample = LockedSample.init();
    sample.set(42.5);
    try std.testing.expectEqual(42.5, sample.get());
}
