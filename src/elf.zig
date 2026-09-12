// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! ELF64 loader: copies PT_LOAD segments of a static x86_64 executable to
//! their physical addresses.

const std = @import("std");
const uefi = std.os.uefi;
const con = @import("console.zig");

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
    @"align": u64,
};

const PT_LOAD = 1;
const EM_X86_64 = 62;
const ET_EXEC = 2;

pub const Loaded = struct {
    entry: u64,
    phys_base: u64,
    size: u64,
};

pub const Error = error{
    NotElf,
    NotX86_64,
    NotExecutable,
    NoLoadableSegments,
    Truncated,
} || uefi.tables.BootServices.AllocatePagesError;

fn phdrs(image: []const u8, hdr: *const Ehdr) Error![]const Phdr {
    if (hdr.phentsize != @sizeOf(Phdr)) return error.NotElf;
    const end = hdr.phoff + @as(u64, hdr.phnum) * @sizeOf(Phdr);
    if (end > image.len) return error.Truncated;
    const p: [*]const Phdr = @ptrCast(@alignCast(image.ptr + hdr.phoff));
    return p[0..hdr.phnum];
}

pub fn load(bs: *uefi.tables.BootServices, image: []align(8) const u8) Error!Loaded {
    if (image.len < @sizeOf(Ehdr)) return error.NotElf;
    const hdr: *const Ehdr = @ptrCast(@alignCast(image.ptr));

    if (!std.mem.eql(u8, hdr.ident[0..4], "\x7fELF")) return error.NotElf;
    if (hdr.ident[4] != 2) return error.NotX86_64; // ELFCLASS64
    if (hdr.machine != EM_X86_64) return error.NotX86_64;
    if (hdr.type != ET_EXEC) return error.NotExecutable;

    const segs = try phdrs(image, hdr);

    // Physical extent of everything we need to place.
    var lo: u64 = std.math.maxInt(u64);
    var hi: u64 = 0;
    for (segs) |ph| {
        if (ph.type != PT_LOAD or ph.memsz == 0) continue;
        if (ph.offset + ph.filesz > image.len) return error.Truncated;
        lo = @min(lo, ph.paddr);
        hi = @max(hi, ph.paddr + ph.memsz);
    }
    if (hi == 0) return error.NoLoadableSegments;

    const page = 4096;
    const base = lo & ~@as(u64, page - 1);
    const top = (hi + page - 1) & ~@as(u64, page - 1);
    const npages: usize = @intCast((top - base) / page);

    con.puts("  placing kernel at ");
    con.putHex(base);
    con.puts(" (");
    con.putDec(npages);
    con.puts(" pages)\n");

    const pages = try bs.allocatePages(
        .{ .address = @ptrFromInt(base) },
        .loader_data,
        npages,
    );
    const dst: [*]u8 = @ptrCast(pages.ptr);
    @memset(dst[0 .. npages * page], 0);

    for (segs) |ph| {
        if (ph.type != PT_LOAD or ph.memsz == 0) continue;
        const d = dst[ph.paddr - base ..][0..ph.filesz];
        @memcpy(d, image[ph.offset..][0..ph.filesz]);
    }

    return .{ .entry = hdr.entry, .phys_base = base, .size = top - base };
}
