const std = @import("std");
const promz = @import("promz");

const HttpLabels = struct {
    method: []const u8,
    status: []const u8,
};

const Metrics = struct {
    collector: promz.MetricCollector,
    http_requests: promz.Counter(HttpLabels, .{}),
    memory_bytes: promz.Gauge(promz.NoLabels, .{}),
    latency_hist: promz.Histogram(promz.NoLabels, .{}),

    fn init(allocator: std.mem.Allocator) !Metrics {
        return .{
            .collector = try promz.MetricCollector.init(allocator, "default"),
            .http_requests = try promz.Counter(HttpLabels, .{}).init(
                allocator,
                "http_requests_total",
                "Total HTTP requests",
            ),
            .memory_bytes = try promz.Gauge(promz.NoLabels, .{}).init(
                allocator,
                "memory_usage_bytes",
                "Memory usage in bytes",
            ),
            .latency_hist = try promz.Histogram(promz.NoLabels, .{}).init(
                allocator,
                "request_duration_seconds",
                "Request duration in seconds",
                promz.BucketConfig.default(),
            ),
        };
    }

    // CRITICAL: Register metrics AFTER struct is in final location
    fn register(self: *Metrics) !void {
        try self.collector.registerMetric(&self.http_requests);
        try self.collector.registerMetric(&self.memory_bytes);
        try self.collector.registerMetric(&self.latency_hist);
    }

    fn deinit(self: *Metrics) void {
        self.latency_hist.deinit();
        self.memory_bytes.deinit();
        self.http_requests.deinit();
        // NOTE: Don't deinit collector here - it's owned by the Registry
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var registry = promz.Registry.init(allocator);
    defer registry.deinit();

    // Initialize metrics
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    // Register AFTER metrics struct is in final location
    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    // Use metrics
    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "GET", .status = "200" });
    try metrics.http_requests.inc(.{ .method = "POST", .status = "201" });
    try metrics.memory_bytes.set(.{}, 134217728.0);
    try metrics.latency_hist.observe(.{}, 0.023);
    try metrics.latency_hist.observe(.{}, 0.156);
    try metrics.latency_hist.observe(.{}, 0.089);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("=== Prometheus Text Exposition Format ===\n\n");

    const output = try registry.gatherToString();
    defer allocator.free(output);
    try stdout.writeAll(output);
}
