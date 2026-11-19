// The design workbench, independent of any windowing system. A platform
// backend fills in `host`, forwards input to the pub functions below and calls
// `draw` whenever the window needs painting.

const std = @import("std");
const sv = @import("solver.zig");
const lz = @import("lzstring.zig");

pub const Color = u32; // 0xRRGGBBAA
pub const Align = enum { left, center, right };

/// What a platform has to provide. Coordinates are in points, origin top left.
/// Text is anchored at its vertical centre. Drawing calls are only valid
/// while `draw` runs; `textWidth` must work at any time.
pub const Host = struct {
    fillRect: *const fn (x: f64, y: f64, w: f64, h: f64, c: Color) void,
    strokeRect: *const fn (x: f64, y: f64, w: f64, h: f64, width: f64, c: Color) void,
    line: *const fn (x1: f64, y1: f64, x2: f64, y2: f64, width: f64, c: Color, dashed: bool) void,
    polyline: *const fn (pts: []const [2]f64, width: f64, c: Color) void,
    circle: *const fn (cx: f64, cy: f64, r: f64, c: Color) void,
    text: *const fn (x: f64, y: f64, size: f64, bold: bool, c: Color, al: Align, s: []const u8) void,
    textWidth: *const fn (size: f64, bold: bool, s: []const u8) f64,
    /// Put text on the system clipboard.
    copy: *const fn (s: []const u8) void,
    /// Read clipboard text into `buf`; returns the part that was filled.
    paste: *const fn (buf: []u8) []const u8,
};
pub var host: Host = undefined;

/// Key codes above the printable range, shared by every backend.
pub const Key = struct {
    pub const up: u32 = 0xF700;
    pub const down: u32 = 0xF701;
    pub const left: u32 = 0xF702;
    pub const right: u32 = 0xF703;
    pub const backspace: u32 = 0x7F;
    pub const delete: u32 = 0xF728;
    pub const tab: u32 = 9;
    pub const escape: u32 = 27;
    pub const undo: u32 = 0xE000;
    pub const redo: u32 = 0xE001;
    pub const copy: u32 = 0xE002;
    pub const paste: u32 = 0xE003;
};

// ------------------------------------------------------------------ state

const Cage = struct { cells: [9]u8 = undefined, n: u8 = 0, sum: u16 = 0 };
/// A path of cells with a rule along it. Kind 0 is a thermometer; the others
/// are the solver's line kinds.
const Thermo = struct { cells: [9]u8 = undefined, n: u8 = 0, kind: u8 = 0 };
const Tool = enum { cage, thermo, between, given, wanted, erase, parity, select };
/// A relation between two neighbouring cells; `a` is the upper or left one.
const Link = struct { a: u8, b: u8, op: u8, val: u8 };
const Sign = enum { less, greater, x, v, white, black };
const MAX_THERMOS = sv.MAX_THERMO + sv.MAX_LINE;

var cages: [81]Cage = undefined;
var cage_n: usize = 0;
var thermos: [MAX_THERMOS]Thermo = undefined;
var thermo_n: usize = 0;
var links: [sv.MAX_LINK]Link = undefined;
var link_n: usize = 0;
var sel_edge: ?[2]u8 = null;
var digits: [81]u8 = @splat(0);
/// A wanted digit is part of the solution the setter is aiming for. The solver
/// is never told it; it only decides which solution the search builds towards.
var wanted: [81]bool = @splat(false);
/// Cell marks: 0 none, 1 odd (circle), 2 even (square).
var parity: [81]u8 = @splat(0);
const ODD_MASK: u16 = 0b101010101;
const EVEN_MASK: u16 = 0b010101010;

var tool: Tool = .cage;
var sel: usize = 40;
var sel_cage: i32 = -1;
var stroke: Thermo = .{};
/// The style the line tool draws with.
var line_kind: u8 = 0;
var stroking = false;

var show_deductions = true;
var show_solution = false;
/// Analyse as if the wanted digits were printed in the puzzle.
var assume_wanted = false;

/// One thing the Select tool can single out. Everything under the last click
/// is listed in `picks`, top layer first, and `pick_at` is the chosen one.
const Pick = union(enum) { link: usize, digit: usize, mark: usize, line: usize, cage: usize };
var picks: [48]Pick = undefined;
var pick_n: usize = 0;
var pick_at: usize = 0;
var pick_cell: usize = 0;
var pick_pos: [2]f64 = .{ 0, 0 };
var rule_diagonals = false;
var rule_knight = false;

const Analysis = struct {
    valid: bool = false,
    status: u32 = 0,
    cand: [81]u16 = @splat(0),
    sol: [81]u8 = @splat(0),
    guesses: u32 = 0,
    steps: u32 = 0,
    /// Uses per step beyond singles, in the solver's order, easiest first.
    tech: [sv.TECHNIQUES]u32 = @splat(0),
    red_cage: [81]bool = @splat(false),
    red_thermo: [MAX_THERMOS]bool = @splat(false),
    red_digit: [81]bool = @splat(false),
    red_link: [sv.MAX_LINK]bool = @splat(false),
    red_mark: [81]bool = @splat(false),
    /// No solution at all has the wanted digits where the setter put them.
    wanted_impossible: bool = false,
};
var an: Analysis = .{};

/// Background search for the fewest extra givens that make the puzzle unique.
const Suggestion = struct {
    active: bool = false,
    delay: u32 = 0,
    has: bool = false,
    added: [81]u8 = @splat(0),
    added_n: u32 = 0,
    sol: [81]u8 = @splat(0),
    tries: u32 = 0,
    done: bool = false,
    impossible: bool = false,
};
var sug: Suggestion = .{};

/// Background check of every remaining candidate against a full search, so
/// the board shows what the clues really leave open and not just what the
/// solver's own logic can see.
const Exact = struct {
    active: bool = false,
    done: bool = false,
    cand: [81]u16 = @splat(0), // not ruled out so far
    seen: [81]u16 = @splat(0), // found in some solution
    at: usize = 0, // next cell * 9 + digit to look at
    unsure: u32 = 0, // searches that ran out of budget
};
var ex: Exact = .{};
const SUGGEST_TRIES = 400;

var rng: u64 = 0x9E3779B97F4A7C15;
fn rnd() u32 {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return @truncate(rng >> 16);
}

// ------------------------------------------------------------------ solver

fn clueCount() usize {
    var n: usize = cage_n + thermo_n + link_n;
    for (digits) |d| n += @intFromBool(d != 0);
    for (parity) |m| n += @intFromBool(m != 0);
    return n;
}

fn rules() u32 {
    return @as(u32, @intFromBool(rule_diagonals)) | (@as(u32, @intFromBool(rule_knight)) << 1);
}

fn writeClues() void {
    const cage = sv.userCagePtr();
    const sum = sv.userSumPtr();
    for (0..81) |i| {
        cage[i] = sv.NONE;
        sum[i] = 0;
    }
    for (cages[0..cage_n], 0..) |g, i| {
        for (g.cells[0..g.n]) |c| cage[c] = @intCast(i);
        sum[i] = g.sum;
    }
    // Thermometers and the other line kinds live in separate solver lists.
    const cells = sv.userThermoPtr();
    const len = sv.userThermoLenPtr();
    const line_cells = sv.userLineCellPtr();
    const line_len = sv.userLineLenPtr();
    const line_kinds = sv.userLineKindPtr();
    var tn: usize = 0;
    var ln: usize = 0;
    for (thermos[0..thermo_n]) |t| {
        if (t.kind == 0) {
            for (t.cells[0..t.n], 0..) |c, k| cells[tn * 9 + k] = c;
            len[tn] = t.n;
            tn += 1;
        } else {
            for (t.cells[0..t.n], 0..) |c, k| line_cells[ln * 9 + k] = c;
            line_len[ln] = t.n;
            line_kinds[ln] = t.kind;
            ln += 1;
        }
    }
    sv.setUserThermoCount(@intCast(tn));
    sv.setUserLineCount(@intCast(ln));
    const lk = sv.userLinkPtr();
    for (links[0..link_n], 0..) |l, i| {
        // "greater" is stored as "less" with the cells swapped.
        lk[i * 4] = l.a;
        lk[i * 4 + 1] = l.b;
        lk[i * 4 + 2] = l.op;
        lk[i * 4 + 3] = l.val;
    }
    sv.setUserLinkCount(@intCast(link_n));
    const dg = sv.userDigitPtr();
    const hidden = sv.userHiddenPtr();
    const mask = sv.userMaskPtr();
    for (0..81) |i| {
        mask[i] = switch (parity[i]) {
            1 => ODD_MASK,
            2 => EVEN_MASK,
            else => 0x1FF,
        };
        dg[i] = digits[i];
        hidden[i] = @intFromBool(wanted[i] and !wanted_as_given);
    }
    sv.setRules(rules());
}
/// Set while asking whether the wanted digits can be honoured at all.
var wanted_as_given = false;

fn wantedCount() u32 {
    var n: u32 = 0;
    for (0..81) |c| n += @intFromBool(digits[c] != 0 and wanted[c]);
    return n;
}

fn runAnalysis() void {
    an = .{};
    if (clueCount() == 0) return;
    var impossible = false;
    if (wantedCount() > 0) {
        wanted_as_given = true;
        writeClues();
        wanted_as_given = false;
        impossible = sv.analyze(2000, 1) == sv.Status.none;
    }
    wanted_as_given = assume_wanted;
    writeClues();
    wanted_as_given = false;
    an.valid = true;
    an.wanted_impossible = impossible;
    an.status = sv.analyze(2000, 1);
    const cand = sv.analysisCandPtr();
    for (0..81) |i| an.cand[i] = cand[i];
    for (&an.tech, 0..) |*t, i| t.* = sv.techniquePtr()[i];
    if (an.status != sv.Status.unique) return;
    const sol = sv.analysisSolutionPtr();
    const rc = sv.redundantCagePtr();
    const rt = sv.redundantThermoPtr();
    const rd = sv.redundantDigitPtr();
    for (0..81) |i| {
        an.sol[i] = sol[i];
        an.red_cage[i] = i < cage_n and rc[i] == 1;
        an.red_digit[i] = digits[i] != 0 and !wanted[i] and rd[i] == 1;
        // The solver reports a spare cell mark the same way as a spare given.
        an.red_mark[i] = parity[i] != 0 and (digits[i] == 0 or wanted[i]) and rd[i] == 1;
    }
    const rline = sv.redundantLinePtr();
    var tn: usize = 0;
    var ln: usize = 0;
    for (thermos[0..thermo_n], 0..) |t, i| {
        if (t.kind == 0) {
            an.red_thermo[i] = rt[tn] == 1;
            tn += 1;
        } else {
            an.red_thermo[i] = rline[ln] == 1;
            ln += 1;
        }
    }
    const rl = sv.redundantLinkPtr();
    for (0..link_n) |i| an.red_link[i] = rl[i] == 1;
    an.guesses = sv.guesses();
    an.steps = sv.ruleSteps();
}

/// The steps as the panel names them. Both kinds of set equivalence share a
/// name, so the solver's nine counters make eight entries.
const STEP_NAMES = [8][]const u8{ "locked candidates", "X-wing", "swordfish", "XY-wing", "fork rule", "linear sums", "set equivalence", "trial and error" };
const STEP_KEYS = [8][]const u8{ "locked", "xwing", "swordfish", "xywing", "fork", "linear", "seteq", "trial" };

fn stepCount(i: usize) u32 {
    return switch (i) {
        6 => an.tech[6] + an.tech[7],
        7 => an.tech[8],
        else => an.tech[i],
    };
}

/// "locked candidates x3, X-wing x1.", or nothing when no step was needed.
fn stepList(out: []u8) []const u8 {
    var n: usize = 0;
    for (STEP_NAMES, 0..) |name, i| {
        const k = stepCount(i);
        if (k == 0) continue;
        const w = std.fmt.bufPrint(out[n..], "{s}{s} x{d}", .{ if (n == 0) "" else ", ", name, k }) catch break;
        n += w.len;
    }
    return out[0..n];
}

