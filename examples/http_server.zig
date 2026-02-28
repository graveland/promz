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
    http_requests: promz.Counter(f64, HttpLabels, .{ .thread_safe = true }),
    http_duration: promz.Histogram(f64, DurationLabels, .{ .thread_safe = true }),
    active_connections: promz.Gauge(f64, promz.NoLabels, .{ .thread_safe = true }),

    fn init(allocator: std.mem.Allocator, io: std.Io) !Metrics {
        return .{
            .collector = try promz.MetricCollector.init(allocator, "app"),
            .http_requests = try promz.Counter(f64, HttpLabels, .{ .thread_safe = true }).init(
                allocator,
                "http_requests_total",
                "Total HTTP requests by method and status",
            ),
            .http_duration = try promz.Histogram(f64, DurationLabels, .{ .thread_safe = true }).init(
                allocator,
                "http_request_duration_seconds",
                "HTTP request duration in seconds",
                promz.defaultBuckets(),
                io,
            ),
            .active_connections = try promz.Gauge(f64, promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "http_active_connections",
                "Number of active HTTP connections",
            ),
        };
    }

    fn register(self: *Metrics) !void {
        try self.collector.registerMetric(&self.http_requests);
        try self.collector.registerMetric(&self.http_duration);
        try self.collector.registerMetric(&self.active_connections);
    }

    fn deinit(self: *Metrics) void {
        self.active_connections.deinit();
        self.http_duration.deinit();
        self.http_requests.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    var registry = promz.Registry.init(allocator, io);
    defer registry.deinit();

    var metrics = try Metrics.init(allocator, io);
    defer metrics.deinit();

    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "POST", .status = "201" });
    try metrics.http_requests.inc(.{ .method = "GET", .status = "404" });

    try metrics.http_duration.observe(.{ .method = "GET" }, 0.023);
    try metrics.http_duration.observe(.{ .method = "GET" }, 0.156);
    try metrics.http_duration.observe(.{ .method = "POST" }, 0.089);

    try metrics.active_connections.set(.{}, 5.0);

    var server = promz.MetricsServer.initWithIo(allocator, io, &registry);
    defer server.deinit();

    std.log.info("Press Ctrl+C to stop", .{});
    try server.serve(.{ .port = 9090 });
}
