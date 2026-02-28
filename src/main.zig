const std = @import("std");
const promz = @import("promz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    const stdout = std.Io.File.stdout();

    try stdout.writeStreamingAll(io, "Prometheus Client Example (Phase 3 - Histogram)\n\n");

    // Example 1: Counter with struct labels (compile-time)
    const HttpLabels = struct {
        method: []const u8,
        status: []const u8,
    };

    var http_requests = try promz.Counter(f64, HttpLabels, .{}).init(
        allocator,
        "http_requests_total",
        "Total HTTP requests",
    );
    defer http_requests.deinit();

    try http_requests.inc(.{ .method = "GET", .status = "200" });
    try http_requests.inc(.{ .method = "GET", .status = "200" });
    try http_requests.inc(.{ .method = "POST", .status = "201" });
    try http_requests.inc(.{ .method = "GET", .status = "404" });

    var buffer: [256]u8 = undefined;

    try stdout.writeStreamingAll(io, "HTTP Requests Counter (struct labels):\n");
    var msg = try std.fmt.bufPrint(&buffer, "  GET 200: {d}\n", .{try http_requests.get(.{ .method = "GET", .status = "200" })});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  POST 201: {d}\n", .{try http_requests.get(.{ .method = "POST", .status = "201" })});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  GET 404: {d}\n\n", .{try http_requests.get(.{ .method = "GET", .status = "404" })});
    try stdout.writeStreamingAll(io, msg);

    // Example 2: Gauge with RuntimeLabels (dynamic)
    var memory_usage = try promz.Gauge(f64, promz.RuntimeLabels, .{}).init(
        allocator,
        "memory_usage_bytes",
        "Memory usage in bytes",
    );
    defer memory_usage.deinit();

    const keys = [_][]const u8{"host"};
    const server1_values = [_][]const u8{"server1"};
    const server2_values = [_][]const u8{"server2"};

    const server1_labels = try promz.RuntimeLabels.init(&keys, &server1_values);
    const server2_labels = try promz.RuntimeLabels.init(&keys, &server2_values);

    try memory_usage.set(server1_labels, 1024.0 * 1024.0);
    try memory_usage.set(server2_labels, 2048.0 * 1024.0);

    try stdout.writeStreamingAll(io, "Memory Usage Gauge (runtime labels):\n");
    msg = try std.fmt.bufPrint(&buffer, "  server1: {d} MB\n", .{(try memory_usage.get(server1_labels)) / 1024.0 / 1024.0});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  server2: {d} MB\n\n", .{(try memory_usage.get(server2_labels)) / 1024.0 / 1024.0});
    try stdout.writeStreamingAll(io, msg);

    // Example 3: Simple counter without labels
    var simple_counter = try promz.Counter(f64, promz.NoLabels, .{}).init(
        allocator,
        "simple_counter",
        "A simple counter without labels",
    );
    defer simple_counter.deinit();

    try simple_counter.add(.{}, 42.0);

    try stdout.writeStreamingAll(io, "Simple Counter (no labels):\n");
    msg = try std.fmt.bufPrint(&buffer, "  value: {d}\n", .{try simple_counter.get(.{})});
    try stdout.writeStreamingAll(io, msg);

    // Example 4: Histogram for measuring distributions
    const latency_buckets = promz.BucketConfig(f64).custom(&[_]f64{ 0.01, 0.05, 0.1, 0.5, 1.0 });
    var request_latency = try promz.Histogram(f64, promz.NoLabels, .{}).init(
        allocator,
        "request_duration_seconds",
        "Request duration in seconds",
        latency_buckets,
        {},
    );
    defer request_latency.deinit();

    // Simulate some requests with varying latencies
    try request_latency.observe(.{}, 0.005); // 5ms
    try request_latency.observe(.{}, 0.023); // 23ms
    try request_latency.observe(.{}, 0.087); // 87ms
    try request_latency.observe(.{}, 0.234); // 234ms
    try request_latency.observe(.{}, 0.567); // 567ms
    try request_latency.observe(.{}, 1.234); // 1234ms

    try stdout.writeStreamingAll(io, "\nRequest Latency Histogram:\n");
    msg = try std.fmt.bufPrint(&buffer, "  Total requests: {d}\n", .{try request_latency.getCount(.{})});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  Total time: {d:.3}s\n", .{try request_latency.getSum(.{})});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  <= 10ms: {d}\n", .{try request_latency.getBucketCount(.{}, 0)});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  <= 50ms: {d}\n", .{try request_latency.getBucketCount(.{}, 1)});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  <= 100ms: {d}\n", .{try request_latency.getBucketCount(.{}, 2)});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  <= 500ms: {d}\n", .{try request_latency.getBucketCount(.{}, 3)});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  <= 1s: {d}\n", .{try request_latency.getBucketCount(.{}, 4)});
    try stdout.writeStreamingAll(io, msg);

    msg = try std.fmt.bufPrint(&buffer, "  +Inf: {d}\n", .{try request_latency.getBucketCount(.{}, 5)});
    try stdout.writeStreamingAll(io, msg);
}