/// A full grid that fitted the clues the last time one was known. It outlives
/// edits, and is checked against the clues again before it is used.
var hint_sol: [81]u8 = @splat(0);
var hint_ok = false;
var auto_sum = true;

fn keepHint() void {
    const sol = knownSolution() orelse return;
    hint_sol = sol.*;
    hint_ok = true;
}

fn isOpen() bool {
    return an.valid and (an.status == sv.Status.multiple or an.status == sv.Status.at_least_one or an.status == sv.Status.unknown);
}

/// Everything undo has to bring back.
const Snapshot = struct {
    cages: [81]Cage,
    cage_n: usize,
    thermos: [MAX_THERMOS]Thermo,
    thermo_n: usize,
    links: [sv.MAX_LINK]Link,
    link_n: usize,
    digits: [81]u8,
    wanted: [81]bool,
    parity: [81]u8,
    rule_diagonals: bool,
    rule_knight: bool,
};
const HISTORY = 200;
var history: [HISTORY]Snapshot = undefined;
var hist_n: usize = 0; // snapshots stored
var hist_at: usize = 0; // index of the one on screen

fn capture() Snapshot {
    return .{ .cages = cages, .cage_n = cage_n, .thermos = thermos, .thermo_n = thermo_n, .links = links, .link_n = link_n, .digits = digits, .wanted = wanted, .parity = parity, .rule_diagonals = rule_diagonals, .rule_knight = rule_knight };
}
fn restore(snap: *const Snapshot) void {
    cages = snap.cages;
    cage_n = snap.cage_n;
    thermos = snap.thermos;
    thermo_n = snap.thermo_n;
    links = snap.links;
    link_n = snap.link_n;
    digits = snap.digits;
    wanted = snap.wanted;
    parity = snap.parity;
    rule_diagonals = snap.rule_diagonals;
    rule_knight = snap.rule_knight;
    sel_cage = -1;
    sel_edge = null;
    stroking = false;
    reanalyse();
}

// ------------------------------------------------------------------ share codes

// A puzzle as text: "SF1" followed by base64url of a byte stream. The stream
// is a version byte, the rule bits, then five counted lists: cages (length,
// sum, cells), lines (kind, length, cells), signs (two cells, operator,
// operand), digits (cell, digit with bit 7 set when only wanted) and cell
// marks (cell, kind).
const CODE_PREFIX = "SF1";
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn encode(out: []u8) []const u8 {
    var raw: [2048]u8 = undefined;
    var n: usize = 0;
    raw[0] = 1;
    raw[1] = @intCast(rules());
    raw[2] = @intCast(cage_n);
    n = 3;
    for (cages[0..cage_n]) |g| {
        raw[n] = g.n;
        raw[n + 1] = @intCast(g.sum);
        @memcpy(raw[n + 2 .. n + 2 + g.n], g.cells[0..g.n]);
        n += 2 + g.n;
    }
    raw[n] = @intCast(thermo_n);
    n += 1;
    for (thermos[0..thermo_n]) |t| {
        raw[n] = t.kind;
        raw[n + 1] = t.n;
        @memcpy(raw[n + 2 .. n + 2 + t.n], t.cells[0..t.n]);
        n += 2 + t.n;
    }
    raw[n] = @intCast(link_n);
    n += 1;
    for (links[0..link_n]) |l| {
        raw[n..][0..4].* = .{ l.a, l.b, l.op, l.val };
        n += 4;
    }
    const digit_count = n;
    raw[n] = 0;
    n += 1;
    for (0..81) |c| {
        if (digits[c] == 0) continue;
        raw[n] = @intCast(c);
        raw[n + 1] = digits[c] | (@as(u8, @intFromBool(wanted[c])) << 7);
        n += 2;
        raw[digit_count] += 1;
    }
    const mark_count = n;
    raw[n] = 0;
    n += 1;
    for (0..81) |c| {
        if (parity[c] == 0) continue;
        raw[n] = @intCast(c);
        raw[n + 1] = parity[c];
        n += 2;
        raw[mark_count] += 1;
    }

    @memcpy(out[0..CODE_PREFIX.len], CODE_PREFIX);
    var o: usize = CODE_PREFIX.len;
    var i: usize = 0;
    while (i < n) : (i += 3) {
        const b0: u32 = raw[i];
        const b1: u32 = if (i + 1 < n) raw[i + 1] else 0;
        const b2: u32 = if (i + 2 < n) raw[i + 2] else 0;
        const v = b0 << 16 | b1 << 8 | b2;
        out[o] = B64[v >> 18];
        out[o + 1] = B64[(v >> 12) & 63];
        o += 2;
        if (i + 1 < n) {
            out[o] = B64[(v >> 6) & 63];
            o += 1;
        }
        if (i + 2 < n) {
            out[o] = B64[v & 63];
            o += 1;
        }
    }
    return out[0..o];
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn byte(r: *Reader) ?u8 {
        if (r.at >= r.bytes.len) return null;
        r.at += 1;
        return r.bytes[r.at - 1];
    }
    fn cell(r: *Reader) ?u8 {
        const c = r.byte() orelse return null;
        return if (c < 81) c else null;
    }
};

/// Parse a share code into a snapshot. Null when the text is not a valid code.
fn decode(text: []const u8) ?Snapshot {
    var start: usize = 0;
    while (start < text.len and text[start] <= ' ') start += 1;
    var end = text.len;
    while (end > start and text[end - 1] <= ' ') end -= 1;
    const body = text[start..end];
    if (body.len < CODE_PREFIX.len or !std.mem.eql(u8, body[0..CODE_PREFIX.len], CODE_PREFIX)) return null;

    var raw: [2048]u8 = undefined;
    var n: usize = 0;
    var acc: u32 = 0;
    var bits: u32 = 0;
    for (body[CODE_PREFIX.len..]) |ch| {
        const v = std.mem.indexOfScalar(u8, B64, ch) orelse return null;
        acc = (acc << 6) | @as(u32, @intCast(v));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n >= raw.len) return null;
            raw[n] = @truncate(acc >> @intCast(bits));
            n += 1;
        }
    }

    var r: Reader = .{ .bytes = raw[0..n] };
    var snap: Snapshot = undefined;
    if ((r.byte() orelse return null) != 1) return null;
    const rule_bits = r.byte() orelse return null;
    snap.rule_diagonals = rule_bits & 1 != 0;
    snap.rule_knight = rule_bits & 2 != 0;

    var taken: [81]bool = @splat(false);
    snap.cage_n = r.byte() orelse return null;
    if (snap.cage_n > 81) return null;
    for (0..snap.cage_n) |i| {
        var g: Cage = .{};
        g.n = r.byte() orelse return null;
        g.sum = r.byte() orelse return null;
        if (g.n < 1 or g.n > 9 or g.sum > 45) return null;
        for (0..g.n) |k| {
            g.cells[k] = r.cell() orelse return null;
            if (taken[g.cells[k]]) return null;
            taken[g.cells[k]] = true;
        }
        snap.cages[i] = g;
    }
    snap.thermo_n = r.byte() orelse return null;
    if (snap.thermo_n > MAX_THERMOS) return null;
    for (0..snap.thermo_n) |i| {
        var t: Thermo = .{};
        t.kind = r.byte() orelse return null;
        t.n = r.byte() orelse return null;
        if (t.kind > sv.Line.palindrome or t.n < 2 or t.n > 9) return null;
        for (0..t.n) |k| t.cells[k] = r.cell() orelse return null;
        snap.thermos[i] = t;
    }
    snap.link_n = r.byte() orelse return null;
    if (snap.link_n > sv.MAX_LINK) return null;
    for (0..snap.link_n) |i| {
        const a = r.cell() orelse return null;
        const b = r.cell() orelse return null;
        const op = r.byte() orelse return null;
        const val = r.byte() orelse return null;
        if (op < sv.Link.less or op > sv.Link.ratio or !orth(a, b)) return null;
        snap.links[i] = .{ .a = a, .b = b, .op = op, .val = val };
    }
    snap.digits = @splat(0);
    snap.wanted = @splat(false);
    for (0..(r.byte() orelse return null)) |_| {
        const c = r.cell() orelse return null;
        const d = r.byte() orelse return null;
        if (d & 127 < 1 or d & 127 > 9) return null;
        snap.digits[c] = d & 127;
        snap.wanted[c] = d & 128 != 0;
    }
    snap.parity = @splat(0);
    for (0..(r.byte() orelse return null)) |_| {
        const c = r.cell() orelse return null;
        const kind = r.byte() orelse return null;
        if (kind < 1 or kind > 2) return null;
        snap.parity[c] = kind;
    }
    return snap;
}

/// Replace the board with the puzzle in a share code, as one undoable step.
/// Plain-text summary of the analysis, for scripted checks.
pub fn report(out: []u8) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn f(o: []u8, at: *usize, comptime fmt: []const u8, args: anytype) void {
            const w = std.fmt.bufPrint(o[at.*..], fmt, args) catch return;
            at.* += w.len;
        }
    }.f;
    var forced: u32 = 0;
    var settled: u32 = 0;
    for (an.cand) |m| forced += @intFromBool(m != 0 and m & (m - 1) == 0);
    for (ex.cand) |m| settled += @intFromBool(m != 0 and m & (m - 1) == 0);
    put(out, &n, "status {d} guesses {d} forced {d} settled {d} unsure {d}\n", .{ an.status, an.guesses, forced, settled, ex.unsure });
    var total: u32 = 0;
    for (an.cand) |m| total += @popCount(m);
    put(out, &n, "candidates {d} r3c3 {b:0>9}\n", .{ total, an.cand[20] });
    put(out, &n, "logic ", .{});
    for (an.cand) |m| put(out, &n, "{c}", .{@as(u8, if (m != 0 and m & (m - 1) == 0) '1' + @as(u8, @ctz(m)) else '.')});
    if (knownSolution()) |sol| {
        put(out, &n, "\nsolution ", .{});
        for (sol) |d| put(out, &n, "{d}", .{d});
    }
    if (sug.has) {
        put(out, &n, "\nsuggest {d}:", .{sug.added_n});
        for (sug.added, 0..) |d, c| {
            if (d != 0) put(out, &n, " {d}={d}", .{ c, d });
        }
    }
    put(out, &n, "\nsteps", .{});
    for (STEP_KEYS, 0..) |name, i| put(out, &n, " {s}={d}", .{ name, stepCount(i) });
    put(out, &n, "\n", .{});
    return out[0..n];
}

pub fn setLogicLevel(level: u32) void {
    sv.setDeepLogic(level);
    reanalyse();
}

pub fn loadCode(text: []const u8) bool {
    const snap = decode(text) orelse return false;
    restore(&snap);
    edited();
    return true;
}

// ------------------------------------------------------------------ SudokuPad export

// SudokuPad opens puzzles written in the f-puzzles JSON format, compressed
// with lz-string and appended to its address. Wanted digits are left out:
// they are the setter's notes, not part of the puzzle.

