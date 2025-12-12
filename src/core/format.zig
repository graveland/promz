const std = @import("std");

/// Write a numeric value (integer or float) to a writer in Prometheus format.
/// Handles special float values (NaN, +Inf, -Inf) according to the exposition format.
pub fn writeValue(comptime V: type, writer: anytype, value: V) !void {
    var buf: [64]u8 = undefined;
    const str = switch (@typeInfo(V)) {
        .int => try std.fmt.bufPrint(&buf, "{d}", .{value}),
        .float => blk: {
            if (std.math.isNan(value)) {
                break :blk "NaN";
            } else if (std.math.isInf(value)) {
                break :blk if (value > 0) "+Inf" else "-Inf";
            } else {
                break :blk try std.fmt.bufPrint(&buf, "{d}", .{value});
            }
        },
        else => unreachable,
    };
    try writer.writeAll(str);
}

test "writeValue: integers" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeValue(u64, &aw.writer, 42);
    try std.testing.expectEqualStrings("42", aw.written());
}

test "writeValue: floats" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeValue(f64, &aw.writer, 3.14);
    const written = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "3.14"));
}

test "writeValue: NaN" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeValue(f64, &aw.writer, std.math.nan(f64));
    try std.testing.expectEqualStrings("NaN", aw.written());
}

test "writeValue: +Inf" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeValue(f64, &aw.writer, std.math.inf(f64));
    try std.testing.expectEqualStrings("+Inf", aw.written());
}

test "writeValue: -Inf" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeValue(f64, &aw.writer, -std.math.inf(f64));
    try std.testing.expectEqualStrings("-Inf", aw.written());
}
