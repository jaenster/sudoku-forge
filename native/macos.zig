// macOS backend: an AppKit window with one custom view, driven through the
// Objective-C runtime. Drawing is CoreGraphics plus NSString for text.

const app = @import("app.zig");
const o = @import("objc.zig");
const id = o.id;
const SEL = o.SEL;

var view: id = null;
var cg: o.CGContext = null;

// ------------------------------------------------------------------ drawing

fn rgba(c: app.Color) [4]f64 {
    return .{
        @as(f64, @floatFromInt((c >> 24) & 255)) / 255.0,
        @as(f64, @floatFromInt((c >> 16) & 255)) / 255.0,
        @as(f64, @floatFromInt((c >> 8) & 255)) / 255.0,
        @as(f64, @floatFromInt(c & 255)) / 255.0,
    };
}
fn setFill(c: app.Color) void {
    const v = rgba(c);
    o.CGContextSetRGBFillColor(cg, v[0], v[1], v[2], v[3]);
}
fn setStroke(c: app.Color, width: f64) void {
    const v = rgba(c);
    o.CGContextSetRGBStrokeColor(cg, v[0], v[1], v[2], v[3]);
    o.CGContextSetLineWidth(cg, width);
}

fn fillRect(x: f64, y: f64, w: f64, h: f64, c: app.Color) void {
    setFill(c);
    o.CGContextFillRect(cg, o.Rect.make(x, y, w, h));
}
fn strokeRect(x: f64, y: f64, w: f64, h: f64, width: f64, c: app.Color) void {
    setStroke(c, width);
    o.CGContextStrokeRect(cg, o.Rect.make(x + 0.5, y + 0.5, w - 1, h - 1));
}
fn line(x1: f64, y1: f64, x2: f64, y2: f64, width: f64, c: app.Color, dashed: bool) void {
    setStroke(c, width);
    o.CGContextSetLineCap(cg, 0);
    const dash = [2]f64{ 4, 3 };
    if (dashed) o.CGContextSetLineDash(cg, 0, &dash, 2);
    o.CGContextBeginPath(cg);
    o.CGContextMoveToPoint(cg, x1, y1);
    o.CGContextAddLineToPoint(cg, x2, y2);
    o.CGContextStrokePath(cg);
    if (dashed) o.CGContextSetLineDash(cg, 0, null, 0);
}
fn polyline(pts: []const [2]f64, width: f64, c: app.Color) void {
    setStroke(c, width);
    o.CGContextSetLineCap(cg, 1);
    o.CGContextSetLineJoin(cg, 1);
    o.CGContextBeginPath(cg);
    o.CGContextMoveToPoint(cg, pts[0][0], pts[0][1]);
    for (pts[1..]) |p| o.CGContextAddLineToPoint(cg, p[0], p[1]);
    o.CGContextStrokePath(cg);
}
fn circle(cx: f64, cy: f64, r: f64, c: app.Color) void {
    setFill(c);
    o.CGContextFillEllipseInRect(cg, o.Rect.make(cx - r, cy - r, r * 2, r * 2));
}

fn nsString(s: []const u8) id {
    const raw = o.send(id, o.class("NSString"), "alloc", .{});
    const made = o.send(id, raw, "initWithBytes:length:encoding:", .{ s.ptr, @as(c_ulong, s.len), @as(c_ulong, 4) });
    return o.send(id, made, "autorelease", .{});
}
fn attributes(size: f64, bold: bool, c: app.Color) id {
    const v = rgba(c);
    const font = o.send(id, o.class("NSFont"), if (bold) "boldSystemFontOfSize:" else "systemFontOfSize:", .{size});
    const color = o.send(id, o.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ v[0], v[1], v[2], v[3] });
    const objects = [2]id{ font, color };
    const keys = [2]id{ o.NSFontAttributeName, o.NSForegroundColorAttributeName };
    return o.send(id, o.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &objects, &keys, @as(c_ulong, 2) });
}
fn textWidth(size: f64, bold: bool, s: []const u8) f64 {
    return o.send(o.Size, nsString(s), "sizeWithAttributes:", .{attributes(size, bold, 0xFF)}).w;
}
fn text(x: f64, y: f64, size: f64, bold: bool, c: app.Color, al: app.Align, s: []const u8) void {
    const str = nsString(s);
    const attrs = attributes(size, bold, c);
    const sz = o.send(o.Size, str, "sizeWithAttributes:", .{attrs});
    const left = switch (al) {
        .left => x,
        .center => x - sz.w / 2,
        .right => x - sz.w,
    };
    o.send(void, str, "drawAtPoint:withAttributes:", .{ o.Point{ .x = left, .y = y - sz.h / 2 }, attrs });
}

