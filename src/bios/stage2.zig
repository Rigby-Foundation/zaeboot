// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! zaeboot legacy BIOS stage 2. Runs in 32-bit protected mode at 0x10000,
//! loaded by stage1.s; BIOS services are reached through the real-mode
//! trampoline in bios.s. Loads the kernel ELF and the initrd from the raw
//! disk image (LBAs patched in by tools/mkimage), gathers the E820 memory
//! map, sets a VBE framebuffer mode, finds the ACPI RSDP, builds the same
//! boot info the UEFI loader does, and enters long mode.
const std = @import("std");
const protocol = @import("protocol");

// ---- fixed physical layout below 16 MiB (stage 2 itself is at 0x10000) ----
const bounce_addr: u32 = 0x30000; // 32 KiB disk bounce buffer (real-mode reachable)
const bounce_sectors: u32 = 64;
const page_tables: u32 = 0x40000; // PML4, PDPT, 4 PDs -> 0x46000
const info_addr: u32 = 0x50000; // boot info
const mmap_addr: u32 = 0x51000; // protocol mmap entries
const kernel_scratch: u32 = 0x100_0000; // the ELF file, before its segments are placed
const initrd_addr: u32 = 0x200_0000;

// ---- what mkimage patches -------------------------------------------------
const ImageTable = extern struct {
    magic: [8]u8 = "ZAEBIMG\x00".*,
    kernel_lba: u32 = 0,
    kernel_sectors: u32 = 0,
    initrd_lba: u32 = 0,
    initrd_sectors: u32 = 0,
};
export var image_table: ImageTable linksection(".data") = .{};

// ---- BIOS calls -----------------------------------------------------------
const BiosRegs = extern struct {
    eax: u32 = 0,
    edi: u32 = 0,
    esi: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    es: u16 = 0,
    ds: u16 = 0,
    flags: u32 = 0,
};
extern fn bios_int(vector: u8, regs: *BiosRegs) callconv(.c) void;
extern fn enter_long_mode(pml4: u32, entry_lo: u32, entry_hi: u32, info: u32) callconv(.c) noreturn;

const CF: u32 = 1;

// Real-mode segment:offset for an address inside stage 2 (segment 0x1000).
fn seg(addr: usize) u16 {
    return @intCast(addr >> 4);
}
fn off(addr: usize) u16 {
    return @intCast(addr & 0xF);
}

// ---- console: INT 10h teletype, mirrored to COM1 -------------------------------
fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "{dx}" (port),
    );
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}
var serial_ready = false;
var text_mode = true; // false once a VBE graphics mode is set: only serial then
fn serialInit() void {
    outb(0x3F9, 0);
    outb(0x3FB, 0x80);
    outb(0x3F8, 1);
    outb(0x3F9, 0);
    outb(0x3FB, 0x03);
    outb(0x3FA, 0xC7);
    outb(0x3FC, 0x0B);
    serial_ready = true;
}
fn putc(c: u8) void {
    if (serial_ready) {
        if (c == '\n') putc('\r');
        var spins: u32 = 0;
        while (inb(0x3FD) & 0x20 == 0 and spins < 100000) : (spins += 1) {}
        outb(0x3F8, c);
    }
    if (text_mode) vgaPutc(c);
}
fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

