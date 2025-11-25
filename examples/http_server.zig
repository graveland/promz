const std = @import("std");
const promz = @import("promz");

/// HTTP Server Example
///
/// This example demonstrates how to use promz.MetricsServer to expose
/// Prometheus metrics over HTTP.
///
/// Run with: zig build run-http-server
/// Then visit: http://127.0.0.1:9090/metrics
///
/// You can also scrape with curl:
///   curl http://127.0.0.1:9090/metrics

const HttpLabels = struct {
    method: []const u8,
    status: []const u8,
};

const DurationLabels = struct {
    method: []const u8,
};

const Metrics = struct {
    collector: promz.MetricCollector,
    http_requests: promz.Counter(HttpLabels, .{ .thread_safe = true }),
    http_duration: promz.Histogram(DurationLabels, .{ .thread_safe = true }),
    active_connections: promz.Gauge(promz.NoLabels, .{ .thread_safe = true }),

    fn init(allocator: std.mem.Allocator) !Metrics {
        return .{
            .collector = try promz.MetricCollector.init(allocator, "app"),
            .http_requests = try promz.Counter(HttpLabels, .{ .thread_safe = true }).init(
                allocator,
                "http_requests_total",
                "Total HTTP requests by method and status",
            ),
            .http_duration = try promz.Histogram(DurationLabels, .{ .thread_safe = true }).init(
                allocator,
                "http_request_duration_seconds",
                "HTTP request duration in seconds",
                promz.BucketConfig.default(),
            ),
            .active_connections = try promz.Gauge(promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "http_active_connections",
                "Number of active HTTP connections",
            ),
        };
    }

    // CRITICAL: Register metrics AFTER struct is in final location
    fn register(self: *Metrics) !void {
        try self.collector.registerMetric(&self.http_requests);
        try self.collector.registerMetric(&self.http_duration);
        try self.collector.registerMetric(&self.active_connections);
    }

    fn deinit(self: *Metrics) void {
        self.active_connections.deinit();
        self.http_duration.deinit();
        self.http_requests.deinit();
        // NOTE: Don't deinit collector - it's owned by the Registry
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create registry
    var registry = promz.Registry.init(allocator);
    defer registry.deinit();

    // Initialize metrics
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    // Register AFTER metrics struct is in final location
    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    // Add some sample data
    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "POST", .status = "201" });
    try metrics.http_requests.inc(.{ .method = "GET", .status = "404" });

    try metrics.http_duration.observe(.{ .method = "GET" }, 0.023);
    try metrics.http_duration.observe(.{ .method = "GET" }, 0.156);
    try metrics.http_duration.observe(.{ .method = "POST" }, 0.089);

    try metrics.active_connections.set(.{}, 5.0);

    // Start the metrics server
    var server = promz.MetricsServer.init(allocator, &registry);
    defer server.deinit();

    std.log.info("Press Ctrl+C to stop", .{});
    try server.serve(.{ .port = 9090 });
}
