//! Passive is a termio backend with no subprocess and no pty. The terminal is
//! driven entirely by external bytes handed to `Termio.processOutput` (exposed
//! to the C API as `ghostty_surface_write`). This lets a host own the actual
//! I/O — e.g. an Android SSH client that supplies the received byte stream and
//! does its own input handling — while reusing Ghostty's terminal + renderer
//! unchanged.
//!
//! Bytes the terminal wants to "send to the pty" (encoded keystrokes) have no
//! pty to go to, so they're forwarded to an optional host `write_callback`. The
//! host must copy them synchronously; the buffer is invalid after the call.
const Passive = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_passive);

/// The callback invoked with bytes the terminal would normally write to the
/// pty. `callconv(.c)` so it can be supplied directly from the C API.
pub const WriteCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;

pub const Config = struct {
    write_callback: ?WriteCallback = null,
    userdata: ?*anyopaque = null,
};

write_callback: ?WriteCallback = null,
userdata: ?*anyopaque = null,

pub fn init(alloc: Allocator, cfg: Config) !Passive {
    _ = alloc;
    return .{ .write_callback = cfg.write_callback, .userdata = cfg.userdata };
}

pub fn deinit(self: *Passive) void {
    _ = self;
}

pub fn initTerminal(self: *Passive, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
}

pub fn threadEnter(
    self: *Passive,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .passive = .{} };
}

pub fn threadExit(self: *Passive, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Passive,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Passive,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    // The terminal itself is resized by Termio.resize before this is called;
    // there is no pty to notify.
    _ = self;
    _ = grid_size;
    _ = screen_size;
}

pub fn queueWrite(
    self: *Passive,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    const cb = self.write_callback orelse return;

    if (!linefeed) {
        cb(self.userdata, data.ptr, data.len);
        return;
    }

    // Replace \r with \r\n, chunked through a small stack buffer to match the
    // linefeed translation the exec backend applies before writing to the pty.
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < data.len) {
        var buf_i: usize = 0;
        while (i < data.len and buf_i < buf.len - 1) {
            const ch = data[i];
            i += 1;
            if (ch != '\r') {
                buf[buf_i] = ch;
                buf_i += 1;
                continue;
            }
            buf[buf_i] = '\r';
            buf[buf_i + 1] = '\n';
            buf_i += 2;
        }
        cb(self.userdata, &buf, buf_i);
    }
}

pub fn childExitedAbnormally(
    self: *Passive,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    // No child process exists in passive mode.
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Thread-local data for the passive backend. There is no pty/loop state.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