// Text output goes straight to VGA memory rather than through INT 10h: the
// teletype call is one more thing a real BIOS can get wrong (scrolling in
// particular), and stage 2 is 32-bit flat anyway. The cursor is picked up
// from and written back to the BIOS data area so stage 1's output and the
// BIOS stay in step.
fn vgaPutc(c: u8) void {
    const vram: [*]volatile u16 = @ptrFromInt(0xB8000);
    const cur: *volatile [2]u8 = @ptrFromInt(0x450); // BDA: column, row of page 0
    var col: usize = cur[0];
    var row: usize = cur[1];
    if (col >= 80) col = 0;
    if (row >= 25) row = 24;
    if (c == '\r') {
        col = 0;
    } else if (c == '\n') {
        col = 0;
        row += 1;
    } else {
        vram[row * 80 + col] = 0x0700 | @as(u16, c);
        col += 1;
        if (col == 80) {
            col = 0;
            row += 1;
        }
    }
    if (row == 25) {
        var i: usize = 0;
        while (i < 24 * 80) : (i += 1) vram[i] = vram[i + 80];
        while (i < 25 * 80) : (i += 1) vram[i] = 0x0720;
        row = 24;
    }
    cur[0] = @intCast(col);
    cur[1] = @intCast(row);
    const pos: u16 = @intCast(row * 80 + col);
    outb(0x3D4, 0x0F);
    outb(0x3D5, @truncate(pos));
    outb(0x3D4, 0x0E);
    outb(0x3D5, @truncate(pos >> 8));
}
fn putHex(v: u64) void {
    puts("0x");
    var i: u6 = 60;
    while (true) : (i -= 4) {
        putc("0123456789abcdef"[@intCast((v >> i) & 0xF)]);
        if (i == 0) break;
    }
}
fn putDec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var x = v;
    if (x == 0) {
        puts("0");
        return;
    }
    while (x > 0) : (x /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + x % 10);
    }
    puts(buf[i..]);
}
fn fatal(msg: []const u8) noreturn {
    puts("\nzaeboot: fatal: ");
    puts(msg);
    puts("\n");
    while (true) asm volatile ("cli; hlt");
}

// ---- disk -----------------------------------------------------------------------
const Dap = extern struct {
    size: u8 = 0x10,
    zero: u8 = 0,
    count: u16,
    offset: u16,
    segment: u16,
    lba: u64,
};
var dap: Dap align(4) = undefined;
var boot_drive: u8 = 0;

/// Read `count` sectors from `lba` to physical `dest` through the bounce buffer.
fn readSectors(lba: u64, count: u32, dest: u32) void {
    var done: u32 = 0;
    while (done < count) {
        const n: u32 = @min(count - done, bounce_sectors);
        dap = .{ .count = @intCast(n), .offset = 0, .segment = @intCast(bounce_addr >> 4), .lba = lba + done };
        var r = BiosRegs{ .eax = 0x4200, .edx = boot_drive, .esi = off(@intFromPtr(&dap)), .ds = seg(@intFromPtr(&dap)) };
        bios_int(0x13, &r);
        if (r.flags & CF != 0) {
            puts("  read failed at lba ");
            putDec(lba + done);
            fatal("disk read error");
        }
        const src: [*]const u8 = @ptrFromInt(bounce_addr);
        const dst: [*]u8 = @ptrFromInt(dest + done * 512);
        @memcpy(dst[0 .. n * 512], src[0 .. n * 512]);
        done += n;
        if (done % 2048 == 0) putc('.'); // one dot per MiB: shows how far a flaky BIOS got
    }
    if (a20Off()) {
        // Some BIOSes (USB legacy emulation in SMM) switch A20 off behind our
        // back during INT 13h. Everything above 1 MiB would alias without it.
        puts("\n  A20 was disabled by the BIOS, re-enabling");
        outb(0x92, (inb(0x92) | 2) & 0xFE);
        if (a20Off()) {
            var r = BiosRegs{ .eax = 0x2401 };
            bios_int(0x15, &r);
        }
        if (a20Off()) fatal("A20 could not be re-enabled");
        puts(" ok");
    }
    puts("\n");
}

/// A20 test without touching memory we care about: 0x2000 is free, and its
/// 1 MiB alias 0x102000 sits inside the placed kernel (or unused RAM before
/// it is loaded) - we only read that side.
fn a20Off() bool {
    const lo: *volatile u32 = @ptrFromInt(0x2000);
    const hi: *volatile u32 = @ptrFromInt(0x102000);
    const saved = lo.*;
    const probe = hi.* ^ 0xA5A5A5A5;
    lo.* = probe;
    const aliased = hi.* == probe;
    lo.* = saved;
    return aliased;
}

