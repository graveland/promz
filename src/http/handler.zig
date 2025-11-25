const std = @import("std");
const Registry = @import("../registry/registry.zig").Registry;

/// HTTP handler for Prometheus metrics endpoint.
///
/// This provides a lower-level API for integrating metrics into your own HTTP server.
/// For a complete, ready-to-use metrics server, see `MetricsServer`.
///
/// Example usage with std.http.Server:
/// ```zig
/// var handler = MetricsHandler.init(allocator, &registry);
///
/// // In your HTTP request handler:
/// if (std.mem.eql(u8, request.head.target, "/metrics")) {
///     try handler.handle(&request);
/// }
/// ```
pub const MetricsHandler = struct {
    registry: *Registry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, registry: *Registry) MetricsHandler {
        return .{
            .registry = registry,
            .allocator = allocator,
        };
    }

    /// Handle a metrics request.
    ///
    /// Gathers all metrics from the registry and writes them as a Prometheus
    /// text exposition format response.
    pub fn handle(self: *MetricsHandler, request: *std.http.Server.Request) !void {
        const metrics = try self.registry.gatherToString();
        defer self.allocator.free(metrics);

        try request.respond(metrics, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; version=0.0.4; charset=utf-8" },
            },
        });
    }

    /// Write metrics directly to a writer (for custom integration).
    ///
    /// This allows you to write metrics to any writer, not just HTTP responses.
    pub fn writeMetrics(self: *MetricsHandler, writer: anytype) !void {
        try self.registry.gather(writer);
    }
};
