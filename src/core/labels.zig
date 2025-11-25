const std = @import("std");
const MetricError = @import("metric.zig").MetricError;

/// Hash struct labels using comptime field name seed + runtime value hashing
/// This is much faster than building a label key string and hashing it
/// because field names are computed at compile time
pub fn hashStructLabels(comptime TLabels: type, labels: TLabels) u64 {
    const type_info = @typeInfo(TLabels);
    if (type_info != .@"struct") {
        @compileError("hashStructLabels requires a struct type");
    }

    const fields = type_info.@"struct".fields;
    if (fields.len == 0) {
        return 0; // Empty struct returns constant hash
    }

    // Compute seed from field names at comptime
    const seed = comptime blk: {
        var s: u64 = 0;
        for (fields) |field| {
            s = std.hash.Wyhash.hash(s, field.name);
        }
        break :blk s;
    };

    // Runtime: hash only the values, using the comptime seed
    var h = std.hash.Wyhash.init(seed);
    inline for (fields) |field| {
        const value = @field(labels, field.name);
        h.update(value);
    }
    return h.final();
}

/// Zero-size type representing a metric with no labels
/// This provides optimal performance for metrics that don't need dimensions
pub const NoLabels = struct {};

/// Runtime labels - for dynamic label keys and values
/// Use this when label names are not known at compile time
pub const RuntimeLabels = struct {
    keys: []const []const u8,
    values: []const []const u8,

    /// Create runtime labels from parallel arrays of keys and values
    pub fn init(keys: []const []const u8, values: []const []const u8) MetricError!RuntimeLabels {
        if (keys.len != values.len) {
            return MetricError.LabelCountMismatch;
        }

        // Validate all label names
        for (keys) |key| {
            try validateLabelName(key);
        }

        // Validate all label values
        for (values) |value| {
            try validateLabelValue(value);
        }

        return .{ .keys = keys, .values = values };
    }
};

/// Validate a label name according to Prometheus specification
/// Label names must match: [a-zA-Z_][a-zA-Z0-9_]*
/// Reserved names: "le", "quantile"
pub fn validateLabelName(name: []const u8) MetricError!void {
    if (name.len == 0) return MetricError.InvalidLabelName;

    // Check for reserved label names
    if (std.mem.eql(u8, name, "le") or std.mem.eql(u8, name, "quantile")) {
        return MetricError.InvalidLabelName;
    }

    // First character must be [a-zA-Z_]
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') {
        return MetricError.InvalidLabelName;
    }

    // Remaining characters must be [a-zA-Z0-9_]
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return MetricError.InvalidLabelName;
        }
    }
}

/// Validate a label value
/// Label values can contain any Unicode characters
/// Empty label values are valid in Prometheus
pub fn validateLabelValue(value: []const u8) MetricError!void {
    // Prometheus allows any UTF-8 string as a label value
    // We just need to ensure it's valid UTF-8
    if (!std.unicode.utf8ValidateSlice(value)) {
        return MetricError.InvalidLabelValue;
    }
}

/// Generate a stable key string from label values for HashMap lookup
/// Format: key1="value1",key2="value2"
/// For NoLabels, returns empty string
/// For RuntimeLabels, uses runtime keys/values
/// For structs, uses field names/values
pub fn generateLabelKey(
    allocator: std.mem.Allocator,
    comptime TLabels: type,
    labels: TLabels,
) ![]const u8 {
    // NoLabels special case - empty key
    if (TLabels == NoLabels) {
        return try allocator.dupe(u8, "");
    }

    // RuntimeLabels
    if (TLabels == RuntimeLabels) {
        return try generateRuntimeLabelKey(allocator, labels);
    }

    // Struct labels (comptime)
    return try generateStructLabelKey(allocator, TLabels, labels);
}

/// Generate label key into a provided buffer (zero allocations)
/// Returns slice of the buffer that was written
/// Returns error.NoSpaceLeft if buffer is too small
pub fn generateLabelKeyBuf(
    buf: []u8,
    comptime TLabels: type,
    labels: TLabels,
) ![]const u8 {
    if (TLabels == NoLabels) {
        return buf[0..0];
    }

    if (TLabels == RuntimeLabels) {
        return generateRuntimeLabelKeyBuf(buf, labels);
    }

    return generateStructLabelKeyBuf(buf, TLabels, labels);
}

