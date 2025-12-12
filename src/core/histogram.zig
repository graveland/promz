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
const writeValue = @import("format.zig").writeValue;

/// Default histogram buckets recommended by Prometheus
/// Covers: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s
pub const DEFAULT_BUCKETS = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

/// Configuration for histogram buckets
/// Generic over V - the value type for bucket boundaries
pub fn BucketConfig(comptime V: type) type {
    return struct {
        const Self = @This();

        upper_bounds: []const V,
        owned: bool,

        /// Create buckets with custom upper bounds (caller-owned, not freed by deinit)
        /// Note: +Inf bucket is added automatically
        pub fn custom(bounds: []const V) Self {
            return .{ .upper_bounds = bounds, .owned = false };
        }

        /// Create linearly spaced buckets (allocator-owned, freed by deinit)
        /// start: first bucket boundary
        /// width: distance between buckets
        /// count: number of buckets to create
        pub fn linear(allocator: std.mem.Allocator, start: V, width: V, count: usize) !Self {
            const bounds = try allocator.alloc(V, count);
            const is_integer = @typeInfo(V) == .int;
            for (bounds, 0..) |*bound, i| {
                const idx: V = if (is_integer) @intCast(i) else @floatFromInt(i);
                bound.* = start + width * idx;
            }
            return .{ .upper_bounds = bounds, .owned = true };
        }

        /// Create exponentially spaced buckets (allocator-owned, freed by deinit)
        /// start: first bucket boundary
        /// factor: multiplication factor between buckets
        /// count: number of buckets to create
        pub fn exponential(allocator: std.mem.Allocator, start: V, factor: V, count: usize) !Self {
            const bounds = try allocator.alloc(V, count);
            var current = start;
            for (bounds) |*bound| {
                bound.* = current;
                current *= factor;
            }
            return .{ .upper_bounds = bounds, .owned = true };
        }

        /// Free allocated bucket memory (only needed for linear/exponential)
        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            if (self.owned) {
                allocator.free(@constCast(self.upper_bounds));
            }
        }
    };
}

/// Default bucket config (f64)
pub fn defaultBuckets() BucketConfig(f64) {
    return BucketConfig(f64).custom(&DEFAULT_BUCKETS);
}

/// Validate that V is a valid histogram type
fn assertHistogramType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => return,
        .int => return,
        else => {},
    }
    @compileError("Histogram metric must be an integer or a float, got: " ++ @typeName(T));
}

