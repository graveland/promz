const std = @import("std");
const MetricInfo = @import("metric.zig").MetricInfo;
const MetricError = @import("metric.zig").MetricError;
const MetricType = @import("metric.zig").MetricType;
const LabelHandle = @import("metric.zig").LabelHandle;
const NoLabels = @import("labels.zig").NoLabels;
const RuntimeLabels = @import("labels.zig").RuntimeLabels;
const generateLabelKey = @import("labels.zig").generateLabelKey;
const generateLabelKeyBuf = @import("labels.zig").generateLabelKeyBuf;
const hashStructLabels = @import("labels.zig").hashStructLabels;

/// Default histogram buckets recommended by Prometheus
/// Covers: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s
pub const DEFAULT_BUCKETS = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

/// Configuration for histogram buckets
pub const BucketConfig = struct {
    upper_bounds: []const f64,

    /// Create buckets with custom upper bounds
    /// Note: +Inf bucket is added automatically
    pub fn custom(bounds: []const f64) BucketConfig {
        return .{ .upper_bounds = bounds };
    }

    /// Create linearly spaced buckets
    /// start: first bucket boundary
    /// width: distance between buckets
    /// count: number of buckets to create
    pub fn linear(allocator: std.mem.Allocator, start: f64, width: f64, count: usize) !BucketConfig {
        const bounds = try allocator.alloc(f64, count);
        for (bounds, 0..) |*bound, i| {
            bound.* = start + width * @as(f64, @floatFromInt(i));
        }
        return .{ .upper_bounds = bounds };
    }

    /// Create exponentially spaced buckets
    /// start: first bucket boundary
    /// factor: multiplication factor between buckets
    /// count: number of buckets to create
    pub fn exponential(allocator: std.mem.Allocator, start: f64, factor: f64, count: usize) !BucketConfig {
        const bounds = try allocator.alloc(f64, count);
        var current = start;
        for (bounds) |*bound| {
            bound.* = current;
            current *= factor;
        }
        return .{ .upper_bounds = bounds };
    }

    /// Use default Prometheus buckets
    pub fn default() BucketConfig {
        return .{ .upper_bounds = &DEFAULT_BUCKETS };
    }

    /// Free allocated bucket memory (only for linear/exponential)
    pub fn deinit(self: BucketConfig, allocator: std.mem.Allocator) void {
        // Only free if this was allocated (not default or custom static)
        // User must track this themselves for now
        _ = self;
        _ = allocator;
    }
};

/// A single histogram observation tracking buckets, sum, and count
fn HistogramSampleType(comptime thread_safe: bool) type {
    return struct {
        bucket_counts: []u64,  // Cumulative counts for each bucket (including +Inf)
        sum: f64,              // Sum of all observed values
        count: u64,            // Total number of observations
        allocator: std.mem.Allocator,
        mutex: if (thread_safe) std.Thread.Mutex else void,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, bucket_count: usize) !Self {
            // +1 for the +Inf bucket
            const bucket_counts = try allocator.alloc(u64, bucket_count + 1);
            @memset(bucket_counts, 0);

            return Self{
                .bucket_counts = bucket_counts,
                .sum = 0.0,
                .count = 0,
                .allocator = allocator,
                .mutex = if (thread_safe) std.Thread.Mutex{} else {},
            };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.bucket_counts);
        }

        fn observe(self: *Self, value: f64, upper_bounds: []const f64) void {
            if (thread_safe) {
                self.mutex.lock();
                defer self.mutex.unlock();
            }

            self.sum += value;
            self.count += 1;

            // Increment all buckets where value <= upper_bound
            for (upper_bounds, 0..) |upper_bound, i| {
                if (value <= upper_bound) {
                    self.bucket_counts[i] += 1;
                }
            }
            // +Inf bucket always gets incremented
            self.bucket_counts[upper_bounds.len] += 1;
        }
    };
}

/// Configuration for Histogram behavior
pub const HistogramConfig = struct {
    /// Enable thread safety with mutex
    thread_safe: bool = false,
    /// Initial capacity for label combinations
    initial_capacity: usize = 16,
    /// Enable thread-local LRU cache for faster repeated lookups
    thread_local_cache: bool = false,
    /// Number of entries in thread-local cache (default 32)
    cache_size: usize = 32,
};