// ---- E820 memory map ------------------------------------------------------------
const E820 = extern struct { base: u64, len: u64, type: u32, attr: u32 };
var e820_buf: E820 align(4) = undefined;
var e820: [64]E820 = undefined;
var e820_count: usize = 0;

fn readE820() void {
    var cont: u32 = 0;
    var calls: u32 = 0;
    var rejected: u32 = 0;
    var first = BiosRegs{};
    var last = BiosRegs{};
    while (e820_count < e820.len and calls < 128) : (calls += 1) {
        var r = BiosRegs{
            .eax = 0xE820,
            .ebx = cont,
            .ecx = @sizeOf(E820),
            .edx = 0x534D4150, // "SMAP"
            .edi = off(@intFromPtr(&e820_buf)),
            .es = seg(@intFromPtr(&e820_buf)),
        };
        e820_buf = .{ .base = 0, .len = 0, .type = 0, .attr = 1 };
        bios_int(0x15, &r);
        if (calls == 0) first = r;
        last = r;
        if (r.flags & CF != 0 or r.eax != 0x534D4150) break;
        const valid = r.ecx >= 20 and e820_buf.len != 0 and e820_buf.type >= 1 and e820_buf.type <= 5 and
            (r.ecx < 24 or e820_buf.attr & 1 != 0);
        // a BIOS that hands back the same range forever: stop rather than fill up
        const repeat = e820_count > 0 and e820[e820_count - 1].base == e820_buf.base and e820[e820_count - 1].len == e820_buf.len;
        if (valid and !repeat) {
            e820[e820_count] = e820_buf;
            e820_count += 1;
        } else {
            rejected += 1;
            if (repeat) break;
        }
        cont = r.ebx;
        if (cont == 0) break;
    }
    puts("e820: ");
    putDec(e820_count);
    puts(" entries, ");
    putDec(rejected);
    puts(" rejected, ");
    putDec(calls);
    puts(" calls; first ax=");
    putHex(first.eax & 0xFFFF);
    puts(" bx=");
    putHex(first.ebx);
    puts(" cx=");
    putHex(first.ecx);
    puts(" fl=");
    putHex(first.flags & 0xFFFF);
    puts("\n");
    var shown: usize = 0;
    for (e820[0..e820_count]) |e| {
        if (shown == 6) { puts("  ...\n"); break; }
        shown += 1;
        puts("  ");
        putHex(e.base);
        putc(' ');
        putHex(e.len);
        puts(" type ");
        putDec(e.type);
        puts("\n");
    }
    if (ramCovers(kernel_scratch, 1) and ramCovers(initrd_addr, 1)) return;

    // E820 unusable: size memory with INT 15h E801 instead and synthesise a map.
    puts("e820 unusable (last ax=");
    putHex(last.eax & 0xFFFF);
    puts(" fl=");
    putHex(last.flags & 0xFFFF);
    puts("), trying E801: ");
    var r = BiosRegs{ .eax = 0xE801 };
    bios_int(0x15, &r);
    var low_kb: u32 = r.eax & 0xFFFF; // KiB from 1 MiB, up to 15 MiB
    var high_64k: u32 = r.ebx & 0xFFFF; // 64 KiB blocks from 16 MiB
    if (r.flags & CF != 0 or (low_kb == 0 and high_64k == 0)) {
        low_kb = r.ecx & 0xFFFF;
        high_64k = r.edx & 0xFFFF;
    }
    if (r.flags & CF != 0 or low_kb == 0) fatal("no usable memory map from the BIOS (E820 and E801 both failed)");
    putDec(low_kb);
    puts(" KiB + ");
    putDec(high_64k);
    puts(" x 64 KiB\n");
    e820_count = 0;
    e820[e820_count] = .{ .base = 0, .len = 0x9F000, .type = 1, .attr = 1 };
    e820_count += 1;
    e820[e820_count] = .{ .base = 0x9F000, .len = 0x100000 - 0x9F000, .type = 2, .attr = 1 };
    e820_count += 1;
    e820[e820_count] = .{ .base = 0x100000, .len = @as(u64, low_kb) * 1024, .type = 1, .attr = 1 };
    e820_count += 1;
    if (high_64k != 0) {
        e820[e820_count] = .{ .base = 0x1000000, .len = @as(u64, high_64k) * 65536, .type = 1, .attr = 1 };
        e820_count += 1;
    }
}

