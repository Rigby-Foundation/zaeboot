# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Rigby Foundation
#
# zaeboot legacy BIOS stage 1: the boot code of the MBR (446 bytes; the
# partition table at 446..509 is left to whoever owns the disk). Loads stage 2
# from STAGE2_LBA (default 1) to 0x10000 with INT 13h extensions, enables A20,
# enters 32-bit protected mode and jumps to stage 2 with the boot drive in DL.
# tools/mkimage and the installer patch stage2_lba (offset 432) and
# stage2_sectors (offset 436).

.code16
.section .text
.globl _start
_start:
        cli
        xor     %ax, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     $0x7C00, %sp
        sti
        mov     %dl, boot_drive

        mov     $msg, %si
        call    puts

        # Progress markers: "zaeboot 1" ext check, "2" loaded, "3" A20, "4" -> pm.
        # INT 13h extensions present?
        mov     $0x41, %ah
        mov     $0x55AA, %bx
        mov     boot_drive, %dl
        int     $0x13
        jc      fail
        cmp     $0xAA55, %bx
        jne     fail
        mov     $'1', %al
        call    putc

        # Load stage 2 in chunks of up to 64 sectors (32 KiB) to 0x1000:0000...
        movw    stage2_sectors, %cx     # remaining sectors
        movl    stage2_lba, %eax
        movl    %eax, dap_lba
        movw    $0x1000, dap_seg
1:
        test    %cx, %cx
        jz      loaded
        mov     %cx, %ax
        cmp     $64, %ax
        jbe     2f
        mov     $64, %ax
2:      movw    %ax, dap_count
        push    %ax
        mov     $0x42, %ah
        mov     boot_drive, %dl
        mov     $dap, %si
        int     $0x13
        jc      fail
        pop     %ax
        sub     %ax, %cx
        addl    %eax, dap_lba
        shl     $5, %ax                 # sectors * 512 / 16 = segment increment
        addw    %ax, dap_seg
        jmp     1b

loaded:
        mov     $'2', %al
        call    putc

        # A20: usually already on (USB/modern BIOS). Test before touching
        # anything: the fast gate first, the BIOS call only as a last resort
        # (INT 15h 2401 hangs some firmware).
        call    a20_test
        jnz     a20_done
        in      $0x92, %al
        test    $2, %al
        jnz     1f
        or      $2, %al
        and     $0xFE, %al
        out     %al, $0x92
1:      call    a20_test
        jnz     a20_done
        mov     $0x2401, %ax
        int     $0x15
        call    a20_test
        jnz     a20_done
        mov     $errA20, %si
        call    puts
        jmp     halt
a20_done:
        mov     $'3', %al
        call    putc

        cli
        lgdt    gdt_ptr
        mov     %cr0, %eax
        or      $1, %eax
        mov     %eax, %cr0
        ljmp    $0x08, $pm32

fail:
        mov     $err, %si
        call    puts
halt:   hlt
        jmp     halt

puts:   lodsb
        test    %al, %al
        jz      4f
        call    putc
        jmp     puts
4:      ret
putc:   mov     $0x0E, %ah
        mov     $7, %bx
        int     $0x10
        ret

# ZF clear if A20 is enabled: 0000:0500 and FFFF:0510 must not alias.
a20_test:
        push    %ds
        push    %es
        xor     %ax, %ax
        mov     %ax, %ds
        mov     $0xFFFF, %ax
        mov     %ax, %es
        movb    $0x00, 0x500
        movb    $0xFF, %es:0x510
        cmpb    $0xFF, 0x500
        pop     %es
        pop     %ds
        ret                             # ZF set = aliased = A20 off

.code32
pm32:
        mov     $0x10, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     %ax, %fs
        mov     %ax, %gs
        mov     $0x7C00, %esp
        movzbl  boot_drive, %edx
        ljmp    $0x08, $0x10000

.align 8
gdt:    .quad 0
        .quad 0x00CF9A000000FFFF        # 0x08: 32-bit code, flat
        .quad 0x00CF92000000FFFF        # 0x10: 32-bit data, flat
gdt_ptr:
        .word gdt_ptr - gdt - 1
        .long gdt

dap:    .byte 0x10, 0
dap_count: .word 0
        .word 0                         # offset
dap_seg:   .word 0
dap_lba:   .quad 0

boot_drive: .byte 0
msg:    .asciz "zaeboot "
err:    .asciz " disk error\r\n"
errA20: .asciz " A20 failed\r\n"

.org 432
.globl stage2_lba, stage2_sectors
stage2_lba:     .long 1                 # patched by mkimage / the installer
stage2_sectors: .word 0
.org 440
.long 0                                 # disk signature
.word 0
.org 446                                # partition table (4 x 16 bytes)
.skip 64
.word 0xAA55
