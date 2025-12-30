const std = @import("std");
const build_options = @import("build_options");
const counter = @import("counter.zig");
const gauge = @import("gauge.zig");
const histogram = @import("histogram.zig");
const MetricInfo = @import("metric.zig").MetricInfo;
const LabelHandle = @import("metric.zig").LabelHandle;

/// Whether debug metrics are enabled (from build options).
/// When false, all debug metric types compile to zero-size no-ops.
pub const enabled = build_options.enable_debug_metrics;

/// Debug Counter - compiles to real Counter when enabled, zero-size no-op when disabled.
/// Use for instrumentation that should only be active in debug builds.
pub fn DebugCounter(comptime V: type, comptime TLabels: type, comptime config: counter.CounterConfig) type {
    if (enabled) {
        return counter.Counter(V, TLabels, config);
    } else {
        return NoopCounter(V, TLabels);
    }
}

/// Debug Gauge - compiles to real Gauge when enabled, zero-size no-op when disabled.
/// Use for instrumentation that should only be active in debug builds.
pub fn DebugGauge(comptime V: type, comptime TLabels: type, comptime config: gauge.GaugeConfig) type {
    if (enabled) {
        return gauge.Gauge(V, TLabels, config);
    } else {
        return NoopGauge(V, TLabels);
    }
}

/// Debug Histogram - compiles to real Histogram when enabled, zero-size no-op when disabled.
/// Use for instrumentation that should only be active in debug builds.
pub fn DebugHistogram(comptime V: type, comptime TLabels: type, comptime config: histogram.HistogramConfig) type {
    if (enabled) {
        return histogram.Histogram(V, TLabels, config);
    } else {
        return NoopHistogram(V, TLabels);
    }
}

/// Zero-size no-op Counter - all methods compile away completely.
fn NoopCounter(comptime V: type, comptime TLabels: type) type {
    const is_integer = @typeInfo(V) == .int;
    const zero: V = if (is_integer) 0 else 0.0;

    return struct {
        pub const Labels = TLabels;
        pub const ValueType = V;

        pub fn init(_: std.mem.Allocator, _: []const u8, _: []const u8) !@This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn inc(_: *@This(), _: TLabels) !void {}

        pub fn add(_: *@This(), _: TLabels, _: V) !void {}

        pub fn register(_: *@This(), _: TLabels) !LabelHandle {
            return .{ .index = 0, .generation = 0 };
        }

        pub fn incByHandle(_: *@This(), _: LabelHandle) !void {}

        pub fn addByHandle(_: *@This(), _: LabelHandle, _: V) !void {}

        pub fn getByHandle(_: *const @This(), _: LabelHandle) !V {
            return zero;
        }

        pub fn get(_: *const @This(), _: TLabels) !V {
            return zero;
        }

        pub fn reset(_: *@This()) void {}

        pub fn getInfo(_: *const @This()) ?MetricInfo {
            return null;
        }

        pub fn write(_: *const @This(), _: anytype) !void {}
    };
}

/// Zero-size no-op Gauge - all methods compile away completely.
fn NoopGauge(comptime V: type, comptime TLabels: type) type {
    const is_integer = @typeInfo(V) == .int;
    const zero: V = if (is_integer) 0 else 0.0;

    return struct {
        pub const Labels = TLabels;
        pub const ValueType = V;

        pub fn init(_: std.mem.Allocator, _: []const u8, _: []const u8) !@This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn inc(_: *@This(), _: TLabels) !void {}

        pub fn dec(_: *@This(), _: TLabels) !void {}

        pub fn add(_: *@This(), _: TLabels, _: V) !void {}

        pub fn sub(_: *@This(), _: TLabels, _: V) !void {}

        pub fn set(_: *@This(), _: TLabels, _: V) !void {}

        pub fn register(_: *@This(), _: TLabels) !LabelHandle {
            return .{ .index = 0, .generation = 0 };
        }

        pub fn incByHandle(_: *@This(), _: LabelHandle) !void {}

        pub fn decByHandle(_: *@This(), _: LabelHandle) !void {}

        pub fn addByHandle(_: *@This(), _: LabelHandle, _: V) !void {}

        pub fn subByHandle(_: *@This(), _: LabelHandle, _: V) !void {}

        pub fn setByHandle(_: *@This(), _: LabelHandle, _: V) !void {}

        pub fn getByHandle(_: *const @This(), _: LabelHandle) !V {
            return zero;
        }

        pub fn get(_: *const @This(), _: TLabels) !V {
            return zero;
        }

        pub fn getInfo(_: *const @This()) ?MetricInfo {
            return null;
        }

        pub fn write(_: *const @This(), _: anytype) !void {}
    };
}

