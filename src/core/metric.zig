const std = @import("std");

/// Metric types supported by Prometheus
pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary, // Reserved for future implementation
};

/// Errors that can occur during metric operations
pub const MetricError = error{
    /// Metric name doesn't match Prometheus naming conventions
    InvalidMetricName,
    /// Label name doesn't match Prometheus naming conventions or is reserved
    InvalidLabelName,
    /// Label value contains invalid characters
    InvalidLabelValue,
    /// Duplicate label name provided
    DuplicateLabel,
    /// Number of label values doesn't match number of label keys
    LabelCountMismatch,
    /// Attempted to add negative value to counter
    NegativeCounterValue,
    /// Sample with given label combination not found
    SampleNotFound,
    /// Memory allocation failed
    OutOfMemory,
    /// Handle was created for a different metric generation (stale after reset/recreate)
    StaleHandle,
    /// Handle index is out of bounds
    InvalidHandle,
};

/// Handle to a pre-registered label combination for O(1) access
/// Contains a validation token to detect stale handles after metric reset
pub const LabelHandle = struct {
    index: u32,
    generation: u32,
};

/// Base metric metadata shared by all metric types
pub const MetricInfo = struct {
    name: []const u8,
    help: []const u8,
    metric_type: MetricType,

    /// Validate metric name according to Prometheus specification
    /// Metric names must match: [a-zA-Z_:][a-zA-Z0-9_:]*
    pub fn validate(self: MetricInfo) MetricError!void {
        if (self.name.len == 0) return MetricError.InvalidMetricName;

        // First character must be [a-zA-Z_:]
        const first = self.name[0];
        if (!std.ascii.isAlphabetic(first) and first != '_' and first != ':') {
            return MetricError.InvalidMetricName;
        }

        // Remaining characters must be [a-zA-Z0-9_:]
        for (self.name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != ':') {
                return MetricError.InvalidMetricName;
            }
        }
    }
};

test "MetricInfo: valid metric names" {
    const valid_names = [_][]const u8{
        "simple_metric",
        "http_requests_total",
        "process_cpu_seconds_total",
        "metric_with_123",
        "_leading_underscore",
        "namespace:subsystem:name",
        "CamelCase",
    };

    for (valid_names) |name| {
        const info = MetricInfo{
            .name = name,
            .help = "Test metric",
            .metric_type = .counter,
        };
        try info.validate();
    }
}

test "MetricInfo: invalid metric names" {
    const invalid_names = [_][]const u8{
        "",            // empty
        "123invalid",  // starts with number
        "invalid-dash", // contains dash
        "invalid.dot", // contains dot
        "invalid space", // contains space
        "invalid@symbol", // contains @
    };

    for (invalid_names) |name| {
        const info = MetricInfo{
            .name = name,
            .help = "Test metric",
            .metric_type = .counter,
        };
        const result = info.validate();
        try std.testing.expectError(MetricError.InvalidMetricName, result);
    }
}

test "MetricType: enum values" {
    try std.testing.expectEqual(MetricType.counter, .counter);
    try std.testing.expectEqual(MetricType.gauge, .gauge);
    try std.testing.expectEqual(MetricType.histogram, .histogram);
    try std.testing.expectEqual(MetricType.summary, .summary);
}
