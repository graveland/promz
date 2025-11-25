const std = @import("std");
const promz = @import("promz");

// Unique label types - using comptime_int phantom field to ensure type uniqueness
fn MethodLabelsType(comptime _: u8) type {
    return struct { method: []const u8 };
}
const MethodLabels = MethodLabelsType(0);
const MethodLabelsCache4 = MethodLabelsType(4);
const MethodLabelsCache16 = MethodLabelsType(16);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();

    try stdout.writeAll("=== Promz Performance Benchmarks ===\n\n");

    // ---- Basic Benchmarks ----
    try stdout.writeAll("--- Basic Operations ---\n");
    try benchmarkCounterNoLabels(allocator, allocator);
    try benchmarkCounterWithLabels(allocator, allocator);
    try benchmarkCounterThreadSafe(allocator, allocator);
    try benchmarkGaugeWithLabels(allocator);
    try benchmarkHistogram(allocator, allocator);
    try benchmarkHistogramWithLabels(allocator);

    // ---- Pre-registered Handle Benchmarks ----
    try stdout.writeAll("\n--- Pre-registered Handles (O(1) lookup) ---\n");
    try benchmarkCounterWithHandle(allocator);
    try benchmarkGaugeWithHandle(allocator);
    try benchmarkHistogramWithHandle(allocator);

    // ---- Thread-Local Cache Benchmarks ----
    try stdout.writeAll("\n--- Thread-Local Cache ---\n");
    try benchmarkCounterWithCache(allocator);
    try benchmarkCounterCacheRotating(allocator);
    try benchmarkCounterNoCacheRotating(allocator);

    // ---- Cache Size Comparison (4 vs 16 entries) ----
    try stdout.writeAll("\n--- Cache Size Comparison (4 vs 16 entries) ---\n");
    try benchmarkCounterCacheEviction(allocator);
    try benchmarkCounterCache16Entries(allocator);
    try benchmarkCounterCache16With16Labels(allocator);

    // ---- RuntimeLabels Benchmark ----
    try stdout.writeAll("\n--- RuntimeLabels ---\n");
    try benchmarkCounterRuntimeLabels(allocator);

    // ---- Mixed API (Realistic) ----
    try stdout.writeAll("\n--- Mixed API (Realistic Usage) ---\n");
    try benchmarkMixedApi(allocator);

    try stdout.writeAll("\n=== Benchmarks Complete ===\n");
}

fn benchmarkCounterNoLabels(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    var counter = try promz.Counter(promz.NoLabels, .{}).init(
        allocator,
        "test_counter",
        "Test counter",
    );
    defer counter.deinit();

    const iterations: usize = 10_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try counter.inc(.{});
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (NoLabels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkCounterWithLabels(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(Labels, .{}).init(
        allocator,
        "test_counter",
        "Test counter",
    );
    defer counter.deinit();

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try counter.inc(.{ .method = "GET" });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (With Labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkCounterThreadSafe(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    var counter = try promz.Counter(promz.NoLabels, .{ .thread_safe = true }).init(
        allocator,
        "test_counter",
        "Test counter",
    );
    defer counter.deinit();

    const iterations: usize = 10_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try counter.inc(.{});
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Thread-Safe): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkGaugeWithLabels(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        host: []const u8,
    };

    var gauge = try promz.Gauge(Labels, .{}).init(
        allocator,
        "test_gauge",
        "Test gauge",
    );
    defer gauge.deinit();

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 1000));
        try gauge.set(.{ .host = "server1" }, value);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Gauge (With Labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkHistogram(allocator: std.mem.Allocator, alloc2: std.mem.Allocator) !void {
    _ = alloc2;
    var hist = try promz.Histogram(promz.NoLabels, .{}).init(
        allocator,
        "test_histogram",
        "Test histogram",
        promz.BucketConfig.default(),
    );
    defer hist.deinit();

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 100)) / 100.0;
        try hist.observe(.{}, value);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Histogram (NoLabels): {d:.2} observations in {d:.2}ms ({d:.0} obs/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkHistogramWithLabels(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var hist = try promz.Histogram(Labels, .{}).init(
        allocator,
        "test_histogram",
        "Test histogram",
        promz.BucketConfig.default(),
    );
    defer hist.deinit();

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 100)) / 100.0;
        try hist.observe(.{ .method = "GET" }, value);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Histogram (With Labels): {d:.2} observations in {d:.2}ms ({d:.0} obs/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

// ============================================================================
// NEW: Pre-registered Labels (Handle-Based) Benchmarks
// ============================================================================

fn benchmarkCounterWithHandle(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try promz.Counter(Labels, .{}).init(
        allocator,
        "test_counter_handle",
        "Test counter with handle",
    );
    defer counter.deinit();

    // Pre-register label combination
    const handle = try counter.register(.{ .method = "GET" });

    const iterations: usize = 10_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try counter.incByHandle(handle);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Pre-registered Handle): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkGaugeWithHandle(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        host: []const u8,
    };

    var gauge = try promz.Gauge(Labels, .{}).init(
        allocator,
        "test_gauge_handle",
        "Test gauge with handle",
    );
    defer gauge.deinit();

    const handle = try gauge.register(.{ .host = "server1" });

    const iterations: usize = 10_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 1000));
        try gauge.setByHandle(handle, value);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Gauge (Pre-registered Handle): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkHistogramWithHandle(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    var hist = try promz.Histogram(Labels, .{}).init(
        allocator,
        "test_histogram_handle",
        "Test histogram with handle",
        promz.BucketConfig.default(),
    );
    defer hist.deinit();

    const handle = try hist.register(.{ .method = "GET" });

    const iterations: usize = 10_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        const value = @as(f64, @floatFromInt(i % 100)) / 100.0;
        try hist.observeByHandle(handle, value);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Histogram (Pre-registered Handle): {d:.2} observations in {d:.2}ms ({d:.0} obs/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

// ============================================================================
// NEW: Thread-Local Cache Benchmarks
// ============================================================================

fn benchmarkCounterWithCache(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    // Enable thread-local cache
    var counter = try promz.Counter(Labels, .{ .thread_local_cache = true }).init(
        allocator,
        "test_counter_cached",
        "Test counter with thread-local cache",
    );
    defer counter.deinit();

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    // Same label combination - should hit cache after first lookup
    for (0..iterations) |_| {
        try counter.inc(.{ .method = "GET" });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Thread-Local Cache, same label): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkCounterCacheRotating(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    // Enable thread-local cache
    var counter = try promz.Counter(Labels, .{ .thread_local_cache = true }).init(
        allocator,
        "test_counter_rotating",
        "Test counter with rotating labels",
    );
    defer counter.deinit();

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };
    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    // Rotate through 4 labels - all should fit in cache
    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 4] });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Thread-Local Cache, 4 rotating labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkCounterCacheEviction(allocator: std.mem.Allocator) !void {
    // Use unique label type to ensure separate thread-local cache
    // Enable thread-local cache with size=4 to demonstrate eviction behavior
    var counter = try promz.Counter(MethodLabelsCache4, .{ .thread_local_cache = true, .cache_size = 4 }).init(
        allocator,
        "test_counter_evict",
        "Test counter with cache eviction",
    );
    defer counter.deinit();

    // 8 labels - more than cache size (4), causes evictions
    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE" };
    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 8] });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Cache size=4, 8 labels w/eviction): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkCounterCache16Entries(allocator: std.mem.Allocator) !void {
    // Use unique label type to ensure separate thread-local cache
    // Enable thread-local cache with 16 entries
    var counter = try promz.Counter(MethodLabelsCache16, .{ .thread_local_cache = true, .cache_size = 16 }).init(
        allocator,
        "test_counter_cache16",
        "Test counter with 16-entry cache",
    );
    defer counter.deinit();

    // 8 labels - fits in cache size (16), no evictions
    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE" };
    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 8] });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Cache size=16, 8 labels no eviction): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

