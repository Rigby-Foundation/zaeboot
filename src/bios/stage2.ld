/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (C) 2026 Rigby Foundation */
/* Stage 2: a flat binary loaded at 0x10000. .text16 (real-mode code and the
 * data it touches) comes first in the file but is linked at VMA 0, see bios.s. */
ENTRY(_start)
SECTIONS
{
    . = 0;
    .text16 : AT(0x10000) { KEEP(*(.text16)) }
    . = 0x10000 + SIZEOF(.text16);
    .text : AT(ADDR(.text)) { KEEP(*(.text.entry)) *(.text .text.*) }
    .rodata : AT(ADDR(.rodata)) { *(.rodata .rodata.*) }
    .data : AT(ADDR(.data)) { *(.data .data.*) }
    __bss_start = .;
    .bss : AT(ADDR(.bss)) { *(COMMON) *(.bss .bss.*) }
    _end = .;
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) *(.debug*) }
}
