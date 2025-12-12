const std = @import("std");

/// Write all metrics from a struct to a writer.
/// This is a convenience function that iterates over all fields
/// of a metrics struct and calls write() on each metric.
///
/// Usage:
/// ```
/// const Metrics = struct {
///     requests: promz.Counter(u64, promz.NoLabels, .{}),
///     latency: promz.Histogram(f64, promz.NoLabels, .{}),
/// };
///
/// var metrics = Metrics{
///     .requests = try promz.Counter(u64, promz.NoLabels, .{}).init(allocator, "requests", "Total requests"),
///     .latency = try promz.Histogram(f64, promz.NoLabels, .{}).init(allocator, "latency", "Request latency", promz.defaultBuckets()),
/// };
///
/// // Write all metrics to any writer (e.g., HTTP response)
/// try promz.write(&metrics, response_writer);
/// ```
pub fn write(metrics: anytype, writer: anytype) !void {
    const T = @TypeOf(metrics.*);
    const info = @typeInfo(T);

    if (info != .@"struct") {
        @compileError("write() requires a pointer to a struct, got: " ++ @typeName(T));
    }

    inline for (info.@"struct".fields) |field| {
        const field_info = @typeInfo(field.type);
        // Check if this field is a metric (union with noop/impl or has write method)
        if (field_info == .@"union") {
            // It's a union type (Counter, Gauge, Histogram with noop support)
            if (@hasDecl(field.type, "write")) {
                const field_ptr: *const field.type = &@field(metrics, field.name);
                try field_ptr.write(writer);
            }
        } else if (field_info == .@"struct") {
            // Legacy direct metric type with write method
            if (@hasDecl(field.type, "write")) {
                const field_ptr: *const field.type = &@field(metrics, field.name);
                try field_ptr.write(writer);
            }
        }
        // Skip non-metric fields (primitives, slices, etc. that don't have write method)
    }
}

test "write: writes all metrics from struct" {
    const Counter = @import("counter.zig").Counter;
    const Gauge = @import("gauge.zig").Gauge;
    const NoLabels = @import("labels.zig").NoLabels;

    const Metrics = struct {
        requests: Counter(u64, NoLabels, .{}),
        active: Gauge(i64, NoLabels, .{}),
    };

    var metrics = Metrics{
        .requests = try Counter(u64, NoLabels, .{}).init(std.testing.allocator, "requests_total", "Total requests"),
        .active = try Gauge(i64, NoLabels, .{}).init(std.testing.allocator, "active_connections", "Active connections"),
    };
    defer {
        metrics.requests.deinit();
        metrics.active.deinit();
    }

    try metrics.requests.inc(.{});
    try metrics.active.set(.{}, 5);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try write(&metrics, &aw.writer);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "active_connections") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE requests_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE active_connections gauge") != null);
}

test "write: skips noop metrics" {
    const Counter = @import("counter.zig").Counter;
    const Gauge = @import("gauge.zig").Gauge;
    const NoLabels = @import("labels.zig").NoLabels;

    const Metrics = struct {
        enabled: Counter(u64, NoLabels, .{}),
        disabled: Gauge(i64, NoLabels, .{}),
    };

    var metrics = Metrics{
        .enabled = try Counter(u64, NoLabels, .{}).init(std.testing.allocator, "enabled_counter", "Enabled counter"),
        .disabled = .noop, // This one is disabled
    };
    defer metrics.enabled.deinit();

    try metrics.enabled.inc(.{});

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try write(&metrics, &aw.writer);

    const output = aw.written();
    // Enabled counter should be present
    try std.testing.expect(std.mem.indexOf(u8, output, "enabled_counter") != null);
    // Disabled gauge should not be present
    try std.testing.expect(std.mem.indexOf(u8, output, "disabled") == null);
}

test "write: ignores non-metric fields" {
    const Counter = @import("counter.zig").Counter;
    const NoLabels = @import("labels.zig").NoLabels;

    const Metrics = struct {
        counter: Counter(u64, NoLabels, .{}),
        name: []const u8, // Non-metric field
        count: u32, // Non-metric field
    };

    var metrics = Metrics{
        .counter = try Counter(u64, NoLabels, .{}).init(std.testing.allocator, "test_counter", "Test"),
        .name = "my_metrics",
        .count = 42,
    };
    defer metrics.counter.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try write(&metrics, &aw.writer);

    const output = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "test_counter") != null);
}
