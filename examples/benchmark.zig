const std = @import("std");
const promz = @import("promz");

fn MethodLabelsType(comptime _: u8) type {
    return struct { method: []const u8 };
}
const MethodLabels = MethodLabelsType(0);
const MethodLabelsCache4 = MethodLabelsType(4);
const MethodLabelsCache16 = MethodLabelsType(16);

var bench_io: std.Io = undefined;

fn elapsed(start: std.Io.Timestamp) struct { ms: f64, ns: i96 } {
    const duration = start.durationTo(std.Io.Timestamp.now(bench_io, .awake));
    return .{ .ms = @as(f64, @floatFromInt(duration.nanoseconds)) / 1_000_000.0, .ns = duration.nanoseconds };
}

fn now() std.Io.Timestamp {
    return std.Io.Timestamp.now(bench_io, .awake);
}

fn writeOut(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(bench_io, bytes);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    bench_io = threaded.io();

    try writeOut("=== Promz Performance Benchmarks ===\n\n");

    try writeOut("--- Basic Operations ---\n");
    try benchmarkCounterNoLabels(allocator, allocator);
    try benchmarkCounterWithLabels(allocator, allocator);
    try benchmarkCounterThreadSafe(allocator, allocator);
    try benchmarkGaugeWithLabels(allocator);
    try benchmarkHistogram(allocator, allocator);
    try benchmarkHistogramWithLabels(allocator);

    try writeOut("\n--- Pre-registered Handles (O(1) lookup) ---\n");
    try benchmarkCounterWithHandle(allocator);
    try benchmarkGaugeWithHandle(allocator);
    try benchmarkHistogramWithHandle(allocator);

    try writeOut("\n--- Thread-Local Cache ---\n");
    try benchmarkCounterWithCache(allocator);
    try benchmarkCounterCacheRotating(allocator);
    try benchmarkCounterNoCacheRotating(allocator);

    try writeOut("\n--- Cache Size Comparison (4 vs 16 entries) ---\n");
    try benchmarkCounterCacheEviction(allocator);
    try benchmarkCounterCache16Entries(allocator);
    try benchmarkCounterCache16With16Labels(allocator);

    try writeOut("\n--- RuntimeLabels ---\n");
    try benchmarkCounterRuntimeLabels(allocator);

    try writeOut("\n--- Mixed API (Realistic Usage) ---\n");
    try benchmarkMixedApi(allocator);

    try writeOut("\n=== Benchmarks Complete ===\n");
}

fn benchmarkCounterNoLabels(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    var counter = try promz.Counter(f64, promz.NoLabels, .{}).init(
        allocator,
        "test_counter",
        "Test counter",
    );
    defer counter.deinit();

    const iterations: usize = 10_000_000;
    const start = now();

    for (0..iterations) |_| {
        try counter.inc(.{});
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (NoLabels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkCounterWithLabels(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(f64, Labels, .{}).init(
        allocator,
        "test_counter",
        "Test counter",
    );
    defer counter.deinit();

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |_| {
        try counter.inc(.{ .method = "GET" });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (With Labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkCounterThreadSafe(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    var counter = try promz.Counter(f64, promz.NoLabels, .{ .thread_safe = true }).init(
        allocator,
        "test_counter",
        "Test counter",
    );
    defer counter.deinit();

    const iterations: usize = 10_000_000;
    const start = now();

    for (0..iterations) |_| {
        try counter.inc(.{});
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Thread-Safe): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkGaugeWithLabels(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        host: []const u8,
    };

    var gauge = try promz.Gauge(f64, Labels, .{}).init(
        allocator,
        "test_gauge",
        "Test gauge",
    );
    defer gauge.deinit();

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 1000));
        try gauge.set(.{ .host = "server1" }, value);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Gauge (With Labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkHistogram(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    var hist = try promz.Histogram(f64, promz.NoLabels, .{}).init(
        allocator,
        "test_histogram",
        "Test histogram",
        promz.defaultBuckets(),
        {},
    );
    defer hist.deinit();

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 100)) / 100.0;
        try hist.observe(.{}, value);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Histogram (NoLabels): {d:.2} observations in {d:.2}ms ({d:.0} obs/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkHistogramWithLabels(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var hist = try promz.Histogram(f64, Labels, .{}).init(
        allocator,
        "test_histogram",
        "Test histogram",
        promz.defaultBuckets(),
        {},
    );
    defer hist.deinit();

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 100)) / 100.0;
        try hist.observe(.{ .method = "GET" }, value);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Histogram (With Labels): {d:.2} observations in {d:.2}ms ({d:.0} obs/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

// ============================================================================
// Pre-registered Labels (Handle-Based) Benchmarks
// ============================================================================

fn benchmarkCounterWithHandle(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(f64, Labels, .{}).init(
        allocator,
        "test_counter_handle",
        "Test counter with handle",
    );
    defer counter.deinit();

    const handle = try counter.register(.{ .method = "GET" });

    const iterations: usize = 10_000_000;
    const start = now();

    for (0..iterations) |_| {
        try counter.incByHandle(handle);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Pre-registered Handle): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkGaugeWithHandle(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        host: []const u8,
    };

    var gauge = try promz.Gauge(f64, Labels, .{}).init(
        allocator,
        "test_gauge_handle",
        "Test gauge with handle",
    );
    defer gauge.deinit();

    const handle = try gauge.register(.{ .host = "server1" });

    const iterations: usize = 10_000_000;
    const start = now();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 1000));
        try gauge.setByHandle(handle, value);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Gauge (Pre-registered Handle): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkHistogramWithHandle(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var hist = try promz.Histogram(f64, Labels, .{}).init(
        allocator,
        "test_histogram_handle",
        "Test histogram with handle",
        promz.defaultBuckets(),
        {},
    );
    defer hist.deinit();

    const handle = try hist.register(.{ .method = "GET" });

    const iterations: usize = 10_000_000;
    const start = now();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 100)) / 100.0;
        try hist.observeByHandle(handle, value);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Histogram (Pre-registered Handle): {d:.2} observations in {d:.2}ms ({d:.0} obs/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

// ============================================================================
// Thread-Local Cache Benchmarks
// ============================================================================

fn benchmarkCounterWithCache(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(f64, Labels, .{ .thread_local_cache = true }).init(
        allocator,
        "test_counter_cached",
        "Test counter with thread-local cache",
    );
    defer counter.deinit();

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |_| {
        try counter.inc(.{ .method = "GET" });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Thread-Local Cache, same label): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkCounterCacheRotating(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(f64, Labels, .{ .thread_local_cache = true }).init(
        allocator,
        "test_counter_rotating",
        "Test counter with rotating labels",
    );
    defer counter.deinit();

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };
    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 4] });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Thread-Local Cache, 4 rotating labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkCounterCacheEviction(allocator: std.mem.Allocator) !void {
    var counter = try promz.Counter(f64, MethodLabelsCache4, .{ .thread_local_cache = true, .cache_size = 4 }).init(
        allocator,
        "test_counter_evict",
        "Test counter with cache eviction",
    );
    defer counter.deinit();

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE" };
    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 8] });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Cache size=4, 8 labels w/eviction): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkCounterCache16Entries(allocator: std.mem.Allocator) !void {
    var counter = try promz.Counter(f64, MethodLabelsCache16, .{ .thread_local_cache = true, .cache_size = 16 }).init(
        allocator,
        "test_counter_cache16",
        "Test counter with 16-entry cache",
    );
    defer counter.deinit();

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE" };
    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 8] });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Cache size=16, 8 labels no eviction): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

