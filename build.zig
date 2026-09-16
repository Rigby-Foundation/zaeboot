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

    // Two raw disk images for NVMe controllers, created on first use: one the
    // kernel formats with zaefs, one it formats with FAT.
    // ...plus a 256 MiB blank SATA disk to try `sicinstall /dev/sdX` on.
    const mkdisk = b.addSystemCommand(&.{ "sh", "-c", "[ -f zig-out/disk.img ] || dd if=/dev/zero of=zig-out/disk.img bs=1M count=64 status=none; [ -f zig-out/fat.img ] || dd if=/dev/zero of=zig-out/fat.img bs=1M count=64 status=none; [ -f zig-out/sata.img ] || dd if=/dev/zero of=zig-out/sata.img bs=1M count=256 status=none" });
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
        "-drive",    "format=raw,file=zig-out/fat.img,if=none,id=nvm1",
        "-device",   "nvme,serial=sic1,drive=nvm1",
        "-drive",    "format=raw,file=zig-out/sata.img,if=ide",
        "-netdev",   "user,id=n0,hostfwd=tcp::8080-:80",
        "-device",   "e1000,netdev=n0",
        "-serial",   "stdio",
        "-no-reboot",
    });
    qemu.step.dependOn(&mkdisk.step);
    if (b.args) |args| qemu.addArgs(args);

    const run = b.step("run", "Boot the loader + kernel in QEMU (OVMF)");
    run.dependOn(&qemu.step);

    // ---- legacy BIOS -----------------------------------------------------------------
    // stage 1 (MBR) and stage 2 (32-bit protected mode) are flat binaries;
    // mkimage lays them out with the kernel and initrd in a raw disk image.
    const bios_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.i686 },
    });

    const stage1 = b.addExecutable(.{
        .name = "stage1",
        .root_module = b.createModule(.{
            .target = bios_target,
            .optimize = .ReleaseSmall,
            .pic = false,
        }),
    });
    stage1.root_module.addAssemblyFile(b.path("src/bios/stage1.s"));
    stage1.setLinkerScript(b.path("src/bios/stage1.ld"));
    const stage1_bin = stage1.addObjCopy(.{ .format = .bin, .basename = "stage1.bin" });

    const stage2 = b.addExecutable(.{
        .name = "stage2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bios/stage2.zig"),
            .target = bios_target,
            .optimize = .ReleaseSmall,
            .pic = false,
            .strip = true,
        }),
    });
    stage2.root_module.addImport("protocol", b.createModule(.{ .root_source_file = b.path("src/protocol.zig"), .target = bios_target, .optimize = .ReleaseSmall }));
    stage2.root_module.addAssemblyFile(b.path("src/bios/bios.s"));
    stage2.setLinkerScript(b.path("src/bios/stage2.ld"));
    const stage2_bin = stage2.addObjCopy(.{ .format = .bin, .basename = "stage2.bin" });

    const mkimage = b.addExecutable(.{
        .name = "mkimage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkimage.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const mk = b.addRunArtifact(mkimage);
    mk.addFileArg(stage1_bin.getOutput());
    mk.addFileArg(stage2_bin.getOutput());
    mk.addFileArg(.{ .cwd_relative = kernel });
    mk.addFileArg(.{ .cwd_relative = initrd });
    const image = mk.addOutputFileArg("zaeboot-bios.img");
    const install_img = b.addInstallFile(image, "bios/zaeboot-bios.img");

    const bios = b.step("bios", "Build the legacy BIOS disk image (zig-out/bios/zaeboot-bios.img)");
    bios.dependOn(&install_img.step);

    // `zig build sysroot`: the loader binaries the installer needs, into
    // $SYSROOT/boot/zaeboot/ (ZAE packs that directory into the initrd).
    const sr_efi = b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = "sysroot-boot" }, "BOOTX64.EFI");
    const sr_s1 = b.addInstallFileWithDir(stage1_bin.getOutput(), .{ .custom = "sysroot-boot" }, "stage1.bin");
    const sr_s2 = b.addInstallFileWithDir(stage2_bin.getOutput(), .{ .custom = "sysroot-boot" }, "stage2.bin");
    const copy = b.addSystemCommand(&.{ "sh", "-c", b.fmt("mkdir -p '{s}/boot/zaeboot' && cp zig-out/sysroot-boot/* '{s}/boot/zaeboot/'", .{ sysroot, sysroot }) });
    copy.step.dependOn(&sr_efi.step);
    copy.step.dependOn(&sr_s1.step);
    copy.step.dependOn(&sr_s2.step);
    const sysroot_step = b.step("sysroot", "Install BOOTX64.EFI, stage1.bin, stage2.bin into $SIC_SYSROOT/boot/zaeboot");
    sysroot_step.dependOn(&copy.step);

    const qemu_bios = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-machine",  "q35",
        "-m",        "512M",
        "-smp",      "2",
        "-drive",    "format=raw,file=zig-out/bios/zaeboot-bios.img",
        "-drive",    "format=raw,file=zig-out/disk.img,if=none,id=nvm",
        "-device",   "nvme,serial=sic0,drive=nvm",
        "-drive",    "format=raw,file=zig-out/fat.img,if=none,id=nvm1",
        "-device",   "nvme,serial=sic1,drive=nvm1",
        "-drive",    "format=raw,file=zig-out/sata.img,if=ide",
        "-netdev",   "user,id=n0,hostfwd=tcp::8080-:80",
        "-device",   "e1000,netdev=n0",
        "-serial",   "stdio",
        "-no-reboot",
    });
    qemu_bios.step.dependOn(&install_img.step);
    qemu_bios.step.dependOn(&mkdisk.step);
    if (b.args) |args| qemu_bios.addArgs(args);
    const run_bios = b.step("run-bios", "Boot the BIOS image in QEMU (SeaBIOS)");
    run_bios.dependOn(&qemu_bios.step);

    // Boot the disk sicinstall wrote (zig-out/sata.img) as the only disk.
    inline for (.{ .{ "run-installed", "Boot the installed SATA disk with OVMF", true }, .{ "run-installed-bios", "Boot the installed SATA disk with SeaBIOS", false } }) |v| {
        const cmd = b.addSystemCommand(&.{ "qemu-system-x86_64", "-machine", "q35", "-m", "512M", "-smp", "2" });
        if (v[2]) cmd.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf}) });
        cmd.addArgs(&.{ "-drive", "format=raw,file=zig-out/sata.img,if=ide", "-netdev", "user,id=n0,hostfwd=tcp::8080-:80", "-device", "e1000,netdev=n0", "-serial", "stdio", "-no-reboot" });
        if (b.args) |args| cmd.addArgs(args);
        b.step(v[0], v[1]).dependOn(&cmd.step);
    }
}
