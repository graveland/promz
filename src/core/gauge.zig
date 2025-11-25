const std = @import("std");
const MetricInfo = @import("metric.zig").MetricInfo;
const MetricError = @import("metric.zig").MetricError;
const MetricType = @import("metric.zig").MetricType;
const LabelHandle = @import("metric.zig").LabelHandle;
const Sample = @import("sample.zig").Sample;
const AtomicSample = @import("atomic_sample.zig").AtomicSample;
const LockedSample = @import("locked_sample.zig").LockedSample;
const NoLabels = @import("labels.zig").NoLabels;
const RuntimeLabels = @import("labels.zig").RuntimeLabels;
const generateLabelKey = @import("labels.zig").generateLabelKey;
const generateLabelKeyBuf = @import("labels.zig").generateLabelKeyBuf;
const hashStructLabels = @import("labels.zig").hashStructLabels;

/// Configuration for Gauge behavior
pub const GaugeConfig = struct {
    /// Enable thread safety with atomic operations
    thread_safe: bool = false,
    /// Initial capacity for label combinations
    initial_capacity: usize = 16,
    /// Enable thread-local LRU cache for faster repeated lookups
    thread_local_cache: bool = false,
    /// Number of entries in thread-local cache (default 32)
    cache_size: usize = 32,
};

