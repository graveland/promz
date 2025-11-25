const std = @import("std");
const Collector = @import("collector.zig").Collector;

/// Registry manages collectors and provides metric exposition
/// Thread-safe for concurrent gathering and registration
pub const Registry = struct {
    allocator: std.mem.Allocator,
    collectors: std.ArrayList(Collector),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{
            .allocator = allocator,
            .collectors = .empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.collectors.items) |collector| {
            collector.deinit();
        }
        self.collectors.deinit(self.allocator);
    }

    /// Register a collector with this registry (thread-safe)
    pub fn registerCollector(self: *Registry, collector: Collector) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.collectors.append(self.allocator, collector);
    }

    /// Gather all metrics from all collectors and write in Prometheus format (thread-safe)
    pub fn gather(self: *Registry, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.collectors.items) |collector| {
            try collector.collect(writer);
        }
    }

    /// Gather metrics into a string (thread-safe)
    pub fn gatherToString(self: *Registry) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Start with empty list and let it grow naturally
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);

        // Create a simple wrapper that appends to the list
        const ListWriter = struct {
            list: *std.ArrayList(u8),
            allocator: std.mem.Allocator,

            pub fn writeAll(w: *@This(), bytes: []const u8) !void {
                try w.list.appendSlice(w.allocator, bytes);
            }
        };

        var writer = ListWriter{ .list = &list, .allocator = self.allocator };

        // Collect from each collector
        for (self.collectors.items) |collector| {
            try collector.collect(&writer);
        }

        return list.toOwnedSlice(self.allocator);
    }
};

test "Registry: init and deinit" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectEqual(0, registry.collectors.items.len);
}

test "Registry: gatherToString" {
    const Counter = @import("../core/counter.zig").Counter;
    const NoLabels = @import("../core/labels.zig").NoLabels;
    const MetricCollector = @import("collector.zig").MetricCollector;

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var collector = try MetricCollector.init(std.testing.allocator, "test");

    var counter = try Counter(NoLabels, .{}).init(
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
    const BucketConfig = @import("../core/histogram.zig").BucketConfig;
    const MetricCollector = @import("collector.zig").MetricCollector;

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    var collector = try MetricCollector.init(std.testing.allocator, "app");

    // Labeled counter
    var http_requests = try Counter(struct {
        method: []const u8,
        status: []const u8,
    }, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "http_requests_total",
        "Total HTTP requests by method and status",
    );
    defer http_requests.deinit();

    // Labeled histogram
    var http_duration = try Histogram(struct {
        method: []const u8,
    }, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "http_request_duration_seconds",
        "HTTP request duration in seconds",
        BucketConfig.default(),
    );
    defer http_duration.deinit();

    // Simple gauge
    var active_connections = try Gauge(NoLabels, .{ .thread_safe = true }).init(
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
