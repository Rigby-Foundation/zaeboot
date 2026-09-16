// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! mkimage: build a raw BIOS-bootable disk image.
//!   mkimage <stage1.bin> <stage2.bin> <sic.elf> <initrd.tar|-> <out.img>
//! Layout (512-byte sectors): [0] stage 1 (MBR)  [1..] stage 2  kernel  initrd,
//! each padded to a sector. Patches stage 1's sector count and stage 2's
//! image table (magic "ZAEBIMG\0") with the kernel/initrd LBAs.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 6) {
        std.debug.print("usage: mkimage <stage1.bin> <stage2.bin> <sic.elf> <initrd.tar|-> <out.img>\n", .{});
        return error.Usage;
    }
    const cwd = std.Io.Dir.cwd();
    const stage1 = try cwd.readFileAlloc(io, args[1], a, .limited(1 << 20));
    const stage2 = try cwd.readFileAlloc(io, args[2], a, .limited(1 << 20));
    const kernel = try cwd.readFileAlloc(io, args[3], a, .limited(256 << 20));
    const initrd: []u8 = if (std.mem.eql(u8, args[4], "-")) &.{} else try cwd.readFileAlloc(io, args[4], a, .limited(256 << 20));
    if (stage1.len != 512) return error.Stage1NotOneSector;

    const s2_sectors = sectors(stage2.len);
    const k_sectors = sectors(kernel.len);
    const i_sectors = sectors(initrd.len);
    const kernel_lba: u32 = 1 + s2_sectors;
    const initrd_lba: u32 = kernel_lba + k_sectors;

    std.mem.writeInt(u32, stage1[432..436], 1, .little);
    std.mem.writeInt(u16, stage1[436..438], @intCast(s2_sectors), .little);
    // The table is the copy of the magic followed by 16 zero bytes (its
    // unpatched fields); a string literal elsewhere in the binary is not.
    var idx: usize = 0;
    var found: ?usize = null;
    while (std.mem.indexOfPos(u8, stage2, idx, "ZAEBIMG\x00")) |i| : (idx = i + 1) {
        if (i + 24 <= stage2.len and std.mem.allEqual(u8, stage2[i + 8 .. i + 24], 0)) {
            found = i;
            break;
        }
    }
    const t = stage2[(found orelse return error.NoImageTable) + 8 ..][0..16];
    std.mem.writeInt(u32, t[0..4], kernel_lba, .little);
    std.mem.writeInt(u32, t[4..8], k_sectors, .little);
    std.mem.writeInt(u32, t[8..12], initrd_lba, .little);
    std.mem.writeInt(u32, t[12..16], i_sectors, .little);

    var out = std.ArrayList(u8).empty;
    try appendPadded(a, &out, stage1);
    try appendPadded(a, &out, stage2);
    try appendPadded(a, &out, kernel);
    try appendPadded(a, &out, initrd);
    try cwd.writeFile(io, .{ .sub_path = args[5], .data = out.items });
    std.debug.print("mkimage: stage2 {d} sectors, kernel {d} @ lba {d}, initrd {d} @ lba {d}\n", .{ s2_sectors, k_sectors, kernel_lba, i_sectors, initrd_lba });
}

fn sectors(len: usize) u32 {
    return @intCast((len + 511) / 512);
}

fn appendPadded(a: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    try out.appendSlice(a, data);
    const pad = (512 - data.len % 512) % 512;
    try out.appendNTimes(a, 0, pad);
}