/// A single histogram observation tracking buckets, sum, and count
fn HistogramSampleType(comptime V: type, comptime thread_safe: bool) type {
    assertHistogramType(V);
    const is_integer = @typeInfo(V) == .int;
    const zero: V = if (is_integer) 0 else 0.0;

    return struct {
        bucket_counts: []u64, // Cumulative counts for each bucket (including +Inf)
        sum: V, // Sum of all observed values
        count: u64, // Total number of observations
        allocator: std.mem.Allocator,
        mutex: if (thread_safe) std.Thread.Mutex else void,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, bucket_count: usize) !Self {
            // +1 for the +Inf bucket
            const bucket_counts = try allocator.alloc(u64, bucket_count + 1);
            @memset(bucket_counts, 0);

            return Self{
                .bucket_counts = bucket_counts,
                .sum = zero,
                .count = 0,
                .allocator = allocator,
                .mutex = if (thread_safe) std.Thread.Mutex{} else {},
            };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.bucket_counts);
        }

        fn reset(self: *Self) void {
            if (thread_safe) {
                self.mutex.lock();
                defer self.mutex.unlock();
            }
            @memset(self.bucket_counts, 0);
            self.sum = zero;
            self.count = 0;
        }

        fn observe(self: *Self, value: V, upper_bounds: []const V) void {
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
/// Generic over:
/// - V: the value type (f32, f64, u32, u64, etc.)
/// - TLabels: the label type for compile-time type safety
/// - config: configuration options
///
/// This is a union type that supports noop mode for zero-cost disabled metrics.
/// Use `.noop` for disabled metrics or call `init()` for active metrics.
pub fn Histogram(comptime V: type, comptime TLabels: type, comptime config: HistogramConfig) type {
    assertHistogramType(V);

    return union(enum) {
        const Self = @This();
        pub const Labels = TLabels;
        pub const ValueType = V;

        noop: void,
        impl: Impl,

        /// Initialize an active histogram with the given name, help text, and bucket configuration
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            help: []const u8,
            buckets: BucketConfig(V),
        ) !Self {
            return .{ .impl = try Impl.init(allocator, name, help, buckets) };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| impl.deinit(),
            }
        }

        /// Observe a value and update the histogram
        pub fn observe(self: *Self, labels: TLabels, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.observe(labels, value),
            }
        }

        /// Pre-register a label combination for O(1) access
        pub fn register(self: *Self, labels: TLabels) !LabelHandle {
            switch (self.*) {
                .noop => return LabelHandle{ .index = 0, .generation = 0 },
                .impl => |*impl| return impl.register(labels),
            }
        }

        /// Observe using a pre-registered handle
        pub fn observeByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.observeByHandle(handle, value),
            }
        }

        /// Get bucket count for a specific bucket index
        pub fn getBucketCount(self: *const Self, labels: TLabels, bucket_index: usize) !u64 {
            switch (self.*) {
                .noop => return 0,
                .impl => |*impl| return impl.getBucketCount(labels, bucket_index),
            }
        }

        /// Get the sum of all observed values
        pub fn getSum(self: *const Self, labels: TLabels) !V {
            const is_integer = @typeInfo(V) == .int;
            const zero: V = if (is_integer) 0 else 0.0;
            switch (self.*) {
                .noop => return zero,
                .impl => |*impl| return impl.getSum(labels),
            }
        }

        /// Get the total count of observations
        pub fn getCount(self: *const Self, labels: TLabels) !u64 {
            switch (self.*) {
                .noop => return 0,
                .impl => |*impl| return impl.getCount(labels),
            }
        }

        /// Get bucket count using a pre-registered handle
        pub fn getBucketCountByHandle(self: *const Self, handle: LabelHandle, bucket_index: usize) !u64 {
            switch (self.*) {
                .noop => return 0,
                .impl => |*impl| return impl.getBucketCountByHandle(handle, bucket_index),
            }
        }

        /// Get sum using a pre-registered handle
        pub fn getSumByHandle(self: *const Self, handle: LabelHandle) !V {
            const is_integer = @typeInfo(V) == .int;
            const zero: V = if (is_integer) 0 else 0.0;
            switch (self.*) {
                .noop => return zero,
                .impl => |*impl| return impl.getSumByHandle(handle),
            }
        }

        /// Get count using a pre-registered handle
        pub fn getCountByHandle(self: *const Self, handle: LabelHandle) !u64 {
            switch (self.*) {
                .noop => return 0,
                .impl => |*impl| return impl.getCountByHandle(handle),
            }
        }

        /// Reset all histogram data (for testing)
        pub fn reset(self: *Self) void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| impl.reset(),
            }
        }

        /// Get metric info (returns null for noop)
        pub fn getInfo(self: *const Self) ?MetricInfo {
            switch (self.*) {
                .noop => return null,
                .impl => |*impl| return impl.info,
            }
        }

        /// Write the metric in Prometheus text exposition format to any writer
        /// This allows metrics to write themselves directly without a registry
        pub fn write(self: *const Self, writer: anytype) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.write(writer),
            }
        }

        /// The implementation type (for advanced usage)
        pub const Impl = HistogramImpl(V, TLabels, config);
    };
}

