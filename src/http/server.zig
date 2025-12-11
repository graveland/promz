const std = @import("std");
const Registry = @import("../registry/registry.zig").Registry;

/// MetricsServer provides a simple HTTP server for exposing Prometheus metrics.
///
/// Example usage:
/// ```zig
/// var server = MetricsServer.init(allocator, &registry);
/// defer server.deinit();
/// try server.serve(.{ .port = 9090 });
/// ```
///
/// For background serving:
/// ```zig
/// try server.serveInBackground(.{ .port = 9090 });
/// // ... do other work ...
/// server.stop();
/// ```
pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    registry: *Registry,
    io: std.Io,
    owns_io: bool,
    server: ?std.Io.net.Server,
    running: std.atomic.Value(bool),
    server_thread: ?std.Thread,
    logger: ?Logger,

    /// Type-erased logger interface for error reporting
    pub const Logger = struct {
        ptr: *anyopaque,
        errFn: *const fn (ptr: *anyopaque, msg: []const u8, err_name: ?[]const u8) void,

        pub fn err(self: Logger, msg: []const u8, err_name: ?[]const u8) void {
            self.errFn(self.ptr, msg, err_name);
        }
    };

    pub const Config = struct {
        /// The address to bind to (default: "127.0.0.1")
        address: []const u8 = "127.0.0.1",
        /// The port to listen on (default: 9090)
        port: u16 = 9090,
    };

    /// Initialize a new MetricsServer with its own Io.Threaded instance.
    ///
    /// The registry must remain valid for the lifetime of the server.
    pub fn init(allocator: std.mem.Allocator, registry: *Registry) MetricsServer {
        var threaded = std.Io.Threaded.init(allocator);
        return .{
            .allocator = allocator,
            .registry = registry,
            .io = threaded.io(),
            .owns_io = true,
            .server = null,
            .running = std.atomic.Value(bool).init(false),
            .server_thread = null,
            .logger = null,
        };
    }

    /// Initialize a new MetricsServer using an existing Io instance.
    ///
    /// This is useful when you want to share the Io instance with other parts
    /// of your application to avoid creating multiple Io.Threaded instances.
    /// The registry and io must remain valid for the lifetime of the server.
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, registry: *Registry) MetricsServer {
        return .{
            .allocator = allocator,
            .registry = registry,
            .io = io,
            .owns_io = false,
            .server = null,
            .running = std.atomic.Value(bool).init(false),
            .server_thread = null,
            .logger = null,
        };
    }

    /// Set a logger for error reporting. If set, errors will be logged through
    /// this logger instead of std.log.
    pub fn setLogger(self: *MetricsServer, logger: Logger) void {
        self.logger = logger;
    }

    fn logError(self: *MetricsServer, msg: []const u8, err_name: ?[]const u8) void {
        if (self.logger) |logger| {
            logger.err(msg, err_name);
        } else {
            if (err_name) |name| {
                std.log.err("{s}: {s}", .{ msg, name });
            } else {
                std.log.err("{s}", .{msg});
            }
        }
    }

    /// Clean up server resources.
    ///
    /// This will stop the server if it's running.
    /// Note: This does NOT deinit the Io instance if it was provided via initWithIo.
    pub fn deinit(self: *MetricsServer) void {
        self.stop();
        // Note: stop() already closes and nulls the server
        // Only deinit threaded if we own it
        // Note: We can't actually deinit it here since we converted to io()
        // The caller who used init() must handle threaded.deinit() separately
        // or we need to store the threaded instance
    }

    /// Start serving metrics (blocking).
    ///
    /// This function blocks until `stop()` is called or an unrecoverable error occurs.
    /// Metrics will be available at http://{address}:{port}/metrics
    pub fn serve(self: *MetricsServer, config: Config) !void {
        const address = try std.Io.net.IpAddress.parse(config.address, config.port);

        self.server = try std.Io.net.IpAddress.listen(address, self.io, .{
            .reuse_address = true,
        });

        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            // Use poll with timeout to allow checking running flag periodically
            var poll_fds = [_]std.posix.pollfd{
                .{
                    .fd = self.server.?.socket.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            const poll_result = std.posix.poll(&poll_fds, 100) catch |err| {
                if (!self.running.load(.acquire)) break;
                self.logError("Poll failed", @errorName(err));
                continue;
            };

            // Timeout - check running flag again
            if (poll_result == 0) {
                continue;
            }

            // Check running flag before accepting
            if (!self.running.load(.acquire)) break;

            const stream = self.server.?.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) break;
                self.logError("Accept failed", @errorName(err));
                continue;
            };

            // Handle connection directly (single-threaded for now)
            self.handleConnection(stream);
        }
    }

    /// Start serving metrics in a background thread.
    ///
    /// Returns immediately. Call `stop()` to stop the server.
    pub fn serveInBackground(self: *MetricsServer, config: Config) !void {
        self.server_thread = try std.Thread.spawn(.{}, serveWrapper, .{ self, config });
    }

    fn serveWrapper(self: *MetricsServer, config: Config) void {
        self.serve(config) catch |err| {
            self.logError("Server error", @errorName(err));
        };
    }

    /// Stop the server.
    ///
    /// If the server is running in the background, this will wait for it to stop.
    pub fn stop(self: *MetricsServer) void {
        self.running.store(false, .release);
        // Close the server socket to unblock any pending accept/poll
        if (self.server) |*s| {
            s.socket.close(self.io);
            self.server = null;
        }
        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
    }

    /// Check if the server is running.
    pub fn isRunning(self: *MetricsServer) bool {
        return self.running.load(.acquire);
    }

    fn handleConnection(self: *MetricsServer, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;

        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);

        // Handle multiple requests on the same connection (keep-alive)
        while (true) {
            var request = http_server.receiveHead() catch break;

            if (std.mem.eql(u8, request.head.target, "/metrics")) {
                self.handleMetricsRequest(&request);
            } else {
                handleNotFound(&request);
            }

            if (!request.head.keep_alive) break;
        }
    }

    fn handleMetricsRequest(self: *MetricsServer, request: *std.http.Server.Request) void {
        // Use the registry's built-in gatherToString which is thread-safe
        const metrics = self.registry.gatherToString() catch |err| {
            self.logError("gatherToString failed", @errorName(err));
            request.respond("Internal Server Error\n", .{
                .status = .internal_server_error,
            }) catch {};
            return;
        };
        defer self.allocator.free(metrics);

        request.respond(metrics, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; version=0.0.4; charset=utf-8" },
            },
        }) catch |err| {
            self.logError("respond failed", @errorName(err));
        };
    }

    fn handleNotFound(request: *std.http.Server.Request) void {
        request.respond("404 Not Found\n", .{
            .status = .not_found,
        }) catch {};
    }
};