fn benchmarkCounterCache16With16Labels(allocator: std.mem.Allocator) !void {
    var counter = try promz.Counter(f64, MethodLabelsCache16, .{ .thread_local_cache = true, .cache_size = 16 }).init(
        allocator,
        "test_counter_cache16_full",
        "Test counter with 16-entry cache full",
    );
    defer counter.deinit();

    const methods = [_][]const u8{
        "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE",
        "CONNECT", "M1", "M2", "M3", "M4", "M5", "M6", "M7",
    };
    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 16] });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Cache size=16, 16 labels fills cache): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

// ============================================================================
// Comparison - No Cache vs Cache
// ============================================================================

fn benchmarkCounterNoCacheRotating(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(f64, Labels, .{ .thread_local_cache = false }).init(
        allocator,
        "test_counter_nocache",
        "Test counter without cache",
    );
    defer counter.deinit();

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };
    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 4] });
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (No Cache, 4 rotating labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

// ============================================================================
// Mixed API Benchmark (Realistic scenario)
// ============================================================================

fn benchmarkMixedApi(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    var counter = try promz.Counter(f64, Labels, .{ .thread_local_cache = true }).init(
        allocator,
        "http_requests_total",
        "Total HTTP requests",
    );
    defer counter.deinit();

    const get_200 = try counter.register(.{ .method = "GET", .status = "200" });
    const get_404 = try counter.register(.{ .method = "GET", .status = "404" });
    const post_201 = try counter.register(.{ .method = "POST", .status = "201" });

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |i| {
        switch (i % 10) {
            0...5 => try counter.incByHandle(get_200),
            6 => try counter.incByHandle(get_404),
            7 => try counter.incByHandle(post_201),
            8 => try counter.inc(.{ .method = "PUT", .status = "200" }),
            9 => try counter.inc(.{ .method = "DELETE", .status = "204" }),
            else => unreachable,
        }
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Mixed API (80%% handles, 20%% labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}

// ============================================================================
// RuntimeLabels Benchmark
// ============================================================================

fn benchmarkCounterRuntimeLabels(allocator: std.mem.Allocator) !void {
    var counter = try promz.Counter(f64, promz.RuntimeLabels, .{}).init(
        allocator,
        "runtime_counter",
        "Counter with runtime labels",
    );
    defer counter.deinit();

    const keys = [_][]const u8{"method"};
    const values = [_][]const u8{"GET"};
    const labels = try promz.RuntimeLabels.init(&keys, &values);

    const iterations: usize = 1_000_000;
    const start = now();

    for (0..iterations) |_| {
        try counter.inc(labels);
    }

    const t = elapsed(start);
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (t.ms / 1000.0);

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (RuntimeLabels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        t.ms,
        ops_per_sec,
    });
    try writeOut(msg);
}
