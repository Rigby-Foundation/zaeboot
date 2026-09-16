# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Rigby Foundation
#
# Stage 2 glue: entry from stage 1, the protected-mode <-> real-mode
# trampoline for BIOS calls, and the jump into long mode.
#
# Stage 2 is loaded at 0x10000. The real-mode code lives in .text16, which
# the linker script places FIRST in the file but links at VMA 0: that way
# its 16-bit offsets are exactly what real-mode CS=0x1000 / the 16-bit
# protected-mode segments (base 0x10000) need, with no relocation tricks.
# 32-bit code must never use .text16 addresses without adding BASE.

.set BASE, 0x10000

# ---- .text16: entered at 0x10000 by stage 1 --------------------------------------
.section .text16, "ax"
.code32
        jmp     *(entry_ptr + BASE)     # first bytes of the image: hop to the 32-bit entry
entry_ptr: .long _start

.code16
# Arrive from bios_int via ljmp $0x18 (16-bit code segment, base 0x10000).
pm16:
        mov     $0x20, %ax              # 16-bit data segment, base 0
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     %ax, %fs
        mov     %ax, %gs
        mov     %cr0, %eax
        and     $0xFFFFFFFE, %eax
        mov     %eax, %cr0
        ljmp    $0x1000, $real
real:
        mov     $0x1000, %ax
        mov     %ax, %ds
        xor     %ax, %ax
        mov     %ax, %ss                # real-mode stack: 0000:7C00 downwards, ~30 KiB,
        mov     $0x7C00, %sp            # because real BIOSes (USB boot!) need far more than QEMU
        mov     %ax, %es
        lidt    ivt_ptr
        sti

        # Registers from the struct: eax edi esi ebx ecx edx es ds flags.
        # bios_int copied it into rm_regs (inside .text16, so ds=0x1000
        # reaches it with a plain 16-bit offset). No (%bp) addressing here:
        # in 16-bit code that implies SS, and the stack is a different segment.
        mov     rm_regs + 24, %ax
        mov     %ax, %es
        mov     rm_regs + 0, %eax
        mov     rm_regs + 4, %edi
        mov     rm_regs + 8, %esi
        mov     rm_regs + 12, %ebx
        mov     rm_regs + 16, %ecx
        mov     rm_regs + 20, %edx
        mov     rm_regs + 26, %bp
        test    %bp, %bp
        jz      1f
        mov     %bp, %ds
1:
int_opcode:
        int     $0x00
        mov     $0x1000, %bp
        mov     %bp, %ds
        mov     %eax, rm_regs + 0
        pushf
        pop     %ax
        mov     %ax, rm_regs + 28
        mov     %edi, rm_regs + 4
        mov     %esi, rm_regs + 8
        mov     %ebx, rm_regs + 12
        mov     %ecx, rm_regs + 16
        mov     %edx, rm_regs + 20
        mov     %es, rm_regs + 24

        cli
        lgdt    gdt_ptr16
        mov     %cr0, %eax
        or      $1, %eax
        mov     %eax, %cr0
        ljmpl   $0x08, $back32

.align 4
ivt_ptr:   .word 0x3FF
           .long 0
gdt_ptr16: .word 7 * 8 - 1
           .long gdt                    # flat address of the GDT in .data
.align 4
rm_regs:   .space 32                    # copy of the caller's struct bios_regs

# ---- 32-bit code --------------------------------------------------------------
.section .text.entry, "ax"
.code32
.globl _start
_start:
        mov     %edx, boot_drive
        lgdt    gdt_ptr                 # our own GDT (adds 16-bit and 64-bit segments)
        ljmp    $0x08, $1f
1:      mov     $0x10, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     %ax, %fs
        mov     %ax, %gs
        mov     $0x7F000, %esp
        # Stage 1 only copies the file: clear .bss ourselves. Real machines
        # boot with leftovers in RAM, and every counter in stage 2 lives here.
        mov     $__bss_start, %edi
        mov     $_end, %ecx
        sub     %edi, %ecx
        xor     %eax, %eax
        cld
        rep     stosb
        push    boot_drive
        call    stage2_main
2:      cli
        hlt
        jmp     2b

.section .text
.code32
# void bios_int(u8 vector, struct bios_regs *regs)
.globl bios_int
bios_int:
        pusha
        mov     36(%esp), %eax          # vector
        mov     %al, int_opcode + 1 + BASE
        mov     40(%esp), %esi          # regs (flat): copy into rm_regs
        mov     $(rm_regs + BASE), %edi
        mov     $8, %ecx
        rep     movsl
        mov     %esp, saved_esp
        cli
        ljmp    $0x18, $pm16            # .text16 offsets are exactly the 16-bit segment offsets
back32:
        mov     $0x10, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        mov     %ax, %fs
        mov     %ax, %gs
        mov     saved_esp, %esp
        mov     $(rm_regs + BASE), %esi # copy the results back
        mov     40(%esp), %edi
        mov     $8, %ecx
        rep     movsl
        popa
        ret

# void enter_long_mode(u32 pml4, u32 entry_lo, u32 entry_hi, u32 info) -- never returns
.globl enter_long_mode
enter_long_mode:
        cli
        mov     4(%esp), %eax
        mov     %eax, %cr3
        mov     8(%esp), %esi           # entry (kernel lives below 4 GiB)
        mov     16(%esp), %edi          # boot info

        mov     %cr4, %eax
        or      $(1 << 5), %eax         # PAE
        mov     %eax, %cr4
        mov     $0xC0000080, %ecx       # EFER: LME | NXE
        rdmsr
        or      $((1 << 8) | (1 << 11)), %eax
        wrmsr
        mov     %cr0, %eax
        or      $0x80000001, %eax
        mov     %eax, %cr0
        lgdt    gdt64_ptr
        ljmp    $0x28, $lm64
.code64
lm64:
        mov     $0x30, %ax
        mov     %ax, %ds
        mov     %ax, %es
        mov     %ax, %ss
        xor     %ax, %ax
        mov     %ax, %fs
        mov     %ax, %gs
        mov     $0x7F000, %rsp
        mov     %edi, %edi              # zero-extend: info pointer -> arg 0
        mov     %esi, %esi
        mov     %rsi, %rax
        jmp     *%rax

.section .data
.align 8
gdt:    .quad 0
        .quad 0x00CF9A000000FFFF        # 0x08: 32-bit code, flat
        .quad 0x00CF92000000FFFF        # 0x10: 32-bit data, flat
        .quad 0x00009A010000FFFF        # 0x18: 16-bit code, base 0x10000, limit 64K
        .quad 0x000092000000FFFF        # 0x20: 16-bit data, base 0, limit 64K
        .quad 0x00209A0000000000        # 0x28: 64-bit code
        .quad 0x0000920000000000        # 0x30: 64-bit data
gdt_ptr:
        .word gdt_ptr - gdt - 1
        .long gdt
gdt64_ptr:
        .word gdt_ptr - gdt - 1
        .long gdt
        .long 0
saved_esp:  .long 0
boot_drive: .long 0