fn ramCovers(base: u64, len: u64) bool {
    for (e820[0..e820_count]) |e|
        if (e.type == 1 and e.base <= base and e.base + e.len >= base + len) return true;
    return false;
}

// ---- VBE framebuffer --------------------------------------------------------------
// Packed on the wire: no natural alignment, hence the u16 pairs.
const VbeInfo = extern struct {
    sig: [4]u8,
    version: u16,
    oem: [2]u16,
    caps: [2]u16,
    modes_off: u16, // far pointer to the mode list
    modes_seg: u16,
    memory: u16,
    rest: [512 - 20]u8,
};
const VbeMode = extern struct {
    attrs: u16,
    win: [14]u8,
    pitch: u16,
    width: u16,
    height: u16,
    chars: [2]u8,
    planes: u8,
    bpp: u8,
    banks: u8,
    model: u8,
    bank_size: u8,
    pages: u8,
    reserved0: u8,
    red_mask: u8,
    red_pos: u8,
    green_mask: u8,
    green_pos: u8,
    blue_mask: u8,
    blue_pos: u8,
    rsv_mask: u8,
    rsv_pos: u8,
    dcm: u8,
    framebuffer: u32,
    rest: [256 - 50]u8,
};
var vbe_info: VbeInfo align(4) = undefined;
var vbe_mode: VbeMode align(4) = undefined;

const preferred = [_][2]u16{ .{ 1280, 1024 }, .{ 1280, 800 }, .{ 1024, 768 }, .{ 800, 600 } };

var edid: [128]u8 align(4) = undefined;

/// The panel's native resolution from EDID (VBE/DDC), or null.
fn nativeResolution() ?[2]u16 {
    var r = BiosRegs{ .eax = 0x4F15, .ebx = 1, .ecx = 0, .edx = 0, .edi = off(@intFromPtr(&edid)), .es = seg(@intFromPtr(&edid)) };
    bios_int(0x10, &r);
    if (r.eax & 0xFFFF != 0x004F) return null;
    const magic = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    if (!std.mem.eql(u8, edid[0..8], &magic)) return null;
    const d = edid[54..72]; // first detailed timing descriptor
    if (d[0] == 0 and d[1] == 0) return null;
    const w: u16 = @as(u16, d[2]) | (@as(u16, d[4] >> 4) << 8);
    const h: u16 = @as(u16, d[5]) | (@as(u16, d[7] >> 4) << 8);
    if (w < 320 or h < 200 or w > 4096 or h > 4096) return null;
    return .{ w, h };
}

