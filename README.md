# Promz - Prometheus Client Library for Zig

A pure Zig implementation of a Prometheus client library with idiomatic API, zero-cost abstractions, and optional thread safety.

## Features

- **Core Metric Types**: Counter, Gauge, and Histogram
- **Type-Safe Labels**: Compile-time struct labels or runtime dynamic labels
- **Zero-Cost Abstractions**: No overhead for unlabeled metrics
- **Thread Safety**: Optional atomic and mutex-based thread-safe metrics
- **HTTP Handler**: Built-in /metrics endpoint server
- **Prometheus Text Format**: Standard exposition format output
- **Pure Zig**: No C dependencies, idiomatic Zig API

## Quick Start

```zig
const std = @import("std");
const promz = @import("promz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a registry
    var registry = promz.Registry.init(allocator);
    defer registry.deinit();

    // Create a metrics collection struct to keep metrics in stable memory
    const MyMetrics = struct {
        collector: promz.MetricCollector,
        requests: promz.Counter(promz.NoLabels, .{}),

        fn init(alloc: std.mem.Allocator) !@This() {
            return .{
                .collector = try promz.MetricCollector.init(alloc, "default"),
                .requests = try promz.Counter(promz.NoLabels, .{}).init(
                    alloc,
                    "requests_total",
                    "Total requests",
                ),
            };
        }

        // IMPORTANT: Register metrics AFTER the struct is in its final location
        fn register(self: *@This()) !void {
            try self.collector.registerMetric(&self.requests);
        }

        fn deinit(self: *@This()) void {
            self.requests.deinit();
            self.collector.deinit();
        }
    };

    // Initialize metrics
    var metrics = try MyMetrics.init(allocator);
    defer metrics.deinit();

    // Register AFTER metrics struct is in final location (critical for pointer stability)
    try metrics.register();
    try registry.registerCollector(metrics.collector.collector());

    // Use metrics
    try metrics.requests.inc(.{});
    try metrics.requests.add(.{}, 5.0);

    // Output metrics to string
    const output = try registry.gatherToString();
    defer allocator.free(output);
    std.debug.print("{s}", .{output});
}
```

## Important: Metric Registration Pattern

⚠️ **Critical**: Metrics must be registered AFTER they are in their final memory location.

Zig structs are value types and get copied when returned from functions. If you register metrics with pointers before the struct is in its final location, those pointers will become invalid (dangling pointers).

**Correct Pattern** (as shown in Quick Start):
```zig
// 1. Create struct with metrics
var metrics = try MyMetrics.init(allocator);

// 2. Register AFTER struct is in final location
try metrics.register();  // Now pointers are stable
```

**Incorrect Pattern** (will cause crashes):
```zig
fn init(allocator: std.mem.Allocator) !MyMetrics {
    var result = MyMetrics{ ... };
    try result.collector.registerMetric(&result.requests); // ❌ BAD! Pointer becomes invalid when struct is copied
    return result; // Struct gets copied, invalidating the registered pointer
}
```

## Metric Types

### Counter

Monotonically increasing metric (can only go up):

```zig
// Without labels
var counter = try promz.Counter(promz.NoLabels, .{}).init(
    allocator,
    "requests_total",
    "Total HTTP requests",
);
try counter.inc(.{});
try counter.add(.{}, 5.0);

// With struct labels (compile-time type-safe)
const HttpLabels = struct {
    method: []const u8,
    status: []const u8,
};
var http_requests = try promz.Counter(HttpLabels, .{}).init(
    allocator,
    "http_requests_total",
    "HTTP requests by method and status",
);
try http_requests.inc(.{ .method = "GET", .status = "200" });
```

### Gauge

Metric that can increase or decrease:

```zig
var memory = try promz.Gauge(promz.NoLabels, .{}).init(
    allocator,
    "memory_bytes",
    "Memory usage in bytes",
);
try memory.set(.{}, 1024.0);
try memory.inc(.{});
try memory.dec(.{});
try memory.add(.{}, 512.0);
try memory.sub(.{}, 256.0);
```

### Histogram

Observations bucketed by configurable boundaries:

