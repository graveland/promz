const std = @import("std");
const MetricType = @import("../core/metric.zig").MetricType;

/// Write a metric in Prometheus text exposition format (takes value)
pub fn writeMetric(writer: anytype, metric: anytype) !void {
    const info = metric.info;

    // Write HELP line
    try writer.writeAll("# HELP ");
    try writer.writeAll(info.name);
    try writer.writeAll(" ");
    try writer.writeAll(info.help);
    try writer.writeAll("\n");

    // Write TYPE line
    try writer.writeAll("# TYPE ");
    try writer.writeAll(info.name);
    try writer.writeAll(" ");
    try writer.writeAll(@tagName(info.metric_type));
    try writer.writeAll("\n");

    // Write samples - use comptime check to avoid type errors
    const T = @TypeOf(metric);
    if (@hasField(T, "buckets")) {
        try writeHistogramSamples(writer, metric);
    } else {
        try writeSamples(writer, metric);
    }
}

/// Write a metric in Prometheus text exposition format (takes pointer - avoids shallow copy issues)
/// Supports both union-wrapped metrics (with noop/impl) and direct metrics
pub fn writeMetricPtr(writer: anytype, metric: anytype) !void {
    const T = @TypeOf(metric.*);
    const type_info = @typeInfo(T);

    // Handle union types (new noop-capable metrics)
    if (type_info == .@"union") {
        switch (metric.*) {
            .noop => return, // Don't write noop metrics
            .impl => |*impl| {
                try writeMetricImpl(writer, impl);
            },
        }
    } else {
        // Handle non-union types (legacy metrics)
        try writeMetricImpl(writer, metric);
    }
}

/// Internal function to write metric implementation
fn writeMetricImpl(writer: anytype, metric: anytype) !void {
    const info = metric.info;

    // Write HELP line
    try writer.writeAll("# HELP ");
    try writer.writeAll(info.name);
    try writer.writeAll(" ");
    try writer.writeAll(info.help);
    try writer.writeAll("\n");

    // Write TYPE line
    try writer.writeAll("# TYPE ");
    try writer.writeAll(info.name);
    try writer.writeAll(" ");
    try writer.writeAll(@tagName(info.metric_type));
    try writer.writeAll("\n");

    // Write samples - use comptime check to avoid type errors
    const T = @TypeOf(metric.*);
    if (@hasField(T, "buckets")) {
        try writeHistogramSamplesPtr(writer, metric);
    } else {
        try writeSamplesPtr(writer, metric);
    }
}

fn writeSamples(writer: anytype, metric: anytype) !void {
    const TLabels = @TypeOf(metric).Labels;
    const use_single_sample = (TLabels == @import("../core/labels.zig").NoLabels);

    if (use_single_sample) {
        // Single sample - no labels
        try writer.writeAll(metric.info.name);
        try writer.writeAll(" ");
        try writeFloat(writer, metric.sample.get());
        try writer.writeAll("\n");
    } else {
        // Multiple samples with labels - value_ptr.* is *SampleType (pointer to heap-allocated sample)
        var it = metric.samples.iterator();
        while (it.next()) |entry| {
            try writer.writeAll(metric.info.name);
            if (entry.key_ptr.len > 0) {
                try writer.writeAll("{");
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("}");
            }
            try writer.writeAll(" ");
            try writeFloat(writer, entry.value_ptr.*.get());
            try writer.writeAll("\n");
        }
    }
}

fn writeSamplesPtr(writer: anytype, metric: anytype) !void {
    const TLabels = @TypeOf(metric.*).Labels;
    const use_single_sample = (TLabels == @import("../core/labels.zig").NoLabels);

    if (use_single_sample) {
        // Single sample - no labels
        try writer.writeAll(metric.info.name);
        try writer.writeAll(" ");
        try writeFloat(writer, metric.sample.get());
        try writer.writeAll("\n");
    } else {
        // Multiple samples with labels - value_ptr.* is *SampleType (pointer to heap-allocated sample)
        var it = metric.samples.iterator();
        while (it.next()) |entry| {
            try writer.writeAll(metric.info.name);
            if (entry.key_ptr.len > 0) {
                try writer.writeAll("{");
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("}");
            }
            try writer.writeAll(" ");
            try writeFloat(writer, entry.value_ptr.*.get());
            try writer.writeAll("\n");
        }
    }
}

