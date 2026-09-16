/* SPDX-License-Identifier: GPL-2.0-only */
/* Copyright (C) 2026 Rigby Foundation */
ENTRY(_start)
SECTIONS
{
    . = 0x7C00;
    .text : { *(.text) *(.data) }
    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) *(.debug*) }
}
