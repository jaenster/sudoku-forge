// Thin bindings to the Objective-C runtime, AppKit constants and CoreGraphics.
// Everything is declared by hand so the build needs no C headers.

pub const id = ?*opaque {};
pub const SEL = ?*opaque {};
pub const Class = ?*opaque {};
pub const IMP = *const anyopaque;
pub const CGContext = ?*opaque {};

pub const CGFloat = f64;
pub const Point = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const Size = extern struct { w: CGFloat = 0, h: CGFloat = 0 };
pub const Rect = extern struct {
    o: Point = .{},
    s: Size = .{},
    pub fn make(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) Rect {
        return .{ .o = .{ .x = x, .y = y }, .s = .{ .w = w, .h = h } };
    }
};

extern "c" fn objc_msgSend() void;
extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_allocateClassPair(super: Class, name: [*:0]const u8, extra: usize) Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) bool;

pub fn class(name: [*:0]const u8) id {
    return @ptrCast(objc_getClass(name));
}
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Send a message. `args` is a tuple; every element must have a concrete C type.
pub fn send(comptime R: type, target: id, name: [*:0]const u8, args: anytype) R {
    const s = sel(name);
    const raw = &objc_msgSend;
    switch (args.len) {
        0 => {
            const f: *const fn (id, SEL) callconv(.c) R = @ptrCast(raw);
            return f(target, s);
        },
        1 => {
            const f: *const fn (id, SEL, @TypeOf(args[0])) callconv(.c) R = @ptrCast(raw);
            return f(target, s, args[0]);
        },
        2 => {
            const f: *const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) R = @ptrCast(raw);
            return f(target, s, args[0], args[1]);
        },
        3 => {
            const f: *const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) R = @ptrCast(raw);
            return f(target, s, args[0], args[1], args[2]);
        },
        4 => {
            const f: *const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(.c) R = @ptrCast(raw);
            return f(target, s, args[0], args[1], args[2], args[3]);
        },
        5 => {
            const f: *const fn (id, SEL, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3]), @TypeOf(args[4])) callconv(.c) R = @ptrCast(raw);
            return f(target, s, args[0], args[1], args[2], args[3], args[4]);
        },
        else => @compileError("send: too many arguments"),
    }
}

/// Start a subclass. Add methods with `method`, then call `register`.
pub fn subclass(super: [*:0]const u8, name: [*:0]const u8) Class {
    return objc_allocateClassPair(objc_getClass(super), name, 0);
}
pub fn method(cls: Class, name: [*:0]const u8, imp: anytype, types: [*:0]const u8) void {
    _ = class_addMethod(cls, sel(name), @ptrCast(&imp), types);
}
pub fn register(cls: Class) void {
    objc_registerClassPair(cls);
}

pub fn str(s: [*:0]const u8) id {
    return send(id, class("NSString"), "stringWithUTF8String:", .{s});
}
pub fn new(cls: [*:0]const u8) id {
    return send(id, send(id, class(cls), "alloc", .{}), "init", .{});
}

// ---- AppKit constants
pub extern "c" var NSFontAttributeName: id;
pub extern "c" var NSForegroundColorAttributeName: id;
pub extern "c" var NSPasteboardTypeString: id;

// ---- CoreGraphics
pub extern "c" fn CGContextSetRGBFillColor(c: CGContext, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern "c" fn CGContextSetRGBStrokeColor(c: CGContext, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) void;
pub extern "c" fn CGContextSetLineWidth(c: CGContext, w: CGFloat) void;
pub extern "c" fn CGContextSetLineCap(c: CGContext, cap: c_int) void;
pub extern "c" fn CGContextSetLineJoin(c: CGContext, join: c_int) void;
pub extern "c" fn CGContextSetLineDash(c: CGContext, phase: CGFloat, lengths: ?[*]const CGFloat, count: usize) void;
pub extern "c" fn CGContextFillRect(c: CGContext, r: Rect) void;
pub extern "c" fn CGContextStrokeRect(c: CGContext, r: Rect) void;
pub extern "c" fn CGContextFillEllipseInRect(c: CGContext, r: Rect) void;
pub extern "c" fn CGContextBeginPath(c: CGContext) void;
pub extern "c" fn CGContextMoveToPoint(c: CGContext, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextAddLineToPoint(c: CGContext, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextStrokePath(c: CGContext) void;
pub extern "c" fn CGContextTranslateCTM(c: CGContext, x: CGFloat, y: CGFloat) void;
pub extern "c" fn CGContextScaleCTM(c: CGContext, x: CGFloat, y: CGFloat) void;

// ---- offscreen rendering to a PNG file
pub extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bits: usize, row: usize, space: ?*anyopaque, info: u32) CGContext;
pub extern "c" fn CGBitmapContextCreateImage(c: CGContext) ?*anyopaque;
pub extern "c" fn CGImageDestinationCreateWithURL(url: id, kind: id, count: usize, options: ?*anyopaque) ?*anyopaque;
pub extern "c" fn CGImageDestinationAddImage(dest: ?*anyopaque, image: ?*anyopaque, properties: ?*anyopaque) void;
pub extern "c" fn CGImageDestinationFinalize(dest: ?*anyopaque) bool;

pub extern "c" fn _NSGetArgc() *c_int;
pub extern "c" fn _NSGetArgv() *[*][*:0]u8;