const Json = struct {
    buf: [lz.max_input_len]u8 = undefined,
    n: usize = 0,
    overflow: bool = false,

    fn put(j: *Json, text: []const u8) void {
        if (j.n + text.len > j.buf.len) {
            j.overflow = true;
            return;
        }
        @memcpy(j.buf[j.n .. j.n + text.len], text);
        j.n += text.len;
    }
    /// A cell reference such as "R3C7", quoted.
    fn cellRef(j: *Json, c: usize) void {
        const text = [_]u8{ '"', 'R', '1' + @as(u8, @intCast(c / 9)), 'C', '1' + @as(u8, @intCast(c % 9)), '"' };
        j.put(&text);
    }
    fn cellList(j: *Json, cells: []const u8) void {
        j.put("[");
        for (cells, 0..) |c, i| {
            if (i > 0) j.put(",");
            j.cellRef(c);
        }
        j.put("]");
    }
    fn number(j: *Json, v: u32) void {
        var tmp: [12]u8 = undefined;
        j.put(std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0");
    }
};

/// The cells from the bulb to the end of thermometer `i`, following it back
/// through the thermometer it branches from.
fn fullPath(i: usize, out: *[40]u8, depth: u32) usize {
    const t = thermos[i];
    var n: usize = 0;
    if (depth < 4) {
        for (thermos[0..thermo_n], 0..) |parent, k| {
            if (k == i or parent.kind != 0 or parent.n < 2) continue;
            const at = std.mem.indexOfScalar(u8, parent.cells[1..parent.n], t.cells[0]) orelse continue;
            var head: [40]u8 = undefined;
            const head_n = fullPath(k, &head, depth + 1);
            const keep = head_n - (parent.n - 1 - at);
            @memcpy(out[0..keep], head[0..keep]);
            n = keep;
            break;
        }
    }
    for (t.cells[0..t.n]) |c| {
        if (n < out.len) {
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

/// Write every line of one kind, grouped by starting cell, as f-puzzles
/// entries. Arrows also name their circle.
fn putGrouped(j: *Json, name: []const u8, kind: u8) void {
    var paths: [MAX_THERMOS][40]u8 = undefined;
    var lens: [MAX_THERMOS]usize = @splat(0);
    var any = false;
    for (thermos[0..thermo_n], 0..) |t, i| {
        if (t.kind != kind) continue;
        if (kind == 0) {
            lens[i] = fullPath(i, &paths[i], 0);
        } else {
            @memcpy(paths[i][0..t.n], t.cells[0..t.n]);
            lens[i] = t.n;
        }
        any = true;
    }
    if (!any) return;
    j.put(",\"");
    j.put(name);
    j.put("\":[");
    var first_entry = true;
    for (0..thermo_n) |i| {
        if (lens[i] == 0) continue;
        const start = paths[i][0];
        var seen = false;
        for (0..i) |k| seen = seen or (lens[k] != 0 and paths[k][0] == start);
        if (seen) continue;
        if (!first_entry) j.put(",");
        first_entry = false;
        j.put("{");
        if (kind == sv.Line.arrow) {
            j.put("\"cells\":[");
            j.cellRef(start);
            j.put("],");
        }
        j.put("\"lines\":[");
        var first_line = true;
        for (i..thermo_n) |k| {
            if (lens[k] == 0 or paths[k][0] != start) continue;
            if (!first_line) j.put(",");
            first_line = false;
            j.cellList(paths[k][0..lens[k]]);
        }
        j.put("]}");
    }
    j.put("]");
}

/// Coloured lines that SudokuPad draws but does not check.
fn putCosmeticLines(j: *Json) void {
    var first = true;
    for (thermos[0..thermo_n]) |t| {
        if (t.kind != sv.Line.whisper and t.kind != sv.Line.renban) continue;
        j.put(if (first) ",\"line\":[" else ",");
        first = false;
        j.put("{\"lines\":[");
        j.cellList(t.cells[0..t.n]);
        j.put(if (t.kind == sv.Line.whisper) "],\"outlineC\":\"#67F067\",\"width\":0.3}" else "],\"outlineC\":\"#F067F0\",\"width\":0.3}");
    }
    if (!first) j.put("]");
}

fn putLinks(j: *Json, name: []const u8, op: u8) void {
    var first = true;
    for (links[0..link_n]) |l| {
        if (l.op != op) continue;
        j.put(if (first) ",\"" else ",");
        if (first) {
            j.put(name);
            j.put("\":[");
        }
        first = false;
        const lo = @min(l.a, l.b);
        const hi = @max(l.a, l.b);
        j.put("{\"cells\":");
        j.cellList(&.{ lo, hi });
        switch (op) {
            sv.Link.sum => j.put(if (l.val == 10) ",\"value\":\"X\"}" else ",\"value\":\"V\"}"),
            sv.Link.less => {
                // The sign opens towards the larger cell. Vertical pairs use
                // the logical "and" and "or" signs, written as escapes.
                const sign: []const u8 = if (hi - lo == 1) (if (l.a == lo) "<" else ">") else (if (l.a == lo) "\\u2227" else "\\u2228");
                j.put(",\"value\":\"");
                j.put(sign);
                j.put("\",\"fontC\":\"#000000\",\"size\":0.5,\"angle\":0}");
            },
            else => j.put("}"),
        }
    }
    if (!first) j.put("]");
}

fn hasLine(kind: u8) bool {
    for (thermos[0..thermo_n]) |t| {
        if (t.kind == kind) return true;
    }
    return false;
}
fn hasLink(op: u8) bool {
    for (links[0..link_n]) |l| {
        if (l.op == op) return true;
    }
    return false;
}

/// The puzzle as a link that opens in SudokuPad. Null when it does not fit.
pub fn sudokuPadLink(out: []u8) ?[]const u8 {
    const S = struct {
        var j: Json = .{};
        var packed_text: [lz.max_input_len * 2]u8 = undefined;
    };
    const j = &S.j;
    j.* = .{};
    j.put("{\"size\":9,\"title\":\"Sudoku Forge puzzle\",\"author\":\"\",\"ruleset\":\"Normal sudoku rules apply.");
    if (rule_diagonals) j.put(" Digits do not repeat on the two main diagonals.");
    if (rule_knight) j.put(" Cells a knight's move apart hold different digits.");
    if (cage_n > 0) j.put(" Digits in a cage do not repeat and add up to the number in its corner, if one is given.");
    if (hasLine(0)) j.put(" Digits on a thermometer increase from the bulb.");
    if (hasLine(sv.Line.arrow)) j.put(" Digits along an arrow add up to the digit in its circle.");
    if (hasLine(sv.Line.whisper)) j.put(" Neighbouring digits on a green line differ by at least 5.");
    if (hasLine(sv.Line.renban)) j.put(" A purple line holds a set of consecutive digits in any order.");
    if (hasLine(sv.Line.palindrome)) j.put(" A grey line reads the same from both ends.");
    if (hasLink(sv.Link.diff)) j.put(" Cells joined by a white dot hold consecutive digits.");
    if (hasLink(sv.Link.ratio)) j.put(" Cells joined by a black dot hold digits in a 1:2 ratio.");
    if (hasLink(sv.Link.sum)) j.put(" Cells joined by an X add up to 10, by a V to 5.");
    if (hasLink(sv.Link.less)) j.put(" An inequality sign points at the smaller digit.");
    var odd_n: u32 = 0;
    var even_n: u32 = 0;
    for (parity) |m| {
        odd_n += @intFromBool(m == 1);
        even_n += @intFromBool(m == 2);
    }
    if (odd_n > 0) j.put(" A cell with a grey circle is odd.");
    if (even_n > 0) j.put(" A cell with a grey square is even.");
    j.put("\",\"grid\":[");
    for (0..9) |r| {
        j.put(if (r == 0) "[" else ",[");
        for (0..9) |c| {
            if (c > 0) j.put(",");
            const d = digits[r * 9 + c];
            if (d != 0 and !wanted[r * 9 + c]) {
                j.put("{\"value\":");
                j.number(d);
                j.put(",\"given\":true}");
            } else j.put("{}");
        }
        j.put("]");
    }
    j.put("]");
    if (rule_diagonals) j.put(",\"diagonal+\":true,\"diagonal-\":true");
    if (rule_knight) j.put(",\"antiknight\":true");
    if (cage_n > 0) {
        j.put(",\"killercage\":[");
        for (cages[0..cage_n], 0..) |g, i| {
            if (i > 0) j.put(",");
            j.put("{\"cells\":");
            j.cellList(g.cells[0..g.n]);
            if (g.sum != 0) {
                j.put(",\"value\":\"");
                j.number(g.sum);
                j.put("\"");
            }
            j.put("}");
        }
        j.put("]");
    }
    putGrouped(j, "thermometer", 0);
    putGrouped(j, "arrow", sv.Line.arrow);
    putGrouped(j, "palindrome", sv.Line.palindrome);
    putCosmeticLines(j);
    putLinks(j, "difference", sv.Link.diff);
    putLinks(j, "ratio", sv.Link.ratio);
    putLinks(j, "xv", sv.Link.sum);
    putLinks(j, "text", sv.Link.less);
    inline for (.{ "odd", "even" }, 1..) |name, kind| {
        var first = true;
        for (0..81) |c| {
            if (parity[c] != kind) continue;
            j.put(if (first) ",\"" ++ name ++ "\":[{\"cell\":" else ",{\"cell\":");
            first = false;
            j.cellRef(c);
            j.put("}");
        }
        if (!first) j.put("]");
    }
    j.put("}");
    if (j.overflow) return null;

    const data = lz.compressToBase64(j.buf[0..j.n], &S.packed_text) orelse return null;
    const base = "https://sudokupad.app/fpuzzles";
    if (out.len < base.len) return null;
    @memcpy(out[0..base.len], base);
    var n: usize = base.len;
    for (data) |ch| {
        const esc: ?[]const u8 = switch (ch) {
            '+' => "%2B",
            '/' => "%2F",
            '=' => "%3D",
            else => null,
        };
        const piece: []const u8 = esc orelse &[_]u8{ch};
        if (n + piece.len > out.len) return null;
        @memcpy(out[n .. n + piece.len], piece);
        n += piece.len;
    }
    return out[0..n];
}

var link_buf: [40000]u8 = undefined;

fn copySudokuPadLink() void {
    if (sudokuPadLink(&link_buf)) |link| {
        host.copy(link);
        notice = "SudokuPad link copied. Wanted digits are not included.";
    } else notice = "The puzzle is too large for a link.";
}

/// One line of feedback under the share buttons, cleared by the next action.
var notice: []const u8 = "";

fn copyCode() void {
    var buf: [3000]u8 = undefined;
    host.copy(encode(&buf));
    notice = "Code copied. Paste it into a message to share the puzzle.";
}
fn pasteCode() void {
    var buf: [4096]u8 = undefined;
    notice = if (loadCode(host.paste(&buf))) "Puzzle loaded from the clipboard." else "The clipboard does not hold a Sudoku Forge code.";
}

/// The first snapshot is the empty board, taken before any edit.
pub fn init() void {
    sv.setDeepLogic(31);
    history[0] = capture();
    hist_n = 1;
    hist_at = 0;
}

fn canUndo() bool {
    return hist_at > 0;
}
fn canRedo() bool {
    return hist_at + 1 < hist_n;
}
fn undo() void {
    if (!canUndo()) return;
    hist_at -= 1;
    restore(&history[hist_at]);
}
fn redo() void {
    if (!canRedo()) return;
    hist_at += 1;
    restore(&history[hist_at]);
}

/// Call after every change to the clues: records an undo step and re-analyses.
fn edited() void {
    if (hist_at + 1 == HISTORY) {
        for (1..HISTORY) |i| history[i - 1] = history[i];
        hist_at -= 1;
    }
    hist_at += 1;
    history[hist_at] = capture();
    hist_n = hist_at + 1;
    reanalyse();
}

fn reanalyse() void {
    pick_n = 0;
    if (sel_cage >= @as(i32, @intCast(cage_n))) sel_cage = -1;
    runAnalysis();
    keepHint();
    sug = .{};
    ex = .{};
    if (isOpen()) {
        ex.active = true;
        ex.cand = an.cand;
    }
    if (isOpen() and !an.wanted_impossible) {
        sug.active = true;
        sug.delay = 6;
    }
}

/// Advance the background search a little. Returns true when a repaint is due.
pub fn tick() bool {
    if (stroking) return false;
    if (ex.active and !ex.done) {
        wanted_as_given = assume_wanted;
        writeClues();
        wanted_as_given = false;
        var probes: u32 = 0;
        while (ex.at < 729 and probes < 3) : (ex.at += 1) {
            const c = ex.at / 9;
            const bit = @as(u16, 1) << @intCast(ex.at % 9);
            if (ex.cand[c] & bit == 0 or ex.seen[c] & bit != 0) continue;
            probes += 1;
            switch (sv.probe(@intCast(c), @intCast(ex.at % 9 + 1), 300, 1)) {
                1 => {
                    const sol = sv.analysisSolutionPtr();
                    for (0..81) |i| ex.seen[i] |= @as(u16, 1) << @intCast(sol[i] - 1);
                },
                0 => ex.cand[c] &= ~bit,
                else => ex.unsure += 1,
            }
        }
        if (ex.at >= 729) ex.done = true;
        return true;
    }
    if (!sug.active or sug.done) return false;
    if (sug.delay > 0) {
        sug.delay -= 1;
        return false;
    }
    var redraw = false;
    for (0..1) |_| {
        writeClues();
        const code = sv.generate(rnd() | 1, 0, 4, 0, 1, 0, 100, 1, 1, 1);
        sug.tries += 1;
        // The generator also answers 2 when its randomised grid search runs
        // out of budget, so only believe it while no solution is known.
        if (code == 2 and an.status == sv.Status.unknown and !sug.has) {
            sug.impossible = true;
            sug.done = true;
            return true;
        }
        if (code == 1) {
            // A generated single-cell cage is a given digit.
            const cage = sv.cagePtr();
            const sol = sv.solutionPtr();
            var size: [256]u8 = @splat(0);
            for (0..81) |c| size[cage[c]] +|= 1;
            var added: [81]u8 = @splat(0);
            var n: u32 = 0;
            for (0..81) |c| {
                if (cage[c] == sv.NONE or size[cage[c]] != 1 or (digits[c] != 0 and !wanted[c]) or userSingle(c)) continue;
                added[c] = sol[c];
                n += 1;
            }
            if (!sug.has or n < sug.added_n) {
                sug.has = true;
                sug.added = added;
                sug.added_n = n;
                for (0..81) |c| sug.sol[c] = sol[c];
                keepHint();
                redraw = true;
            }
        }
        if (sug.tries >= SUGGEST_TRIES) {
            sug.done = true;
            return true;
        }
    }
    return redraw or sug.tries % 12 == 0;
}

fn userSingle(c: usize) bool {
    for (cages[0..cage_n]) |g| {
        if (g.n == 1 and g.cells[0] == c) return true;
    }
    return false;
}

// ------------------------------------------------------------------ editing

fn orth(a: usize, b: usize) bool {
    const d = if (a > b) a - b else b - a;
    return d == 9 or (d == 1 and a / 9 == b / 9);
}
fn king(a: usize, b: usize) bool {
    const dc = @as(i32, @intCast(a % 9)) - @as(i32, @intCast(b % 9));
    const dr = @as(i32, @intCast(a / 9)) - @as(i32, @intCast(b / 9));
    return a != b and @abs(dc) <= 1 and @abs(dr) <= 1;
}
fn has(cells: []const u8, c: usize) bool {
    for (cells) |x| {
        if (x == c) return true;
    }
    return false;
}
fn cageAt(c: usize) i32 {
    for (cages[0..cage_n], 0..) |g, i| {
        if (has(g.cells[0..g.n], c)) return @intCast(i);
    }
    return -1;
}

fn connected(cells: []const u8) bool {
    var seen: [9]bool = @splat(false);
    seen[0] = true;
    var count: usize = 1;
    var grew = true;
    while (grew) {
        grew = false;
        for (cells, 0..) |c, i| {
            if (seen[i]) continue;
            for (cells, 0..) |d, k| {
                if (seen[k] and orth(c, d)) {
                    seen[i] = true;
                    count += 1;
                    grew = true;
                    break;
                }
            }
        }
    }
    return count == cells.len;
}

fn removeCage(i: usize) void {
    for (i..cage_n - 1) |k| cages[k] = cages[k + 1];
    cage_n -= 1;
}
fn removeThermo(i: usize) void {
    for (i..thermo_n - 1) |k| thermos[k] = thermos[k + 1];
    thermo_n -= 1;
}

fn removeLink(i: usize) void {
    for (i..link_n - 1) |k| links[k] = links[k + 1];
    link_n -= 1;
}
fn linkAt(e: [2]u8) ?usize {
    for (links[0..link_n], 0..) |l, i| {
        if ((l.a == e[0] and l.b == e[1]) or (l.a == e[1] and l.b == e[0])) return i;
    }
    return null;
}
fn signOf(l: Link, e: [2]u8) ?Sign {
    return switch (l.op) {
        sv.Link.less => if (l.a == e[0]) .less else .greater,
        sv.Link.sum => if (l.val == 10) .x else .v,
        sv.Link.diff => .white,
        sv.Link.ratio => .black,
        else => null,
    };
}
/// Put a sign on the selected border, or clear it with null.
fn setSign(sign: ?Sign) void {
    const e = sel_edge orelse return;
    if (linkAt(e)) |i| removeLink(i);
    if (sign) |sg| {
        if (link_n >= sv.MAX_LINK) return;
        links[link_n] = switch (sg) {
            .less => .{ .a = e[0], .b = e[1], .op = sv.Link.less, .val = 0 },
            .greater => .{ .a = e[1], .b = e[0], .op = sv.Link.less, .val = 0 },
            .x => .{ .a = e[0], .b = e[1], .op = sv.Link.sum, .val = 10 },
            .v => .{ .a = e[0], .b = e[1], .op = sv.Link.sum, .val = 5 },
            .white => .{ .a = e[0], .b = e[1], .op = sv.Link.diff, .val = 1 },
            .black => .{ .a = e[0], .b = e[1], .op = sv.Link.ratio, .val = 2 },
        };
        link_n += 1;
    }
    edited();
}

fn finishStroke() void {
    if (!stroking) return;
    stroking = false;
    const cells = stroke.cells[0..stroke.n];
    if (tool == .cage) {
        const hit = cageAt(cells[0]);
        if (cells.len == 1 and hit >= 0) {
            sel_cage = hit;
            return;
        }
        // Cells taken from another cage leave it without a sum; a cage that
        // falls apart is dropped.
        var i: usize = 0;
        while (i < cage_n) {
            var g = &cages[i];
            var kept: u8 = 0;
            for (g.cells[0..g.n]) |c| {
                if (!has(cells, c)) {
                    g.cells[kept] = c;
                    kept += 1;
                }
            }
            if (kept != g.n) {
                g.n = kept;
                g.sum = 0;
            }
            if (kept == 0 or !connected(g.cells[0..kept])) removeCage(i) else i += 1;
        }
        var g: Cage = .{ .n = stroke.n };
        @memcpy(g.cells[0..g.n], cells);
        std.mem.sort(u8, g.cells[0..g.n], {}, std.sort.asc(u8));
        cages[cage_n] = g;
        sel_cage = @intCast(cage_n);
        cage_n += 1;
        // With the new cage in place, a grid that still fits every clue
        // says what the cage adds up to.
        if (auto_sum and hint_ok) {
            wanted_as_given = assume_wanted;
            writeClues();
            wanted_as_given = false;
            if (sv.checkGrid(&hint_sol) == 1) {
                var sum: u16 = 0;
                for (g.cells[0..g.n]) |c| sum += hint_sol[c];
                cages[cage_n - 1].sum = sum;
            }
        }
    } else if (tool == .thermo and cells.len >= 2) {
        // Thermometers may cross and share cells. One that starts on another
        // is drawn as a branch of it.
        var same: usize = 0;
        for (thermos[0..thermo_n]) |t| same += @intFromBool((t.kind == 0) == (line_kind == 0));
        if (same >= (if (line_kind == 0) @as(usize, sv.MAX_THERMO) else sv.MAX_LINE)) return;
        stroke.kind = line_kind;
        thermos[thermo_n] = stroke;
        thermo_n += 1;
    } else return;
    edited();
}

fn picked() ?Pick {
    return if (tool == .select and pick_n > 0) picks[pick_at] else null;
}

/// The cage that typed digits go to: the one chosen in the Cage tool, or the
/// one singled out with Select.
fn activeCage() i32 {
    if (tool == .cage) return sel_cage;
    if (picked()) |p| switch (p) {
        .cage => |i| return @intCast(i),
        else => {},
    };
    return -1;
}

/// List what lies at a point. Clicking the same cell again steps down a layer.
fn pickAt(c: usize, x: f64, y: f64, step: bool) void {
    const before = pick_n;
    const at = pick_at;
    const again = step and before > 0 and pick_cell == c;
    pick_n = 0;
    if (nearestEdge(c, x, y, 0.25)) |e| {
        if (linkAt(e)) |i| {
            picks[pick_n] = .{ .link = i };
            pick_n += 1;
        }
    }
    if (digits[c] != 0) {
        picks[pick_n] = .{ .digit = c };
        pick_n += 1;
    }
    if (parity[c] != 0) {
        picks[pick_n] = .{ .mark = c };
        pick_n += 1;
    }
    var i = thermo_n;
    while (i > 0) {
        i -= 1;
        if (has(thermos[i].cells[0..thermos[i].n], c)) {
            picks[pick_n] = .{ .line = i };
            pick_n += 1;
        }
    }
    const g = cageAt(c);
    if (g >= 0) {
        picks[pick_n] = .{ .cage = @intCast(g) };
        pick_n += 1;
    }
    pick_cell = c;
    pick_pos = .{ x, y };
    pick_at = if (again and pick_n == before) (at + 1) % pick_n else 0;
}

/// An edit that leaves every clue in place, so the selection stays valid.
fn editedKeepingPick() void {
    const n = pick_n;
    edited();
    pick_n = n;
}

fn deletePicked() void {
    const p = picked() orelse return;
    switch (p) {
        .link => |i| removeLink(i),
        .digit => |c| {
            digits[c] = 0;
            wanted[c] = false;
        },
        .mark => |c| parity[c] = 0,
        .line => |i| removeThermo(i),
        .cage => |i| removeCage(i),
    }
    edited();
    // Whatever else is there moves up, ready to be the next one removed.
    pickAt(pick_cell, pick_pos[0], pick_pos[1], false);
}

fn restylePicked(kind: u8) void {
    const p = picked() orelse return;
    const i = switch (p) {
        .line => |i| i,
        else => return,
    };
    const t = &thermos[i];
    if (t.kind == kind) return;
    if ((t.kind == 0) != (kind == 0)) {
        var same: usize = 0;
        for (thermos[0..thermo_n]) |o| same += @intFromBool((o.kind == 0) == (kind == 0));
        if (same >= (if (kind == 0) @as(usize, sv.MAX_THERMO) else sv.MAX_LINE)) {
            notice = "No room for another line of that style.";
            return;
        }
    }
    t.kind = kind;
    editedKeepingPick();
}

fn reversePicked() void {
    const p = picked() orelse return;
    switch (p) {
        .line => |i| std.mem.reverse(u8, thermos[i].cells[0..thermos[i].n]),
        else => return,
    }
    editedKeepingPick();
}

fn flipPicked() void {
    const p = picked() orelse return;
    switch (p) {
        .digit => |c| wanted[c] = !wanted[c],
        .mark => |c| parity[c] = 3 - parity[c],
        else => return,
    }
    editedKeepingPick();
}

fn lineName(kind: u8) []const u8 {
    return switch (kind) {
        sv.Line.arrow => "Arrow",
        sv.Line.whisper => "Whisper line",
        sv.Line.renban => "Renban line",
        sv.Line.palindrome => "Palindrome",
        else => "Thermometer",
    };
}

fn pickLabel(buf: []u8, p: Pick) []const u8 {
    return switch (p) {
        .link => |i| switch (links[i].op) {
            sv.Link.less => "Inequality sign",
            sv.Link.sum => if (links[i].val == 10) "X, sum of 10" else "V, sum of 5",
            sv.Link.diff => "White dot, consecutive",
            else => "Black dot, double",
        },
        .digit => |c| std.fmt.bufPrint(buf, "{s} digit {d}", .{ if (wanted[c]) "Wanted" else "Given", digits[c] }) catch "",
        .mark => |c| if (parity[c] == 1) "Odd mark" else "Even mark",
        .line => |i| std.fmt.bufPrint(buf, "{s}, {d} cells", .{ lineName(thermos[i].kind), thermos[i].n }) catch "",
        .cage => |i| if (cages[i].sum != 0)
            std.fmt.bufPrint(buf, "Cage of {d}, sum {d}", .{ cages[i].n, cages[i].sum }) catch ""
        else
            std.fmt.bufPrint(buf, "Cage of {d}, sum open", .{cages[i].n}) catch "",
    };
}

/// The full grid to pencil in: the solution when there is exactly one, else
/// the one the search for extra givens is building towards.
fn knownSolution() ?*const [81]u8 {
    if (!an.valid) return null;
    if (an.status == sv.Status.unique) return &an.sol;
    if (sug.has) return &sug.sol;
    return null;
}

/// Remove one thing per click, whichever lies on top at that point: a sign on
/// the nearest border, else the digit, else the odd or even mark, else the
/// newest thermometer through the cell, else its cage.
fn eraseAt(c: usize, x: f64, y: f64) void {
    sel_cage = -1;
    sel_edge = null;
    if (nearestEdge(c, x, y, 0.25)) |e| {
        if (linkAt(e)) |i| {
            removeLink(i);
            return edited();
        }
    }
    if (digits[c] != 0) {
        digits[c] = 0;
        wanted[c] = false;
        return edited();
    }
    if (parity[c] != 0) {
        parity[c] = 0;
        return edited();
    }
    var i = thermo_n;
    while (i > 0) {
        i -= 1;
        if (has(thermos[i].cells[0..thermos[i].n], c)) {
            removeThermo(i);
            return edited();
        }
    }
    const g = cageAt(c);
    if (g >= 0) {
        removeCage(@intCast(g));
        edited();
    }
}

/// The border of cell `c` closest to a point, if it is within `reach` cell
/// widths and another cell lies beyond it.
fn nearestEdge(c: usize, x: f64, y: f64, reach: f64) ?[2]u8 {
    const fx = (x - bx) / cell - @as(f64, @floatFromInt(c % 9));
    const fy = (y - by) / cell - @as(f64, @floatFromInt(c / 9));
    const dist = [4]f64{ fx, 1 - fx, fy, 1 - fy };
    var best: usize = 0;
    for (dist, 0..) |d, k| {
        if (d < dist[best]) best = k;
    }
    const ok = [4]bool{ c % 9 > 0, c % 9 < 8, c >= 9, c < 72 };
    if (!ok[best] or dist[best] > reach) return null;
    const other = switch (best) {
        0 => c - 1,
        1 => c + 1,
        2 => c - 9,
        else => c + 9,
    };
    return .{ @intCast(@min(c, other)), @intCast(@max(c, other)) };
}

/// Drop spare clues one at a time until every remaining clue is needed.
fn stripSpare() void {
    for (0..200) |_| {
        runAnalysis();
        if (an.status != sv.Status.unique) break;
        var n: u32 = 0;
        for (0..81) |i| n += @intFromBool(an.red_digit[i]) + @intFromBool(an.red_cage[i]);
        for (0..thermo_n) |i| n += @intFromBool(an.red_thermo[i]);
        for (0..link_n) |i| n += @intFromBool(an.red_link[i]);
        for (0..81) |i| n += @intFromBool(an.red_mark[i]);
        if (n == 0) break;
        var pick = rnd() % n;
        var done = false;
        for (0..81) |i| {
            if (done or !an.red_digit[i]) continue;
            if (pick == 0) {
                digits[i] = 0;
                wanted[i] = false;
                done = true;
            } else pick -= 1;
        }
        for (0..81) |i| {
            if (done or !an.red_cage[i]) continue;
            if (pick == 0) {
                removeCage(i);
                done = true;
            } else pick -= 1;
        }
        for (0..thermo_n) |i| {
            if (done or !an.red_thermo[i]) continue;
            if (pick == 0) {
                removeThermo(i);
                done = true;
            } else pick -= 1;
        }
        for (0..link_n) |i| {
            if (done or !an.red_link[i]) continue;
            if (pick == 0) {
                removeLink(i);
                done = true;
            } else pick -= 1;
        }
        for (0..81) |i| {
            if (done or !an.red_mark[i]) continue;
            if (pick == 0) {
                parity[i] = 0;
                done = true;
            } else pick -= 1;
        }
    }
    sel_cage = -1;
    sel_edge = null;
    edited();
}

fn acceptSuggestion() void {
    if (!sug.has) return;
    for (cages[0..cage_n]) |*g| {
        if (g.sum != 0) continue;
        for (g.cells[0..g.n]) |c| g.sum += sug.sol[c];
    }
    for (0..81) |c| {
        if (sug.added[c] == 0) continue;
        digits[c] = sug.added[c];
        wanted[c] = false;
    }
    edited();
}

fn clearAll() void {
    cage_n = 0;
    thermo_n = 0;
    link_n = 0;
    sel_edge = null;
    digits = @splat(0);
    wanted = @splat(false);
    parity = @splat(0);
    sel_cage = -1;
    edited();
}

// ------------------------------------------------------------------ layout

const MARGIN: f64 = 16;
const PANEL_W: f64 = 290;
var bx: f64 = MARGIN;
var by: f64 = MARGIN;
var cell: f64 = 60;
var px: f64 = 0;

pub fn resize(w: f64, h: f64) void {
    const side = @max(180, @min(h - 2 * MARGIN, w - PANEL_W - 3 * MARGIN));
    cell = side / 9;
    px = bx + side + MARGIN;
}

pub fn cellCenter(c: usize) [2]f64 {
    return .{ bx + (@as(f64, @floatFromInt(c % 9)) + 0.5) * cell, by + (@as(f64, @floatFromInt(c / 9)) + 0.5) * cell };
}

fn cellAt(x: f64, y: f64) ?usize {
    const cx = @floor((x - bx) / cell);
    const cy = @floor((y - by) / cell);
    if (cx < 0 or cx > 8 or cy < 0 or cy > 8) return null;
    return @as(usize, @intFromFloat(cy)) * 9 + @as(usize, @intFromFloat(cx));
}

// ------------------------------------------------------------------ input

/// "Remove all" only acts on a second click straight after the first.
var clear_armed = false;
var clear_was_armed = false;

pub fn pointerDown(x: f64, y: f64) void {
    clear_was_armed = clear_armed;
    clear_armed = false;
    notice = "";
    rng +%= @as(u64, @intFromFloat(@abs(x) * 7919 + @abs(y) * 104729)) | 1;
    const c = cellAt(x, y) orelse {
        panel(false, .{ x, y });
        return;
    };
    switch (tool) {
        .given, .wanted => sel = c,
        .between => sel_edge = nearestEdge(c, x, y, 1) orelse return,
        .erase => eraseAt(c, x, y),
        .select => pickAt(c, x, y, true),
        .parity => {
            parity[c] = (parity[c] + 1) % 3;
            edited();
        },
        .cage, .thermo => {
            stroking = true;
            stroke = .{ .n = 1 };
            stroke.cells[0] = @intCast(c);
        },
    }
}

pub fn pointerMove(x: f64, y: f64) void {
    if (!stroking) return;
    const c = cellAt(x, y) orelse return;
    const last = stroke.cells[stroke.n - 1];
    if (tool == .cage) {
        if (stroke.n >= 9 or has(stroke.cells[0..stroke.n], c)) return;
        // A cage may grow from any of its cells, not only the last one.
        var touches = false;
        for (stroke.cells[0..stroke.n]) |d| touches = touches or orth(c, d);
        if (!touches) return;
    } else {
        // A line only picks a cell up near its middle, so a diagonal drag
        // can slip past the corners of the cells beside it.
        const mid = cellCenter(c);
        const dx = x - mid[0];
        const dy = y - mid[1];
        const reach = cell * 0.38;
        if (dx * dx + dy * dy > reach * reach) return;
        // Dragging back onto the previous cell takes the last one off again.
        if (stroke.n >= 2 and c == stroke.cells[stroke.n - 2]) {
            stroke.n -= 1;
            return;
        }
        if (stroke.n >= 9 or has(stroke.cells[0..stroke.n], c) or !king(c, last)) return;
    }
    stroke.cells[stroke.n] = @intCast(c);
    stroke.n += 1;
}

pub fn pointerUp() void {
    finishStroke();
}

pub fn key(code: u32) void {
    clear_armed = false;
    notice = "";
    if (code == Key.undo) return undo();
    if (code == Key.redo) return redo();
    if (code == Key.copy) return copyCode();
    if (code == Key.paste) return pasteCode();
    if (tool == .between and sel_edge != null) {
        const sign: ?Sign = switch (code) {
            '<', ',' => .less,
            '>', '.' => .greater,
            'x', 'X' => .x,
            'v', 'V' => .v,
            'o', 'O' => .white,
            'k', 'K' => .black,
            else => null,
        };
        if (sign != null or code == Key.backspace or code == 8) return setSign(sign);
    }
    if (picked()) |p| {
        if (code == Key.backspace or code == 8 or code == Key.delete) return deletePicked();
        if (code == Key.tab) {
            pick_at = (pick_at + 1) % pick_n;
            return;
        }
        if (code == Key.escape) {
            pick_n = 0;
            return;
        }
        switch (p) {
            .line => if (code >= '1' and code <= '5') return restylePicked(([_]u8{ 0, sv.Line.arrow, sv.Line.whisper, sv.Line.renban, sv.Line.palindrome })[code - '1']),
            .digit => |c| if (code >= '1' and code <= '9') {
                digits[c] = @intCast(code - '0');
                return editedKeepingPick();
            },
            else => {},
        }
    }
    switch (code) {
        's', 'S' => tool = .select,
        'a', 'A' => show_solution = !show_solution,
        'k', 'K' => {
            assume_wanted = !assume_wanted;
            reanalyse();
        },
        'b', 'B' => tool = .between,
        'p', 'P' => tool = .parity,
        'c', 'C' => tool = .cage,
        't', 'T', 'l', 'L' => tool = .thermo,
        'g', 'G', 'd', 'D' => tool = .given,
        'w', 'W' => tool = .wanted,
        'e', 'E' => tool = .erase,
        Key.up => sel = if (sel >= 9) sel - 9 else sel,
        Key.down => sel = if (sel < 72) sel + 9 else sel,
        Key.left => sel = if (sel % 9 > 0) sel - 1 else sel,
        Key.right => sel = if (sel % 9 < 8) sel + 1 else sel,
        '0'...'9', Key.backspace, 8 => {
            if (tool == .thermo and code >= '1' and code <= '5') {
                line_kind = ([_]u8{ 0, sv.Line.arrow, sv.Line.whisper, sv.Line.renban, sv.Line.palindrome })[code - '1'];
                return;
            }
            const d: u8 = if (code >= '0' and code <= '9') @intCast(code - '0') else 0;
            const erase = code == Key.backspace or code == 8;
            if (tool == .given or tool == .wanted) {
                digits[sel] = d;
                wanted[sel] = d != 0 and tool == .wanted;
                edited();
            } else if (activeCage() >= 0) {
                const at: usize = @intCast(activeCage());
                const g = &cages[at];
                if (erase and g.sum == 0) {
                    removeCage(at);
                    sel_cage = -1;
                    edited();
                } else {
                    const next = g.sum * 10 + d;
                    g.sum = if (erase) 0 else if (next <= 45) next else d;
                    editedKeepingPick();
                }
            }
        },
        else => {},
    }
}

// ------------------------------------------------------------------ drawing

const Theme = struct {
    ink: Color, // digits, cage outlines, heavy grid lines
    muted: Color,
    faint: Color, // spare clues and disabled labels
    paper: Color, // the board
    back: Color, // the window
    grid: Color, // thin grid lines
    border: Color, // button outlines
    accent: Color,
    green: Color,
    red: Color,
    want: Color,
    select: Color,
    stroke: Color,
    thermo: Color,
    thermo_spare: Color,
    mark: Color, // odd and even cells
    mark_spare: Color,
    diagonal: Color,
    whisper: Color,
    renban: Color,
    palindrome: Color,
};
const LIGHT: Theme = .{
    .ink = 0x1A1A1AFF,
    .muted = 0x6B6B6BFF,
    .faint = 0xB4B4B4FF,
    .paper = 0xFFFFFFFF,
    .back = 0xF3F2EEFF,
    .grid = 0xBDBDBDFF,
    .border = 0xC4C4C4FF,
    .accent = 0x2F6FDBFF,
    .green = 0x2E9E4FFF,
    .red = 0xC93B3BFF,
    .want = 0xD9822BFF,
    .select = 0xDCE8FBFF,
    .stroke = 0xFFEDA8FF,
    .thermo = 0xC9C9C9FF,
    .thermo_spare = 0xE9E9E9FF,
    .mark = 0xD6D6D6FF,
    .mark_spare = 0xEFEFEFFF,
    .diagonal = 0xD9C7F0FF,
    .whisper = 0x8ED6A2FF,
    .renban = 0xD3A3EEFF,
    .palindrome = 0xA9C0E6FF,
};
const DARK: Theme = .{
    .ink = 0xE8E6E1FF,
    .muted = 0x9A9892FF,
    .faint = 0x5C5B57FF,
    .paper = 0x1E1F22FF,
    .back = 0x141517FF,
    .grid = 0x45464AFF,
    .border = 0x4A4B50FF,
    .accent = 0x5B93F0FF,
    .green = 0x4CC173FF,
    .red = 0xF06A6AFF,
    .want = 0xF0A04BFF,
    .select = 0x253A5CFF,
    .stroke = 0x5A4E1FFF,
    .thermo = 0x55575CFF,
    .thermo_spare = 0x303136FF,
    .mark = 0x3F4146FF,
    .mark_spare = 0x2A2B2FFF,
    .diagonal = 0x4A3D66FF,
    .whisper = 0x2F7D4AFF,
    .renban = 0x7B4CA3FF,
    .palindrome = 0x4A6190FF,
};
const WHITE: Color = 0xFFFFFFFF;
const BLACK: Color = 0x111111FF;
var dark = false;
var th: Theme = LIGHT;

/// The backend reports the system appearance once at start; the setter can
/// flip it afterwards with the option in the panel.
pub fn setDark(on: bool) void {
    dark = on;
    th = if (on) DARK else LIGHT;
}

pub fn draw(w: f64, h: f64) void {
    resize(w, h);
    host.fillRect(0, 0, w, h, th.back);
    drawBoard();
    panel(true, null);
}

/// A thermometer that starts partway along another one is a branch of it and
/// has no bulb of its own.
fn isBranch(first: u8) bool {
    for (thermos[0..thermo_n]) |t| {
        if (t.kind == 0 and t.n > 1 and has(t.cells[1..t.n], first)) return true;
    }
    return false;
}

fn drawLine(t: *const Thermo, spare: bool, tint: ?Color) void {
    const cells = t.cells[0..t.n];
    var pts: [9][2]f64 = undefined;
    for (cells, 0..) |c, i| pts[i] = cellCenter(c);
    switch (t.kind) {
        0 => {
            const color = tint orelse if (spare) th.thermo_spare else th.thermo;
            if (!isBranch(cells[0])) host.circle(pts[0][0], pts[0][1], cell * 0.3, color);
            if (cells.len > 1) host.polyline(pts[0..cells.len], cell * 0.22, color);
        },
        sv.Line.arrow => {
            // A ring on the sum cell, a thin shaft leaving its edge, and a head.
            const color = tint orelse if (spare) th.faint else th.muted;
            const r = cell * 0.36;
            var ring: [25][2]f64 = undefined;
            for (0..25) |i| {
                const a = @as(f64, @floatFromInt(i)) * (std.math.pi * 2.0 / 24.0);
                ring[i] = .{ pts[0][0] + r * @cos(a), pts[0][1] + r * @sin(a) };
            }
            host.polyline(&ring, 1.6, color);
            if (cells.len < 2) return;
            const d0 = unit(pts[0], pts[1]);
            pts[0] = .{ pts[0][0] + d0[0] * r, pts[0][1] + d0[1] * r };
            const tip = pts[cells.len - 1];
            const d = unit(pts[cells.len - 2], tip);
            const end = [2]f64{ tip[0] + d[0] * cell * 0.25, tip[1] + d[1] * cell * 0.25 };
            pts[cells.len - 1] = end;
            host.polyline(pts[0..cells.len], 1.6, color);
            const h = cell * 0.14;
            host.polyline(&.{
                .{ end[0] - d[0] * h - d[1] * h, end[1] - d[1] * h + d[0] * h },
                end,
                .{ end[0] - d[0] * h + d[1] * h, end[1] - d[1] * h - d[0] * h },
            }, 1.6, color);
        },
        else => {
            const color = tint orelse if (spare) th.thermo_spare else switch (t.kind) {
                sv.Line.whisper => th.whisper,
                sv.Line.renban => th.renban,
                else => th.palindrome,
            };
            if (cells.len > 1) host.polyline(pts[0..cells.len], cell * 0.13, color) else host.circle(pts[0][0], pts[0][1], cell * 0.065, color);
        },
    }
}

fn unit(a: [2]f64, b: [2]f64) [2]f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    return if (len == 0) .{ 0, 0 } else .{ dx / len, dy / len };
}

fn inCage(g: *const Cage, r: i32, c: i32) bool {
    if (r < 0 or r > 8 or c < 0 or c > 8) return false;
    return has(g.cells[0..g.n], @intCast(r * 9 + c));
}

/// How far a border segment's end is pulled in: shortened at an outer corner,
/// extended at an inner one, flush where the border simply continues.
fn endAdjust(ins: f64, along: bool, diagonal: bool) f64 {
    return if (!along) ins else if (diagonal) -ins else 0;
}

fn drawCage(g: *const Cage, color: Color) void {
    const ins = cell * 0.08;
    for (g.cells[0..g.n]) |idx| {
        const r: i32 = @intCast(idx / 9);
        const c: i32 = @intCast(idx % 9);
        const x0 = bx + @as(f64, @floatFromInt(c)) * cell;
        const y0 = by + @as(f64, @floatFromInt(r)) * cell;
        const x1 = x0 + cell;
        const y1 = y0 + cell;
        const l = inCage(g, r, c - 1);
        const rt = inCage(g, r, c + 1);
        const u = inCage(g, r - 1, c);
        const d = inCage(g, r + 1, c);
        if (!u) host.line(x0 + endAdjust(ins, l, inCage(g, r - 1, c - 1)), y0 + ins, x1 - endAdjust(ins, rt, inCage(g, r - 1, c + 1)), y0 + ins, 1.2, color, true);
        if (!d) host.line(x0 + endAdjust(ins, l, inCage(g, r + 1, c - 1)), y1 - ins, x1 - endAdjust(ins, rt, inCage(g, r + 1, c + 1)), y1 - ins, 1.2, color, true);
        if (!l) host.line(x0 + ins, y0 + endAdjust(ins, u, inCage(g, r - 1, c - 1)), x0 + ins, y1 - endAdjust(ins, d, inCage(g, r + 1, c - 1)), 1.2, color, true);
        if (!rt) host.line(x1 - ins, y0 + endAdjust(ins, u, inCage(g, r - 1, c + 1)), x1 - ins, y1 - endAdjust(ins, d, inCage(g, r + 1, c + 1)), 1.2, color, true);
    }
    var buf: [8]u8 = undefined;
    const label = if (g.sum != 0) (std.fmt.bufPrint(&buf, "{d}", .{g.sum}) catch "?") else "?";
    const size = cell * 0.21;
    const first = g.cells[0];
    const lx = bx + @as(f64, @floatFromInt(first % 9)) * cell + ins - 1;
    const ly = by + @as(f64, @floatFromInt(first / 9)) * cell + ins - 1;
    host.fillRect(lx, ly, host.textWidth(size, true, label) + 5, size + 3, th.paper);
    host.text(lx + 2, ly + size * 0.5 + 1.5, size, true, color, .left, label);
}

fn drawLink(l: Link, color: Color) void {
    const a = cellCenter(l.a);
    const b = cellCenter(l.b);
    const mx = (a[0] + b[0]) / 2;
    const my = (a[1] + b[1]) / 2;
    const r = cell * 0.1;
    switch (l.op) {
        sv.Link.less => {
            // A chevron whose point faces the smaller cell.
            const ux = (b[0] - a[0]) / cell;
            const uy = (b[1] - a[1]) / cell;
            host.fillRect(mx - r * 1.3, my - r * 1.3, r * 2.6, r * 2.6, th.paper);
            const tip = [2]f64{ mx - ux * r, my - uy * r };
            host.polyline(&.{ .{ mx + ux * r - uy * r, my + uy * r + ux * r }, tip, .{ mx + ux * r + uy * r, my + uy * r - ux * r } }, 1.8, color);
        },
        sv.Link.sum => {
            const size = cell * 0.26;
            host.fillRect(mx - size * 0.45, my - size * 0.55, size * 0.9, size * 1.1, th.paper);
            host.text(mx, my, size, true, color, .center, if (l.val == 10) "X" else "V");
        },
        sv.Link.diff => {
            host.circle(mx, my, r, color);
            host.circle(mx, my, r - 1.5, WHITE);
        },
        else => {
            host.circle(mx, my, r, color);
            host.circle(mx, my, r - 1.5, BLACK);
        },
    }
}

fn drawBoard() void {
    const side = cell * 9;
    host.fillRect(bx, by, side, side, th.paper);

    const deductions = show_deductions and an.valid and an.status != sv.Status.none;
    const pencil: ?*const [81]u8 = if (show_solution) knownSolution() else null;
    for (0..81) |c| {
        const in_stroke = stroking and has(stroke.cells[0..stroke.n], c);
        const ac = activeCage();
        const pick_here = if (picked()) |p| switch (p) {
            .digit, .mark => |pc| pc == c,
            else => false,
        } else false;
        const selected = pick_here or (ac >= 0 and has(cages[@intCast(ac)].cells[0..cages[@intCast(ac)].n], c)) or ((tool == .given or tool == .wanted) and c == sel);
        if (!in_stroke and !selected) continue;
        const p = cellCenter(c);
        host.fillRect(p[0] - cell / 2, p[1] - cell / 2, cell, cell, if (in_stroke) th.stroke else th.select);
    }

    for (0..81) |c| {
        if (parity[c] == 0) continue;
        const p = cellCenter(c);
        const color: Color = if (an.red_mark[c]) th.mark_spare else th.mark;
        if (parity[c] == 1) host.circle(p[0], p[1], cell * 0.38, color) else host.fillRect(p[0] - cell * 0.36, p[1] - cell * 0.36, cell * 0.72, cell * 0.72, color);
    }

    if (rule_diagonals) {
        host.line(bx, by, bx + side, by + side, 1.5, th.diagonal, false);
        host.line(bx + side, by, bx, by + side, 1.5, th.diagonal, false);
    }

    for (thermos[0..thermo_n], 0..) |*t, i| drawLine(t, an.red_thermo[i], null);
    if (picked()) |p| switch (p) {
        .line => |i| drawLine(&thermos[i], false, th.accent),
        .mark => |c| {
            const m = cellCenter(c);
            const r = cell * 0.38;
            if (parity[c] == 1) {
                var ring: [25][2]f64 = undefined;
                for (0..25) |k| {
                    const a = @as(f64, @floatFromInt(k)) * (std.math.pi * 2.0 / 24.0);
                    ring[k] = .{ m[0] + r * @cos(a), m[1] + r * @sin(a) };
                }
                host.polyline(&ring, 2.5, th.accent);
            } else host.strokeRect(m[0] - r, m[1] - r, r * 2, r * 2, 2.5, th.accent);
        },
        else => {},
    };
    if (stroking and tool == .thermo) {
        stroke.kind = line_kind;
        drawLine(&stroke, false, null);
    }

    for (0..10) |i| {
        const p = @as(f64, @floatFromInt(i)) * cell;
        const major = i % 3 == 0;
        const width: f64 = if (major) 2.5 else 1;
        const color: Color = if (major) th.ink else th.grid;
        host.line(bx + p, by, bx + p, by + side, width, color, false);
        host.line(bx, by + p, bx + side, by + p, width, color, false);
    }

    for (cages[0..cage_n], 0..) |*g, i| drawCage(g, if (an.red_cage[i]) th.faint else th.ink);

    {
        var edge: ?[2]u8 = if (tool == .between) sel_edge else null;
        if (picked()) |p| switch (p) {
            .link => |i| edge = .{ links[i].a, links[i].b },
            else => {},
        };
        if (edge) |e| {
            const a = cellCenter(e[0]);
            const b = cellCenter(e[1]);
            const mx = (a[0] + b[0]) / 2;
            const my = (a[1] + b[1]) / 2;
            // The shared border runs across the line joining the two centres.
            const hx = (b[1] - a[1]) / 2;
            const hy = (b[0] - a[0]) / 2;
            host.line(mx - hx, my - hy, mx + hx, my + hy, 4, th.accent, false);
        }
    }
    const picked_link: ?usize = if (picked()) |p| switch (p) {
        .link => |i| i,
        else => null,
    } else null;
    for (links[0..link_n], 0..) |l, i| drawLink(l, if (picked_link == i) th.accent else if (an.red_link[i]) th.faint else th.ink);

    for (0..81) |c| {
        const p = cellCenter(c);
        const own = digits[c];
        const logic: u16 = if (deductions) an.cand[c] else 0;
        const cand: u16 = if (deductions and ex.active) ex.cand[c] else logic;
        const forced: u8 = if (cand != 0 and cand & (cand - 1) == 0) @as(u8, @ctz(cand)) + 1 else 0;
        // Settled only by ruling out every alternative, beyond the solver's logic.
        const deep = forced != 0 and logic != cand;
        const ghost = if (sug.has) sug.added[c] else 0;
        const d = if (own != 0) own else if (forced != 0) forced else ghost;
        if (d != 0) {
            // A wanted digit turns red once the clues force something else
            // there, and green when the search proposes making it a given.
            const clash = wanted[c] and ((forced != 0 and forced != own) or (cand != 0 and cand & (@as(u16, 1) << @intCast(own - 1)) == 0));
            const color: Color = if (own != 0 and wanted[c]) (if (clash) th.red else if (ghost != 0) th.green else th.want) else if (own != 0) (if (an.red_digit[c]) th.faint else th.ink) else if (forced != 0) (if (deep) th.renban else th.accent) else th.green;
            const ch = [1]u8{'0' + d};
            host.text(p[0], p[1] + cell * 0.03, cell * 0.56, own != 0 and !wanted[c], color, .center, &ch);
        } else if (pencil != null) {
            const ch = [1]u8{'0' + pencil.?[c]};
            host.text(p[0], p[1] + cell * 0.03, cell * 0.32, false, th.muted, .center, &ch);
        } else if (cand != 0 and @popCount(cand) <= 6) {
            for (0..9) |k| {
                if (cand & (@as(u16, 1) << @intCast(k)) == 0) continue;
                const ch = [1]u8{'1' + @as(u8, @intCast(k))};
                const mx = p[0] + (@as(f64, @floatFromInt(k % 3)) - 1) * cell * 0.27;
                const my = p[1] + (@as(f64, @floatFromInt(k / 3)) - 1) * cell * 0.27 + cell * 0.04;
                host.text(mx, my, cell * 0.2, false, th.muted, .center, &ch);
            }
        }
    }
}

// ------------------------------------------------------------------ panel

/// One pass over the side panel. With `paint` it draws; with `hit` it acts on
/// a click at that point. Both walk the same layout, so they cannot disagree.
const Ui = struct {
    paint: bool,
    hit: ?[2]f64,
    y: f64,

    fn clicked(ui: *const Ui, x: f64, y: f64, w: f64, h: f64) bool {
        const p = ui.hit orelse return false;
        return p[0] >= x and p[0] < x + w and p[1] >= y and p[1] < y + h;
    }

    fn button(ui: *Ui, x: f64, w: f64, label: []const u8, enabled: bool, active: bool) bool {
        const h: f64 = 30;
        if (ui.paint) {
            host.fillRect(x, ui.y, w, h, if (active) th.accent else th.paper);
            host.strokeRect(x, ui.y, w, h, 1, if (active) th.accent else th.border);
            host.text(x + w / 2, ui.y + h / 2, 13, active, if (active) WHITE else if (enabled) th.ink else th.faint, .center, label);
        }
        return enabled and ui.clicked(x, ui.y, w, h);
    }

    fn toggle(ui: *Ui, label: []const u8, on: bool) bool {
        const h: f64 = 26;
        if (ui.paint) {
            host.fillRect(px, ui.y + 6, 14, 14, th.paper);
            host.strokeRect(px, ui.y + 6, 14, 14, 1, th.muted);
            if (on) host.fillRect(px + 3, ui.y + 9, 8, 8, th.accent);
            host.text(px + 22, ui.y + h / 2, 13, false, th.ink, .left, label);
        }
        const r = ui.clicked(px, ui.y, PANEL_W, h);
        ui.y += h;
        return r;
    }

    fn heading(ui: *Ui, s: []const u8) void {
        ui.y += 8;
        if (ui.paint) host.text(px, ui.y + 8, 11, true, th.muted, .left, s);
        ui.y += 22;
    }

    /// Word-wrapped paragraph.
    fn para(ui: *Ui, s: []const u8, size: f64, color: Color, bold: bool) void {
        var start: usize = 0;
        while (start < s.len) {
            var end = start;
            var best = start;
            while (end < s.len) {
                var next = end + 1;
                while (next < s.len and s[next] != ' ') next += 1;
                if (best > start and host.textWidth(size, bold, s[start..next]) > PANEL_W) break;
                best = next;
                end = next;
            }
            if (ui.paint) host.text(px, ui.y + size * 0.7, size, bold, color, .left, s[start..best]);
            ui.y += size * 1.45;
            start = best;
            while (start < s.len and s[start] == ' ') start += 1;
        }
        ui.y += 4;
    }

    fn pill(ui: *Ui, s: []const u8, color: Color) void {
        if (ui.paint) {
            const w = host.textWidth(12, true, s) + 18;
            host.fillRect(px, ui.y, w, 22, color);
            host.text(px + 9, ui.y + 11, 12, true, WHITE, .left, s);
        }
        ui.y += 30;
    }
};

fn plural(buf: []u8, n: u32, one: []const u8, many: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {s}", .{ n, if (n == 1) one else many }) catch "";
}

fn panel(paint: bool, hit: ?[2]f64) void {
    var ui: Ui = .{ .paint = paint, .hit = hit, .y = by };
    var buf: [200]u8 = undefined;
    var nb: [48]u8 = undefined;

    ui.heading("TOOL");
    const names = [_][]const u8{ "Cage", "Line", "Between", "Given", "Wanted", "Odd / Even", "Select", "Erase" };
    const seg = PANEL_W / 3;
    inline for (.{ Tool.cage, Tool.thermo, Tool.between, Tool.given, Tool.wanted, Tool.parity, Tool.select, Tool.erase }, 0..) |t, i| {
        if (i == 3 or i == 6) ui.y += 29;
        if (ui.button(px + seg * (i % 3), seg, names[i], true, tool == t)) tool = t;
    }
    ui.y += 40;
    ui.para(switch (tool) {
        .cage => "Drag across neighbouring cells to draw a cage of up to nine cells. Click a cage to select it, then type its sum. A new cage gets its sum filled in when a solution is known.",
        .thermo => switch (line_kind) {
            sv.Line.arrow => "Drag from the circle along the arrow. The digits on the arrow add up to the digit in the circle. Start another arrow on the same circle to give it a second arm.",
            sv.Line.whisper => "Drag along the line. Neighbouring digits on a whisper line differ by at least five.",
            sv.Line.renban => "Drag along the line. A renban line holds consecutive digits in any order, none repeated.",
            sv.Line.palindrome => "Drag along the line. A palindrome reads the same from both ends.",
            else => "Drag from the bulb along the path, diagonals allowed. Digits rise along it. Start on an existing thermometer to branch off it.",
        },
        .between => "Click the border between two cells, then pick what goes on it. < and > compare the left or upper cell with the other. X and V are sums of 10 and 5. A white dot means consecutive, a black dot means one is double the other.",
        .given => "Click a cell, then type a digit. A given is a clue: it is printed in the puzzle. Arrow keys move.",
        .wanted => "Click a cell, then type a digit. A wanted digit is not a clue. It is what you want the answer to be there, and the search builds towards a solution that has it.",
        .erase => "Each click removes one thing: a sign on the border you click, else the digit, else the odd or even mark, else the newest line through the cell, else its cage.",
        .select => "Click a cell to list everything in it. Click again or press Tab to step down a layer. Backspace removes only the highlighted one and leaves the rest.",
        .parity => "Click a cell to mark it odd (circle), click again for even (square), once more to clear.",
    }, 12, th.muted, false);

    if (tool == .thermo) {
        const styles = [_][]const u8{ "Thermo", "Arrow", "Whisper", "Renban", "Palindrome" };
        const kinds = [_]u8{ 0, sv.Line.arrow, sv.Line.whisper, sv.Line.renban, sv.Line.palindrome };
        const w = PANEL_W / 3;
        inline for (0..5) |i| {
            if (i == 3) ui.y += 29;
            if (ui.button(px + w * (i % 3), w, styles[i], true, line_kind == kinds[i])) line_kind = kinds[i];
        }
        ui.y += 40;
    }

    if (tool == .between) {
        const current: ?Sign = if (sel_edge) |e| (if (linkAt(e)) |i| signOf(links[i], e) else null) else null;
        const labels = [_][]const u8{ "<", ">", "X", "V", "\u{25CB}", "\u{25CF}" };
        const w = PANEL_W / 7;
        inline for (.{ Sign.less, Sign.greater, Sign.x, Sign.v, Sign.white, Sign.black }, 0..) |sg, i| {
            if (ui.button(px + w * i, w, labels[i], sel_edge != null, current == sg)) setSign(sg);
        }
        if (ui.button(px + w * 6, w, "None", sel_edge != null and current != null, false)) setSign(null);
        ui.y += 40;
    }

    if (tool == .select) {
        for (picks[0..pick_n], 0..) |p, i| {
            if (ui.button(px, PANEL_W, pickLabel(&buf, p), true, i == pick_at)) pick_at = i;
            ui.y += 29;
        }
        if (pick_n > 0) {
            ui.y += 9;
            const p = picks[pick_at];
            const w = (PANEL_W - 8) / 2;
            const Act = enum { none, delete, reverse, flip };
            var act: Act = .none;
            var style: ?u8 = null;
            if (ui.button(px, w, "Delete", true, false)) act = .delete;
            switch (p) {
                .line => if (ui.button(px + w + 8, w, "Reverse direction", true, false)) {
                    act = .reverse;
                },
                .digit => |c| if (ui.button(px + w + 8, w, if (wanted[c]) "Make it a given" else "Make it wanted", true, false)) {
                    act = .flip;
                },
                .mark => |c| if (ui.button(px + w + 8, w, if (parity[c] == 1) "Make it even" else "Make it odd", true, false)) {
                    act = .flip;
                },
                else => {},
            }
            ui.y += 38;
            switch (p) {
                .line => |li| {
                    const styles = [_][]const u8{ "Thermo", "Arrow", "Whisper", "Renban", "Palindrome" };
                    const kinds = [_]u8{ 0, sv.Line.arrow, sv.Line.whisper, sv.Line.renban, sv.Line.palindrome };
                    const sw = PANEL_W / 3;
                    inline for (0..5) |i| {
                        if (i == 3) ui.y += 29;
                        if (ui.button(px + sw * (i % 3), sw, styles[i], true, thermos[li].kind == kinds[i])) style = kinds[i];
                    }
                    ui.y += 40;
                },
                .cage => ui.para("Type digits to set this cage's sum.", 12, th.accent, false),
                .digit => ui.para("Type a digit to change it.", 12, th.accent, false),
                else => {},
            }
            // Acted on only now, so a button cannot move under the click.
            switch (act) {
                .delete => deletePicked(),
                .reverse => reversePicked(),
                .flip => flipPicked(),
                .none => if (style) |k| restylePicked(k),
            }
        }
    }

    if (tool == .cage and sel_cage >= 0) {
        const g = cages[@intCast(sel_cage)];
        const s = if (g.sum != 0)
            std.fmt.bufPrint(&buf, "Selected cage: sum {d}. Type to change, Backspace to leave it open.", .{g.sum}) catch ""
        else
            "Selected cage: sum open. Type digits to set it, Backspace to remove the cage.";
        ui.para(s, 12, th.accent, false);
    }

    ui.heading("OPTIONS");
    if (ui.toggle("Show forced digits and candidates", show_deductions)) show_deductions = !show_deductions;
    if (ui.toggle("Pencil in the solution (A)", show_solution)) show_solution = !show_solution;
    if (ui.toggle("Count wanted digits as known", assume_wanted)) {
        assume_wanted = !assume_wanted;
        reanalyse();
    }
    if (ui.toggle("New cages take their sum from the solution", auto_sum)) auto_sum = !auto_sum;
    if (ui.toggle("Dark theme", dark)) setDark(!dark);
    if (ui.toggle("Both diagonals hold 1 to 9", rule_diagonals)) {
        rule_diagonals = !rule_diagonals;
        edited();
    }
    if (ui.toggle("Knight's move apart differ", rule_knight)) {
        rule_knight = !rule_knight;
        edited();
    }

    ui.heading("ANALYSIS");
    var spare: u32 = 0;
    for (0..81) |i| spare += @intFromBool(an.red_cage[i]) + @intFromBool(an.red_digit[i]);
    for (an.red_thermo) |r| spare += @intFromBool(r);
    for (an.red_link) |r| spare += @intFromBool(r);
    for (an.red_mark) |r| spare += @intFromBool(r);
    if (an.valid and assume_wanted and wantedCount() > 0) ui.para("Counting your wanted digits as known. The printed puzzle would not have them.", 12, th.want, false);
    if (!an.valid) {
        ui.para("Draw a cage, a line or a digit. This box then says whether a solution exists and how much is still open.", 13, th.muted, false);
    } else if (an.status == sv.Status.none) {
        ui.pill("No solution", th.red);
        ui.para("These clues contradict each other. Remove or change the last one.", 13, th.ink, false);
    } else if (an.status == sv.Status.unique) {
        ui.pill("Exactly one solution", th.green);
        if (an.guesses == 0) {
            ui.para(std.fmt.bufPrint(&buf, "Solvable without guessing. The 45 rule is needed {s}.", .{plural(&nb, an.steps, "time", "times")}) catch "", 13, th.ink, false);
        } else {
            ui.para(std.fmt.bufPrint(&buf, "Needs guessing. The solver branched {s}.", .{plural(&nb, an.guesses, "time", "times")}) catch "", 13, th.ink, false);
        }
        var sb: [200]u8 = undefined;
        const used = stepList(&sb);
        if (used.len > 0) ui.para(std.fmt.bufPrint(&buf, "Steps beyond singles: {s}.", .{used}) catch "", 13, th.ink, false);
        if (spare > 0) {
            ui.para(std.fmt.bufPrint(&buf, "{s} spare, drawn faint: each could go on its own and the solution stays unique.", .{plural(&nb, spare, "clue is", "clues are")}) catch "", 13, th.ink, false);
        } else ui.para("Every clue is needed. Remove any one and the solution is no longer unique.", 13, th.ink, false);
        if (wantedCount() > 0) {
            var off: u32 = 0;
            for (0..81) |c| off += @intFromBool(wanted[c] and digits[c] != 0 and digits[c] != an.sol[c]);
            if (off > 0) {
                ui.para(std.fmt.bufPrint(&buf, "The solution disagrees with {s}, drawn red.", .{plural(&nb, off, "wanted digit", "wanted digits")}) catch "", 13, th.red, false);
            } else ui.para("The solution has every wanted digit where you put it.", 13, th.green, false);
        }
    } else {
        ui.pill(if (an.status == sv.Status.multiple) "More than one solution" else "Too open to count", th.muted);
        var forced: u32 = 0;
        var settled: u32 = 0;
        for (an.cand) |m| forced += @intFromBool(m != 0 and m & (m - 1) == 0);
        for (ex.cand) |m| settled += @intFromBool(m != 0 and m & (m - 1) == 0);
        if (settled > forced) {
            ui.para(std.fmt.bufPrint(&buf, "{d} of 81 cells are already forced: {d} by step-by-step logic, {d} more only by ruling out every alternative (purple).", .{ settled, forced, settled - forced }) catch "", 13, th.ink, false);
        } else ui.para(std.fmt.bufPrint(&buf, "{d} of 81 cells are already forced by logic.", .{forced}) catch "", 13, th.ink, false);
        if (!ex.done) {
            ui.para(std.fmt.bufPrint(&buf, "Checking every candidate against a full search, {d}% done...", .{ex.at * 100 / 729}) catch "", 13, th.muted, false);
        } else if (ex.unsure > 0) {
            ui.para(std.fmt.bufPrint(&buf, "{s} too hard to settle and left in.", .{plural(&nb, ex.unsure, "candidate was", "candidates were")}) catch "", 13, th.muted, false);
        }
        if (an.wanted_impossible) {
            ui.para("No solution has your wanted digits where you put them.", 13, th.red, false);
        } else if (sug.impossible) {
            ui.para("No full grid fits these clues.", 13, th.red, false);
        } else if (sug.has) {
            var tb: [48]u8 = undefined;
            ui.para(std.fmt.bufPrint(&buf, "{s} would pin it down, shown in green. {s} of {s} tried.", .{
                plural(&nb, sug.added_n, "more given digit", "more given digits"),
                if (sug.done) "Best" else "Best so far",
                plural(&tb, sug.tries, "layout", "layouts"),
            }) catch "", 13, th.ink, false);
        } else if (sug.done) {
            ui.para(std.fmt.bufPrint(&buf, "No completion found in {s}.", .{plural(&nb, sug.tries, "layout", "layouts")}) catch "", 13, th.ink, false);
        } else ui.para("Looking for the fewest extra given digits...", 13, th.muted, false);
    }

    ui.y += 6;
    const half = (PANEL_W - 8) / 2;
    if (ui.button(px, half, "Strip spare clues", an.status == sv.Status.unique and spare > 0 and !assume_wanted, false)) stripSpare();
    if (ui.button(px + half + 8, half, "Add suggested givens", sug.has, false)) acceptSuggestion();
    ui.y += 38;
    if (ui.button(px, half, "Undo", canUndo(), false)) undo();
    if (ui.button(px + half + 8, half, "Redo", canRedo(), false)) redo();
    ui.y += 38;
    if (ui.button(px, PANEL_W, if (clear_armed) "Click again to remove everything" else "Remove all", clueCount() > 0, clear_armed)) {
        if (clear_was_armed) clearAll() else clear_armed = true;
    }
    ui.y += 44;

    ui.y -= 14;
    ui.heading("SHARE");
    if (ui.button(px, half, "Copy code", clueCount() > 0, false)) copyCode();
    if (ui.button(px + half + 8, half, "Paste code", true, false)) pasteCode();
    ui.y += 38;
    if (ui.button(px, PANEL_W, "Copy SudokuPad link", clueCount() > 0, false)) copySudokuPadLink();
    ui.y += 40;
    if (notice.len > 0) ui.para(notice, 12, th.accent, false);

    var given: u32 = 0;
    for (0..81) |c| given += @intFromBool(digits[c] != 0 and !wanted[c]);
    var cb: [48]u8 = undefined;
    var tb: [48]u8 = undefined;
    var marks: u32 = 0;
    for (parity) |m| marks += @intFromBool(m != 0);
    ui.para(std.fmt.bufPrint(&buf, "{s}, {s}, {d} between, {d} odd/even, {s}, {d} wanted", .{
        plural(&cb, @intCast(cage_n), "cage", "cages"),
        plural(&tb, @intCast(thermo_n), "line", "lines"),
        link_n,
        marks,
        plural(&nb, given, "given", "givens"),
        wantedCount(),
    }) catch "", 12, th.muted, false);
}

test "a diagonal drag gives a diagonal line" {
    resize(1060, 900);
    tool = .thermo;
    const a = cellCenter(0);
    const b = cellCenter(30);
    pointerDown(a[0], a[1]);
    var i: usize = 0;
    while (i <= 300) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 300.0;
        // Wobble sideways by a fifth of a cell, as a hand would.
        const wobble = cell * 0.2 * @sin(t * 40.0);
        pointerMove(a[0] + (b[0] - a[0]) * t + wobble, a[1] + (b[1] - a[1]) * t - wobble);
    }
    try @import("std").testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30 }, stroke.cells[0..stroke.n]);
    // Back up one cell, then turn a corner.
    pointerMove(cellCenter(20)[0], cellCenter(20)[1]);
    pointerMove(cellCenter(21)[0], cellCenter(21)[1]);
    try @import("std").testing.expectEqualSlices(u8, &.{ 0, 10, 20, 21 }, stroke.cells[0..stroke.n]);
    stroking = false;
}

