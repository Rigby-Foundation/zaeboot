// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! zaeboot - a small UEFI bootloader for the sic kernel.
//!
//! 1. Read `\sic.elf` from the EFI System Partition the loader was started from.
//! 2. Copy its PT_LOAD segments to their physical addresses.
//! 3. Pick a GOP framebuffer mode, find the ACPI RSDP.
//! 4. Grab the UEFI memory map, ExitBootServices, translate the map.
//! 5. Jump to the kernel entry with a `protocol.Info` pointer in RDI.

const std = @import("std");
const uefi = std.os.uefi;
const con = @import("console.zig");
const elf = @import("elf.zig");
const protocol = @import("protocol.zig");

const kernel_path = std.unicode.utf8ToUtf16LeStringLiteral("sic.elf");
const initrd_path = std.unicode.utf8ToUtf16LeStringLiteral("initrd.tar");
/// Tried in order; falls back to whatever mode the firmware left active.
const preferred_modes = [_][2]u32{
    .{ 1280, 1024 },
    .{ 1280, 800 },
    .{ 1024, 768 },
};

pub fn main() void {
    con.init();
    con.puts("zaeboot 0.1\n\n");

    boot() catch |err| {
        con.puts("\nzaeboot: fatal: ");
        con.putErr(err);
        con.puts("\n");
    };
    hang();
}

fn hang() noreturn {
    while (true) asm volatile ("hlt");
}

fn boot() !noreturn {
    const st = uefi.system_table;
    const bs = st.boot_services orelse return error.NoBootServices;

    // -- 1. read the kernel image ------------------------------------------
    con.puts("loading \\sic.elf...\n");
    const image = try readFile(bs, kernel_path);
    con.puts("  read ");
    con.putDec(image.len);
    con.puts(" bytes\n");

    const initrd: ?[]align(8) u8 = readFile(bs, initrd_path) catch |err| blk: {
        con.puts("no initrd (");
        con.putErr(err);
        con.puts(")\n");
        break :blk null;
    };
    if (initrd) |rd| {
        con.puts("loaded \\initrd.tar, ");
        con.putDec(rd.len);
        con.puts(" bytes\n");
    }

    // -- 2. place it in memory ----------------------------------------------
    const loaded = try elf.load(bs, image);
    con.puts("  entry ");
    con.putHex(loaded.entry);
    con.puts("\n");

    // -- 3. framebuffer + ACPI ------------------------------------------------
    const fb = try setupFramebuffer(bs);
    con.puts("framebuffer ");
    con.putDec(fb.width);
    con.puts("x");
    con.putDec(fb.height);
    con.puts(" @ ");
    con.putHex(fb.base);
    con.puts("\n");

    const rsdp = findRsdp(st);
    con.puts("rsdp ");
    con.putHex(rsdp);
    con.puts("\n");

    // -- 4. memory map + exit boot services -----------------------------------
    // Everything the kernel will see must be allocated *before* the final
    // GetMemoryMap: allocations change the map key.
    const info_mem = try bs.allocatePool(.loader_data, @sizeOf(protocol.Info));
    const info: *protocol.Info = @ptrCast(@alignCast(info_mem.ptr));

    const map_info = try bs.getMemoryMapInfo();
    const slack = 16;
    const raw_len = (map_info.len + slack) * map_info.descriptor_size;
    const raw_buf = try bs.allocatePool(.loader_data, raw_len);

    const entries_mem = try bs.allocatePool(.loader_data, (map_info.len + slack) * @sizeOf(protocol.MmapEntry));
    const entries: [*]protocol.MmapEntry = @ptrCast(@alignCast(entries_mem.ptr));

    con.puts("exiting boot services, jumping to kernel\n");

    var map = try bs.getMemoryMap(raw_buf);
    bs.exitBootServices(uefi.handle, map.info.key) catch {
        // The map may have changed under us; one retry is what the spec suggests.
        map = try bs.getMemoryMap(raw_buf);
        try bs.exitBootServices(uefi.handle, map.info.key);
    };

    // From here on: no boot services, no console.
    const count = translateMemoryMap(map, entries);

    info.* = .{
        .fb = fb,
        .mmap = @intFromPtr(entries),
        .mmap_count = count,
        .rsdp = rsdp,
        .kernel_phys_base = loaded.phys_base,
        .kernel_size = loaded.size,
        .initrd_addr = if (initrd) |rd| @intFromPtr(rd.ptr) else 0,
        .initrd_size = if (initrd) |rd| rd.len else 0,
        .firmware = .uefi,
    };

    // -- 5. go ------------------------------------------------------------------
    asm volatile ("cli");
    const entry: protocol.KernelEntry = @ptrFromInt(loaded.entry);
    entry(info);
}