fn copy(s: []const u8) void {
    const board = o.send(id, o.class("NSPasteboard"), "generalPasteboard", .{});
    _ = o.send(c_long, board, "clearContents", .{});
    _ = o.send(bool, board, "setString:forType:", .{ nsString(s), o.NSPasteboardTypeString });
}
fn paste(buf: []u8) []const u8 {
    const board = o.send(id, o.class("NSPasteboard"), "generalPasteboard", .{});
    const str = o.send(id, board, "stringForType:", .{o.NSPasteboardTypeString});
    if (str == null) return buf[0..0];
    const utf8 = o.send(?[*:0]const u8, str, "UTF8String", .{}) orelse return buf[0..0];
    var n: usize = 0;
    while (n < buf.len and utf8[n] != 0) : (n += 1) buf[n] = utf8[n];
    return buf[0..n];
}

const host: app.Host = .{
    .fillRect = fillRect,
    .strokeRect = strokeRect,
    .line = line,
    .polyline = polyline,
    .circle = circle,
    .text = text,
    .textWidth = textWidth,
    .copy = copy,
    .paste = paste,
};

// ------------------------------------------------------------------ view

fn currentContext() o.CGContext {
    return o.send(o.CGContext, o.send(id, o.class("NSGraphicsContext"), "currentContext", .{}), "CGContext", .{});
}
fn redraw() void {
    o.send(void, view, "setNeedsDisplay:", .{true});
}
fn location(self: id, event: id) o.Point {
    const p = o.send(o.Point, event, "locationInWindow", .{});
    return o.send(o.Point, self, "convertPoint:fromView:", .{ p, @as(id, null) });
}

fn drawRect(self: id, _: SEL, _: o.Rect) callconv(.c) void {
    cg = currentContext();
    const b = o.send(o.Rect, self, "bounds", .{});
    app.draw(b.s.w, b.s.h);
}
fn yes(_: id, _: SEL) callconv(.c) bool {
    return true;
}
fn mouseDown(self: id, _: SEL, event: id) callconv(.c) void {
    const p = location(self, event);
    app.pointerDown(p.x, p.y);
    redraw();
}
fn mouseDragged(self: id, _: SEL, event: id) callconv(.c) void {
    const p = location(self, event);
    app.pointerMove(p.x, p.y);
    redraw();
}
fn mouseUp(_: id, _: SEL, _: id) callconv(.c) void {
    app.pointerUp();
    redraw();
}
fn keyDown(_: id, _: SEL, event: id) callconv(.c) void {
    const chars = o.send(id, event, "characters", .{});
    if (o.send(c_ulong, chars, "length", .{}) == 0) return;
    app.key(o.send(u16, chars, "characterAtIndex:", .{@as(c_ulong, 0)}));
    redraw();
}
fn copyAction(_: id, _: SEL, _: id) callconv(.c) void {
    app.key(app.Key.copy);
    redraw();
}
fn pasteAction(_: id, _: SEL, _: id) callconv(.c) void {
    app.key(app.Key.paste);
    redraw();
}
fn undoAction(_: id, _: SEL, _: id) callconv(.c) void {
    app.key(app.Key.undo);
    redraw();
}
fn redoAction(_: id, _: SEL, _: id) callconv(.c) void {
    app.key(app.Key.redo);
    redraw();
}
fn menuItem(menu: id, title: [*:0]const u8, action: [*:0]const u8, shortcut: [*:0]const u8, target: id) void {
    const item = o.send(id, o.send(id, o.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ o.str(title), o.sel(action), o.str(shortcut) });
    if (target != null) o.send(void, item, "setTarget:", .{target});
    o.send(void, menu, "addItem:", .{item});
}
fn timerFired(_: id, _: SEL, _: id) callconv(.c) void {
    if (app.tick()) redraw();
}
fn quitAfterLastWindow(_: id, _: SEL, _: id) callconv(.c) bool {
    return true;
}

