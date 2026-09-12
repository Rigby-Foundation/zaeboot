// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // The kernel and initrd come from the sysroot the other projects install
    // into ($SIC_SYSROOT, default ~/.sic/sysroot), unless given explicitly.
    const sysroot = b.graph.environ_map.get("SIC_SYSROOT") orelse
        b.pathJoin(&.{ b.graph.environ_map.get("HOME") orelse ".", ".sic", "sysroot" });
    const kernel = b.option([]const u8, "kernel", "Kernel ELF to stage on the ESP") orelse
        b.pathJoin(&.{ sysroot, "boot", "sic.elf" });
    const initrd = b.option([]const u8, "initrd", "initrd tarball to stage on the ESP") orelse
        b.pathJoin(&.{ sysroot, "boot", "initrd.tar" });
    const ovmf = b.option([]const u8, "ovmf", "OVMF firmware image for `zig build run`") orelse
        "/opt/homebrew/share/qemu/edk2-x86_64-code.fd";

    const exe = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Stage a bootable ESP directory tree under zig-out/esp:
    //   EFI/BOOT/BOOTX64.EFI  (this loader, the default removable-media path)
    //   sic.elf               (the kernel)
    //   initrd.tar            (USTAR ramdisk with the user programs)
    const esp_loader = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "esp/EFI/BOOT" } },
        .dest_sub_path = "BOOTX64.EFI",
    });
    const esp_kernel = b.addInstallFile(.{ .cwd_relative = kernel }, "esp/sic.elf");
    const esp_initrd = b.addInstallFile(.{ .cwd_relative = initrd }, "esp/initrd.tar");

    const esp = b.step("esp", "Stage the ESP directory (zig-out/esp)");
    esp.dependOn(&esp_loader.step);
    esp.dependOn(&esp_kernel.step);
    esp.dependOn(&esp_initrd.step);

    // A 64 MiB raw disk image for the NVMe controller, created on first use.
    const mkdisk = b.addSystemCommand(&.{ "sh", "-c", "[ -f zig-out/disk.img ] || dd if=/dev/zero of=zig-out/disk.img bs=1M count=64 status=none" });
    mkdisk.step.dependOn(esp);

    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-machine",  "q35",
        "-m",        "512M",
        "-smp",      "2",
        "-drive",    b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}),
        "-drive",    "format=raw,file=fat:rw:zig-out/esp",
        "-drive",    "format=raw,file=zig-out/disk.img,if=none,id=nvm",
        "-device",   "nvme,serial=sic0,drive=nvm",
        "-net",      "none",
        "-serial",   "stdio",
        "-no-reboot",
    });
    qemu.step.dependOn(&mkdisk.step);
    if (b.args) |args| qemu.addArgs(args);

    const run = b.step("run", "Boot the loader + kernel in QEMU (OVMF)");
    run.dependOn(&qemu.step);
}
