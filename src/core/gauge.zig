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

/// Validate that V is a valid gauge type (any integer or float)
fn assertGaugeType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => return,
        .int => return,
        else => {},
    }
    @compileError("Gauge metric must be an integer or a float, got: " ++ @typeName(T));
}

/// Gauge - a metric that can go up or down
/// Unlike counters, gauges can be incremented, decremented, or set to arbitrary values
/// Generic over:
/// - V: the value type (i32, i64, u32, u64, f32, f64)
/// - TLabels: the label type for compile-time type safety
/// - config: configuration options
///
/// This is a union type that supports noop mode for zero-cost disabled metrics.
/// Use `.noop` for disabled metrics or call `init()` for active metrics.
pub fn Gauge(comptime V: type, comptime TLabels: type, comptime config: GaugeConfig) type {
    assertGaugeType(V);

    return union(enum) {
        const Self = @This();
        pub const Labels = TLabels;
        pub const ValueType = V;

        noop: void,
        impl: Impl,

        /// Initialize an active gauge with the given name and help text
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

        /// Increment gauge by 1
        pub fn inc(self: *Self, labels: TLabels) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.inc(labels),
            }
        }

        /// Decrement gauge by 1
        pub fn dec(self: *Self, labels: TLabels) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.dec(labels),
            }
        }

        /// Add a value to the gauge
        pub fn add(self: *Self, labels: TLabels, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.add(labels, value),
            }
        }

        /// Subtract a value from the gauge
        pub fn sub(self: *Self, labels: TLabels, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.sub(labels, value),
            }
        }

        /// Set the gauge to an absolute value
        pub fn set(self: *Self, labels: TLabels, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.set(labels, value),
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

        /// Decrement by 1 using a pre-registered handle
        pub fn decByHandle(self: *Self, handle: LabelHandle) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.decByHandle(handle),
            }
        }

        /// Add value using a pre-registered handle
        pub fn addByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.addByHandle(handle, value),
            }
        }

        /// Subtract value using a pre-registered handle
        pub fn subByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.subByHandle(handle, value),
            }
        }

        /// Set value using a pre-registered handle
        pub fn setByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            switch (self.*) {
                .noop => {},
                .impl => |*impl| try impl.setByHandle(handle, value),
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

        /// Get the current gauge value
        pub fn get(self: *const Self, labels: TLabels) !V {
            const is_integer = @typeInfo(V) == .int;
            const zero: V = if (is_integer) 0 else 0.0;
            switch (self.*) {
                .noop => return zero,
                .impl => |*impl| return impl.get(labels),
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
        pub const Impl = GaugeImpl(V, TLabels, config);
    };
}

/// Internal implementation of Gauge (extracted for union wrapper)
fn GaugeImpl(comptime V: type, comptime TLabels: type, comptime config: GaugeConfig) type {
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
                self.generation +%= 1;

                // Clear thread-local cache to avoid stale pointers
                if (config.thread_local_cache) {
                    tl_cache = .{null} ** CACHE_SIZE;
                }
            }
        }

        /// Increment gauge by 1
        pub fn inc(self: *Self, labels: TLabels) !void {
            return self.add(labels, one);
        }

        /// Decrement gauge by 1
        pub fn dec(self: *Self, labels: TLabels) !void {
            return self.sub(labels, one);
        }

        /// Add a value to the gauge (can be positive or negative)
        pub fn add(self: *Self, labels: TLabels, value: V) !void {
            if (use_single_sample) {
                self.sample.add(value);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.add(value);
            }
        }

        /// Subtract a value from the gauge
        pub fn sub(self: *Self, labels: TLabels, value: V) !void {
            if (use_single_sample) {
                self.sample.sub(value);
            } else {
                const sample = try self.getOrCreateSample(labels);
                sample.sub(value);
            }
        }

        /// Set the gauge to an absolute value
        pub fn set(self: *Self, labels: TLabels, value: V) !void {
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
            return self.addByHandle(handle, one);
        }

        /// Decrement by 1 using a pre-registered handle
        pub fn decByHandle(self: *Self, handle: LabelHandle) !void {
            return self.subByHandle(handle, one);
        }

        /// Add value using a pre-registered handle
        pub fn addByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.add(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].add(value);
            }
        }

        /// Subtract value using a pre-registered handle
        pub fn subByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.sub(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].sub(value);
            }
        }

        /// Set value using a pre-registered handle
        pub fn setByHandle(self: *Self, handle: LabelHandle, value: V) !void {
            if (use_single_sample) {
                try self.validateHandle(handle);
                self.sample.set(value);
            } else {
                try self.validateHandle(handle);
                self.samples_array.items[handle.index].set(value);
            }
        }

        /// Get value using a pre-registered handle
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

        /// Get the current gauge value
        pub fn get(self: *const Self, labels: TLabels) !V {
            if (use_single_sample) {
                return self.sample.get();
            } else {
                var key_buf: [256]u8 = undefined;
                const key = generateLabelKeyBuf(&key_buf, TLabels, labels) catch |err| switch (err) {
                    error.NoSpaceLeft => {
                        const allocated_key = try generateLabelKey(self.allocator, TLabels, labels);
                        defer self.allocator.free(allocated_key);
                        const sample_ptr = self.samples.get(allocated_key) orelse return MetricError.SampleNotFound;
                        return sample_ptr.get();
                    },
                };
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
            var key_buf: [256]u8 = undefined;
            const key = generateLabelKeyBuf(&key_buf, TLabels, labels) catch |err| switch (err) {
                error.NoSpaceLeft => return self.getOrCreateSampleAlloc(labels, hash),
            };

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

        /// Fallback path for labels that don't fit in stack buffer
        fn getOrCreateSampleAlloc(self: *Self, labels: TLabels, hash: u64) !*SampleType {
            const allocated_key = try generateLabelKey(self.allocator, TLabels, labels);

            // Check if sample already exists
            if (self.samples.get(allocated_key)) |sample_ptr| {
                self.allocator.free(allocated_key);
                if (config.thread_local_cache and use_comptime_hash) {
                    self.updateCache(hash, sample_ptr);
                }
                return sample_ptr;
            }

            // Cold path: allocate new sample on heap (pointer-stable)
            const sample_ptr = try self.allocator.create(SampleType);
            errdefer self.allocator.destroy(sample_ptr);
            sample_ptr.* = if (config.thread_safe) SampleType.init() else SampleType.init(zero);

            // Store pointer in HashMap with the already-allocated key
            try self.samples.put(allocated_key, sample_ptr);

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
            try writer.writeAll(" gauge\n");

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

test "Gauge(f64, NoLabels): init" {
    var gauge = try Gauge(f64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "A test gauge",
    );
    defer gauge.deinit();

    try std.testing.expectEqual(0.0, try gauge.get(.{}));
}

test "Gauge(f64, NoLabels): inc and dec" {
    var gauge = try Gauge(f64, NoLabels, .{}).init(
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

test "Gauge(f64, NoLabels): set" {
    var gauge = try Gauge(f64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.set(.{}, 42.0);
    try std.testing.expectEqual(42.0, try gauge.get(.{}));
}

test "Gauge(f64) with struct labels" {
    const Labels = struct {
        host: []const u8,
        region: []const u8,
    };

    var gauge = try Gauge(f64, Labels, .{}).init(
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

test "Gauge(f64) with RuntimeLabels" {
    var gauge = try Gauge(f64, RuntimeLabels, .{}).init(
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

// ============================================================================
// Tests with integer types
// ============================================================================

test "Gauge(i64, NoLabels): init and basic operations" {
    var gauge = try Gauge(i64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "A test gauge",
    );
    defer gauge.deinit();

    try std.testing.expectEqual(0, try gauge.get(.{}));

    try gauge.inc(.{});
    try std.testing.expectEqual(1, try gauge.get(.{}));

    try gauge.dec(.{});
    try std.testing.expectEqual(0, try gauge.get(.{}));

    try gauge.add(.{}, -10);
    try std.testing.expectEqual(-10, try gauge.get(.{}));
}

test "Gauge(u64, NoLabels): basic operations" {
    var gauge = try Gauge(u64, NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.set(.{}, 100);
    try std.testing.expectEqual(100, try gauge.get(.{}));

    try gauge.add(.{}, 50);
    try std.testing.expectEqual(150, try gauge.get(.{}));
}

test "Gauge(i32, NoLabels): signed operations" {
    var gauge = try Gauge(i32, NoLabels, .{}).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.set(.{}, -50);
    try std.testing.expectEqual(-50, try gauge.get(.{}));

    try gauge.add(.{}, 100);
    try std.testing.expectEqual(50, try gauge.get(.{}));
}

test "Gauge(i64) with struct labels" {
    const Labels = struct {
        host: []const u8,
    };

    var gauge = try Gauge(i64, Labels, .{}).init(
        std.testing.allocator,
        "connections",
        "Active connections",
    );
    defer gauge.deinit();

    try gauge.set(.{ .host = "server1" }, 10);
    try gauge.set(.{ .host = "server2" }, 20);

    try std.testing.expectEqual(10, try gauge.get(.{ .host = "server1" }));
    try std.testing.expectEqual(20, try gauge.get(.{ .host = "server2" }));

    try gauge.dec(.{ .host = "server1" });
    try std.testing.expectEqual(9, try gauge.get(.{ .host = "server1" }));
}

// ============================================================================
// Thread-safe tests
// ============================================================================

test "Gauge(i64, NoLabels, thread_safe): basic operations" {
    var gauge = try Gauge(i64, NoLabels, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.inc(.{});
    try gauge.add(.{}, 10);
    try std.testing.expectEqual(11, try gauge.get(.{}));

    try gauge.sub(.{}, 5);
    try std.testing.expectEqual(6, try gauge.get(.{}));
}

test "Gauge(f64, NoLabels, thread_safe): basic operations" {
    var gauge = try Gauge(f64, NoLabels, .{ .thread_safe = true }).init(
        std.testing.allocator,
        "test_gauge",
        "Test",
    );
    defer gauge.deinit();

    try gauge.set(.{}, 42.5);
    try std.testing.expectEqual(42.5, try gauge.get(.{}));

    try gauge.add(.{}, 2.5);
    try std.testing.expectEqual(45.0, try gauge.get(.{}));
}

// ============================================================================
// Noop tests
// ============================================================================

test "Gauge noop: operations are no-ops" {
    var gauge: Gauge(f64, NoLabels, .{}) = .noop;

    // All operations should succeed silently
    try gauge.inc(.{});
    try gauge.dec(.{});
    try gauge.add(.{}, 5.0);
    try gauge.sub(.{}, 2.0);
    try gauge.set(.{}, 100.0);
    gauge.deinit();

    // Get returns zero
    try std.testing.expectEqual(0.0, try gauge.get(.{}));
}

test "Gauge noop: handles work" {
    var gauge: Gauge(i64, NoLabels, .{}) = .noop;

    const handle = try gauge.register(.{});
    try gauge.incByHandle(handle);
    try gauge.decByHandle(handle);
    try gauge.addByHandle(handle, 10);
    try gauge.subByHandle(handle, 5);
    try gauge.setByHandle(handle, 100);

    try std.testing.expectEqual(0, try gauge.getByHandle(handle));
}

test "Gauge noop: getInfo returns null" {
    const gauge: Gauge(f64, NoLabels, .{}) = .noop;
    try std.testing.expect(gauge.getInfo() == null);
}
