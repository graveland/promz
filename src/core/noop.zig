const std = @import("std");

/// Options for initializing metrics, controlling which metrics are enabled
pub const RegistryOpts = struct {
    /// Prefix to prepend to all metric names
    prefix: []const u8 = "",
};

/// Initialize a metrics struct with all metric fields set to noop.
/// This provides a safe default where all metrics are disabled.
///
/// Usage:
/// ```
/// const Metrics = struct {
///     requests: promz.Counter(u64, promz.NoLabels, .{}),
///     latency: promz.Histogram(f64, promz.NoLabels, .{}),
/// };
///
/// // All metrics start as noop
/// var metrics = promz.initializeNoop(Metrics);
/// ```
pub fn initializeNoop(comptime T: type) T {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("initializeNoop requires a struct type, got: " ++ @typeName(T));
    }

    var result: T = undefined;
    inline for (info.@"struct".fields) |field| {
        const field_info = @typeInfo(field.type);
        if (field_info == .@"union") {
            // Check if the union has a 'noop' field
            if (hasNoopField(field.type)) {
                @field(result, field.name) = .noop;
            } else if (field.default_value_ptr) |default| {
                const typed_default: *const field.type = @alignCast(@ptrCast(default));
                @field(result, field.name) = typed_default.*;
            } else {
                @compileError("Field '" ++ field.name ++ "' is a union without 'noop' and has no default value");
            }
        } else if (field.default_value_ptr) |default| {
            const typed_default: *const field.type = @alignCast(@ptrCast(default));
            @field(result, field.name) = typed_default.*;
        } else {
            @compileError("Field '" ++ field.name ++ "' has no default value and is not a noop-capable union");
        }
    }
    return result;
}

fn hasNoopField(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"union") return false;

    inline for (info.@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, "noop")) {
            return true;
        }
    }
    return false;
}

test "RegistryOpts defaults" {
    const opts = RegistryOpts{};
    try std.testing.expectEqualStrings("", opts.prefix);
}

test "initializeNoop with simple struct" {
    const TestUnion = union(enum) {
        noop: void,
        impl: u32,

        pub fn hasNoopField() bool {
            return true;
        }
    };

    const TestMetrics = struct {
        counter: TestUnion = .noop,
        gauge: TestUnion = .noop,
    };

    const metrics = initializeNoop(TestMetrics);
    try std.testing.expectEqual(.noop, metrics.counter);
    try std.testing.expectEqual(.noop, metrics.gauge);
}

test "initializeNoop preserves default values" {
    const TestUnion = union(enum) {
        noop: void,
        impl: u32,
    };

    const TestMetrics = struct {
        counter: TestUnion = .noop,
        name: []const u8 = "default_name",
    };

    const metrics = initializeNoop(TestMetrics);
    try std.testing.expectEqual(.noop, metrics.counter);
    try std.testing.expectEqualStrings("default_name", metrics.name);
}
