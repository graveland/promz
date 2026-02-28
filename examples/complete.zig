const std = @import("std");
const promz = @import("promz");

const HttpLabels = struct {
    method: []const u8,
    status: []const u8,
};

const Metrics = struct {
    collector: promz.MetricCollector,
    http_requests: promz.Counter(f64, HttpLabels, .{}),
    memory_bytes: promz.Gauge(f64, promz.NoLabels, .{}),
    latency_hist: promz.Histogram(f64, promz.NoLabels, .{}),

    fn init(allocator: std.mem.Allocator) !Metrics {
        return .{
            .collector = try promz.MetricCollector.init(allocator, "default"),
            .http_requests = try promz.Counter(f64, HttpLabels, .{}).init(
                allocator,
                "http_requests_total",
                "Total HTTP requests",
            ),
            .memory_bytes = try promz.Gauge(f64, promz.NoLabels, .{}).init(
                allocator,
                "memory_usage_bytes",
                "Memory usage in bytes",
            ),
            .latency_hist = try promz.Histogram(f64, promz.NoLabels, .{}).init(
                allocator,
                "request_duration_seconds",
                "Request duration in seconds",
                promz.defaultBuckets(),
                {},
            ),
        };
    }

    fn register(self: *Metrics) !void {
        try self.collector.registerMetric(&self.http_requests);
        try self.collector.registerMetric(&self.memory_bytes);
        try self.collector.registerMetric(&self.latency_hist);
    }

    fn deinit(self: *Metrics) void {
        self.latency_hist.deinit();
        self.memory_bytes.deinit();
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

    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "POST", .status = "201" });
    try metrics.memory_bytes.set(.{}, 134217728.0);
    try metrics.latency_hist.observe(.{}, 0.023);
    try metrics.latency_hist.observe(.{}, 0.156);
    try metrics.latency_hist.observe(.{}, 0.089);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "=== Prometheus Text Exposition Format ===\n\n");

    const output = try registry.gatherToString();
    defer allocator.free(output);
    try stdout.writeStreamingAll(io, output);
}
