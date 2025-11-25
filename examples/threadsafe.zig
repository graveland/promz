const std = @import("std");
const promz = @import("promz");

const Metrics = struct {
    collector: promz.MetricCollector,
    counter: promz.Counter(promz.NoLabels, .{ .thread_safe = true }),
    gauge: promz.Gauge(promz.NoLabels, .{ .thread_safe = true }),
    histogram: promz.Histogram(promz.NoLabels, .{ .thread_safe = true }),

    fn init(allocator: std.mem.Allocator) !Metrics {
        return .{
            .collector = try promz.MetricCollector.init(allocator, "default"),
            .counter = try promz.Counter(promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "requests_total",
                "Total number of requests",
            ),
            .gauge = try promz.Gauge(promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "active_workers",
                "Number of active workers",
            ),
            .histogram = try promz.Histogram(promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "processing_duration_seconds",
                "Processing duration in seconds",
                promz.BucketConfig.default(),
            ),
        };
    }

    // CRITICAL: Register metrics AFTER struct is in final location
    fn register(self: *Metrics) !void {
        try self.collector.registerMetric(&self.counter);
        try self.collector.registerMetric(&self.gauge);
        try self.collector.registerMetric(&self.histogram);
    }

    fn deinit(self: *Metrics) void {
        self.histogram.deinit();
        self.gauge.deinit();
        self.counter.deinit();
        // NOTE: Don't deinit collector - it's owned by the Registry
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Thread-Safe Metrics Example ===\n", .{});

    // Initialize metrics
    var metrics = try Metrics.init(allocator);
    defer metrics.deinit();

    std.log.info("Starting 10 worker threads...\n", .{});

    // Spawn multiple threads that concurrently update metrics
    var threads: [10]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ i, &metrics.counter, &metrics.gauge, &metrics.histogram });
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    std.log.info("\nAll threads completed!\n", .{});
    std.log.info("Final counter value: {d}\n", .{try metrics.counter.get(.{})});
    std.log.info("Final gauge value: {d}\n", .{try metrics.gauge.get(.{})});

    // Print metrics in Prometheus format
    var registry = promz.Registry.init(allocator);
    defer registry.deinit();

    // Register AFTER metrics struct is in final location
    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("\n=== Prometheus Metrics ===\n\n");

    const output = try registry.gatherToString();
    defer allocator.free(output);
    try stdout.writeAll(output);
}

fn workerThread(
    id: usize,
    counter: *promz.Counter(promz.NoLabels, .{ .thread_safe = true }),
    gauge: *promz.Gauge(promz.NoLabels, .{ .thread_safe = true }),
    histogram: *promz.Histogram(promz.NoLabels, .{ .thread_safe = true }),
) !void {
    std.log.info("Worker {d} started\n", .{id});

    // Increment gauge to show this worker is active
    try gauge.inc(.{});

    // Simulate some work and update metrics
    for (0..100) |i| {
        try counter.inc(.{});

        // Simulate varying processing times
        const duration = @as(f64, @floatFromInt(i)) / 1000.0;
        try histogram.observe(.{}, duration);

        // Small delay to simulate work (spin wait)
        var j: usize = 0;
        while (j < 1000) : (j += 1) {}
    }

    // Decrement gauge when done
    try gauge.dec(.{});

    std.log.info("Worker {d} finished\n", .{id});
}