/// Histogram - records observations in configurable buckets
/// Useful for measuring distributions (latency, request sizes, etc.)
pub fn Histogram(comptime TLabels: type, comptime config: HistogramConfig) type {
    const HistogramSample = HistogramSampleType(config.thread_safe);
    const use_single_sample = (TLabels == NoLabels);
    const use_comptime_hash = !use_single_sample and (TLabels != RuntimeLabels);

    return struct {
        const Self = @This();
        // Store pointers to heap-allocated samples for pointer stability
        // This ensures cached pointers remain valid even when HashMap resizes
        const SampleMap = std.StringHashMap(*HistogramSample);
        pub const Labels = TLabels;

        // Thread-local cache constants
        const CACHE_SIZE = config.cache_size;
        const CacheEntry = struct {
            hash: u64,
            sample: *HistogramSample,
            lru_counter: u8,
        };

        allocator: std.mem.Allocator,
        info: MetricInfo,
        buckets: BucketConfig,
        sample: if (use_single_sample) HistogramSample else void,
        samples: if (use_single_sample) void else SampleMap,
        samples_array: if (use_single_sample) void else std.ArrayListUnmanaged(*HistogramSample),
        generation: u32,

        threadlocal var tl_cache: [CACHE_SIZE]?CacheEntry = .{null} ** CACHE_SIZE;
        threadlocal var tl_lru_tick: u8 = 0;

        /// Initialize a histogram with the given name, help text, and bucket configuration
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            help: []const u8,
            buckets: BucketConfig,
        ) !Self {
            const info = MetricInfo{
                .name = name,
                .help = help,
                .metric_type = .histogram,
            };
            try info.validate();

            if (use_single_sample) {
                return Self{
                    .allocator = allocator,
                    .info = info,
                    .buckets = buckets,
                    .sample = try HistogramSample.init(allocator, buckets.upper_bounds.len),
                    .samples = {},
                    .samples_array = {},
                    .generation = 0,
                };
            } else {
                return Self{
                    .allocator = allocator,
                    .info = info,
                    .buckets = buckets,
                    .sample = {},
                    .samples = SampleMap.init(allocator),
                    .samples_array = .empty,
                    .generation = 0,
                };
            }
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            if (use_single_sample) {
                self.sample.deinit();
            } else {
                // Free all string keys and heap-allocated samples
                var it = self.samples.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    entry.value_ptr.*.deinit();
                    self.allocator.destroy(entry.value_ptr.*);
                }
                self.samples.deinit();
                self.samples_array.deinit(self.allocator);
                self.generation +%= 1;

                // Clear thread-local cache to avoid stale pointers
                if (config.thread_local_cache) {
                    tl_cache = .{null} ** CACHE_SIZE;
                }
            }
        }

        /// Observe a value and update the histogram
        pub fn observe(self: *Self, labels: TLabels, value: f64) !void {
            if (use_single_sample) {
                self.sample.observe(value, self.buckets.upper_bounds);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.observe(value, self.buckets.upper_bounds);
            }
        }

        /// Pre-register a label combination for O(1) access
        pub fn register(self: *Self, labels: TLabels) !LabelHandle {
            if (use_single_sample) {
                return LabelHandle{ .index = 0, .generation = self.generation };
            }
            const sample = try self.getOrCreateSample(labels);
            try self.samples_array.append(self.allocator, sample);
            return LabelHandle{
                .index = @intCast(self.samples_array.items.len - 1),
                .generation = self.generation,
            };
        }

        /// Observe using a pre-registered handle
        pub fn observeByHandle(self: *Self, handle: LabelHandle, value: f64) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.observe(value, self.buckets.upper_bounds);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].observe(value, self.buckets.upper_bounds);
            }
        }

        fn validateHandle(self: *const Self, handle: LabelHandle) !void {
            if (handle.generation != self.generation) {
                return MetricError.StaleHandle;
            }
            if (!use_single_sample and handle.index >= self.samples_array.items.len) {
                return MetricError.InvalidHandle;
            }
        }

        /// Get bucket count for a specific bucket index
        pub fn getBucketCount(self: *const Self, labels: TLabels, bucket_index: usize) !u64 {
            if (use_single_sample) {
                if (bucket_index >= self.sample.bucket_counts.len) {
                    return MetricError.SampleNotFound;
                }
                return self.sample.bucket_counts[bucket_index];
            } else {
                var key_buf: [64]u8 = undefined;
                const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);
                const sample_ptr = self.samples.get(key) orelse return MetricError.SampleNotFound;
                if (bucket_index >= sample_ptr.bucket_counts.len) {
                    return MetricError.SampleNotFound;
                }
                return sample_ptr.bucket_counts[bucket_index];
            }
        }

        /// Get the sum of all observed values
        pub fn getSum(self: *const Self, labels: TLabels) !f64 {
            if (use_single_sample) {
                return self.sample.sum;
            } else {
                var key_buf: [64]u8 = undefined;
                const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);
                const sample_ptr = self.samples.get(key) orelse return MetricError.SampleNotFound;
                return sample_ptr.sum;
            }
        }

        /// Get the total count of observations
        pub fn getCount(self: *const Self, labels: TLabels) !u64 {
            if (use_single_sample) {
                return self.sample.count;
            } else {
                var key_buf: [64]u8 = undefined;
                const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);
                const sample_ptr = self.samples.get(key) orelse return MetricError.SampleNotFound;
                return sample_ptr.count;
            }
        }

        /// Get or create a sample for the given labels (internal)
        fn getOrCreateSample(self: *Self, labels: TLabels) !*HistogramSample {
            const hash = if (use_comptime_hash) hashStructLabels(TLabels, labels) else 0;

            // Check thread-local cache first
            if (config.thread_local_cache and use_comptime_hash) {
                for (&tl_cache) |*entry| {
                    if (entry.*) |*e| {
                        if (e.hash == hash) {
                            e.lru_counter = tl_lru_tick;
                            tl_lru_tick +%= 1;
                            return e.sample;
                        }
                    }
                }
            }

            // Fast path: use stack buffer for lookup (zero allocations)
            var key_buf: [64]u8 = undefined;
            const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);

            // Check if sample already exists (hot path)
            if (self.samples.get(key)) |sample_ptr| {
                if (config.thread_local_cache and use_comptime_hash) {
                    self.updateCache(hash, sample_ptr);
                }
                return sample_ptr;
            }

            // Cold path: allocate new sample on heap (pointer-stable)
            const sample_ptr = try self.allocator.create(HistogramSample);
            errdefer self.allocator.destroy(sample_ptr);
            sample_ptr.* = try HistogramSample.init(self.allocator, self.buckets.upper_bounds.len);

            // Allocate key for storage in HashMap
            const owned_key = try generateLabelKey(self.allocator, TLabels, labels);
            errdefer self.allocator.free(owned_key);

            // Store pointer in HashMap - no cache invalidation needed since
            // sample_ptr is heap-allocated and never moves
            try self.samples.put(owned_key, sample_ptr);

            if (config.thread_local_cache and use_comptime_hash) {
                self.updateCache(hash, sample_ptr);
            }

            return sample_ptr;
        }

        fn updateCache(self: *Self, hash: u64, sample: *HistogramSample) void {
            _ = self;
            var oldest_idx: usize = 0;
            var oldest_tick: u8 = 255;

            for (tl_cache, 0..) |entry, i| {
                if (entry == null) {
                    oldest_idx = i;
                    break;
                }
                if (entry.?.lru_counter < oldest_tick) {
                    oldest_tick = entry.?.lru_counter;
                    oldest_idx = i;
                }
            }

            tl_cache[oldest_idx] = .{
                .hash = hash,
                .sample = sample,
                .lru_counter = tl_lru_tick,
            };
            tl_lru_tick +%= 1;
        }
    };
}