fn generateStructLabelKeyBuf(
    buf: []u8,
    comptime TLabels: type,
    labels: TLabels,
) ![]const u8 {
    const fields = @typeInfo(TLabels).@"struct".fields;
    if (fields.len == 0) {
        return buf[0..0];
    }

    var pos: usize = 0;

    inline for (fields, 0..) |field, i| {
        if (i > 0) {
            if (pos >= buf.len) return error.NoSpaceLeft;
            buf[pos] = ',';
            pos += 1;
        }
        // Write field name
        if (pos + field.name.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..field.name.len], field.name);
        pos += field.name.len;

        // Write ="
        if (pos + 2 > buf.len) return error.NoSpaceLeft;
        buf[pos] = '=';
        buf[pos + 1] = '"';
        pos += 2;

        // Write value
        const value = @field(labels, field.name);
        if (pos + value.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..value.len], value);
        pos += value.len;

        // Write closing quote
        if (pos >= buf.len) return error.NoSpaceLeft;
        buf[pos] = '"';
        pos += 1;
    }

    return buf[0..pos];
}

fn generateRuntimeLabelKeyBuf(
    buf: []u8,
    labels: RuntimeLabels,
) ![]const u8 {
    if (labels.keys.len == 0) {
        return buf[0..0];
    }

    // For runtime labels, we need to sort by key name
    // Use a simple inline sort for small number of labels (typically <10)
    var indices: [16]usize = undefined;
    if (labels.keys.len > 16) {
        return error.NoSpaceLeft; // Too many labels for stack sort
    }

    for (0..labels.keys.len) |i| {
        indices[i] = i;
    }

    // Bubble sort indices by key name
    var i: usize = 0;
    while (i < labels.keys.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < labels.keys.len) : (j += 1) {
            if (std.mem.order(u8, labels.keys[indices[i]], labels.keys[indices[j]]) == .gt) {
                const tmp = indices[i];
                indices[i] = indices[j];
                indices[j] = tmp;
            }
        }
    }

    var pos: usize = 0;

    for (indices[0..labels.keys.len], 0..) |idx, field_pos| {
        if (field_pos > 0) {
            if (pos >= buf.len) return error.NoSpaceLeft;
            buf[pos] = ',';
            pos += 1;
        }
        // Write key name
        const key = labels.keys[idx];
        if (pos + key.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;

        // Write ="
        if (pos + 2 > buf.len) return error.NoSpaceLeft;
        buf[pos] = '=';
        buf[pos + 1] = '"';
        pos += 2;

        // Write value
        const value = labels.values[idx];
        if (pos + value.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..value.len], value);
        pos += value.len;

        // Write closing quote
        if (pos >= buf.len) return error.NoSpaceLeft;
        buf[pos] = '"';
        pos += 1;
    }

    return buf[0..pos];
}