// ------------------------------------------------------------------ snapshot

/// Paint the app into a PNG without opening a window. Used to check rendering.
fn snapshot(path: [*:0]const u8, w: f64, h: f64) void {
    const scale: f64 = 2;
    const pw: usize = @intFromFloat(w * scale);
    const ph: usize = @intFromFloat(h * scale);
    cg = o.CGBitmapContextCreate(null, pw, ph, 8, 0, o.CGColorSpaceCreateDeviceRGB(), 1);
    o.CGContextTranslateCTM(cg, 0, @floatFromInt(ph));
    o.CGContextScaleCTM(cg, scale, -scale);
    const gc = o.send(id, o.class("NSGraphicsContext"), "graphicsContextWithCGContext:flipped:", .{ cg, true });
    o.send(void, o.class("NSGraphicsContext"), "setCurrentContext:", .{gc});
    app.draw(w, h);
    const url = o.send(id, o.class("NSURL"), "fileURLWithPath:", .{o.str(path)});
    const dest = o.CGImageDestinationCreateWithURL(url, o.str("public.png"), 1, null);
    o.CGImageDestinationAddImage(dest, o.CGBitmapContextCreateImage(cg), null);
    _ = o.CGImageDestinationFinalize(dest);
}

fn drag(cells: []const usize) void {
    const a = app.cellCenter(cells[0]);
    app.pointerDown(a[0], a[1]);
    for (cells[1..]) |c| {
        const p = app.cellCenter(c);
        app.pointerMove(p[0], p[1]);
    }
    app.pointerUp();
}

/// Drive the app through its input functions the way a setter would.
fn demo() void {
    drag(&.{ 0, 1, 10 });
    app.key('1');
    app.key('5');
    drag(&.{ 4, 5, 6, 15 });
    app.key('2');
    app.key('0');
    drag(&.{ 30, 31, 40, 49, 48 });
    app.key('t');
    drag(&.{ 72, 64, 56, 48 });
    drag(&.{ 8, 17, 26, 35 });
    drag(&.{ 8, 7, 16 });
    drag(&.{ 56, 57, 58 });
    // Three givens, then three digits that are only wanted in the solution.
    const placed = [_][2]u8{ .{ 20, 7 }, .{ 22, 3 }, .{ 37, 9 }, .{ 44, 1 }, .{ 60, 4 }, .{ 78, 6 } };
    for (placed, 0..) |g, n| {
        app.key(if (n < 3) 'g' else 'w');
        const p = app.cellCenter(g[0]);
        app.pointerDown(p[0], p[1]);
        app.pointerUp();
        app.key('0' + @as(u32, g[1]));
    }
    // One line of each other style: arrow, whisper, renban, palindrome.
    app.key('t');
    app.key('2');
    drag(&.{ 36, 45, 54 });
    app.key('3');
    drag(&.{ 23, 24, 33, 34 });
    app.key('4');
    drag(&.{ 65, 66, 67 });
    app.key('5');
    drag(&.{ 39, 47, 55 });
    app.key('1');
    // Odd and even cells: one click is odd, two clicks is even.
    app.key('p');
    for ([_]usize{ 80, 79, 79, 70 }) |c| {
        const p = app.cellCenter(c);
        app.pointerDown(p[0], p[1]);
        app.pointerUp();
    }
    // Signs on borders: click near the shared edge, then type the sign.
    app.key('b');
    const signs = [_][3]u32{ .{ 63, 64, '<' }, .{ 64, 73, '>' }, .{ 2, 3, 'x' }, .{ 27, 28, 'v' }, .{ 28, 29, 'o' }, .{ 51, 52, 'k' }, .{ 13, 14, 'o' } };
    for (signs) |g| {
        const a = app.cellCenter(g[0]);
        const b = app.cellCenter(g[1]);
        app.pointerDown(a[0] + (b[0] - a[0]) * 0.45, a[1] + (b[1] - a[1]) * 0.45);
        app.pointerUp();
        app.key(g[2]);
    }
}

// ------------------------------------------------------------------ main

extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
fn print(bytes: []const u8) void {
    _ = write(1, bytes.ptr, bytes.len);
}
fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
fn eql(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return true;
    }
    return false;
}