fn benchmarkCounterCache16With16Labels(allocator: std.mem.Allocator) !void {
    // Use same label type as benchmarkCounterCache16Entries - same config/cache_size
    // Enable thread-local cache with 16 entries
    var counter = try promz.Counter(MethodLabelsCache16, .{ .thread_local_cache = true, .cache_size = 16 }).init(
        allocator,
        "test_counter_cache16_full",
        "Test counter with 16-entry cache full",
    );
    defer counter.deinit();

    // 16 labels - exactly fills cache size
    const methods = [_][]const u8{
        "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE",
        "CONNECT", "M1", "M2", "M3", "M4", "M5", "M6", "M7",
    };
    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 16] });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (Cache size=16, 16 labels fills cache): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

// ============================================================================
// NEW: Comparison - No Cache vs Cache
// ============================================================================

fn benchmarkCounterNoCacheRotating(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
    };

    // NO thread-local cache
    var counter = try promz.Counter(Labels, .{ .thread_local_cache = false }).init(
        allocator,
        "test_counter_nocache",
        "Test counter without cache",
    );
    defer counter.deinit();

    const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE" };
    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |i| {
        try counter.inc(.{ .method = methods[i % 4] });
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (No Cache, 4 rotating labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

// ============================================================================
// NEW: Mixed API Benchmark (Realistic scenario)
// ============================================================================

fn benchmarkMixedApi(allocator: std.mem.Allocator) !void {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    var counter = try promz.Counter(Labels, .{ .thread_local_cache = true }).init(
        allocator,
        "http_requests_total",
        "Total HTTP requests",
    );
    defer counter.deinit();

    // Pre-register common paths
    const get_200 = try counter.register(.{ .method = "GET", .status = "200" });
    const get_404 = try counter.register(.{ .method = "GET", .status = "404" });
    const post_201 = try counter.register(.{ .method = "POST", .status = "201" });

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    // Realistic mix: 80% common paths via handles, 20% less common via labels
    for (0..iterations) |i| {
        switch (i % 10) {
            0...5 => try counter.incByHandle(get_200), // 60% GET 200
            6 => try counter.incByHandle(get_404), // 10% GET 404
            7 => try counter.incByHandle(post_201), // 10% POST 201
            8 => try counter.inc(.{ .method = "PUT", .status = "200" }), // 10% PUT 200
            9 => try counter.inc(.{ .method = "DELETE", .status = "204" }), // 10% DELETE 204
            else => unreachable,
        }
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Mixed API (80%% handles, 20%% labels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}

// ============================================================================
// NEW: RuntimeLabels Benchmark
// ============================================================================

fn benchmarkCounterRuntimeLabels(allocator: std.mem.Allocator) !void {
    var counter = try promz.Counter(promz.RuntimeLabels, .{}).init(
        allocator,
        "runtime_counter",
        "Counter with runtime labels",
    );
    defer counter.deinit();

    const keys = [_][]const u8{"method"};
    const values = [_][]const u8{"GET"};
    const labels = try promz.RuntimeLabels.init(&keys, &values);

    const iterations: usize = 1_000_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        try counter.inc(labels);
    }

    const duration_ns = timer.read();
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (duration_ms / 1000.0);

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Counter (RuntimeLabels): {d:.2} ops in {d:.2}ms ({d:.0} ops/sec)\n", .{
        @as(f64, @floatFromInt(iterations)),
        duration_ms,
        ops_per_sec,
    });
    try stdout.writeAll(msg);
}
