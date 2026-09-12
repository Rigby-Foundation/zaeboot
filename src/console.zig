// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 Rigby Foundation
//! Minimal text output over the UEFI SimpleTextOutput protocol.
//! No std.fmt here: keeps the loader small and avoids allocations.

const uefi = @import("std").os.uefi;

var out: ?*uefi.protocol.SimpleTextOutput = null;

pub fn init() void {
    out = uefi.system_table.con_out;
    if (out) |o| {
        o.reset(false) catch {};
        o.clearScreen() catch {};
    }
}

fn emit(buf: [:0]const u16) void {
    const o = out orelse return;
    _ = o.outputString(buf.ptr) catch false;
}

pub fn puts(s: []const u8) void {
    var buf: [128:0]u16 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (n + 2 >= buf.len) {
            buf[n] = 0;
            emit(buf[0..n :0]);
            n = 0;
        }
        if (c == '\n') {
            buf[n] = '\r';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    buf[n] = 0;
    emit(buf[0..n :0]);
}

pub fn putHex(v: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        buf[2 + i] = digits[@intCast((v >> shift) & 0xF)];
    }
    puts(&buf);
}

pub fn putDec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var x = v;
    if (x == 0) {
        puts("0");
        return;
    }
    while (x > 0) : (x /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + x % 10);
    }
    puts(buf[i..]);
}

pub fn putErr(err: anyerror) void {
    puts(@errorName(err));
}
