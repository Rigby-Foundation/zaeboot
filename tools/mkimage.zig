// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! mkimage: build a raw BIOS-bootable disk image.
//!   mkimage <stage1.bin> <stage2.bin> <sic.elf> <initrd.tar|-> <out.img>
//! Layout (512-byte sectors): [0] stage 1 (MBR)  [1..] stage 2  kernel  initrd,
//! each padded to a sector. Patches stage 1's sector count and stage 2's
//! image table (magic "ZAEBIMG\0") with the kernel/initrd LBAs.
//!
//!   mkimage --hybrid <stage1.bin> <stage2.bin> <esp.img> <out.img>
//! One image for BIOS and UEFI: the MBR and stage 2, then from 1 MiB a FAT32
//! EFI system partition (EFI/BOOT/BOOTX64.EFI, sic.elf, initrd.tar) that the
//! partition table points UEFI firmware at. Stage 2 reads sic.elf and
//! initrd.tar where they lie inside that partition (each must be contiguous,
//! as a freshly formatted FAT writes them), so nothing is stored twice.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 6 and std.mem.eql(u8, args[1], "--hybrid")) return hybrid(a, io, args[2..6]);
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
    try patchTable(stage2, kernel_lba, k_sectors, initrd_lba, i_sectors);

    var out = std.ArrayList(u8).empty;
    try appendPadded(a, &out, stage1);
    try appendPadded(a, &out, stage2);
    try appendPadded(a, &out, kernel);
    try appendPadded(a, &out, initrd);
    try cwd.writeFile(io, .{ .sub_path = args[5], .data = out.items });
    std.debug.print("mkimage: stage2 {d} sectors, kernel {d} @ lba {d}, initrd {d} @ lba {d}\n", .{ s2_sectors, k_sectors, kernel_lba, i_sectors, initrd_lba });
}

fn patchTable(stage2: []u8, kernel_lba: u32, k_sectors: u32, initrd_lba: u32, i_sectors: u32) !void {
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
}

const esp_lba: u32 = 2048; // 1 MiB: where partitioning tools put the first partition

/// A file in the root directory of a FAT32 image: its first sector (in the
/// image) and its length in sectors, or an error unless it is contiguous.
fn fatFile(esp: []const u8, name: *const [11]u8) !struct { lba: u32, sectors: u32 } {
    if (esp.len < 512 or std.mem.readInt(u16, esp[11..13], .little) != 512) return error.EspNotFat512;
    const spc: u32 = esp[13];
    const reserved: u32 = std.mem.readInt(u16, esp[14..16], .little);
    const fats: u32 = esp[16];
    const fat_sectors = std.mem.readInt(u32, esp[36..40], .little);
    if (std.mem.readInt(u16, esp[22..24], .little) != 0 or fat_sectors == 0) return error.EspNotFat32;
    const root = std.mem.readInt(u32, esp[44..48], .little);
    const data = reserved + fats * fat_sectors;
    const fat = esp[reserved * 512 ..][0 .. fat_sectors * 512];
    const next = struct {
        fn f(t: []const u8, c: u32) u32 {
            return std.mem.readInt(u32, t[c * 4 ..][0..4], .little) & 0x0FFF_FFFF;
        }
    }.f;
    var c = root;
    while (c >= 2 and c < 0x0FFF_FFF8) : (c = next(fat, c)) {
        const dir = esp[(data + (c - 2) * spc) * 512 ..][0 .. spc * 512];
        var off: usize = 0;
        while (off < dir.len) : (off += 32) {
            const e = dir[off..][0..32];
            if (e[0] == 0) return error.FileNotInEsp;
            if (e[0] == 0xE5 or e[11] == 0x0F or !std.mem.eql(u8, e[0..11], name)) continue;
            const first = @as(u32, std.mem.readInt(u16, e[20..22], .little)) << 16 | std.mem.readInt(u16, e[26..28], .little);
            const size = std.mem.readInt(u32, e[28..32], .little);
            const clusters = (size + spc * 512 - 1) / (spc * 512);
            var k = first;
            var n: u32 = 1;
            while (n < clusters) : (n += 1) {
                const nx = next(fat, k);
                if (nx != k + 1) return error.EspFileFragmented;
                k = nx;
            }
            return .{ .lba = esp_lba + data + (first - 2) * spc, .sectors = sectors(size) };
        }
    }
    return error.FileNotInEsp;
}

fn hybrid(a: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stage1 = try cwd.readFileAlloc(io, args[0], a, .limited(1 << 20));
    const stage2 = try cwd.readFileAlloc(io, args[1], a, .limited(1 << 20));
    const esp = try cwd.readFileAlloc(io, args[2], a, .limited(4 << 30));
    if (stage1.len != 512) return error.Stage1NotOneSector;
    const s2_sectors = sectors(stage2.len);
    if (1 + s2_sectors > esp_lba) return error.Stage2TooBig;
    if (esp.len % 512 != 0) return error.EspNotSectors;

    const k = try fatFile(esp, "SIC     ELF");
    const i = try fatFile(esp, "INITRD  TAR");
    std.mem.writeInt(u32, stage1[432..436], 1, .little);
    std.mem.writeInt(u16, stage1[436..438], @intCast(s2_sectors), .little);
    try patchTable(stage2, k.lba, k.sectors, i.lba, i.sectors);
    // one partition: the ESP, LBA-addressed (CHS fields "beyond 1024 cylinders")
    const p = stage1[446..462];
    @memset(stage1[446..510], 0);
    p[0] = 0x80;
    p[1] = 0xFE; p[2] = 0xFF; p[3] = 0xFF;
    p[4] = 0xEF;
    p[5] = 0xFE; p[6] = 0xFF; p[7] = 0xFF;
    std.mem.writeInt(u32, p[8..12], esp_lba, .little);
    std.mem.writeInt(u32, p[12..16], @intCast(esp.len / 512), .little);

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, stage1);
    try appendPadded(a, &out, stage2);
    try out.appendNTimes(a, 0, esp_lba * 512 - out.items.len);
    try out.appendSlice(a, esp);
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = out.items });
    std.debug.print("mkimage: hybrid, stage2 {d} sectors, ESP {d} MiB @ lba {d}, kernel @ lba {d}, initrd {d} sectors @ lba {d}\n", .{ s2_sectors, esp.len >> 20, esp_lba, k.lba, i.sectors, i.lba });
}

fn sectors(len: usize) u32 {
    return @intCast((len + 511) / 512);
}

fn appendPadded(a: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    try out.appendSlice(a, data);
    const pad = (512 - data.len % 512) % 512;
    try out.appendNTimes(a, 0, pad);
}
