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
const writeValue = @import("format.zig").writeValue;

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

/// Validate that V is a valid counter type (unsigned integer or float)
fn assertCounterType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => return,
        .int => |int| {
            if (int.signedness == .unsigned) return;
        },
        else => {},
    }
    @compileError("Counter requires an unsigned integer (u32, u64) or float (f32, f64). " ++
        "Signed integers are not allowed because counters can only increase. Got: " ++ @typeName(T));
}

/// Counter - a monotonically increasing metric
/// Counters can only increase (or be reset to zero)
/// Generic over:
/// - V: the value type (u32, u64, f32, f64)
/// - TLabels: the label type for compile-time type safety
/// - config: configuration options
///
/// This is a union type that supports noop mode for zero-cost disabled metrics.
/// Use `.noop` for disabled metrics or call `init()` for active metrics.
pub fn Counter(comptime V: type, comptime TLabels: type, comptime config: CounterConfig) type {
    assertCounterType(V);

    return union(enum) {
        const Self = @This();
        pub const Labels = TLabels;
        pub const ValueType = V;

        noop: void,
        impl: Impl,

        /// Initialize an active counter with the given name and help text
        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            help: []const u8,
        ) !Self {
            return .{ .impl = try Impl.init(allocator, name, help) };
        }

        /// Clean up resources
        pub fn deinit(self: *Self) void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| impl.deinit(),
            }
        }

        /// Increment counter by 1
        pub fn inc(self: *Self, labels: TLabels) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.inc(labels),
            }
        }

        /// Add a positive value to the counter
        pub fn add(self: *Self, labels: TLabels, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.add(labels, value),
            }
        }

        /// Pre-register a label combination for O(1) access
        pub fn register(self: *Self, labels: TLabels) !LabelHandle {
            switch (self.*) {
                .noop => return LabelHandle{ .index = 0, .generation = 0 },
                .impl => |*impl| return impl.register(labels),
            }
        }

        /// Increment by 1 using a pre-registered handle
        pub fn incByHandle(self: *Self, handle: LabelHandle) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.incByHandle(handle),
            }
        }

        /// Add value using a pre-registered handle
        pub fn addByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.addByHandle(handle, value),
            }
        }

        /// Get value using a pre-registered handle
        pub fn getByHandle(self: *const Self, handle: LabelHandle) !V {
            const is_integer = @typeInfo(V) == .int;
            const zero: V = if (is_integer) 0 else 0.0;
            switch (self.*) {
                .noop => return zero,
                .impl => |*impl| return impl.getByHandle(handle),
            }
        }

        /// Get the current counter value
        pub fn get(self: *const Self, labels: TLabels) !V {
            const is_integer = @typeInfo(V) == .int;
            const zero: V = if (is_integer) 0 else 0.0;
            switch (self.*) {
                .noop => return zero,
                .impl => |*impl| return impl.get(labels),
            }
        }

        /// Reset counter to zero
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
        pub const Impl = CounterImpl(V, TLabels, config);
    };
}

/// Internal implementation of Counter (extracted for union wrapper)
fn CounterImpl(comptime V: type, comptime TLabels: type, comptime config: CounterConfig) type {
    // Choose sample type based on thread safety config
    const SampleType = if (config.thread_safe) AtomicSample(V) else Sample(V);

    // Optimization: NoLabels uses a single sample instead of HashMap
    const use_single_sample = (TLabels == NoLabels);

    // Check if we can use comptime hash for faster lookups (struct labels only)
    const use_comptime_hash = !use_single_sample and (TLabels != RuntimeLabels);

    const is_integer = @typeInfo(V) == .int;
    const zero: V = if (is_integer) 0 else 0.0;
    const one: V = if (is_integer) 1 else 1.0;

    return struct {
        const Self = @This();
        // Store pointers to heap-allocated samples for pointer stability
        // This ensures cached pointers remain valid even when HashMap resizes
        const SampleMap = std.StringHashMap(*SampleType);
        pub const Labels = TLabels;
        pub const ValueType = V;

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
                    .sample = if (config.thread_safe) SampleType.init() else SampleType.init(zero),
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
            return self.add(labels, one);
        }

        /// Add a positive value to the counter
        /// Returns error if value is negative (for floats)
        pub fn add(self: *Self, labels: TLabels, value: V) !void {
            // For floats, check for negative values
            if (!is_integer) {
                if (value < zero) {
                    return MetricError.NegativeCounterValue;
                }
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
            return self.addByHandle(handle, one);
        }

        /// Add value using a pre-registered handle (O(1) with validation)
        pub fn addByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            // For floats, check for negative values
            if (!is_integer) {
                if (value < zero) return MetricError.NegativeCounterValue;
            }

            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.add(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].add(value);
            }
        }

        /// Get value using a pre-registered handle (O(1) with validation)
        pub fn getByHandle(self: *const Self, handle: LabelHandle) !V {
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
        pub fn get(self: *const Self, labels: TLabels) !V {
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
                self.sample.set(zero);
            } else {
                var it = self.samples.valueIterator();
                while (it.next()) |sample_ptr| {
                    sample_ptr.*.set(zero);
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
            sample_ptr.* = if (config.thread_safe) SampleType.init() else SampleType.init(zero);

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
            try writer.writeAll(" counter\n");

            // Write samples
            if (use_single_sample) {
                try writer.writeAll(self.info.name);
                try writer.writeAll(" ");
                try writeValue(V, writer, self.sample.get());
                try writer.writeAll("\n");
            } else {
                var it = self.samples.iterator();
                while (it.next()) |entry| {
                    try writer.writeAll(self.info.name);
                    if (entry.key_ptr.len > 0) {
                        try writer.writeAll("{");
                        try writer.writeAll(entry.key_ptr.*);
                        try writer.writeAll("}");
                    }
                    try writer.writeAll(" ");
                    try writeValue(V, writer, entry.value_ptr.*.get());
                    try writer.writeAll("\n");
                }
            }
        }
    };
}