/// Gauge - a metric that can go up or down
/// Unlike counters, gauges can be incremented, decremented, or set to arbitrary values
/// Generic over label type TLabels for compile-time type safety
pub fn Gauge(comptime TLabels: type, comptime config: GaugeConfig) type {
    // Choose sample type based on thread safety config
    const SampleType = if (config.thread_safe) AtomicSample else Sample;

    // Optimization: NoLabels uses a single sample instead of HashMap
    const use_single_sample = (TLabels == NoLabels);

    // Check if we can use comptime hash for faster lookups (struct labels only)
    const use_comptime_hash = !use_single_sample and (TLabels != RuntimeLabels);

    return struct {
        const Self = @This();
        // Store pointers to heap-allocated samples for pointer stability
        // This ensures cached pointers remain valid even when HashMap resizes
        const SampleMap = std.StringHashMap(*SampleType);
        pub const Labels = TLabels;

        // Thread-local cache constants (comptime configurable via config.cache_size)
        const CACHE_SIZE = config.cache_size;
        const CacheEntry = struct {
            hash: u64,
            sample: *SampleType,
            lru_counter: u8,
        };

        allocator: std.mem.Allocator,
        info: MetricInfo,
        // For NoLabels: use single sample (zero overhead)
        // For labels: use HashMap of pointers to heap-allocated samples
        sample: if (use_single_sample) SampleType else void,
        samples: if (use_single_sample) void else SampleMap,
        // For pre-registered labels: ArrayList for O(1) indexed access
        samples_array: if (use_single_sample) void else std.ArrayListUnmanaged(*SampleType),
        // Generation counter for handle validation
        generation: u32,

        // Thread-local cache - fixed-size array, never reallocates
        // (only used when thread_local_cache is enabled)
        threadlocal var tl_cache: [CACHE_SIZE]?CacheEntry = .{null} ** CACHE_SIZE;
        threadlocal var tl_lru_tick: u8 = 0;

        /// Initialize a gauge with the given name and help text
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            help: []const u8,
        ) !Self {
            const info = MetricInfo{
                .name = name,
                .help = help,
                .metric_type = .gauge,
            };
            try info.validate();

            if (use_single_sample) {
                return Self{
                    .allocator = allocator,
                    .info = info,
                    .sample = if (config.thread_safe) SampleType.init() else SampleType.init(0.0),
                    .samples = {},
                    .samples_array = {},
                    .generation = 0,
                };
            } else {
                return Self{
                    .allocator = allocator,
                    .info = info,
                    .sample = {},
                    .samples = SampleMap.init(allocator),
                    .samples_array = .empty,
                    .generation = 0,
                };
            }
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            if (!use_single_sample) {
                // Free all string keys and heap-allocated samples
                var it = self.samples.iterator();
                while (it.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
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

        /// Increment gauge by 1
        pub fn inc(self: *Self, labels: TLabels) !void {
            return self.add(labels, 1.0);
        }

        /// Decrement gauge by 1
        pub fn dec(self: *Self, labels: TLabels) !void {
            return self.sub(labels, 1.0);
        }

        /// Add a value to the gauge (can be positive or negative)
        pub fn add(self: *Self, labels: TLabels, value: f64) !void {
            if (use_single_sample) {
                self.sample.add(value);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.add(value);
            }
        }

        /// Subtract a value from the gauge
        pub fn sub(self: *Self, labels: TLabels, value: f64) !void {
            if (use_single_sample) {
                self.sample.sub(value);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.sub(value);
            }
        }

        /// Set the gauge to an absolute value
        pub fn set(self: *Self, labels: TLabels, value: f64) !void {
            if (use_single_sample) {
                self.sample.set(value);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.set(value);
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

        /// Increment by 1 using a pre-registered handle
        pub fn incByHandle(self: *Self, handle: LabelHandle) !void {
            return self.addByHandle(handle, 1.0);
        }

        /// Decrement by 1 using a pre-registered handle
        pub fn decByHandle(self: *Self, handle: LabelHandle) !void {
            return self.subByHandle(handle, 1.0);
        }

        /// Add value using a pre-registered handle
        pub fn addByHandle(self: *Self, handle: LabelHandle, value: f64) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.add(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].add(value);
            }
        }

        /// Subtract value using a pre-registered handle
        pub fn subByHandle(self: *Self, handle: LabelHandle, value: f64) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.sub(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].sub(value);
            }
        }

        /// Set value using a pre-registered handle
        pub fn setByHandle(self: *Self, handle: LabelHandle, value: f64) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.set(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].set(value);
            }
        }

        /// Get value using a pre-registered handle
        pub fn getByHandle(self: *const Self, handle: LabelHandle) !f64 {
            if (use_single_sample) {
                try self.validateHandle(handle);
                return self.sample.get();
            } else {
                try self.validateHandle(handle);
                return self.samples_array.items[handle.index].get();
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

        /// Get the current gauge value
        pub fn get(self: *const Self, labels: TLabels) !f64 {
            if (use_single_sample) {
                return self.sample.get();
            } else {
                var key_buf: [64]u8 = undefined;
                const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);
                const sample_ptr = self.samples.get(key) orelse return MetricError.SampleNotFound;
                return sample_ptr.get();
            }
        }

        /// Get or create a sample for the given labels (internal)
        fn getOrCreateSample(self: *Self, labels: TLabels) !*SampleType {
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
            const sample_ptr = try self.allocator.create(SampleType);
            errdefer self.allocator.destroy(sample_ptr);
            sample_ptr.* = if (config.thread_safe) SampleType.init() else SampleType.init(0.0);

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

        fn updateCache(self: *Self, hash: u64, sample: *SampleType) void {
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

test "Gauge(NoLabels): init" {
    var gauge = try Gauge(NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "A test gauge",
    );
    defer gauge.deinit();

    try std.testing.expectEqual(0.0, try gauge.get(.{}));
}

test "Gauge(NoLabels): inc and dec" {
    var gauge = try Gauge(NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.inc(.{});
    try std.testing.expectEqual(1.0, try gauge.get(.{}));

    try gauge.dec(.{});
    try std.testing.expectEqual(0.0, try gauge.get(.{}));
}

test "Gauge(NoLabels): set" {
    var gauge = try Gauge(NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.set(.{}, 42.0);
    try std.testing.expectEqual(42.0, try gauge.get(.{}));
}

test "Gauge with struct labels" {
    const Labels = struct {
        host: []const u8,
        region: []const u8,
    };

    var gauge = try Gauge(Labels, .{}).init(
        std.testing.allocator,
        "memory_usage_bytes",
        "Memory usage in bytes",
    );
    defer gauge.deinit();

    try gauge.set(.{ .host = "server1", .region = "us-east" }, 1024.0);
    try gauge.set(.{ .host = "server2", .region = "us-west" }, 2048.0);

    try std.testing.expectEqual(1024.0, try gauge.get(.{ .host = "server1", .region = "us-east" }));
    try std.testing.expectEqual(2048.0, try gauge.get(.{ .host = "server2", .region = "us-west" }));

    try gauge.add(.{ .host = "server1", .region = "us-east" }, 512.0);
    try std.testing.expectEqual(1536.0, try gauge.get(.{ .host = "server1", .region = "us-east" }));
}

test "Gauge with RuntimeLabels" {
    // RuntimeLabels already imported at top of file

    var gauge = try Gauge(RuntimeLabels, .{}).init(
        std.testing.allocator,
        "temperature_celsius",
        "Temperature in Celsius",
    );
    defer gauge.deinit();

    const keys = [_][]const u8{"location"};
    const values1 = [_][]const u8{"indoor"};
    const values2 = [_][]const u8{"outdoor"};

    const labels1 = try RuntimeLabels.init(&keys, &values1);
    const labels2 = try RuntimeLabels.init(&keys, &values2);

    try gauge.set(labels1, 22.5);
    try gauge.set(labels2, 15.0);

    try std.testing.expectEqual(22.5, try gauge.get(labels1));
    try std.testing.expectEqual(15.0, try gauge.get(labels2));
}