/// Zero-size no-op Histogram - all methods compile away completely.
fn NoopHistogram(comptime V: type, comptime TLabels: type) type {
    const is_integer = @typeInfo(V) == .int;
    const zero: V = if (is_integer) 0 else 0.0;

    return struct {
        pub const Labels = TLabels;
        pub const ValueType = V;

        pub fn init(_: std.mem.Allocator, _: []const u8, _: []const u8, _: histogram.BucketConfig(V)) !@This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn observe(_: *@This(), _: TLabels, _: V) !void {}

        pub fn register(_: *@This(), _: TLabels) !LabelHandle {
            return .{ .index = 0, .generation = 0 };
        }

        pub fn observeByHandle(_: *@This(), _: LabelHandle, _: V) !void {}

        pub fn getBucketCount(_: *const @This(), _: TLabels, _: usize) !u64 {
            return 0;
        }

        pub fn getSum(_: *const @This(), _: TLabels) !V {
            return zero;
        }

        pub fn getCount(_: *const @This(), _: TLabels) !u64 {
            return 0;
        }

        pub fn getBucketCountByHandle(_: *const @This(), _: LabelHandle, _: usize) !u64 {
            return 0;
        }

        pub fn getSumByHandle(_: *const @This(), _: LabelHandle) !V {
            return zero;
        }

        pub fn getCountByHandle(_: *const @This(), _: LabelHandle) !u64 {
            return 0;
        }

        pub fn reset(_: *@This()) void {}

        pub fn getInfo(_: *const @This()) ?MetricInfo {
            return null;
        }

        pub fn write(_: *const @This(), _: anytype) !void {}
    };
}

// ============================================================================
// Tests
// ============================================================================

const NoLabels = @import("labels.zig").NoLabels;

test "NoopCounter has zero size" {
    try std.testing.expectEqual(0, @sizeOf(NoopCounter(u64, NoLabels)));
    try std.testing.expectEqual(0, @sizeOf(NoopCounter(f64, NoLabels)));
}

test "NoopGauge has zero size" {
    try std.testing.expectEqual(0, @sizeOf(NoopGauge(i64, NoLabels)));
    try std.testing.expectEqual(0, @sizeOf(NoopGauge(f64, NoLabels)));
}

test "NoopHistogram has zero size" {
    try std.testing.expectEqual(0, @sizeOf(NoopHistogram(u64, NoLabels)));
    try std.testing.expectEqual(0, @sizeOf(NoopHistogram(f64, NoLabels)));
}

test "NoopCounter: all operations work without error" {
    var c = try NoopCounter(u64, NoLabels).init(std.testing.allocator, "test", "help");
    defer c.deinit();

    try c.inc(.{});
    try c.add(.{}, 10);

    const handle = try c.register(.{});
    try c.incByHandle(handle);
    try c.addByHandle(handle, 5);

    try std.testing.expectEqual(0, try c.get(.{}));
    try std.testing.expectEqual(0, try c.getByHandle(handle));
    try std.testing.expect(c.getInfo() == null);

    c.reset();
}

test "NoopGauge: all operations work without error" {
    var g = try NoopGauge(i64, NoLabels).init(std.testing.allocator, "test", "help");
    defer g.deinit();

    try g.inc(.{});
    try g.dec(.{});
    try g.add(.{}, 10);
    try g.sub(.{}, 5);
    try g.set(.{}, 42);

    const handle = try g.register(.{});
    try g.incByHandle(handle);
    try g.decByHandle(handle);
    try g.addByHandle(handle, 5);
    try g.subByHandle(handle, 3);
    try g.setByHandle(handle, 100);

    try std.testing.expectEqual(0, try g.get(.{}));
    try std.testing.expectEqual(0, try g.getByHandle(handle));
    try std.testing.expect(g.getInfo() == null);
}

test "NoopHistogram: all operations work without error" {
    const buckets = histogram.BucketConfig(f64).custom(&[_]f64{ 1.0, 5.0, 10.0 });
    var h = try NoopHistogram(f64, NoLabels).init(std.testing.allocator, "test", "help", buckets);
    defer h.deinit();

    try h.observe(.{}, 2.5);

    const handle = try h.register(.{});
    try h.observeByHandle(handle, 7.5);

    try std.testing.expectEqual(0, try h.getBucketCount(.{}, 0));
    try std.testing.expectEqual(0.0, try h.getSum(.{}));
    try std.testing.expectEqual(0, try h.getCount(.{}));

    try std.testing.expectEqual(0, try h.getBucketCountByHandle(handle, 0));
    try std.testing.expectEqual(0.0, try h.getSumByHandle(handle));
    try std.testing.expectEqual(0, try h.getCountByHandle(handle));

    try std.testing.expect(h.getInfo() == null);

    h.reset();
}

test "DebugCounter type selection" {
    // When enabled == true, DebugCounter returns real Counter
    // When enabled == false, DebugCounter returns NoopCounter
    // The actual type depends on build_options.enable_debug_metrics
    const DebugCounterType = DebugCounter(u64, NoLabels, .{});

    if (enabled) {
        // Real counter has non-zero size
        try std.testing.expect(@sizeOf(DebugCounterType) > 0);
    } else {
        // Noop counter has zero size
        try std.testing.expectEqual(0, @sizeOf(DebugCounterType));
    }
}

test "DebugGauge type selection" {
    const DebugGaugeType = DebugGauge(i64, NoLabels, .{});

    if (enabled) {
        try std.testing.expect(@sizeOf(DebugGaugeType) > 0);
    } else {
        try std.testing.expectEqual(0, @sizeOf(DebugGaugeType));
    }
}

test "DebugHistogram type selection" {
    const DebugHistogramType = DebugHistogram(f64, NoLabels, .{});

    if (enabled) {
        try std.testing.expect(@sizeOf(DebugHistogramType) > 0);
    } else {
        try std.testing.expectEqual(0, @sizeOf(DebugHistogramType));
    }
}
