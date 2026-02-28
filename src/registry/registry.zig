const std = @import("std");
const Collector = @import("collector.zig").Collector;

/// Registry manages collectors and provides metric exposition
/// Thread-safe for concurrent gathering and registration
pub const Registry = struct {
    allocator: std.mem.Allocator,
    collectors: std.ArrayList(Collector),
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return Registry{
            .allocator = allocator,
            .collectors = .empty,
            .io = io,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.deinitWithOptions(true);
    }

    /// Deinit the registry with control over whether to deinit collectors.
    /// If deinit_collectors is false, only the collector list is freed but
    /// collectors themselves are not deinitialized (caller manages lifecycle).
    pub fn deinitWithOptions(self: *Registry, deinit_collectors: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (deinit_collectors) {
            for (self.collectors.items) |collector| {
                collector.deinit();
            }
        }
        self.collectors.deinit(self.allocator);
    }

    /// Register a collector with this registry (thread-safe)
    pub fn registerCollector(self: *Registry, collector: Collector) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.collectors.append(self.allocator, collector);
    }

    /// Gather all metrics from all collectors and write in Prometheus format.
    /// Lock-free: all collectors must be registered before the first gather.
    /// Individual metrics are thread-safe (atomic counters/gauges, per-sample mutex for histograms).
    pub fn gather(self: *Registry, writer: anytype) !void {
        for (self.collectors.items) |collector| {
            try collector.collect(writer);
        }
    }

    /// Gather metrics into a string.
    /// Lock-free: all collectors must be registered before the first gather.
    /// Individual metrics are thread-safe (atomic counters/gauges, per-sample mutex for histograms).
    pub fn gatherToString(self: *Registry) ![]const u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);

        const ListWriter = struct {
            list: *std.ArrayList(u8),
            allocator: std.mem.Allocator,

            pub fn writeAll(w: *@This(), bytes: []const u8) !void {
                try w.list.appendSlice(w.allocator, bytes);
            }
        };

        var writer = ListWriter{ .list = &list, .allocator = self.allocator };

        for (self.collectors.items) |collector| {
            try collector.collect(&writer);
        }

        return list.toOwnedSlice(self.allocator);
    }
};

fn testIo() std.Io {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    return threaded.io();
}

test "Registry: init and deinit" {
    const io = testIo();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();

    try std.testing.expectEqual(0, registry.collectors.items.len);
}

test "Registry: gatherToString" {
    const Counter = @import("../core/counter.zig").Counter;
    const NoLabels = @import("../core/labels.zig").NoLabels;
    const MetricCollector = @import("collector.zig").MetricCollector;

    const io = testIo();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();

    var collector = try MetricCollector.init(std.testing.allocator, "test");

    var counter = try Counter(f64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "A test counter",
    );
    defer counter.deinit();

    try counter.inc(.{});
    try collector.registerMetric(&counter);
    try registry.registerCollector(collector.collector());

    const metrics = try registry.gatherToString();
    defer std.testing.allocator.free(metrics);

    try std.testing.expect(metrics.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "test_counter") != null);
}

test "Registry: gatherToString with labeled metrics" {
    const Counter = @import("../core/counter.zig").Counter;
    const Histogram = @import("../core/histogram.zig").Histogram;
    const Gauge = @import("../core/gauge.zig").Gauge;
    const NoLabels = @import("../core/labels.zig").NoLabels;
    const MetricCollector = @import("collector.zig").MetricCollector;

    const io = testIo();
    var registry = Registry.init(std.testing.allocator, io);
    defer registry.deinit();

    var collector = try MetricCollector.init(std.testing.allocator, "app");

    // Labeled counter
    var http_requests = try Counter(f64, struct {
        method: []const u8,
        status: []const u8,
    }, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "http_requests_total",
        "Total HTTP requests by method and status",
    );
    defer http_requests.deinit();

    // Labeled histogram
    const defaultBuckets = @import("../core/histogram.zig").defaultBuckets;
    var http_duration = try Histogram(f64, struct {
        method: []const u8,
    }, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "http_request_duration_seconds",
        "HTTP request duration in seconds",
        defaultBuckets(),
        io,
    );
    defer http_duration.deinit();

    // Simple gauge
    var active_connections = try Gauge(f64, NoLabels, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "http_active_connections",
        "Number of active HTTP connections",
    );
    defer active_connections.deinit();

    // Add some data
    try http_requests.inc(.{ .method = "GET", .status = "200" });
    try http_requests.inc(.{ .method = "POST", .status = "201" });
    try http_duration.observe(.{ .method = "GET" }, 0.023);
    try active_connections.set(.{}, 5.0);

    // Register all metrics
    try collector.registerMetric(&http_requests);
    try collector.registerMetric(&http_duration);
    try collector.registerMetric(&active_connections);
    try registry.registerCollector(collector.collector());

    const metrics = try registry.gatherToString();
    defer std.testing.allocator.free(metrics);

    try std.testing.expect(metrics.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "http_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "http_request_duration_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "http_active_connections") != null);
}