fn setupFramebuffer() protocol.Framebuffer {
    const none = protocol.Framebuffer{ .base = 0, .width = 0, .height = 0, .pitch = 0, .bpp = 0, .red_shift = 0, .green_shift = 0, .blue_shift = 0 };
    vbe_info.sig = "VBE2".*;
    puts("video: vbe info");
    var r = BiosRegs{ .eax = 0x4F00, .edi = off(@intFromPtr(&vbe_info)), .es = seg(@intFromPtr(&vbe_info)) };
    bios_int(0x10, &r);
    puts(", edid");
    if (r.eax & 0xFFFF != 0x004F) {
        puts("no VBE (ax="); putHex(r.eax); puts("): continuing without a framebuffer\n");
        return none;
    }
    const list: [*]const u16 = @ptrFromInt(@as(usize, vbe_info.modes_seg) * 16 + vbe_info.modes_off);

    const native = nativeResolution();
    puts(", modes\n");
    if (native) |n| {
        puts("panel: ");
        putDec(n[0]);
        putc('x');
        putDec(n[1]);
        puts("\n");
    }

    var best_mode: u16 = 0;
    var best_rank: usize = preferred.len + 1; // rank 0 = native panel resolution
    var i: usize = 0;
    while (i < 256 and list[i] != 0xFFFF) : (i += 1) {
        const mode = list[i];
        var q = BiosRegs{ .eax = 0x4F01, .ecx = mode, .edi = off(@intFromPtr(&vbe_mode)), .es = seg(@intFromPtr(&vbe_mode)) };
        bios_int(0x10, &q);
        if (q.eax & 0xFFFF != 0x004F) continue;
        if (vbe_mode.attrs & 0x80 == 0 or vbe_mode.bpp != 32 or vbe_mode.model != 6) continue;
        if (native) |n| if (vbe_mode.width == n[0] and vbe_mode.height == n[1] and best_rank > 0) {
            best_rank = 0;
            best_mode = mode;
        };
        for (preferred, 0..) |p, rank| {
            if (vbe_mode.width == p[0] and vbe_mode.height == p[1] and rank + 1 < best_rank) {
                best_rank = rank + 1;
                best_mode = mode;
            }
        }
    }
    if (best_mode == 0) {
        puts("no suitable VBE mode: continuing without a framebuffer\n");
        return none;
    }
    var q = BiosRegs{ .eax = 0x4F01, .ecx = best_mode, .edi = off(@intFromPtr(&vbe_mode)), .es = seg(@intFromPtr(&vbe_mode)) };
    bios_int(0x10, &q);
    const fb = protocol.Framebuffer{
        .base = vbe_mode.framebuffer,
        .width = vbe_mode.width,
        .height = vbe_mode.height,
        .pitch = vbe_mode.pitch,
        .bpp = 32,
        .red_shift = vbe_mode.red_pos,
        .green_shift = vbe_mode.green_pos,
        .blue_shift = vbe_mode.blue_pos,
    };
    puts("video: mode ");
    putHex(best_mode);
    puts(" ");
    putDec(vbe_mode.width);
    putc('x');
    putDec(vbe_mode.height);
    puts("\n");
    var s = BiosRegs{ .eax = 0x4F02, .ebx = @as(u32, best_mode) | 0x4000 };
    bios_int(0x10, &s);
    if (s.eax & 0xFFFF != 0x004F) return none;
    text_mode = false;
    return fb;
}

// ---- ACPI --------------------------------------------------------------------------
fn findRsdp() u64 {
    const ebda_seg: u16 = @as(*const u16, @ptrFromInt(0x40E)).*;
    const ranges = [_][2]u32{ .{ @as(u32, ebda_seg) << 4, (@as(u32, ebda_seg) << 4) + 1024 }, .{ 0xE0000, 0x100000 } };
    for (ranges) |rg| {
        var a = rg[0];
        while (a + 16 <= rg[1]) : (a += 16) {
            const p: [*]const u8 = @ptrFromInt(a);
            if (std.mem.eql(u8, p[0..8], "RSD PTR ")) {
                var sum: u8 = 0;
                for (p[0..20]) |b| sum +%= b;
                if (sum == 0) return a;
            }
        }
    }
    return 0;
}

// ---- ELF ------------------------------------------------------------------------------
const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};
const Phdr = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    alignment: u64,
};

const Loaded = struct { entry: u64, base: u64, size: u64 };

fn loadElf(image: [*]const u8, len: usize) Loaded {
    const eh: *const Ehdr = @ptrCast(@alignCast(image));
    if (len < @sizeOf(Ehdr) or !std.mem.eql(u8, eh.ident[0..4], "\x7fELF") or eh.ident[4] != 2 or eh.machine != 62)
        fatal("sic.elf is not an x86_64 ELF");
    const ph: [*]const Phdr = @ptrCast(@alignCast(image + @as(usize, @intCast(eh.phoff))));
    var lo: u64 = std.math.maxInt(u64);
    var hi: u64 = 0;
    for (ph[0..eh.phnum]) |p| {
        if (p.type != 1 or p.memsz == 0) continue;
        if (p.paddr + p.memsz > 0x100000000) fatal("kernel segment above 4 GiB");
        lo = @min(lo, p.paddr);
        hi = @max(hi, p.paddr + p.memsz);
    }
    if (hi == 0) fatal("kernel has no loadable segments");
    if (hi > kernel_scratch) fatal("kernel overlaps the loader's scratch area");
    for (ph[0..eh.phnum]) |p| {
        if (p.type != 1 or p.memsz == 0) continue;
        const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(p.paddr)));
        const filesz: usize = @intCast(p.filesz);
        const memsz: usize = @intCast(p.memsz);
        const offset: usize = @intCast(p.offset);
        @memcpy(dst[0..filesz], image[offset .. offset + filesz]);
        @memset(dst[filesz..memsz], 0);
    }
    const base = lo & ~@as(u64, 0xFFF);
    return .{ .entry = eh.entry, .base = base, .size = ((hi + 0xFFF) & ~@as(u64, 0xFFF)) - base };
}