/// Internal implementation of Histogram (extracted for union wrapper)
fn HistogramImpl(comptime V: type, comptime TLabels: type, comptime config: HistogramConfig) type {
    const HistogramSample = HistogramSampleType(V, config.thread_safe);
    const use_single_sample = (TLabels == NoLabels);
    const use_comptime_hash = !use_single_sample and (TLabels != RuntimeLabels);

    return struct {
        const Self = @This();
        // Store pointers to heap-allocated samples for pointer stability
        // This ensures cached pointers remain valid even when HashMap resizes
        const SampleMap = std.StringHashMap(*HistogramSample);
        pub const Labels = TLabels;
        pub const ValueType = V;

        // Thread-local cache constants
        const CACHE_SIZE = config.cache_size;
        const CacheEntry = struct {
            hash: u64,
            sample: *HistogramSample,
            lru_counter: u8,
        };

        allocator: std.mem.Allocator,
        info: MetricInfo,
        buckets: BucketConfig(V),
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
            buckets: BucketConfig(V),
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
        pub fn observe(self: *Self, labels: TLabels, value: V) !void {
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
        pub fn observeByHandle(self: *Self, handle: LabelHandle, value: V) !void {
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
                    return MetricError.InvalidHandle;
                }
                return self.sample.bucket_counts[bucket_index];
            } else {
                var key_buf: [64]u8 = undefined;
                const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);
                const sample_ptr = self.samples.get(key) orelse return MetricError.SampleNotFound;
                if (bucket_index >= sample_ptr.bucket_counts.len) {
                    return MetricError.InvalidHandle;
                }
                return sample_ptr.bucket_counts[bucket_index];
            }
        }

        /// Get the sum of all observed values
        pub fn getSum(self: *const Self, labels: TLabels) !V {
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

        /// Get bucket count using a pre-registered handle
        pub fn getBucketCountByHandle(self: *const Self, handle: LabelHandle, bucket_index: usize) !u64 {
            try self.validateHandle(handle);
            if (use_single_sample) {
                if (bucket_index >= self.sample.bucket_counts.len) {
                    return MetricError.InvalidHandle;
                }
                return self.sample.bucket_counts[bucket_index];
            } else {
                const sample = self.samples_array.items[handle.index];
                if (bucket_index >= sample.bucket_counts.len) {
                    return MetricError.InvalidHandle;
                }
                return sample.bucket_counts[bucket_index];
            }
        }

        /// Get sum using a pre-registered handle
        pub fn getSumByHandle(self: *const Self, handle: LabelHandle) !V {
            try self.validateHandle(handle);
            if (use_single_sample) {
                return self.sample.sum;
            } else {
                return self.samples_array.items[handle.index].sum;
            }
        }

        /// Get count using a pre-registered handle
        pub fn getCountByHandle(self: *const Self, handle: LabelHandle) !u64 {
            try self.validateHandle(handle);
            if (use_single_sample) {
                return self.sample.count;
            } else {
                return self.samples_array.items[handle.index].count;
            }
        }

        /// Reset all histogram data (for testing)
        pub fn reset(self: *Self) void {
            if (use_single_sample) {
                self.sample.reset();
            } else {
                var it = self.samples.valueIterator();
                while (it.next()) |sample_ptr| {
                    sample_ptr.*.reset();
                }
            }
            self.generation +%= 1;
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

        /// Write the metric in Prometheus text exposition format to any writer
        pub fn write(self: *const Self, writer: anytype) !void {
            // Write HELP line
            try writer.writeAll("# HELP ");
            try writer.writeAll(self.info.name);
            try writer.writeAll(" ");
            try writer.writeAll(self.info.help);
            try writer.writeAll("\n");

            // Write TYPE line
            try writer.writeAll("# TYPE ");
            try writer.writeAll(self.info.name);
            try writer.writeAll(" histogram\n");

            // Write samples
            if (use_single_sample) {
                try writeHistogramSampleData(V, writer, self.info.name, "", &self.sample, self.buckets.upper_bounds);
            } else {
                var it = self.samples.iterator();
                while (it.next()) |entry| {
                    try writeHistogramSampleData(V, writer, self.info.name, entry.key_ptr.*, entry.value_ptr.*, self.buckets.upper_bounds);
                }
            }
        }
    };
}