/// Generate label key for RuntimeLabels
fn generateRuntimeLabelKey(
    allocator: std.mem.Allocator,
    labels: RuntimeLabels,
) ![]const u8 {
    if (labels.keys.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    // Sort indices by key name for stable ordering
    const indices = try allocator.alloc(usize, labels.keys.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx, i| {
        idx.* = i;
    }

    // Simple bubble sort (fine for small number of labels)
    var i: usize = 0;
    while (i < indices.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < indices.len) : (j += 1) {
            if (std.mem.order(u8, labels.keys[indices[i]], labels.keys[indices[j]]) == .gt) {
                const tmp = indices[i];
                indices[i] = indices[j];
                indices[j] = tmp;
            }
        }
    }

    // Build key string
    for (indices, 0..) |idx, pos| {
        if (pos > 0) {
            try buffer.append(allocator, ',');
        }
        try buffer.appendSlice(allocator, labels.keys[idx]);
        try buffer.appendSlice(allocator, "=\"");
        try buffer.appendSlice(allocator, labels.values[idx]);
        try buffer.append(allocator, '"');
    }

    return buffer.toOwnedSlice(allocator);
}

/// Generate label key for struct labels
fn generateStructLabelKey(
    allocator: std.mem.Allocator,
    comptime TLabels: type,
    labels: TLabels,
) ![]const u8 {
    const fields = @typeInfo(TLabels).@"struct".fields;

    if (fields.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    inline for (fields, 0..) |field, i| {
        if (i > 0) {
            try buffer.append(allocator, ',');
        }

        try buffer.appendSlice(allocator, field.name);
        try buffer.appendSlice(allocator, "=\"");

        const value = @field(labels, field.name);
        try buffer.appendSlice(allocator, value);

        try buffer.append(allocator, '"');
    }

    return buffer.toOwnedSlice(allocator);
}

/// Check if a type is a valid label type
pub fn isValidLabelType(comptime T: type) bool {
    if (T == NoLabels) return true;
    if (T == RuntimeLabels) return true;

    // Check if it's a struct with string fields
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".fields) |field| {
        if (field.type != []const u8) return false;
    }

    return true;
}

test "NoLabels: size is zero" {
    try std.testing.expectEqual(0, @sizeOf(NoLabels));
}

test "validateLabelName: valid names" {
    const valid_names = [_][]const u8{
        "method",
        "status_code",
        "http_method",
        "_private",
        "label123",
        "CamelCase",
    };

    for (valid_names) |name| {
        try validateLabelName(name);
    }
}

test "validateLabelName: invalid names" {
    const invalid_cases = [_][]const u8{
        "",           // empty
        "le",         // reserved
        "quantile",   // reserved
        "123invalid", // starts with number
        "invalid-dash", // contains dash
        "invalid.dot",  // contains dot
        "invalid space", // contains space
    };

    for (invalid_cases) |name| {
        const result = validateLabelName(name);
        try std.testing.expectError(MetricError.InvalidLabelName, result);
    }
}

test "validateLabelValue: valid values" {
    const valid_values = [_][]const u8{
        "",           // empty is valid
        "GET",
        "200",
        "value with spaces",
        "special!@#$%^&*()",
        "unicode: 你好世界",
    };

    for (valid_values) |value| {
        try validateLabelValue(value);
    }
}

test "validateLabelValue: invalid UTF-8" {
    // Invalid UTF-8 sequence
    const invalid_utf8 = [_]u8{ 0xFF, 0xFE, 0xFD };
    const result = validateLabelValue(&invalid_utf8);
    try std.testing.expectError(MetricError.InvalidLabelValue, result);
}

test "RuntimeLabels: init and validate" {
    const keys = [_][]const u8{ "method", "status" };
    const values = [_][]const u8{ "GET", "200" };

    const labels = try RuntimeLabels.init(&keys, &values);
    try std.testing.expectEqual(2, labels.keys.len);
    try std.testing.expectEqual(2, labels.values.len);
}

test "RuntimeLabels: mismatched keys and values" {
    const keys = [_][]const u8{ "method", "status" };
    const values = [_][]const u8{"GET"};

    const result = RuntimeLabels.init(&keys, &values);
    try std.testing.expectError(MetricError.LabelCountMismatch, result);
}

test "RuntimeLabels: invalid label name" {
    const keys = [_][]const u8{"invalid-name"};
    const values = [_][]const u8{"value"};

    const result = RuntimeLabels.init(&keys, &values);
    try std.testing.expectError(MetricError.InvalidLabelName, result);
}

test "generateLabelKey: NoLabels" {
    const key = try generateLabelKey(std.testing.allocator, NoLabels, .{});
    defer std.testing.allocator.free(key);

    try std.testing.expectEqualStrings("", key);
}

test "generateLabelKey: RuntimeLabels single label" {
    const keys = [_][]const u8{"method"};
    const values = [_][]const u8{"GET"};
    const labels = try RuntimeLabels.init(&keys, &values);

    const key = try generateLabelKey(std.testing.allocator, RuntimeLabels, labels);
    defer std.testing.allocator.free(key);

    try std.testing.expectEqualStrings("method=\"GET\"", key);
}

test "generateLabelKey: RuntimeLabels multiple labels sorted" {
    const keys = [_][]const u8{ "status", "method" };
    const values = [_][]const u8{ "200", "GET" };
    const labels = try RuntimeLabels.init(&keys, &values);

    const key = try generateLabelKey(std.testing.allocator, RuntimeLabels, labels);
    defer std.testing.allocator.free(key);

    // Should be sorted alphabetically by key
    try std.testing.expectEqualStrings("method=\"GET\",status=\"200\"", key);
}

test "generateLabelKey: struct labels" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    const labels = Labels{
        .method = "POST",
        .status = "201",
    };

    const key = try generateLabelKey(std.testing.allocator, Labels, labels);
    defer std.testing.allocator.free(key);

    try std.testing.expectEqualStrings("method=\"POST\",status=\"201\"", key);
}

