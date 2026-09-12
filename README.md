# zaeboot

A UEFI bootloader written in Zig for the [sic](https://github.com/Rigby-Foundation/sic) kernel.

Boot sequence (`src/main.zig`):

1. Read `\sic.elf` (and `\initrd.tar` if present) from the EFI System Partition the
   loader started from
2. Parse the ELF64 and copy `PT_LOAD` segments to their physical addresses (`src/elf.zig`)
3. Pick a GOP framebuffer mode (1024x768 if available) and find the ACPI RSDP
4. Fetch the UEFI memory map, `ExitBootServices`, translate the map into the
   protocol's simple entry format
5. Jump to the kernel entry (System V ABI) with a `protocol.Info` pointer in `RDI`

The boot protocol lives in `src/protocol.zig` and mirrors `sic/include/zaeboot.h`.

## Building

Zig 0.16.

```bash
zig build            # zig-out/bin/BOOTX64.efi
zig build esp        # stage zig-out/esp/{EFI/BOOT/BOOTX64.EFI,sic.elf}
zig build run        # boot the staged ESP in QEMU with OVMF, 2 vCPUs
```

`zig build run` also attaches a 64 MiB NVMe disk (`zig-out/disk.img`, created
empty on first use) that sic formats with zaefs and mounts on `/disk`.

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