/// Helper to write histogram sample data (buckets, sum, count)
fn writeHistogramSampleData(comptime V: type, writer: anytype, name: []const u8, label_str: []const u8, sample: anytype, upper_bounds: []const V) !void {
    var buf: [64]u8 = undefined;

    // Write bucket samples
    for (upper_bounds, 0..) |bound, i| {
        try writer.writeAll(name);
        try writer.writeAll("_bucket{");
        if (label_str.len > 0) {
            try writer.writeAll(label_str);
            try writer.writeAll(",");
        }
        try writer.writeAll("le=\"");
        try writeValue(V, writer, bound);
        try writer.writeAll("\"} ");
        const count_str = try std.fmt.bufPrint(&buf, "{d}", .{sample.bucket_counts[i]});
        try writer.writeAll(count_str);
        try writer.writeAll("\n");
    }

    // Write +Inf bucket
    try writer.writeAll(name);
    try writer.writeAll("_bucket{");
    if (label_str.len > 0) {
        try writer.writeAll(label_str);
        try writer.writeAll(",");
    }
    try writer.writeAll("le=\"+Inf\"} ");
    const inf_count_str = try std.fmt.bufPrint(&buf, "{d}", .{sample.bucket_counts[upper_bounds.len]});
    try writer.writeAll(inf_count_str);
    try writer.writeAll("\n");

    // Write sum
    try writer.writeAll(name);
    try writer.writeAll("_sum");
    if (label_str.len > 0) {
        try writer.writeAll("{");
        try writer.writeAll(label_str);
        try writer.writeAll("}");
    }
    try writer.writeAll(" ");
    try writeValue(V, writer, sample.sum);
    try writer.writeAll("\n");

    // Write count
    try writer.writeAll(name);
    try writer.writeAll("_count");
    if (label_str.len > 0) {
        try writer.writeAll("{");
        try writer.writeAll(label_str);
        try writer.writeAll("}");
    }
    try writer.writeAll(" ");
    const count_str2 = try std.fmt.bufPrint(&buf, "{d}", .{sample.count});
    try writer.writeAll(count_str2);
    try writer.writeAll("\n");
}

// ============================================================================
// Tests
// ============================================================================

test "BucketConfig(f64): default buckets" {
    const buckets = defaultBuckets();
    try std.testing.expectEqual(11, buckets.upper_bounds.len);
    try std.testing.expectEqual(0.005, buckets.upper_bounds[0]);
    try std.testing.expectEqual(10.0, buckets.upper_bounds[10]);
}

test "BucketConfig(f64): linear buckets" {
    const buckets = try BucketConfig(f64).linear(std.testing.allocator, 5.0, 5.0, 3);
    defer buckets.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, buckets.upper_bounds.len);
    try std.testing.expectEqual(5.0, buckets.upper_bounds[0]);
    try std.testing.expectEqual(10.0, buckets.upper_bounds[1]);
    try std.testing.expectEqual(15.0, buckets.upper_bounds[2]);
}

test "BucketConfig(f64): exponential buckets" {
    const buckets = try BucketConfig(f64).exponential(std.testing.allocator, 1.0, 2.0, 4);
    defer buckets.deinit(std.testing.allocator);

    try std.testing.expectEqual(4, buckets.upper_bounds.len);
    try std.testing.expectEqual(1.0, buckets.upper_bounds[0]);
    try std.testing.expectEqual(2.0, buckets.upper_bounds[1]);
    try std.testing.expectEqual(4.0, buckets.upper_bounds[2]);
    try std.testing.expectEqual(8.0, buckets.upper_bounds[3]);
}

