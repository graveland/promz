// Prometheus client library for Zig
// Pure Zig implementation with idiomatic API

const std = @import("std");
const build_options = @import("build_options");

pub const version = build_options.version;

// Core types and errors
pub const MetricType = @import("core/metric.zig").MetricType;
pub const MetricError = @import("core/metric.zig").MetricError;
pub const MetricInfo = @import("core/metric.zig").MetricInfo;
pub const LabelHandle = @import("core/metric.zig").LabelHandle;

// Metric implementations
pub const Counter = @import("core/counter.zig").Counter;
pub const CounterConfig = @import("core/counter.zig").CounterConfig;
pub const Gauge = @import("core/gauge.zig").Gauge;
pub const GaugeConfig = @import("core/gauge.zig").GaugeConfig;
pub const Histogram = @import("core/histogram.zig").Histogram;
pub const HistogramConfig = @import("core/histogram.zig").HistogramConfig;
pub const BucketConfig = @import("core/histogram.zig").BucketConfig;
pub const defaultBuckets = @import("core/histogram.zig").defaultBuckets;
pub const DEFAULT_BUCKETS = @import("core/histogram.zig").DEFAULT_BUCKETS;

// Debug metrics (zero-overhead when disabled in release builds)
pub const debug = @import("core/debug.zig");
pub const DebugCounter = debug.DebugCounter;
pub const DebugGauge = debug.DebugGauge;
pub const DebugHistogram = debug.DebugHistogram;
pub const debug_metrics_enabled = debug.enabled;

// Noop support for disabled metrics
pub const RegistryOpts = @import("core/noop.zig").RegistryOpts;
pub const initializeNoop = @import("core/noop.zig").initializeNoop;

// Direct write support (write metrics without registry)
pub const write = @import("core/write.zig").write;

// Label support
pub const NoLabels = @import("core/labels.zig").NoLabels;
pub const RuntimeLabels = @import("core/labels.zig").RuntimeLabels;
pub const generateLabelKey = @import("core/labels.zig").generateLabelKey;
pub const generateLabelKeyBuf = @import("core/labels.zig").generateLabelKeyBuf;
pub const hashStructLabels = @import("core/labels.zig").hashStructLabels;
pub const validateLabelName = @import("core/labels.zig").validateLabelName;
pub const validateLabelValue = @import("core/labels.zig").validateLabelValue;

// Sample (for advanced use cases)
pub const Sample = @import("core/sample.zig").Sample;
pub const AtomicSample = @import("core/atomic_sample.zig").AtomicSample;
pub const LockedSample = @import("core/locked_sample.zig").LockedSample;

// Registry and collectors
pub const Registry = @import("registry/registry.zig").Registry;
pub const Collector = @import("registry/collector.zig").Collector;
pub const MetricCollector = @import("registry/collector.zig").MetricCollector;

// Text formatting
pub const writeMetric = @import("format/text.zig").writeMetric;

// HTTP server and handler
pub const MetricsServer = @import("http/server.zig").MetricsServer;
pub const MetricsHandler = @import("http/handler.zig").MetricsHandler;

test {
    // Run all tests in imported modules
    std.testing.refAllDecls(@This());
}