fn readFile(bs: *uefi.tables.BootServices, path: [*:0]const u16) ![]align(8) u8 {
    const loaded_image = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse
        return error.NoLoadedImage;
    const device = loaded_image.device_handle orelse return error.NoDeviceHandle;
    const fs = (try bs.handleProtocol(uefi.protocol.SimpleFileSystem, device)) orelse
        return error.NoFileSystem;

    const root = try fs.openVolume();
    defer root.close() catch {};
    const file = try root.open(path, .read, .{});
    defer file.close() catch {};

    const info_size = try file.getInfoSize(.file);
    const info_buf = try bs.allocatePool(.loader_data, info_size);
    defer bs.freePool(info_buf.ptr) catch {};
    const finfo = try file.getInfo(.file, info_buf);
    const size: usize = @intCast(finfo.file_size);
    if (size == 0) return error.EmptyFile;

    const buf = try bs.allocatePool(.loader_data, size);
    var done: usize = 0;
    while (done < size) {
        const n = try file.read(buf[done..]);
        if (n == 0) return error.ShortRead;
        done += n;
    }
    return buf;
}

fn setupFramebuffer(bs: *uefi.tables.BootServices) !protocol.Framebuffer {
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse
        return error.NoGraphicsOutput;

    // Prefer a fixed, comfortable mode if the firmware offers it.
    outer: for (preferred_modes) |want| {
        var mode_id: u32 = 0;
        while (mode_id < gop.mode.max_mode) : (mode_id += 1) {
            const m = gop.queryMode(mode_id) catch continue;
            if (m.horizontal_resolution == want[0] and
                m.vertical_resolution == want[1] and
                pixelShifts(m) != null)
            {
                if (mode_id != gop.mode.mode) try gop.setMode(mode_id);
                break :outer;
            }
        }
    }

    const m = gop.mode.info;
    const shifts = pixelShifts(m) orelse return error.UnsupportedPixelFormat;
    return .{
        .base = gop.mode.frame_buffer_base,
        .width = m.horizontal_resolution,
        .height = m.vertical_resolution,
        .pitch = m.pixels_per_scan_line * 4,
        .bpp = 32,
        .red_shift = shifts[0],
        .green_shift = shifts[1],
        .blue_shift = shifts[2],
    };
}

fn pixelShifts(m: *const uefi.protocol.GraphicsOutput.Mode.Info) ?[3]u8 {
    return switch (m.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .{ 0, 8, 16 },
        .blue_green_red_reserved_8_bit_per_color => .{ 16, 8, 0 },
        .bit_mask => blk: {
            const pi = m.pixel_information;
            if (pi.red_mask == 0 or pi.green_mask == 0 or pi.blue_mask == 0) break :blk null;
            break :blk .{ @ctz(pi.red_mask), @ctz(pi.green_mask), @ctz(pi.blue_mask) };
        },
        .blt_only => null,
    };
}

fn findRsdp(st: *uefi.tables.SystemTable) u64 {
    const Table = uefi.tables.ConfigurationTable;
    var rsdp10: u64 = 0;
    for (st.configuration_table[0..st.number_of_table_entries]) |t| {
        if (t.vendor_guid.eql(Table.acpi_20_table_guid)) return @intFromPtr(t.vendor_table);
        if (t.vendor_guid.eql(Table.acpi_10_table_guid)) rsdp10 = @intFromPtr(t.vendor_table);
    }
    return rsdp10;
}

fn translateType(t: uefi.tables.MemoryType) protocol.MemType {
    return switch (t) {
        .conventional_memory => .usable,
        .boot_services_code, .boot_services_data => .boot_services,
        .loader_code, .loader_data => .bootloader,
        .acpi_reclaim_memory => .acpi_reclaimable,
        .acpi_memory_nvs => .acpi_nvs,
        .unusable_memory => .bad,
        else => .reserved,
    };
}

/// Convert UEFI descriptors into protocol entries, merging adjacent runs of
/// the same type. Safe to call after ExitBootServices (no services used).
fn translateMemoryMap(map: uefi.tables.MemoryMapSlice, out: [*]protocol.MmapEntry) u64 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < map.info.len) : (i += 1) {
        const d = map.getUnchecked(i);
        const t = translateType(d.type);
        const base = d.physical_start;
        const len = d.number_of_pages * 4096;
        if (len == 0) continue;

        if (n > 0 and out[n - 1].type == t and out[n - 1].base + out[n - 1].length == base) {
            out[n - 1].length += len;
        } else {
            out[n] = .{ .base = base, .length = len, .type = t };
            n += 1;
        }
    }
    return n;
}