// ---- memory map for the kernel ----------------------------------------------------------
var entries: [*]protocol.MmapEntry = @ptrFromInt(mmap_addr);
var nentries: usize = 0;

fn addEntry(base: u64, len: u64, t: protocol.MemType) void {
    if (len == 0 or nentries >= 200) return;
    entries[nentries] = .{ .base = base, .length = len, .type = t };
    nentries += 1;
}

const Carve = struct { base: u64, len: u64 };

/// Emit `base..base+len` of type `t`, cutting out the carve ranges as `bootloader`.
fn emitUsable(base: u64, len: u64, carves: []const Carve) void {
    var cur = base;
    const end = base + len;
    while (cur < end) {
        // next carve that starts at or after cur and overlaps
        var next_start: u64 = end;
        var next_end: u64 = end;
        for (carves) |c| {
            const cs = @max(c.base, cur);
            const ce = @min(c.base + c.len, end);
            if (cs < ce and cs < next_start) {
                next_start = cs;
                next_end = ce;
            }
        }
        if (next_start > cur) addEntry(cur, next_start - cur, .usable);
        if (next_start < end) addEntry(next_start, next_end - next_start, .bootloader);
        cur = next_end;
    }
}

fn buildMemoryMap(kernel: Loaded, initrd_len: u64) void {
    // Sort E820 by base (insertion sort; the list is short).
    var i: usize = 1;
    while (i < e820_count) : (i += 1) {
        const key = e820[i];
        var j = i;
        while (j > 0 and e820[j - 1].base > key.base) : (j -= 1) e820[j] = e820[j - 1];
        e820[j] = key;
    }
    const carves = [_]Carve{
        .{ .base = kernel.base, .len = kernel.size },
        .{ .base = kernel_scratch, .len = (@as(u64, image_table.kernel_sectors) * 512 + 0xFFF) & ~@as(u64, 0xFFF) },
        .{ .base = initrd_addr, .len = (initrd_len + 0xFFF) & ~@as(u64, 0xFFF) },
        .{ .base = 0, .len = 0x100000 }, // stage 2, page tables, boot info: all below 1 MiB
    };
    for (e820[0..e820_count]) |e| {
        const t: protocol.MemType = switch (e.type) {
            1 => .usable,
            3 => .acpi_reclaimable,
            4 => .acpi_nvs,
            5 => .bad,
            else => .reserved,
        };
        if (t == .usable) emitUsable(e.base, e.len, &carves) else addEntry(e.base, e.len, t);
    }
}

// ---- paging: identity-map the first 4 GiB with 2 MiB pages --------------------------------
fn buildPageTables() u32 {
    const pml4: [*]u64 = @ptrFromInt(page_tables);
    const pdpt: [*]u64 = @ptrFromInt(page_tables + 0x1000);
    @memset(pml4[0..512], 0);
    @memset(pdpt[0..512], 0);
    pml4[0] = (page_tables + 0x1000) | 3;
    var g: u32 = 0;
    while (g < 4) : (g += 1) {
        const pd_addr = page_tables + 0x2000 + g * 0x1000;
        const pd: [*]u64 = @ptrFromInt(pd_addr);
        pdpt[g] = pd_addr | 3;
        var e: u32 = 0;
        while (e < 512) : (e += 1)
            pd[e] = (@as(u64, g) << 30 | @as(u64, e) << 21) | 0x83;
    }
    return page_tables;
}