test "a new cage takes its sum from the known solution" {
    const expect = @import("std").testing.expect;
    resize(1060, 900);
    init();
    tool = .cage;
    auto_sum = true;
    cage_n = 0;
    thermo_n = 0;
    link_n = 0;
    // A full grid of givens has one solution, which becomes the hint.
    for (0..81) |c| digits[c] = @intCast((c / 9 * 3 + c / 27 + c % 9) % 9 + 1);
    const full = digits;
    edited();
    try expect(an.status == sv.Status.unique and hint_ok);
    // Take most givens away again: the puzzle is open, the grid still fits.
    for (27..81) |c| digits[c] = 0;
    edited();
    try expect(an.status != sv.Status.unique);
    const drag = struct {
        fn f(a: usize, b: usize) void {
            pointerDown(cellCenter(a)[0], cellCenter(a)[1]);
            pointerMove(cellCenter(b)[0], cellCenter(b)[1]);
            pointerUp();
        }
    }.f;
    // Two cages straight after each other, with no background search between.
    const undo_at = hist_at;
    drag(36, 37);
    drag(38, 47);
    try expect(cage_n == 2);
    try expect(cages[0].sum == full[36] + full[37]);
    try expect(cages[1].sum == full[38] + full[47]);
    try expect(hist_at == undo_at + 2);
    // A given that disagrees with the grid: it no longer fits, so the next
    // cage stays open. Take the given away and the old grid serves again.
    digits[80] = full[80] % 9 + 1;
    edited();
    drag(54, 55);
    try expect(cage_n == 3 and cages[2].sum == 0);
    digits[80] = 0;
    edited();
    drag(56, 57);
    try expect(cage_n == 4 and cages[3].sum == full[56] + full[57]);
    // Switched off, a new cage starts open as before.
    auto_sum = false;
    drag(72, 73);
    try expect(cages[cage_n - 1].sum == 0);
    auto_sum = true;
    cage_n = 0;
    digits = @splat(0);
    edited();
}