test "Histogram(f64, NoLabels): basic observation" {
    const buckets = BucketConfig(f64).custom(&[_]f64{ 1.0, 5.0, 10.0 });
    var hist = try Histogram(f64, NoLabels, .{}).init(
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

test "Histogram(f64, NoLabels): default buckets" {
    var hist = try Histogram(f64, NoLabels, .{}).init(
        std.testing.allocator,
        "latency_seconds",
        "Request latency in seconds",
        defaultBuckets(),
    );
    defer hist.deinit();

    try hist.observe(.{}, 0.003); // < 5ms
    try hist.observe(.{}, 0.015); // Between 10-25ms
    try hist.observe(.{}, 0.5); // 500ms

    try std.testing.expectEqual(1, try hist.getBucketCount(.{}, 0)); // <= 0.005
    try std.testing.expectEqual(1, try hist.getBucketCount(.{}, 1)); // <= 0.01
    try std.testing.expectEqual(2, try hist.getBucketCount(.{}, 2)); // <= 0.025
    try std.testing.expectEqual(3, try hist.getCount(.{}));
}

test "Histogram(f64) with struct labels" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    const buckets = BucketConfig(f64).custom(&[_]f64{ 0.1, 0.5, 1.0 });
    var hist = try Histogram(f64, Labels, .{}).init(
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

test "Histogram(f64) with RuntimeLabels" {
    const buckets = BucketConfig(f64).custom(&[_]f64{ 10.0, 50.0, 100.0 });
    var hist = try Histogram(f64, RuntimeLabels, .{}).init(
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

// ============================================================================
// Integer histogram tests
// ============================================================================

test "Histogram(u64, NoLabels): basic observation" {
    const buckets = BucketConfig(u64).custom(&[_]u64{ 100, 500, 1000 });
    var hist = try Histogram(u64, NoLabels, .{}).init(
        std.testing.allocator,
        "response_bytes",
        "Response size in bytes",
        buckets,
    );
    defer hist.deinit();

    try hist.observe(.{}, 50);
    try hist.observe(.{}, 300);
    try hist.observe(.{}, 700);
    try hist.observe(.{}, 1500);

    // Check bucket counts (cumulative)
    try std.testing.expectEqual(1, try hist.getBucketCount(.{}, 0)); // <= 100
    try std.testing.expectEqual(2, try hist.getBucketCount(.{}, 1)); // <= 500
    try std.testing.expectEqual(3, try hist.getBucketCount(.{}, 2)); // <= 1000
    try std.testing.expectEqual(4, try hist.getBucketCount(.{}, 3)); // +Inf

    // Check sum and count
    try std.testing.expectEqual(2550, try hist.getSum(.{}));
    try std.testing.expectEqual(4, try hist.getCount(.{}));
}

test "BucketConfig(u64): linear buckets" {
    const buckets = try BucketConfig(u64).linear(std.testing.allocator, 100, 100, 3);
    defer buckets.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, buckets.upper_bounds.len);
    try std.testing.expectEqual(100, buckets.upper_bounds[0]);
    try std.testing.expectEqual(200, buckets.upper_bounds[1]);
    try std.testing.expectEqual(300, buckets.upper_bounds[2]);
}

// ============================================================================
// Thread-safe tests
// ============================================================================

test "Histogram(f64, NoLabels, thread_safe): basic observation" {
    const buckets = BucketConfig(f64).custom(&[_]f64{ 1.0, 5.0, 10.0 });
    var hist = try Histogram(f64, NoLabels, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "test_histogram",
        "Test histogram",
        buckets,
    );
    defer hist.deinit();

    try hist.observe(.{}, 0.5);
    try hist.observe(.{}, 3.0);
    try hist.observe(.{}, 7.0);

    try std.testing.expectEqual(10.5, try hist.getSum(.{}));
    try std.testing.expectEqual(3, try hist.getCount(.{}));
}

// ============================================================================
// Noop tests
// ============================================================================

test "Histogram noop: operations are no-ops" {
    var hist: Histogram(f64, NoLabels, .{}) = .noop;

    // All operations should succeed silently
    try hist.observe(.{}, 0.5);
    try hist.observe(.{}, 3.0);
    hist.deinit();

    // Getters return zero
    try std.testing.expectEqual(0.0, try hist.getSum(.{}));
    try std.testing.expectEqual(0, try hist.getCount(.{}));
    try std.testing.expectEqual(0, try hist.getBucketCount(.{}, 0));
}

test "Histogram noop: handles work" {
    var hist: Histogram(u64, NoLabels, .{}) = .noop;

    const handle = try hist.register(.{});
    try hist.observeByHandle(handle, 100);
    try hist.observeByHandle(handle, 200);

    try std.testing.expectEqual(0, try hist.getSum(.{}));
    try std.testing.expectEqual(0, try hist.getCount(.{}));
}

test "Histogram noop: getInfo returns null" {
    const hist: Histogram(f64, NoLabels, .{}) = .noop;
    try std.testing.expect(hist.getInfo() == null);
}