// ============================================================================
// Tests with f64 (original behavior)
// ============================================================================

test "Counter(f64, NoLabels): init and basic operations" {
    var counter = try Counter(f64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "A test counter",
    );
    defer counter.deinit();

    try std.testing.expectEqual(0.0, try counter.get(.{}));
    try std.testing.expectEqualStrings("test_counter", counter.getInfo().?.name);
}

test "Counter(f64, NoLabels): inc" {
    var counter = try Counter(f64, NoLabels, .{}).init(
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

test "Counter(f64, NoLabels): add" {
    var counter = try Counter(f64, NoLabels, .{}).init(
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

test "Counter(f64, NoLabels): negative value rejected" {
    var counter = try Counter(f64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    const result = counter.add(.{}, -1.0);
    try std.testing.expectError(MetricError.NegativeCounterValue, result);
}

test "Counter(f64) with struct labels" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    var counter = try Counter(f64, Labels, .{}).init(
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

test "Counter(f64) with RuntimeLabels" {
    var counter = try Counter(f64, RuntimeLabels, .{}).init(
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

test "Counter(f64) with pre-registered labels (handles)" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    var counter = try Counter(f64, Labels, .{}).init(
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

test "Counter(f64) handle validation: stale handle after reset" {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try Counter(f64, Labels, .{}).init(
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

test "Counter(f64, NoLabels) with pre-registered handle" {
    var counter = try Counter(f64, NoLabels, .{}).init(
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

test "Counter(f64) with thread-local cache config" {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try Counter(f64, Labels, .{ .thread_local_cache = true }).init(
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

// ============================================================================
// Tests with u64 (new integer support)
// ============================================================================

test "Counter(u64, NoLabels): init and basic operations" {
    var counter = try Counter(u64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "A test counter",
    );
    defer counter.deinit();

    try std.testing.expectEqual(0, try counter.get(.{}));
}

test "Counter(u64, NoLabels): inc and add" {
    var counter = try Counter(u64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    try counter.inc(.{});
    try std.testing.expectEqual(1, try counter.get(.{}));

    try counter.add(.{}, 10);
    try std.testing.expectEqual(11, try counter.get(.{}));
}

test "Counter(u64) with struct labels" {
    const Labels = struct {
        method: []const u8,
    };

    var counter = try Counter(u64, Labels, .{}).init(
        std.testing.allocator,
        "requests",
        "Request counter",
    );
    defer counter.deinit();

    try counter.inc(.{ .method = "GET" });
    try counter.inc(.{ .method = "POST" });
    try counter.inc(.{ .method = "GET" });

    try std.testing.expectEqual(2, try counter.get(.{ .method = "GET" }));
    try std.testing.expectEqual(1, try counter.get(.{ .method = "POST" }));
}

test "Counter(u64) with handles" {
    var counter = try Counter(u64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    const handle = try counter.register(.{});
    try counter.incByHandle(handle);
    try counter.addByHandle(handle, 99);

    try std.testing.expectEqual(100, try counter.getByHandle(handle));
}

// ============================================================================
// Tests with u32 (smaller integer)
// ============================================================================

test "Counter(u32, NoLabels): basic operations" {
    var counter = try Counter(u32, NoLabels, .{}).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    try counter.inc(.{});
    try counter.add(.{}, 100);
    try std.testing.expectEqual(101, try counter.get(.{}));
}

// ============================================================================
// Thread-safe counter tests
// ============================================================================

test "Counter(u64, NoLabels, thread_safe): basic operations" {
    var counter = try Counter(u64, NoLabels, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    try counter.inc(.{});
    try counter.add(.{}, 10);
    try std.testing.expectEqual(11, try counter.get(.{}));
}

test "Counter(f64, NoLabels, thread_safe): basic operations" {
    var counter = try Counter(f64, NoLabels, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "test_counter",
        "Test",
    );
    defer counter.deinit();

    try counter.inc(.{});
    try counter.add(.{}, 2.5);
    try std.testing.expectEqual(3.5, try counter.get(.{}));
}

// ============================================================================
// Noop tests
// ============================================================================

test "Counter noop: operations are no-ops" {
    var counter: Counter(f64, NoLabels, .{}) = .noop;

    // All operations should succeed silently
    try counter.inc(.{});
    try counter.add(.{}, 5.0);
    counter.reset();
    counter.deinit();

    // Get returns zero
    try std.testing.expectEqual(0.0, try counter.get(.{}));
}

test "Counter noop: handles work" {
    var counter: Counter(u64, NoLabels, .{}) = .noop;

    const handle = try counter.register(.{});
    try counter.incByHandle(handle);
    try counter.addByHandle(handle, 10);

    try std.testing.expectEqual(0, try counter.getByHandle(handle));
}

test "Counter noop: getInfo returns null" {
    const counter: Counter(f64, NoLabels, .{}) = .noop;
    try std.testing.expect(counter.getInfo() == null);
}
