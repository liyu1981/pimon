//! Pure CPU-temperature decoding shared by the PawnIO backend and host tests.

const std = @import("std");

/// Tctl offset for the first/second-generation Ryzen SKUs that report a
/// control temperature above the actual die temperature.
pub fn amdTctlOffset(model: []const u8) f32 {
    if (contains(model, "1600X") or contains(model, "1700X") or contains(model, "1800X"))
        return 20.0;
    if (contains(model, "Threadripper 19") or contains(model, "Threadripper 29"))
        return 27.0;
    if (contains(model, "2700X"))
        return 10.0;
    return 0.0;
}

/// Decode the AMD `THM_TCON_CUR_TMP` register (SMN 0x00059800) into the
/// package/die temperature.  `offset` is the positive Tctl offset from
/// `amdTctlOffset`; pass 0 on Zen 2 and newer.
pub fn decodeAmdPackage(raw: u32, offset: f32) ?f32 {
    const cur: u32 = (raw >> 21) & 0x7ff;
    var temp: f32 = @as(f32, @floatFromInt(cur)) * 0.125;

    // RANGE_SEL or TJ_SEL both indicate the 49 C adjustment on newer Zen.
    if ((raw & 0x80000) != 0 or (raw & 0x30000) == 0x30000)
        temp -= 49.0;

    temp -= offset;
    if (temp < -40.0 or temp > 150.0) return null;
    return temp;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "AMD package temperature decoding" {
    // 50 C, no offset flag.
    try std.testing.expectEqual(@as(f32, 50.0), decodeAmdPackage(400 << 21, 0).?);

    // 50 C after the 49 C adjustment.
    try std.testing.expectEqual(@as(f32, 50.0), decodeAmdPackage((792 << 21) | 0x80000, 0).?);

    // Tctl 70 C on an 1800X (20 C offset) is 50 C Tdie.
    try std.testing.expectEqual(@as(f32, 50.0), decodeAmdPackage(560 << 21, 20).?);

    // Implausible values are rejected.
    try std.testing.expect(decodeAmdPackage(0x7ff << 21, 0) == null);
}

test "AMD Tctl offsets" {
    try std.testing.expectEqual(@as(f32, 20.0), amdTctlOffset("AMD Ryzen 7 1800X Eight-Core Processor"));
    try std.testing.expectEqual(@as(f32, 27.0), amdTctlOffset("AMD Ryzen Threadripper 2990WX"));
    try std.testing.expectEqual(@as(f32, 10.0), amdTctlOffset("AMD Ryzen 7 2700X Eight-Core Processor"));
    try std.testing.expectEqual(@as(f32, 0.0), amdTctlOffset("AMD Ryzen 9 5900X 12-Core Processor"));
}
