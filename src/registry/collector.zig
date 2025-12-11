const std = @import("std");

/// Collector interface - type-erased wrapper for metrics
/// Allows heterogeneous collections of different metric types
pub const Collector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Collect metrics and write them in Prometheus text format
        collect: *const fn (ptr: *anyopaque, writer_ptr: *anyopaque, writeFn: *const fn (*anyopaque, []const u8) anyerror!void) anyerror!void,
        /// Clean up collector resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Call collect on this collector
    pub fn collect(self: Collector, writer: anytype) !void {
        const WriterType = @TypeOf(writer);
        const info = @typeInfo(WriterType);

        // Handle both pointer and value writers
        if (info == .pointer) {
            // Writer is already a pointer - pass it directly
            const writeFn = struct {
                fn write(ptr: *anyopaque, bytes: []const u8) !void {
                    const w: WriterType = @ptrCast(@alignCast(ptr));
                    try w.writeAll(bytes);
                }
            }.write;
            return self.vtable.collect(self.ptr, @ptrCast(@constCast(writer)), writeFn);
        } else {
            // Writer is a value - take address of local copy
            const writeFn = struct {
                fn write(ptr: *anyopaque, bytes: []const u8) !void {
                    const w: *WriterType = @ptrCast(@alignCast(ptr));
                    try w.writeAll(bytes);
                }
            }.write;
            var writer_mut = writer;
            return self.vtable.collect(self.ptr, &writer_mut, writeFn);
        }
    }

    /// Clean up collector
    pub fn deinit(self: Collector) void {
        self.vtable.deinit(self.ptr);
    }
};

/// A type-erased writer that wraps any writer type
pub const Writer = struct {
    ptr: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn writeAll(self: Writer, bytes: []const u8) !void {
        try self.writeFn(self.ptr, bytes);
    }
};

/// A simple collector that stores individual metrics
/// This is the most common use case - just register metrics and expose them
pub const MetricCollector = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    metrics: std.ArrayList(*anyopaque),
    collect_fns: std.ArrayList(*const fn (*anyopaque, Writer) anyerror!void),
    /// Track allocated namespaced names that need to be freed
    allocated_names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !MetricCollector {
        return MetricCollector{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .metrics = .empty,
            .collect_fns = .empty,
            .allocated_names = .empty,
        };
    }

    pub fn deinit(self: *MetricCollector) void {
        // Free all allocated namespaced names
        for (self.allocated_names.items) |name| {
            self.allocator.free(name);
        }
        self.allocated_names.deinit(self.allocator);

        self.allocator.free(self.name);
        self.metrics.deinit(self.allocator);
        self.collect_fns.deinit(self.allocator);
    }

    /// Register a metric with this collector
    pub fn registerMetric(self: *MetricCollector, metric: anytype) !void {
        const MetricType = @TypeOf(metric.*);

        // If we have a namespace, prepend it to the metric name
        if (self.name.len > 0) {
            const original_name = metric.info.name;
            const namespaced_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}_{s}",
                .{ self.name, original_name },
            );
            // Track the allocated name so we can free it later
            try self.allocated_names.append(self.allocator, namespaced_name);
            // Replace the metric's name with the namespaced version
            metric.info.name = namespaced_name;
        }

        // Store pointer to metric
        try self.metrics.append(self.allocator, @ptrCast(metric));

        // Store type-specific collect function - pass pointer to avoid shallow copy issues
        const collectFn = struct {
            fn collect(ptr: *anyopaque, writer: Writer) !void {
                const m: *MetricType = @ptrCast(@alignCast(ptr));
                try @import("../format/text.zig").writeMetricPtr(writer, m);
            }
        }.collect;

        try self.collect_fns.append(self.allocator, collectFn);
    }

    /// Convert to type-erased Collector
    pub fn collector(self: *MetricCollector) Collector {
        return Collector{
            .ptr = self,
            .vtable = &.{
                .collect = collectImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn collectImpl(ptr: *anyopaque, writer_ptr: *anyopaque, writeFn: *const fn (*anyopaque, []const u8) anyerror!void) !void {
        const self: *MetricCollector = @ptrCast(@alignCast(ptr));
        const metrics = self.metrics.items;
        const fns = self.collect_fns.items;

        if (metrics.len != fns.len) {
            std.log.err("MetricCollector '{s}' has mismatched lengths: metrics={d}, fns={d}", .{
                self.name,
                metrics.len,
                fns.len,
            });
            return error.MismatchedLengths;
        }

        const writer = Writer{ .ptr = writer_ptr, .writeFn = writeFn };

        for (metrics, fns) |metric, collect_fn| {
            try collect_fn(metric, writer);
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *MetricCollector = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

test "MetricCollector: init and deinit" {
    var collector = try MetricCollector.init(std.testing.allocator, "test");
    defer collector.deinit();

    try std.testing.expectEqualStrings("test", collector.name);
}