test "BucketConfig: default buckets" {
    const buckets = BucketConfig.default();
    try std.testing.expectEqual(11, buckets.upper_bounds.len);
    try std.testing.expectEqual(0.005, buckets.upper_bounds[0]);
    try std.testing.expectEqual(10.0, buckets.upper_bounds[10]);
}

test "BucketConfig: linear buckets" {
    const buckets = try BucketConfig.linear(std.testing.allocator, 5.0, 5.0, 3);
    defer std.testing.allocator.free(buckets.upper_bounds);

    try std.testing.expectEqual(3, buckets.upper_bounds.len);
    try std.testing.expectEqual(5.0, buckets.upper_bounds[0]);
    try std.testing.expectEqual(10.0, buckets.upper_bounds[1]);
    try std.testing.expectEqual(15.0, buckets.upper_bounds[2]);
}

test "BucketConfig: exponential buckets" {
    const buckets = try BucketConfig.exponential(std.testing.allocator, 1.0, 2.0, 4);
    defer std.testing.allocator.free(buckets.upper_bounds);

    try std.testing.expectEqual(4, buckets.upper_bounds.len);
    try std.testing.expectEqual(1.0, buckets.upper_bounds[0]);
    try std.testing.expectEqual(2.0, buckets.upper_bounds[1]);
    try std.testing.expectEqual(4.0, buckets.upper_bounds[2]);
    try std.testing.expectEqual(8.0, buckets.upper_bounds[3]);
}