fn writeHistogramSamples(writer: anytype, histogram: anytype) !void {
    const TLabels = @TypeOf(histogram).Labels;
    const use_single_sample = (TLabels == @import("../core/labels.zig").NoLabels);

    if (use_single_sample) {
        try writeHistogramSample(writer, histogram.info.name, "", &histogram.sample, histogram.buckets.upper_bounds);
    } else {
        // entry.value_ptr.* is *HistogramSample (pointer to heap-allocated sample)
        var it = histogram.samples.iterator();
        while (it.next()) |entry| {
            try writeHistogramSample(writer, histogram.info.name, entry.key_ptr.*, entry.value_ptr.*, histogram.buckets.upper_bounds);
        }
    }
}

fn writeHistogramSamplesPtr(writer: anytype, histogram: anytype) !void {
    const TLabels = @TypeOf(histogram.*).Labels;
    const use_single_sample = (TLabels == @import("../core/labels.zig").NoLabels);

    if (use_single_sample) {
        try writeHistogramSample(writer, histogram.info.name, "", &histogram.sample, histogram.buckets.upper_bounds);
    } else {
        // entry.value_ptr.* is *HistogramSample (pointer to heap-allocated sample)
        var it = histogram.samples.iterator();
        while (it.next()) |entry| {
            try writeHistogramSample(writer, histogram.info.name, entry.key_ptr.*, entry.value_ptr.*, histogram.buckets.upper_bounds);
        }
    }
}

fn writeHistogramSample(writer: anytype, name: []const u8, label_str: []const u8, sample: anytype, upper_bounds: []const f64) !void {
    // Write bucket samples
    for (upper_bounds, 0..) |bound, i| {
        try writer.writeAll(name);
        try writer.writeAll("_bucket{");
        if (label_str.len > 0) {
            try writer.writeAll(label_str);
            try writer.writeAll(",");
        }
        try writer.writeAll("le=\"");
        try writeFloat(writer, bound);
        try writer.writeAll("\"} ");
        var buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&buf, "{d}", .{sample.bucket_counts[i]});
        try writer.writeAll(count_str);
        try writer.writeAll("\n");
    }

    // Write +Inf bucket
    try writer.writeAll(name);
    try writer.writeAll("_bucket{");
    if (label_str.len > 0) {
        try writer.writeAll(label_str);
        try writer.writeAll(",");
    }
    try writer.writeAll("le=\"+Inf\"} ");
    var buf2: [32]u8 = undefined;
    const inf_count_str = try std.fmt.bufPrint(&buf2, "{d}", .{sample.bucket_counts[upper_bounds.len]});
    try writer.writeAll(inf_count_str);
    try writer.writeAll("\n");

    // Write sum
    try writer.writeAll(name);
    try writer.writeAll("_sum");
    if (label_str.len > 0) {
        try writer.writeAll("{");
        try writer.writeAll(label_str);
        try writer.writeAll("}");
    }
    try writer.writeAll(" ");
    try writeFloat(writer, sample.sum);
    try writer.writeAll("\n");

    // Write count
    try writer.writeAll(name);
    try writer.writeAll("_count");
    if (label_str.len > 0) {
        try writer.writeAll("{");
        try writer.writeAll(label_str);
        try writer.writeAll("}");
    }
    try writer.writeAll(" ");
    var buf3: [32]u8 = undefined;
    const count_str2 = try std.fmt.bufPrint(&buf3, "{d}", .{sample.count});
    try writer.writeAll(count_str2);
    try writer.writeAll("\n");
}

fn writeFloat(writer: anytype, value: f64) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("NaN");
    } else if (std.math.isInf(value)) {
        if (value > 0) {
            try writer.writeAll("+Inf");
        } else {
            try writer.writeAll("-Inf");
        }
    } else {
        var buf: [128]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try writer.writeAll(str);
    }
}

test "writeFloat: normal values" {
    // Simple test - writeFloat is used internally and tested through full integration tests
    // Just verify it doesn't crash
    const TestWriter = struct {
        written: []const u8 = "",

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            _ = self;
            _ = bytes;
        }
    };

    var tw = TestWriter{};
    try writeFloat(&tw, 42.5);
}
