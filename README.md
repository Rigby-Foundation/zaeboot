# zaeboot

A bootloader written in Zig for the [sic](https://github.com/Rigby-Foundation/sic)
kernel, for UEFI and legacy BIOS machines. Both paths hand the kernel the same
boot info (`src/protocol.zig`).

## UEFI

Boot sequence (`src/main.zig`):

1. Read `\sic.elf` (and `\initrd.tar` if present) from the EFI System Partition the
   loader started from
2. Parse the ELF64 and copy `PT_LOAD` segments to their physical addresses (`src/elf.zig`)
3. Pick a GOP framebuffer mode (1024x768 if available) and find the ACPI RSDP
4. Fetch the UEFI memory map, `ExitBootServices`, translate the map into the
   protocol's simple entry format
5. Jump to the kernel entry (System V ABI) with a `protocol.Info` pointer in `RDI`

The boot protocol lives in `src/protocol.zig` and mirrors `sic/include/zaeboot.h`.

## Legacy BIOS

`src/bios/`: stage 1 (`stage1.s`) is the 512-byte MBR: it loads stage 2 from
the sectors after it with INT 13h, enables A20 and enters protected mode.
Stage 2 (`stage2.zig`, 32-bit, ~7 KiB) does the real work in Zig, reaching
the BIOS through a protected↔real mode trampoline (`bios.s`): E820 memory
map, VBE framebuffer (32 bpp, largest of 1280x1024/1280x800/1024x768/800x600),
ACPI RSDP scan, then loads the kernel ELF and the initrd from fixed LBAs,
identity-maps 4 GiB and jumps into long mode.

`tools/mkimage.zig` produces a raw disk image for QEMU: MBR, stage 2, kernel,
initrd, with the LBAs patched into stage 2's image table. On a real disk the
same stages live inside a GPT layout written by ZAE's `sicinstall` (stage 1 in
the protective MBR, stage 2 at LBA 34, kernel + initrd in a raw `sicboot`
partition), so one disk boots on both firmwares.

On real firmware the BIOS path narrates itself: stage 1 prints `zaeboot 1 2 3`
(INT 13h extensions, stage 2 loaded, A20), stage 2 prints each step with one
dot per MiB read, re-enables A20 if the BIOS turned it off during disk calls,
and mirrors everything to COM1 (115200 8N1). Typing `v` during the load skips
VBE mode setting for firmware whose video BIOS misbehaves.

```bash
zig build bios        # zig-out/bios/zaeboot-bios.img
zig build run-bios    # boot it in QEMU with SeaBIOS
```

## Building

Zig 0.16.

```bash
zig build            # zig-out/bin/BOOTX64.efi
zig build esp        # stage zig-out/esp/{EFI/BOOT/BOOTX64.EFI,sic.elf}
zig build run        # boot the staged ESP in QEMU with OVMF, 2 vCPUs
zig build run-bios   # boot the BIOS disk image in QEMU with SeaBIOS
zig build sysroot    # install BOOTX64.EFI, stage1.bin, stage2.bin into $SIC_SYSROOT/boot/zaeboot
                     # (ZAE packs them into the initrd for sicinstall)
zig build run-installed[-bios]   # boot zig-out/sata.img, the disk sicinstall wrote in QEMU
```

`zig build run` also attaches two 64 MiB NVMe disks (`zig-out/disk.img`,
`zig-out/fat.img`, created empty on first use): sic formats the first with zaefs
and mounts it on `/disk`; the self test formats the second with FAT32.

By default the kernel and initrd are taken from the sysroot the other sic
projects install into (`$SIC_SYSROOT/boot/{sic.elf,initrd.tar}`, default
`~/.sic/sysroot`). Options: `-Dkernel=path/to/kernel.elf`,
`-Dinitrd=path/to/initrd.tar` and
`-Dovmf=path/to/OVMF_CODE.fd` (default is Homebrew QEMU's bundled
`edk2-x86_64-code.fd`). Extra `zig build run -- ...` arguments are passed to QEMU.

`zig-out/esp` is a plain directory; copy its contents to the root of any
FAT-formatted ESP to boot on real UEFI hardware.

## Contributing

Patches need a `Signed-off-by:` line (DCO 1.1). Read
[CODE_OF_CONFLICT](./CODE_OF_CONFLICT) and [CONTRIBUTING](./CONTRIBUTING).

## License

Copyright (C) 2026 Rigby Foundation. Licensed under the GNU General Public
License, version 2 only (`SPDX-License-Identifier: GPL-2.0-only`); see
`LICENSE`. Every source file carries an SPDX tag.