test "Histogram(NoLabels): basic observation" {
    const buckets = BucketConfig.custom(&[_]f64{ 1.0, 5.0, 10.0 });
    var hist = try Histogram(NoLabels, .{}).init(
        std.testing.allocator,
        "test_histogram",
        "Test histogram",
        buckets,
    );
    defer hist.deinit();

    try hist.observe(.{}, 0.5);
    try hist.observe(.{}, 3.0);
    try hist.observe(.{}, 7.0);
    try hist.observe(.{}, 12.0);

    // Check bucket counts (cumulative)
    try std.testing.expectEqual(1, try hist.getBucketCount(.{}, 0)); // <= 1.0
    try std.testing.expectEqual(2, try hist.getBucketCount(.{}, 1)); // <= 5.0
    try std.testing.expectEqual(3, try hist.getBucketCount(.{}, 2)); // <= 10.0
    try std.testing.expectEqual(4, try hist.getBucketCount(.{}, 3)); // +Inf

    // Check sum and count
    try std.testing.expectEqual(22.5, try hist.getSum(.{}));
    try std.testing.expectEqual(4, try hist.getCount(.{}));
}

test "Histogram(NoLabels): default buckets" {
    var hist = try Histogram(NoLabels, .{}).init(
        std.testing.allocator,
        "latency_seconds",
        "Request latency in seconds",
        BucketConfig.default(),
    );
    defer hist.deinit();

    try hist.observe(.{}, 0.003); // < 5ms
    try hist.observe(.{}, 0.015); // Between 10-25ms
    try hist.observe(.{}, 0.5);   // 500ms

    try std.testing.expectEqual(1, try hist.getBucketCount(.{}, 0)); // <= 0.005
    try std.testing.expectEqual(1, try hist.getBucketCount(.{}, 1)); // <= 0.01
    try std.testing.expectEqual(2, try hist.getBucketCount(.{}, 2)); // <= 0.025
    try std.testing.expectEqual(3, try hist.getCount(.{}));
}

test "Histogram with struct labels" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    const buckets = BucketConfig.custom(&[_]f64{ 0.1, 0.5, 1.0 });
    var hist = try Histogram(Labels, .{}).init(
        std.testing.allocator,
        "http_request_duration_seconds",
        "HTTP request duration",
        buckets,
    );
    defer hist.deinit();

    try hist.observe(.{ .method = "GET", .status = "200" }, 0.05);
    try hist.observe(.{ .method = "GET", .status = "200" }, 0.3);
    try hist.observe(.{ .method = "POST", .status = "201" }, 0.8);

    try std.testing.expectEqual(1, try hist.getBucketCount(.{ .method = "GET", .status = "200" }, 0));
    try std.testing.expectEqual(2, try hist.getBucketCount(.{ .method = "GET", .status = "200" }, 1));
    try std.testing.expectEqual(2, try hist.getCount(.{ .method = "GET", .status = "200" }));

    try std.testing.expectEqual(1, try hist.getCount(.{ .method = "POST", .status = "201" }));
}

test "Histogram with RuntimeLabels" {
    // RuntimeLabels already imported at top of file

    const buckets = BucketConfig.custom(&[_]f64{ 10.0, 50.0, 100.0 });
    var hist = try Histogram(RuntimeLabels, .{}).init(
        std.testing.allocator,
        "response_size_bytes",
        "Response size in bytes",
        buckets,
    );
    defer hist.deinit();

    const keys = [_][]const u8{"endpoint"};
    const api_values = [_][]const u8{"/api"};
    const web_values = [_][]const u8{"/web"};

    const api_labels = try RuntimeLabels.init(&keys, &api_values);
    const web_labels = try RuntimeLabels.init(&keys, &web_values);

    try hist.observe(api_labels, 5.0);
    try hist.observe(api_labels, 25.0);
    try hist.observe(web_labels, 75.0);

    try std.testing.expectEqual(2, try hist.getCount(api_labels));
    try std.testing.expectEqual(1, try hist.getCount(web_labels));
    try std.testing.expectEqual(30.0, try hist.getSum(api_labels));
}