test "isValidLabelType: NoLabels" {
    try std.testing.expect(isValidLabelType(NoLabels));
}

test "isValidLabelType: RuntimeLabels" {
    try std.testing.expect(isValidLabelType(RuntimeLabels));
}

test "isValidLabelType: valid struct" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };
    try std.testing.expect(isValidLabelType(Labels));
}

test "isValidLabelType: invalid struct with wrong field types" {
    const InvalidLabels = struct {
        count: i32,
        name: []const u8,
    };
    try std.testing.expect(!isValidLabelType(InvalidLabels));
}

test "generateLabelKeyBuf: NoLabels" {
    var buf: [64]u8 = undefined;
    const key = try generateLabelKeyBuf(&buf, NoLabels, .{});
    try std.testing.expectEqualStrings("", key);
}

test "generateLabelKeyBuf: struct labels" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    const labels = Labels{
        .method = "POST",
        .status = "201",
    };

    var buf: [64]u8 = undefined;
    const key = try generateLabelKeyBuf(&buf, Labels, labels);
    try std.testing.expectEqualStrings("method=\"POST\",status=\"201\"", key);
}

test "generateLabelKeyBuf: RuntimeLabels sorted" {
    const keys = [_][]const u8{ "status", "method" };
    const values = [_][]const u8{ "200", "GET" };
    const labels = try RuntimeLabels.init(&keys, &values);

    var buf: [64]u8 = undefined;
    const key = try generateLabelKeyBuf(&buf, RuntimeLabels, labels);
    try std.testing.expectEqualStrings("method=\"GET\",status=\"200\"", key);
}

test "generateLabelKeyBuf: buffer too small" {
    const Labels = struct {
        very_long_field_name: []const u8,
    };

    const labels = Labels{
        .very_long_field_name = "very_long_value_that_exceeds_buffer",
    };

    var buf: [10]u8 = undefined;
    const result = generateLabelKeyBuf(&buf, Labels, labels);
    try std.testing.expectError(error.NoSpaceLeft, result);
}

test "hashStructLabels: empty struct" {
    const Empty = struct {};
    const hash = hashStructLabels(Empty, .{});
    try std.testing.expectEqual(@as(u64, 0), hash);
}

test "hashStructLabels: single field" {
    const Labels = struct {
        method: []const u8,
    };

    const hash1 = hashStructLabels(Labels, .{ .method = "GET" });
    const hash2 = hashStructLabels(Labels, .{ .method = "GET" });
    const hash3 = hashStructLabels(Labels, .{ .method = "POST" });

    // Same labels should produce same hash
    try std.testing.expectEqual(hash1, hash2);
    // Different labels should produce different hash
    try std.testing.expect(hash1 != hash3);
}

test "hashStructLabels: multiple fields" {
    const Labels = struct {
        method: []const u8,
        status: []const u8,
    };

    const hash1 = hashStructLabels(Labels, .{ .method = "GET", .status = "200" });
    const hash2 = hashStructLabels(Labels, .{ .method = "GET", .status = "200" });
    const hash3 = hashStructLabels(Labels, .{ .method = "GET", .status = "404" });
    const hash4 = hashStructLabels(Labels, .{ .method = "POST", .status = "200" });

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
    try std.testing.expect(hash1 != hash4);
    try std.testing.expect(hash3 != hash4);
}

test "hashStructLabels: different struct types with same values" {
    const Labels1 = struct {
        method: []const u8,
    };
    const Labels2 = struct {
        endpoint: []const u8,
    };

    // Same value but different field names should produce different hashes
    const hash1 = hashStructLabels(Labels1, .{ .method = "GET" });
    const hash2 = hashStructLabels(Labels2, .{ .endpoint = "GET" });

    try std.testing.expect(hash1 != hash2);
}