// ---- main ---------------------------------------------------------------------------------
export fn stage2_main(drive: u32) callconv(.c) noreturn {
    boot_drive = @intCast(drive & 0xFF);
    serialInit();
    puts("stage 2 (bios ticks ");
    putDec(@as(*const u32, @ptrFromInt(0x46C)).*); // BDA timer: grows across reboots, shows a reset loop
    puts(")\n");
    if (image_table.kernel_sectors == 0)
        fatal("image table not patched (build the image with mkimage)");

    readE820();
    const kernel_bytes: u64 = @as(u64, image_table.kernel_sectors) * 512;
    const initrd_bytes: u64 = @as(u64, image_table.initrd_sectors) * 512;
    if (!ramCovers(kernel_scratch, kernel_bytes)) fatal("no RAM at 16 MiB for the kernel image");
    if (initrd_bytes != 0 and !ramCovers(initrd_addr, initrd_bytes)) fatal("no RAM at 32 MiB for the initrd");

    puts("loading sic.elf (");
    putDec(kernel_bytes);
    puts(" bytes)");
    readSectors(image_table.kernel_lba, image_table.kernel_sectors, kernel_scratch);
    const kernel = loadElf(@ptrFromInt(kernel_scratch), @intCast(kernel_bytes));
    puts("  placed at ");
    putHex(kernel.base);
    puts(", entry ");
    putHex(kernel.entry);
    puts("\n");

    if (initrd_bytes != 0) {
        puts("loading initrd.tar (");
        putDec(initrd_bytes);
        puts(" bytes)");
        readSectors(image_table.initrd_lba, image_table.initrd_sectors, initrd_addr);
    }

    puts("acpi: ");
    const rsdp = findRsdp();
    putHex(rsdp);
    puts("\n");
    buildMemoryMap(kernel, initrd_bytes);
    puts("mmap: ");
    putDec(nentries);
    puts(" entries\n");
    // Escape hatch for firmware whose VBE calls misbehave: a 'v' typed during
    // the load skips mode setting and leaves the kernel on the serial console.
    // Read the BIOS keyboard buffer in the BDA directly rather than through
    // INT 16h: one BIOS call fewer to go wrong on odd firmware.
    var skip_video = false;
    {
        const head: u16 = @as(*const u16, @ptrFromInt(0x41A)).*;
        const tail: u16 = @as(*const u16, @ptrFromInt(0x41C)).*;
        var i = head;
        var steps: u32 = 0;
        while (i != tail and i >= 0x1E and i < 0x3E and steps < 16) : ({ i = if (i + 2 >= 0x3E) 0x1E else i + 2; steps += 1; }) {
            const ch = @as(*const u8, @ptrFromInt(0x400 + @as(usize, i))).*;
            if (ch == 'v' or ch == 'V') skip_video = true;
        }
    }
    const none_fb = protocol.Framebuffer{ .base = 0, .width = 0, .height = 0, .pitch = 0, .bpp = 0, .red_shift = 0, .green_shift = 0, .blue_shift = 0 };
    if (skip_video) puts("video: skipped ('v' pressed)\n");
    const fb = if (skip_video) none_fb else setupFramebuffer(); // last: the text console is gone after this

    const info: *protocol.Info = @ptrFromInt(info_addr);
    info.* = .{
        .fb = fb,
        .mmap = mmap_addr,
        .mmap_count = nentries,
        .rsdp = rsdp,
        .kernel_phys_base = kernel.base,
        .kernel_size = kernel.size,
        .initrd_addr = if (initrd_bytes != 0) initrd_addr else 0,
        .initrd_size = initrd_bytes,
        .firmware = .bios,
    };
    const pml4 = buildPageTables();
    enter_long_mode(pml4, @truncate(kernel.entry), @truncate(kernel.entry >> 32), info_addr);
}

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        fatal(msg);
    }
}.f);
