// Browser backend: the whole app as one WebAssembly module. The page owns a
// canvas and forwards input; drawing goes back out through the imports below.

const app = @import("app.zig");

extern "env" fn js_fill_rect(x: f64, y: f64, w: f64, h: f64, c: u32) void;
extern "env" fn js_stroke_rect(x: f64, y: f64, w: f64, h: f64, width: f64, c: u32) void;
extern "env" fn js_line(x1: f64, y1: f64, x2: f64, y2: f64, width: f64, c: u32, dashed: u32) void;
extern "env" fn js_polyline(pts: [*]const [2]f64, n: usize, width: f64, c: u32) void;
extern "env" fn js_circle(cx: f64, cy: f64, r: f64, c: u32) void;
extern "env" fn js_text(x: f64, y: f64, size: f64, bold: u32, c: u32, al: u32, s: [*]const u8, n: usize) void;
extern "env" fn js_text_width(size: f64, bold: u32, s: [*]const u8, n: usize) f64;
extern "env" fn js_copy(s: [*]const u8, n: usize) void;
extern "env" fn js_request_paste() void;

fn fillRect(x: f64, y: f64, w: f64, h: f64, c: app.Color) void {
    js_fill_rect(x, y, w, h, c);
}
fn strokeRect(x: f64, y: f64, w: f64, h: f64, width: f64, c: app.Color) void {
    js_stroke_rect(x, y, w, h, width, c);
}
fn line(x1: f64, y1: f64, x2: f64, y2: f64, width: f64, c: app.Color, dashed: bool) void {
    js_line(x1, y1, x2, y2, width, c, @intFromBool(dashed));
}
fn polyline(pts: []const [2]f64, width: f64, c: app.Color) void {
    js_polyline(pts.ptr, pts.len, width, c);
}
fn circle(cx: f64, cy: f64, r: f64, c: app.Color) void {
    js_circle(cx, cy, r, c);
}
fn text(x: f64, y: f64, size: f64, bold: bool, c: app.Color, al: app.Align, s: []const u8) void {
    js_text(x, y, size, @intFromBool(bold), c, @intFromEnum(al), s.ptr, s.len);
}
fn textWidth(size: f64, bold: bool, s: []const u8) f64 {
    return js_text_width(size, @intFromBool(bold), s.ptr, s.len);
}
fn copy(s: []const u8) void {
    js_copy(s.ptr, s.len);
}

/// Text handed over by the page: clipboard contents or a code from the URL.
var io: [8192]u8 = undefined;
var pasted: usize = 0;

/// A browser only gives out the clipboard asynchronously. The first call
/// asks for it and comes back empty; the page then stores the text and
/// presses paste again, and that second call finds it here.
fn paste(buf: []u8) []const u8 {
    if (pasted == 0) {
        js_request_paste();
        return buf[0..0];
    }
    const n = @min(pasted, buf.len);
    @memcpy(buf[0..n], io[0..n]);
    pasted = 0;
    return buf[0..n];
}

export fn ioPtr() [*]u8 {
    return &io;
}
export fn ioLen() usize {
    return io.len;
}
export fn start(dark: u32) void {
    app.host = .{ .fillRect = fillRect, .strokeRect = strokeRect, .line = line, .polyline = polyline, .circle = circle, .text = text, .textWidth = textWidth, .copy = copy, .paste = paste };
    app.init();
    app.setDark(dark != 0);
}
export fn frame(w: f64, h: f64) void {
    app.draw(w, h);
}
export fn pointerDown(x: f64, y: f64) void {
    app.pointerDown(x, y);
}
export fn pointerMove(x: f64, y: f64) void {
    app.pointerMove(x, y);
}
export fn pointerUp() void {
    app.pointerUp();
}
export fn key(code: u32) void {
    app.key(code);
}
export fn tick() u32 {
    return @intFromBool(app.tick());
}
/// The page has put `n` bytes of clipboard text in the buffer.
export fn pasteText(n: usize) void {
    pasted = n;
    app.key(app.Key.paste);
    pasted = 0;
}
/// Load a share code the page has put in the buffer.
export fn loadText(n: usize) u32 {
    return @intFromBool(app.loadCode(io[0..n]));
}
