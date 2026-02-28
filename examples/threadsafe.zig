const std = @import("std");
const promz = @import("promz");

const Metrics = struct {
    collector: promz.MetricCollector,
    counter: promz.Counter(f64, promz.NoLabels, .{ .thread_safe = true }),
    gauge: promz.Gauge(f64, promz.NoLabels, .{ .thread_safe = true }),
    histogram: promz.Histogram(f64, promz.NoLabels, .{ .thread_safe = true }),

    fn init(allocator: std.mem.Allocator, io: std.Io) !Metrics {
        return .{
            .collector = try promz.MetricCollector.init(allocator, "default"),
            .counter = try promz.Counter(f64, promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "requests_total",
                "Total number of requests",
            ),
            .gauge = try promz.Gauge(f64, promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "active_workers",
                "Number of active workers",
            ),
            .histogram = try promz.Histogram(f64, promz.NoLabels, .{ .thread_safe = true }).init(
                allocator,
                "processing_duration_seconds",
                "Processing duration in seconds",
                promz.defaultBuckets(),
                io,
            ),
        };
    }

    fn register(self: *Metrics) !void {
        try self.collector.registerMetric(&self.counter);
        try self.collector.registerMetric(&self.gauge);
        try self.collector.registerMetric(&self.histogram);
    }

    fn deinit(self: *Metrics) void {
        self.histogram.deinit();
        self.gauge.deinit();
        self.counter.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    const io = threaded.io();

    std.log.info("=== Thread-Safe Metrics Example ===\n", .{});

    var metrics = try Metrics.init(allocator, io);
    defer metrics.deinit();

    std.log.info("Starting 10 worker threads...\n", .{});

    var threads: [10]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ i, &metrics.counter, &metrics.gauge, &metrics.histogram });
    }

    for (threads) |thread| {
        thread.join();
    }

    std.log.info("\nAll threads completed!\n", .{});
    std.log.info("Final counter value: {d}\n", .{try metrics.counter.get(.{})});
    std.log.info("Final gauge value: {d}\n", .{try metrics.gauge.get(.{})});

    var registry = promz.Registry.init(allocator, io);
    defer registry.deinit();

    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "\n=== Prometheus Metrics ===\n\n");

    const output = try registry.gatherToString();
    defer allocator.free(output);
    try stdout.writeStreamingAll(io, output);
}

fn workerThread(
    id: usize,
    counter: *promz.Counter(f64, promz.NoLabels, .{ .thread_safe = true }),
    gauge: *promz.Gauge(f64, promz.NoLabels, .{ .thread_safe = true }),
    histogram: *promz.Histogram(f64, promz.NoLabels, .{ .thread_safe = true }),
) !void {
    std.log.info("Worker {d} started\n", .{id});

    try gauge.inc(.{});

    for (0..100) |i| {
        try counter.inc(.{});

        const duration = @as(f64, @floatFromInt(i)) / 1000.0;
        try histogram.observe(.{}, duration);

        var j: usize = 0;
        while (j < 1000) : (j += 1) {}
    }

    try gauge.dec(.{});

    std.log.info("Worker {d} finished\n", .{id});
}
