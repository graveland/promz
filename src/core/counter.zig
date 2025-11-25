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

/// Configuration for Counter behavior
pub const CounterConfig = struct {
    /// Enable thread safety with atomic operations
    thread_safe: bool = false,
    /// Initial capacity for label combinations
    initial_capacity: usize = 16,
    /// Enable thread-local LRU cache for faster repeated lookups
    thread_local_cache: bool = false,
    /// Number of entries in thread-local cache (default 32)
    cache_size: usize = 32,
};

/// Counter - a monotonically increasing metric
/// Counters can only increase (or be reset to zero)
/// Generic over label type TLabels for compile-time type safety
pub fn Counter(comptime TLabels: type, comptime config: CounterConfig) type {
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

        /// Initialize a counter with the given name and help text
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            help: []const u8,
        ) !Self {
            const info = MetricInfo{
                .name = name,
                .help = help,
                .metric_type = .counter,
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

                // Invalidate any cached pointers for this metric
                self.generation +%= 1;

                // Clear thread-local cache to avoid stale pointers
                if (config.thread_local_cache) {
                    tl_cache = .{null} ** CACHE_SIZE;
                }
            }
        }

        /// Increment counter by 1
        pub fn inc(self: *Self, labels: TLabels) !void {
            return self.add(labels, 1.0);
        }

        /// Add a positive value to the counter
        /// Returns error if value is negative
        pub fn add(self: *Self, labels: TLabels, value: f64) !void {
            if (value < 0) {
                return MetricError.NegativeCounterValue;
            }

            if (use_single_sample) {
                self.sample.add(value);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.add(value);
            }
        }

        /// Pre-register a label combination for O(1) access
        /// Returns a handle that can be used with incByHandle/addByHandle
        pub fn register(self: *Self, labels: TLabels) !LabelHandle {
            if (use_single_sample) {
                // NoLabels always returns index 0
                return LabelHandle{
                    .index = 0,
                    .generation = self.generation,
                };
            }

            const sample = try self.getOrCreateSample(labels);
            try self.samples_array.append(self.allocator, sample);
            return LabelHandle{
                .index = @intCast(self.samples_array.items.len - 1),
                .generation = self.generation,
            };
        }

        /// Increment by 1 using a pre-registered handle (O(1) with validation)
        pub fn incByHandle(self: *Self, handle: LabelHandle) !void {
            return self.addByHandle(handle, 1.0);
        }

        /// Add value using a pre-registered handle (O(1) with validation)
        pub fn addByHandle(self: *Self, handle: LabelHandle, value: f64) !void {
            if (value < 0) return MetricError.NegativeCounterValue;

            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.add(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].add(value);
            }
        }

        /// Get value using a pre-registered handle (O(1) with validation)
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

        /// Get the current counter value
        /// This is primarily for testing and debugging
        pub fn get(self: *const Self, labels: TLabels) !f64 {
            if (use_single_sample) {
                return self.sample.get();
            } else {
                // Use string buffer for lookup
                var key_buf: [64]u8 = undefined;
                const key = try generateLabelKeyBuf(&key_buf, TLabels, labels);
                const sample_ptr = self.samples.get(key) orelse return MetricError.SampleNotFound;
                return sample_ptr.get();
            }
        }

        /// Reset counter to zero (for testing)
        pub fn reset(self: *Self) void {
            if (use_single_sample) {
                self.sample.set(0.0);
            } else {
                var it = self.samples.valueIterator();
                while (it.next()) |sample_ptr| {
                    sample_ptr.*.set(0.0);
                }
            }
            // Increment generation to invalidate handles
            self.generation +%= 1;
            // Clear registered handles array
            if (!use_single_sample) {
                self.samples_array.clearRetainingCapacity();
            }
            // Clear thread-local cache
            if (config.thread_local_cache) {
                tl_cache = .{null} ** CACHE_SIZE;
            }
        }

        /// Get or create a sample for the given labels (internal)
        fn getOrCreateSample(self: *Self, labels: TLabels) !*SampleType {
            // For struct labels, compute hash for thread-local cache lookup
            const hash = if (use_comptime_hash) hashStructLabels(TLabels, labels) else 0;

            // Check thread-local cache first (if enabled and using comptime hash)
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
            // Find slot: prefer empty, otherwise evict oldest
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

test "Counter(NoLabels): init and basic operations" {
    var counter = try Counter(NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "A test counter",
    );
    defer counter.deinit();

    try std.testing.expectEqual(0.0, try counter.get(.{}));
    try std.testing.expectEqualStrings("test_counter", counter.info.name);
}

test "Counter(NoLabels): inc" {
    var counter = try Counter(NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    try counter.inc(.{});
    try std.testing.expectEqual(1.0, try counter.get(.{}));

    try counter.inc(.{});
    try std.testing.expectEqual(2.0, try counter.get(.{}));
}

test "Counter(NoLabels): add" {
    var counter = try Counter(NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    try counter.add(.{}, 5.0);
    try std.testing.expectEqual(5.0, try counter.get(.{}));

    try counter.add(.{}, 2.5);
    try std.testing.expectEqual(7.5, try counter.get(.{}));
}

test "Counter(NoLabels): negative value rejected" {
    var counter = try Counter(NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    const result = counter.add(.{}, -1.0);
    try std.testing.expectError(MetricError.NegativeCounterValue, result);
}

test "Counter with struct labels" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    var counter = try Counter(Labels, .{}).init(
        std.testing.allocator,
        "http_requests_total",
        "Total HTTP requests",
    );
    defer counter.deinit();

    try counter.inc(.{ .method = "GET", .status = "200" });
    try counter.inc(.{ .method = "POST", .status = "201" });
    try counter.inc(.{ .method = "GET", .status = "200" });

    try std.testing.expectEqual(2.0, try counter.get(.{ .method = "GET", .status = "200" }));
    try std.testing.expectEqual(1.0, try counter.get(.{ .method = "POST", .status = "201" }));
}

test "Counter with RuntimeLabels" {
    // RuntimeLabels already imported at top of file

    var counter = try Counter(RuntimeLabels, .{}).init(
        std.testing.allocator,
        "dynamic_counter",
        "Counter with dynamic labels",
    );
    defer counter.deinit();

    const keys1 = [_][]const u8{"method"};
    const values1 = [_][]const u8{"GET"};
    const labels1 = try RuntimeLabels.init(&keys1, &values1);

    const keys2 = [_][]const u8{"method"};
    const values2 = [_][]const u8{"POST"};
    const labels2 = try RuntimeLabels.init(&keys2, &values2);

    try counter.inc(labels1);
    try counter.inc(labels1);
    try counter.inc(labels2);

    try std.testing.expectEqual(2.0, try counter.get(labels1));
    try std.testing.expectEqual(1.0, try counter.get(labels2));
}

test "Counter with pre-registered labels (handles)" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    var counter = try Counter(Labels, .{}).init(
        std.testing.allocator,
        "http_requests_total",
        "Total HTTP requests",
    );
    defer counter.deinit();

    // Pre-register label combinations
    const get_200 = try counter.register(.{ .method = "GET", .status = "200" });
    const post_201 = try counter.register(.{ .method = "POST", .status = "201" });

    // Use handles for O(1) access
    try counter.incByHandle(get_200);
    try counter.incByHandle(get_200);
    try counter.addByHandle(post_201, 5.0);

    // Verify via get() and getByHandle()
    try std.testing.expectEqual(2.0, try counter.get(.{ .method = "GET", .status = "200" }));
    try std.testing.expectEqual(2.0, try counter.getByHandle(get_200));
    try std.testing.expectEqual(5.0, try counter.getByHandle(post_201));
}

test "Counter handle validation: stale handle after reset" {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try Counter(Labels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    const handle = try counter.register(.{ .method = "GET" });
    try counter.incByHandle(handle);
    try std.testing.expectEqual(1.0, try counter.getByHandle(handle));

    // Reset invalidates the handle
    counter.reset();

    // Handle should now be stale
    const result = counter.incByHandle(handle);
    try std.testing.expectError(MetricError.StaleHandle, result);
}

test "Counter(NoLabels) with pre-registered handle" {
    var counter = try Counter(NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    const handle = try counter.register(.{});
    try counter.incByHandle(handle);
    try counter.addByHandle(handle, 4.0);

    try std.testing.expectEqual(5.0, try counter.getByHandle(handle));
    try std.testing.expectEqual(5.0, try counter.get(.{}));
}

test "Counter with thread-local cache config" {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try Counter(Labels, .{ .thread_local_cache = true }).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    // Use same labels multiple times - should hit cache
    try counter.inc(.{ .method = "GET" });
    try counter.inc(.{ .method = "GET" });
    try counter.inc(.{ .method = "GET" });

    try std.testing.expectEqual(3.0, try counter.get(.{ .method = "GET" }));
}
