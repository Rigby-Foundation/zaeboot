// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! zaeboot -> kernel boot protocol.
//! Keep in sync with sic/include/zaeboot.h.

pub const magic: u64 = 0x00544F4F4245415A; // "ZAEBOOT\0"
pub const version: u32 = 3;

pub const MemType = enum(u32) {
    usable = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    acpi_nvs = 4,
    bootloader = 5,
    bad = 6,
    /// Firmware boot-services memory: free once the kernel no longer uses
    /// firmware page tables, stacks or anything else it left behind.
    boot_services = 7,
};

pub const MmapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemType,
    reserved: u32 = 0,
};

pub const Framebuffer = extern struct {
    base: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,
    reserved: [5]u8 = .{0} ** 5,
};

pub const Info = extern struct {
    magic: u64 = magic,
    version: u32 = version,
    size: u32 = @sizeOf(Info),

    fb: Framebuffer,

    mmap: u64,
    mmap_count: u64,

    rsdp: u64,

    kernel_phys_base: u64,
    kernel_size: u64,

    /// Optional initial ramdisk (`\initrd.tar`), 0/0 if absent. v2+.
    initrd_addr: u64 = 0,
    initrd_size: u64 = 0,
    /// Which firmware we came from. v3+.
    firmware: Firmware = .unknown,
    reserved: u32 = 0,
};

pub const Firmware = enum(u32) { unknown = 0, uefi = 1, bios = 2 };

/// Kernel entry point: System V ABI, boot info pointer in RDI, never returns.
pub const KernelEntry = *const fn (*Info) callconv(.{ .x86_64_sysv = .{} }) noreturn;

comptime {
    const std = @import("std");
    std.debug.assert(@sizeOf(MmapEntry) == 24);
    std.debug.assert(@sizeOf(Framebuffer) == 32);
    std.debug.assert(@sizeOf(Info) == 16 + 32 + 16 + 8 + 16 + 16 + 8);
}