```zig
var latency = try promz.Histogram(promz.NoLabels, .{}).init(
    allocator,
    "request_duration_seconds",
    "Request latency in seconds",
    promz.BucketConfig.default(), // or .linear(), .exponential(), .custom()
);
try latency.observe(.{}, 0.123);
try latency.observe(.{}, 0.456);
```

## Thread Safety

Enable thread-safe metrics with the `thread_safe` config option:

```zig
// Thread-safe counter (uses atomic operations)
var counter = try promz.Counter(promz.NoLabels, .{ .thread_safe = true }).init(
    allocator,
    "concurrent_requests",
    "Requests from multiple threads",
);

// Thread-safe histogram (uses mutex)
var hist = try promz.Histogram(promz.NoLabels, .{ .thread_safe = true }).init(
    allocator,
    "processing_time",
    "Processing time",
    promz.BucketConfig.default(),
);
```

## Performance Optimization

### Pre-registered Handles

For hot paths, pre-register label combinations for O(1) lookup:

```zig
const Labels = struct { method: []const u8, status: []const u8 };
var counter = try promz.Counter(Labels, .{}).init(allocator, "requests", "Total requests");

// Pre-register common label combinations
const get_200 = try counter.register(.{ .method = "GET", .status = "200" });
const post_201 = try counter.register(.{ .method = "POST", .status = "201" });

// Use handles for fast updates (O(1) array index vs HashMap lookup)
try counter.incByHandle(get_200);
try counter.addByHandle(post_201, 5.0);
```

### Thread-Local Cache

Enable thread-local LRU cache for faster repeated label lookups:

```zig
// Enable caching with default 32-entry cache
var counter = try promz.Counter(Labels, .{ .thread_local_cache = true }).init(...);

// Or customize cache size for your workload
var counter = try promz.Counter(Labels, .{
    .thread_local_cache = true,
    .cache_size = 64,  // For applications with many label combinations
}).init(...);
```

Cache sizing recommendations:
- Default (32): Handles most applications with up to 32 unique label combinations per thread
- Memory usage: ~24 bytes per cache entry per thread
- Oversizing has no performance penalty - scanning a larger cache is effectively free

## HTTP Server

Built-in HTTP server for exposing metrics:

```zig
// Create registry and register metrics (see Quick Start)
var registry = promz.Registry.init(allocator);
defer registry.deinit();

// Create and start the metrics server
var server = promz.MetricsServer.init(allocator, &registry);
defer server.deinit();

// Blocking: serves until stopped
try server.serve(.{ .port = 9090 });
// Access metrics at http://127.0.0.1:9090/metrics
```

For background serving:

```zig
// Start server in background thread
try server.serveInBackground(.{ .port = 9090 });

// ... do other work ...

// Stop the server when done
server.stop();
```

## Label Types

### NoLabels
Zero-overhead metrics without labels:
```zig
var counter = try promz.Counter(promz.NoLabels, .{}).init(...);
try counter.inc(.{});
```

### Struct Labels
Compile-time type-safe labels:
```zig
const Labels = struct {
    method: []const u8,
    code: []const u8,
};
var counter = try promz.Counter(Labels, .{}).init(...);
try counter.inc(.{ .method = "GET", .code = "200" });
```

### Runtime Labels
Dynamic labels (for when label names are not known at compile time):
```zig
var labels = promz.RuntimeLabels.init(allocator);
try labels.add("method", "GET");
try labels.add("code", "200");
```

## Building

```bash
# Build the library
zig build

# Run tests
zig build test

# Run examples
zig build run-complete
zig build run-http-server
zig build run-threadsafe
```

## Examples

See the `examples/` directory for complete examples:
- `complete.zig` - All metric types with different label configurations
- `http_server.zig` - HTTP server exposing /metrics endpoint
- `threadsafe.zig` - Multi-threaded metrics with thread safety
- `benchmark.zig` - Performance benchmarks for all optimization strategies

## Architecture

- **Zero-Cost Abstractions**: NoLabels metrics use a single sample, labeled metrics use HashMap
- **Compile-Time Optimization**: Label types and thread safety determined at compile time
- **Type Erasure**: Collectors use vtables for heterogeneous metric storage
- **Prometheus Compatible**: Generates standard Prometheus text exposition format

## License

MIT License - see LICENSE file for details.