pub fn main() void {
    _ = o.new("NSAutoreleasePool");
    app.host = host;
    app.init();
    var want_dark: ?bool = null;
    const W: f64 = 1060;
    const H: f64 = 900;

    const argc: usize = @intCast(o._NSGetArgc().*);
    const argv = o._NSGetArgv().*;
    var i: usize = 1;
    var ticks: usize = 0;
    while (i < argc) : (i += 1) {
        if (eql(argv[i], "--demo")) {
            app.resize(W, H);
            demo();
        } else if (eql(argv[i], "--dark")) {
            want_dark = true;
            app.setDark(true);
        } else if (eql(argv[i], "--light")) {
            want_dark = false;
        } else if (eql(argv[i], "--roundtrip")) {
            // Encode, wipe, decode, encode again: both codes must match.
            var a: [3000]u8 = undefined;
            var b: [3000]u8 = undefined;
            var keep: [3000]u8 = undefined;
            const first = app.encode(&a);
            @memcpy(keep[0..first.len], first);
            const ok = app.loadCode("SF1AQAAAAAAAA") and app.loadCode(keep[0..first.len]);
            const second = app.encode(&b);
            const same = ok and first.len == second.len and eqlBytes(keep[0..first.len], second);
            const rejects = !app.loadCode("SF1!!") and !app.loadCode("hello") and !app.loadCode("SF1AQ");
            print(second);
            print(if (same) "\nroundtrip ok" else "\nroundtrip FAILED");
            print(if (rejects) ", rejects junk ok\n" else ", rejects junk FAILED\n");
        } else if (eql(argv[i], "--sudokupad")) {
            var link: [40000]u8 = undefined;
            print(app.sudokuPadLink(&link) orelse "TOO LARGE");
            print("\n");
        } else if (eql(argv[i], "--code") and i + 1 < argc) {
            i += 1;
            app.resize(W, H);
            var n: usize = 0;
            while (argv[i][n] != 0) n += 1;
            print(if (app.loadCode(argv[i][0..n])) "code loaded\n" else "code REJECTED\n");
        } else if (eql(argv[i], "--report")) {
            var rb: [2000]u8 = undefined;
            print(app.report(&rb));
        } else if (eql(argv[i], "--level") and i + 1 < argc) {
            // The solver's logic level as a decimal bit set; 1 is shaving only.
            i += 1;
            var level: u32 = 0;
            var n: usize = 0;
            while (argv[i][n] >= '0' and argv[i][n] <= '9') : (n += 1) level = level * 10 + (argv[i][n] - '0');
            app.setLogicLevel(level);
        } else if (eql(argv[i], "--keys") and i + 1 < argc) {
            // Type each character; '~' stands for Backspace and '^' for Tab.
            i += 1;
            var n: usize = 0;
            while (argv[i][n] != 0) : (n += 1) app.key(switch (argv[i][n]) {
                '~' => app.Key.backspace,
                '^' => app.Key.tab,
                else => |ch| ch,
            });
        } else if (eql(argv[i], "--click") and i + 1 < argc) {
            // Click the middle of a cell, numbered 0 to 80.
            i += 1;
            var n: usize = 0;
            for (0..2) |k| {
                if (argv[i][k] == 0) break;
                n = n * 10 + (argv[i][k] - '0');
            }
            const p = app.cellCenter(n);
            app.pointerDown(p[0], p[1]);
            app.pointerUp();
        } else if (eql(argv[i], "--undo") and i + 1 < argc) {
            i += 1;
            for (0..argv[i][0] - '0') |_| app.key(app.Key.undo);
        } else if (eql(argv[i], "--redo") and i + 1 < argc) {
            i += 1;
            for (0..argv[i][0] - '0') |_| app.key(app.Key.redo);
        } else if (eql(argv[i], "--erase") and i + 1 < argc) {
            // Erase clicks on the top right cell, where two thermometers start.
            i += 1;
            app.key('e');
            for (0..argv[i][0] - '0') |_| {
                const p = app.cellCenter(8);
                app.pointerDown(p[0], p[1]);
                app.pointerUp();
            }
        } else if (eql(argv[i], "--ticks") and i + 1 < argc) {
            i += 1;
            ticks = 0;
            for (0..16) |k| {
                if (argv[i][k] == 0) break;
                ticks = ticks * 10 + (argv[i][k] - '0');
            }
            for (0..ticks) |_| _ = app.tick();
        } else if (eql(argv[i], "--snapshot") and i + 1 < argc) {
            snapshot(argv[i + 1], W, H);
            return;
        }
    }

    const ns = o.send(id, o.class("NSApplication"), "sharedApplication", .{});
    _ = o.send(bool, ns, "setActivationPolicy:", .{@as(c_long, 0)});

    // Follow the system appearance unless a flag chose one.
    const appearance = o.send(id, o.send(id, ns, "effectiveAppearance", .{}), "name", .{});
    const system_dark = o.send(bool, appearance, "containsString:", .{o.str("Dark")});
    app.setDark(want_dark orelse system_dark);

    const dc = o.subclass("NSObject", "ForgeDelegate");
    o.method(dc, "applicationShouldTerminateAfterLastWindowClosed:", quitAfterLastWindow, "c@:@");
    o.method(dc, "tick:", timerFired, "v@:@");
    o.method(dc, "undoEdit:", undoAction, "v@:@");
    o.method(dc, "redoEdit:", redoAction, "v@:@");
    o.method(dc, "copyCode:", copyAction, "v@:@");
    o.method(dc, "pasteCode:", pasteAction, "v@:@");
    o.register(dc);
    const delegate = o.new("ForgeDelegate");
    o.send(void, ns, "setDelegate:", .{delegate});

    // An application menu, so Cmd-Q works.
    const bar = o.new("NSMenu");
    const bar_item = o.new("NSMenuItem");
    o.send(void, bar, "addItem:", .{bar_item});
    o.send(void, ns, "setMainMenu:", .{bar});
    const menu = o.new("NSMenu");
    menuItem(menu, "Quit Sudoku Forge", "terminate:", "q", null);
    o.send(void, bar_item, "setSubmenu:", .{menu});

    const edit_item = o.new("NSMenuItem");
    o.send(void, bar, "addItem:", .{edit_item});
    const edit = o.send(id, o.send(id, o.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{o.str("Edit")});
    menuItem(edit, "Undo", "undoEdit:", "z", delegate);
    menuItem(edit, "Redo", "redoEdit:", "Z", delegate);
    menuItem(edit, "Copy Puzzle Code", "copyCode:", "c", delegate);
    menuItem(edit, "Paste Puzzle Code", "pasteCode:", "v", delegate);
    o.send(void, edit_item, "setSubmenu:", .{edit});

    const vc = o.subclass("NSView", "ForgeView");
    o.method(vc, "drawRect:", drawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    o.method(vc, "isFlipped", yes, "c@:");
    o.method(vc, "acceptsFirstResponder", yes, "c@:");
    o.method(vc, "mouseDown:", mouseDown, "v@:@");
    o.method(vc, "mouseDragged:", mouseDragged, "v@:@");
    o.method(vc, "mouseUp:", mouseUp, "v@:@");
    o.method(vc, "keyDown:", keyDown, "v@:@");
    o.register(vc);

    const frame = o.Rect.make(0, 0, W, H);
    // titled | closable | miniaturizable | resizable
    const window = o.send(id, o.send(id, o.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ frame, @as(c_ulong, 1 | 2 | 4 | 8), @as(c_ulong, 2), false });
    o.send(void, window, "setTitle:", .{o.str("Sudoku Forge")});
    o.send(void, window, "setContentMinSize:", .{o.Size{ .w = 760, .h = 860 }});
    view = o.send(id, o.send(id, o.class("ForgeView"), "alloc", .{}), "initWithFrame:", .{frame});
    o.send(void, window, "setContentView:", .{view});
    _ = o.send(bool, window, "makeFirstResponder:", .{view});
    o.send(void, window, "center", .{});
    o.send(void, window, "makeKeyAndOrderFront:", .{@as(id, null)});
    o.send(void, ns, "activateIgnoringOtherApps:", .{true});

    _ = o.send(id, o.class("NSTimer"), "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{ @as(f64, 0.02), delegate, o.sel("tick:"), @as(id, null), true });
    o.send(void, ns, "run", .{});
}
