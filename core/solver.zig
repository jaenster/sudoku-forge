// Sudoku Forge solver core: constraint propagation, search, generator and
// clue analysis. Freestanding (no std) so it compiles to a small wasm module.

const ALL: u16 = 0x1FF;
const State = [81]u16; // candidate bitmask per cell, bit d-1 = digit d
const NONE: u8 = 255;

// ---------------------------------------------------------------- tables

const HOUSES: [27][9]u8 = blk: {
    var h: [27][9]u8 = undefined;
    for (0..9) |i| {
        for (0..9) |j| {
            h[i][j] = @intCast(i * 9 + j); // rows
            h[9 + i][j] = @intCast(j * 9 + i); // columns
            h[18 + i][j] = @intCast((i / 3 * 3 + j / 3) * 9 + i % 3 * 3 + j % 3); // boxes
        }
    }
    break :blk h;
};

fn maskSum(m: u16) u16 {
    var s: u16 = 0;
    for (0..9) |d| {
        if ((m >> @intCast(d)) & 1 != 0) s += @intCast(d + 1);
    }
    return s;
}

// All digit subsets grouped by (size, sum): list[start[size][sum]..start[size][sum+1]]
const Combos = struct { list: [512]u16, start: [10][47]u16 };
const combos: Combos = blk: {
    @setEvalBranchQuota(20_000_000);
    var c: Combos = undefined;
    var n: u16 = 0;
    for (0..10) |size| {
        for (0..46) |sum| {
            c.start[size][sum] = n;
            for (0..512) |mi| {
                const m: u16 = @intCast(mi);
                if (@popCount(m) == size and maskSum(m) == sum) {
                    c.list[n] = m;
                    n += 1;
                }
            }
        }
        c.start[size][46] = n;
    }
    break :blk c;
};

// ---------------------------------------------------------------- state

var solution: [81]u8 = @splat(0); // digits 1..9
var cage_of: [81]u8 = @splat(0); // compact cage id per cell
var cage_n: usize = 0;
var cage_cells: [81][9]u8 = undefined;
var cage_len: [81]u8 = @splat(0);
var cage_sum: [81]u16 = @splat(0);
var use_cages: bool = false;

// Sums implied by the 45 rule (innies and outies of unions of houses).
const MAX_DERIVED = 200;
var der_n: usize = 0;
var der_cells: [MAX_DERIVED][9]u8 = undefined;
var der_len: [MAX_DERIVED]u8 = @splat(0);
var der_sum: [MAX_DERIVED]u16 = @splat(0);
var der_distinct: [MAX_DERIVED]bool = @splat(false);
var use_derived: bool = true;
var derived_conflict: bool = false; // the cage sums contradict the 45 rule outright

// Thermometers: digits strictly increase from the bulb (first cell).
const MAX_THERMO = 16;
var thermo_n: usize = 0;
var thermo_cells: [MAX_THERMO][9]u8 = undefined;
var thermo_len: [MAX_THERMO]u8 = @splat(0);
var rule_steps: u32 = 0; // 45-rule applications the graded solve needed
var basic_solved: u32 = 0; // cells solved before the first of them
var grade_done: bool = false;

// Hand-set clues the generator must build around.
var user_cage: [81]u8 = @splat(NONE); // cage id per cell, NONE = not in a hand-set cage
var user_sum: [81]u16 = @splat(0); // wanted sum per hand-set cage id, 0 = generator picks
var user_thermo_cells: [MAX_THERMO][9]u8 = undefined;
var user_thermo_len: [MAX_THERMO]u8 = @splat(0);
var user_thermo_n: usize = 0;
var user_digit: [81]u8 = @splat(0); // digit the setter fixed for a cell, 0 = free

// Hand-set relations between two cells: inequality signs, XV, kropki dots.
// Each is four bytes: first cell, second cell, operator, operand.
const MAX_LINK = 144;
const LINK_LESS = 1; // first cell is smaller than the second
const LINK_SUM = 2; // the two cells add up to the operand
const LINK_DIFF = 3; // the two cells differ by the operand
const LINK_RATIO = 4; // one cell is the operand times the other
var user_link: [MAX_LINK][4]u8 = undefined;
var user_link_n: usize = 0;
var links_on: bool = false; // the active puzzle includes the hand-set links
var link_skip: usize = MAX_LINK; // one link left out, to test whether it is needed
var red_link: [MAX_LINK]u8 = @splat(0);

// Hand-set lines other than thermometers. They share the on/off switch of the
// links above and are never created or removed by the generator.
const MAX_LINE = 24;
const LINE_ARROW = 1; // the first cell is the sum of the others
const LINE_WHISPER = 2; // neighbours on the line differ by at least five
const LINE_RENBAN = 3; // a set of consecutive digits in any order
const LINE_PALINDROME = 4; // reads the same from both ends
var user_line_cells: [MAX_LINE][9]u8 = undefined;
var user_line_len: [MAX_LINE]u8 = @splat(0);
var user_line_kind: [MAX_LINE]u8 = @splat(0);
var user_line_n: usize = 0;
var line_skip: usize = MAX_LINE;
var red_line: [MAX_LINE]u8 = @splat(0);
const LINK_FAR = 5; // the two cells differ by at least the operand
var user_mask: [81]u16 = @splat(ALL); // digits a cell may hold at all (odd and even cells)
var user_hidden: [81]u8 = @splat(0); // 1 = that digit only steers the solution, it is never a clue
var given_mask: State = @splat(ALL); // starting candidates: fixed digits that count as givens
var red_digit: [81]u8 = @splat(0); // 1 = puzzle stays unique without this given
var locked: [81]bool = @splat(false); // cell belongs to a hand-set cage
var locked_thermos: usize = 0; // the first n thermometers are hand-set

var user_in: [81]u8 = @splat(0);
var cand_out: [81]u16 = @splat(0);

var nodes: u32 = 0;
var node_cap: u32 = 0;
var found: u32 = 0;
var limit: u32 = 0;
var randomize: bool = false;
var first: State = undefined;
var second: State = undefined;

// Counterexamples: other grids that satisfied some earlier layout. A candidate
// layout that one of them also satisfies is not unique, no search needed.
const MAX_WIT = 64;
var wit: [MAX_WIT][81]u8 = undefined;
var wit_n: usize = 0;
var wit_next: usize = 0;
var last_guesses: u32 = 0;

var rs: u64 = 0x9E3779B97F4A7C15;

fn rnd() u32 {
    rs ^= rs << 13;
    rs ^= rs >> 7;
    rs ^= rs << 17;
    return @truncate(rs >> 16);
}

fn rndBelow(n: u32) u32 {
    return rnd() % n;
}

/// Decide whether the setter's fixed digits restrict the solver right now.
const Givens = enum { none, marks, shown, all };

/// What the setter fixed per cell constrains the search: nothing, only the
/// cell marks, also the digits that are clues, or the hidden digits as well.
fn setGivens(which: Givens) void {
    for (0..81) |c| {
        const d = user_digit[c];
        const base: u16 = if (which == .none) ALL else user_mask[c] & ALL;
        const active = which == .all or (which == .shown and user_hidden[c] == 0);
        given_mask[c] = if (active and d >= 1 and d <= 9) base & (@as(u16, 1) << @intCast(d - 1)) else base;
    }
}

// ---------------------------------------------------------------- propagation

/// All-different over a group of cells. If `full`, the group is a house of 9
/// cells that must contain every digit, which also enables hidden singles.
fn propGroup(s: *State, cells: []const u8, full: bool, changed: *bool) bool {
    var solved: u16 = 0;
    for (cells) |c| {
        const m = s[c];
        if (m == 0) return false;
        if (m & (m - 1) == 0) {
            if (solved & m != 0) return false;
            solved |= m;
        }
    }
    var once: u16 = 0;
    var twice: u16 = 0;
    for (cells) |c| {
        var m = s[c];
        if (m & (m - 1) != 0 and m & solved != 0) {
            m &= ~solved;
            if (m == 0) return false;
            s[c] = m;
            changed.* = true;
        }
        twice |= once & m;
        once |= m;
    }
    if (full) {
        if (once != ALL) return false;
        const hidden = once & ~twice;
        if (hidden != 0) {
            for (cells) |c| {
                const m = s[c];
                const x = m & hidden;
                if (x == 0) continue;
                if (x & (x - 1) != 0) return false; // two digits need this one cell
                if (m != x) {
                    s[c] = x;
                    changed.* = true;
                }
            }
        }
    }
    if (deep_logic and !trial) return hallSets(s, cells, changed);
    return true;
}

/// Naked subsets of any size: when k unsolved cells of a group hold only k
/// digits between them, those digits go nowhere else in the group. In a full
/// house the same rule, seen from the other cells, is the hidden subset.
fn hallSets(s: *State, cells: []const u8, changed: *bool) bool {
    var open: [9]u8 = undefined;
    var n: usize = 0;
    for (cells) |c| {
        if (s[c] & (s[c] - 1) != 0) {
            open[n] = c;
            n += 1;
        }
    }
    if (n < 3) return true;
    var uni: [512]u16 = undefined;
    uni[0] = 0;
    const top = @as(usize, 1) << @intCast(n);
    for (1..top - 1) |set| {
        const u = uni[set & (set - 1)] | s[open[@ctz(set)]];
        uni[set] = u;
        const k = @popCount(set);
        const digits = @popCount(u);
        if (digits < k) return false;
        if (digits != k or k < 2) continue;
        for (open[0..n], 0..) |c, i| {
            if (set >> @intCast(i) & 1 != 0 or s[c] & u == 0) continue;
            s[c] &= ~u;
            if (s[c] == 0) return false;
            changed.* = true;
        }
    }
    return true;
}

/// Sum cage: keep only candidates that appear in some digit combination
/// that is still compatible with every cell of the cage.
fn propSum(s: *State, cells: []const u8, sum: u16, changed: *bool) bool {
    const n = cells.len;
    var uni: u16 = 0;
    for (cells) |c| uni |= s[c];
    var sup: [9]u16 = @splat(0);
    const a = combos.start[n][sum];
    const b = combos.start[n][sum + 1];
    outer: for (combos.list[a..b]) |m| {
        if (m & ~uni != 0) continue;
        for (cells) |c| {
            if (s[c] & m == 0) continue :outer;
        }
        for (cells, 0..) |c, i| sup[i] |= s[c] & m;
    }
    for (cells, 0..) |c, i| {
        if (sup[i] == 0) return false;
        if (sup[i] != s[c]) {
            s[c] = sup[i];
            changed.* = true;
        }
    }
    return true;
}

/// Sum over cells that may repeat digits: exact reachability over partial sums.
fn propSumFree(s: *State, cells: []const u8, sum: u16, changed: *bool) bool {
    const n = cells.len;
    const cap: u64 = (@as(u64, 2) << @intCast(sum)) - 1;
    var fwd: [10]u64 = undefined;
    var bwd: [10]u64 = undefined;
    fwd[0] = 1;
    for (cells, 0..) |c, i| {
        var acc: u64 = 0;
        var m = s[c];
        while (m != 0) : (m &= m - 1) acc |= fwd[i] << @intCast(@ctz(m) + 1);
        fwd[i + 1] = acc & cap;
    }
    bwd[n] = @as(u64, 1) << @intCast(sum);
    if (fwd[n] & bwd[n] == 0) return false;
    var i = n;
    while (i > 0) {
        i -= 1;
        const c = cells[i];
        var acc: u64 = 0;
        var keep: u16 = 0;
        var m = s[c];
        while (m != 0) : (m &= m - 1) {
            const d: u6 = @intCast(@ctz(m) + 1);
            acc |= bwd[i + 1] >> d;
            if ((fwd[i] << d) & bwd[i + 1] != 0) keep |= m & (~m +% 1);
        }
        bwd[i] = acc;
        if (keep == 0) return false;
        if (keep != s[c]) {
            s[c] = keep;
            changed.* = true;
        }
    }
    return true;
}

/// Thermometer: bounds consistency along the chain of "less than" links.
fn propThermo(s: *State, cells: []const u8, changed: *bool) bool {
    var i: usize = 1;
    while (i < cells.len) : (i += 1) {
        const prev = s[cells[i - 1]];
        if (prev == 0) return false;
        const lo: u4 = @intCast(@ctz(prev));
        const m = s[cells[i]] & (ALL & ~((@as(u16, 2) << lo) - 1));
        if (m == 0) return false;
        if (m != s[cells[i]]) {
            s[cells[i]] = m;
            changed.* = true;
        }
    }
    i = cells.len - 1;
    while (i > 0) {
        i -= 1;
        const nxt = s[cells[i + 1]];
        const hi: u4 = @intCast(15 - @clz(nxt));
        const m = s[cells[i]] & ((@as(u16, 1) << hi) - 1);
        if (m == 0) return false;
        if (m != s[cells[i]]) {
            s[cells[i]] = m;
            changed.* = true;
        }
    }
    return true;
}

// Every constraint lives in one table so propagation can run as a worklist:
// only constraints that watch a cell that just changed are run again.
const K_HOUSE = 0;
const K_CAGE = 1;
const K_THERMO = 2;
const K_SUM_DISTINCT = 3; // 45-rule sum, cells share a house
const K_SUM_FREE = 4; // 45-rule sum, digits may repeat
const K_DISTINCT = 5; // cage shape whose sum is not chosen yet
const K_LINE = 8; // hand-set line; sum holds its kind
const K_LINK = 7; // relation between two cells; sum holds operator << 8 | operand
const K_APART = 6; // first cell differs from every other cell listed (anti-knight)

// Extra global rules, as a bit set chosen by the setter.
const RULE_DIAGONALS = 1; // both long diagonals hold 1 to 9
const RULE_ANTI_KNIGHT = 2; // cells a chess knight's move apart differ
var rules: u32 = 0;

fn isDerived(kind: u8) bool {
    return kind == K_SUM_DISTINCT or kind == K_SUM_FREE;
}
const Con = struct { kind: u8, len: u8, sum: u16, cells: [9]u8 };
const MAX_CON = 27 + 2 + 81 + 81 + MAX_THERMO + MAX_DERIVED + MAX_LINK + MAX_LINE;
const MAX_WATCH = 112;
var cons: [MAX_CON]Con = undefined;
var con_n: usize = 0;
var watch: [81][MAX_WATCH]u16 = undefined; // constraints touching each cell
var watch_n: [81]u8 = @splat(0);
var queue: [1024]u16 = undefined;
var q_head: usize = 0;
var q_tail: usize = 0;
var queued: [MAX_CON]bool = @splat(false);

fn addCon(kind: u8, cells: []const u8, sum: u16) void {
    for (cells) |c| {
        if (watch_n[c] >= MAX_WATCH) return; // only ever drops a redundant 45-rule sum
    }
    var con = Con{ .kind = kind, .len = @intCast(cells.len), .sum = sum, .cells = undefined };
    for (cells, 0..) |c, i| {
        con.cells[i] = c;
        watch[c][watch_n[c]] = @intCast(con_n);
        watch_n[c] += 1;
    }
    cons[con_n] = con;
    con_n += 1;
}

/// Rebuild the constraint table. Without `puzzle` only the sudoku rules apply.
fn buildCons(puzzle: bool) void {
    if (!puzzle) derived_conflict = false;
    lin_n = 0;
    lin_dirty = puzzle;
    con_n = 0;
    watch_n = @splat(0);
    for (&HOUSES) |*h| addCon(K_HOUSE, h[0..9], 45);
    if (rules & RULE_DIAGONALS != 0) {
        var down: [9]u8 = undefined;
        var up: [9]u8 = undefined;
        for (0..9) |i| {
            down[i] = @intCast(i * 10);
            up[i] = @intCast(i * 8 + 8);
        }
        addCon(K_HOUSE, &down, 45);
        addCon(K_HOUSE, &up, 45);
    }
    if (rules & RULE_ANTI_KNIGHT != 0) {
        const jr = [8]i32{ -2, -2, -1, -1, 1, 1, 2, 2 };
        const jc = [8]i32{ -1, 1, -2, 2, -2, 2, -1, 1 };
        for (0..81) |c| {
            var cells: [9]u8 = undefined;
            var n: usize = 1;
            cells[0] = @intCast(c);
            const r: i32 = @intCast(c / 9);
            const q: i32 = @intCast(c % 9);
            for (0..8) |k| {
                const r2 = r + jr[k];
                const q2 = q + jc[k];
                if (r2 < 0 or r2 > 8 or q2 < 0 or q2 > 8) continue;
                cells[n] = @intCast(r2 * 9 + q2);
                n += 1;
            }
            addCon(K_APART, cells[0..n], 0);
        }
    }
    if (!puzzle) return;
    if (links_on) addLinks(link_skip, line_skip);
    for (0..thermo_n) |k| addCon(K_THERMO, thermo_cells[k][0..thermo_len[k]], 0);
    for (0..cage_n) |k| addCon(K_CAGE, cage_cells[k][0..cage_len[k]], cage_sum[k]);
    for (0..der_n) |k| {
        addCon(if (der_distinct[k]) K_SUM_DISTINCT else K_SUM_FREE, der_cells[k][0..der_len[k]], der_sum[k]);
    }
}

fn addLinks(skip: usize, skip_line: usize) void {
    for (0..user_link_n) |k| {
        if (k == skip) continue;
        const l = user_link[k];
        addCon(K_LINK, l[0..2], @as(u16, l[2]) << 8 | l[3]);
    }
    for (0..user_line_n) |k| {
        if (k == skip_line or user_line_len[k] < 2) continue;
        addCon(K_LINE, user_line_cells[k][0..user_line_len[k]], user_line_kind[k]);
    }
}

/// The digits from lo to hi as a candidate mask; empty when the range is.
fn rangeMask(lo: i32, hi: i32) u16 {
    const l: u4 = @intCast(@max(lo, 1));
    const h: u4 = @intCast(@min(@max(hi, 0), 9));
    if (l > h) return 0;
    return ((@as(u16, 1) << h) - 1) & ~((@as(u16, 1) << (l - 1)) - 1);
}
fn low(m: u16) i32 {
    return @as(i32, @ctz(m)) + 1;
}
fn high(m: u16) i32 {
    return 16 - @as(i32, @clz(m));
}
fn narrow(s: *State, c: u8, m: u16, changed: *bool) bool {
    const n = s[c] & m;
    if (n == 0) return false;
    if (n != s[c]) {
        s[c] = n;
        changed.* = true;
    }
    return true;
}

/// Two different cells in one row, column or box, which can never match.
fn sees(a: u8, b: u8) bool {
    return a != b and (a / 9 == b / 9 or a % 9 == b % 9 or (a / 27 == b / 27 and (a % 9) / 3 == (b % 9) / 3));
}

var arrow_cells: []const u8 = &.{};
var arrow_state: *State = undefined;
var arrow_val: [9]u8 = undefined;
var arrow_ok: [9]u16 = undefined;
var arrow_min: [10]i32 = undefined; // least the shaft can add from cell i on

/// Fill shaft cell `i` onwards, given what the cells before it add up to.
/// Shaft cells that see each other take different digits, which is what
/// makes three cells in a row add up to at least six.
fn arrowWalk(i: usize, sum: i32) void {
    const cells = arrow_cells;
    if (i == cells.len) {
        const bit = @as(u16, 1) << @intCast(sum - 1);
        if (arrow_state[cells[0]] & bit == 0) return;
        for (1..cells.len) |j| {
            if (arrow_val[j] == sum and sees(cells[0], cells[j])) return;
        }
        arrow_ok[0] |= bit;
        for (1..cells.len) |j| arrow_ok[j] |= @as(u16, 1) << @intCast(arrow_val[j] - 1);
        return;
    }
    var m = arrow_state[cells[i]];
    next: while (m != 0) {
        const v: u8 = @intCast(@ctz(m) + 1);
        m &= m - 1;
        if (sum + v + arrow_min[i + 1] > 9) break;
        for (1..i) |j| {
            if (arrow_val[j] == v and sees(cells[i], cells[j])) continue :next;
        }
        arrow_val[i] = v;
        arrowWalk(i + 1, sum + v);
    }
}

fn propLine(s: *State, cells: []const u8, kind: u16, changed: *bool) bool {
    for (cells) |c| {
        if (s[c] == 0) return false;
    }
    switch (kind) {
        LINE_WHISPER => {
            for (1..cells.len) |i| {
                const pair = [2]u8{ cells[i - 1], cells[i] };
                if (!propLink(s, &pair, @as(u16, LINK_FAR) << 8 | 5, changed)) return false;
            }
        },
        LINE_PALINDROME => {
            for (0..cells.len / 2) |i| {
                const a = cells[i];
                const b = cells[cells.len - 1 - i];
                const m = s[a] & s[b];
                if (!narrow(s, a, m, changed) or !narrow(s, b, m, changed)) return false;
            }
        },
        LINE_RENBAN => {
            if (!propGroup(s, cells, false, changed)) return false;
            // Every digit lies within the line's length of the largest
            // minimum and of the smallest maximum.
            var most_low: i32 = 1;
            var least_high: i32 = 9;
            for (cells) |c| {
                most_low = @max(most_low, low(s[c]));
                least_high = @min(least_high, high(s[c]));
            }
            const span: i32 = @intCast(cells.len - 1);
            const m = rangeMask(most_low - span, least_high + span);
            for (cells) |c| {
                if (!narrow(s, c, m, changed)) return false;
            }
        },
        LINE_ARROW => {
            // Try every way to fill the shaft that adds up to a digit the
            // circle may hold, and keep only the digits some way uses.
            if (cells.len < 2) return true;
            arrow_cells = cells;
            arrow_state = s;
            arrow_ok = @splat(0);
            arrow_min[cells.len] = 0;
            var i = cells.len;
            while (i > 1) {
                i -= 1;
                arrow_min[i] = arrow_min[i + 1] + low(s[cells[i]]);
            }
            arrowWalk(1, 0);
            for (cells, 0..) |c, k| {
                if (!narrow(s, c, arrow_ok[k], changed)) return false;
            }
        },
        else => {},
    }
    return true;
}

fn lineHolds(g: *const [81]u8, cells: []const u8, kind: u8) bool {
    switch (kind) {
        LINE_WHISPER => {
            for (1..cells.len) |i| {
                if (!linkHolds(LINK_FAR, 5, g[cells[i - 1]], g[cells[i]])) return false;
            }
        },
        LINE_PALINDROME => {
            for (0..cells.len / 2) |i| {
                if (g[cells[i]] != g[cells[cells.len - 1 - i]]) return false;
            }
        },
        LINE_RENBAN => {
            var mask: u16 = 0;
            for (cells) |c| mask |= @as(u16, 1) << @intCast(g[c] - 1);
            if (@popCount(mask) != cells.len or high(mask) - low(mask) != @as(i32, @intCast(cells.len - 1))) return false;
        },
        LINE_ARROW => {
            var sum: u16 = 0;
            for (cells[1..]) |c| sum += g[c];
            if (sum != g[cells[0]]) return false;
        },
        else => {},
    }
    return true;
}

fn linkHolds(op: u8, v: u8, x: u8, y: u8) bool {
    return switch (op) {
        LINK_LESS => x < y,
        LINK_SUM => x + y == v,
        LINK_DIFF => x == y + v or y == x + v,
        LINK_RATIO => x == y * v or y == x * v,
        LINK_FAR => x >= y + v or y >= x + v,
        else => true,
    };
}

/// Keep only the digits of each cell that some digit of the other supports.
fn propLink(s: *State, cells: []const u8, code: u16, changed: *bool) bool {
    const op: u8 = @intCast(code >> 8);
    const v: u8 = @intCast(code & 255);
    const a = s[cells[0]];
    const b = s[cells[1]];
    var na: u16 = 0;
    var nb: u16 = 0;
    var x: u8 = 1;
    while (x <= 9) : (x += 1) {
        if (a & (@as(u16, 1) << @intCast(x - 1)) == 0) continue;
        var y: u8 = 1;
        while (y <= 9) : (y += 1) {
            if (b & (@as(u16, 1) << @intCast(y - 1)) == 0 or !linkHolds(op, v, x, y)) continue;
            na |= @as(u16, 1) << @intCast(x - 1);
            nb |= @as(u16, 1) << @intCast(y - 1);
        }
    }
    if (na == 0 or nb == 0) return false;
    if (na != a or nb != b) {
        s[cells[0]] = na;
        s[cells[1]] = nb;
        changed.* = true;
    }
    return true;
}

/// Constraints for inventing a solved grid: the sudoku rules plus, when asked,
/// the hand-set cage shapes, sums and thermometers.
fn buildGridCons(use_user: bool) void {
    buildCons(false);
    if (!use_user) return;
    addLinks(MAX_LINK, MAX_LINE);
    for (0..user_thermo_n) |k| addCon(K_THERMO, user_thermo_cells[k][0..user_thermo_len[k]], 0);
    for (0..81) |id| {
        var cells: [9]u8 = undefined;
        var n: usize = 0;
        for (0..81) |c| {
            if (user_cage[c] == id and n < 9) {
                cells[n] = @intCast(c);
                n += 1;
            }
        }
        if (n == 0) continue;
        if (user_sum[id] != 0 and user_sum[id] <= 45) {
            addCon(K_CAGE, cells[0..n], user_sum[id]);
        } else {
            addCon(K_DISTINCT, cells[0..n], 0);
        }
    }
}

/// Once the first cell is solved, no other listed cell may hold its digit.
fn propApart(s: *State, cells: []const u8, changed: *bool) bool {
    const m = s[cells[0]];
    if (m == 0) return false;
    if (m & (m - 1) != 0) return true;
    for (cells[1..]) |c| {
        if (s[c] & m == 0) continue;
        s[c] &= ~m;
        if (s[c] == 0) return false;
        changed.* = true;
    }
    return true;
}

fn runCon(s: *State, k: usize, changed: *bool) bool {
    const con = &cons[k];
    const cells = con.cells[0..con.len];
    return switch (con.kind) {
        K_HOUSE => propGroup(s, cells, true, changed),
        K_CAGE => propGroup(s, cells, false, changed) and propSum(s, cells, con.sum, changed),
        K_THERMO => propThermo(s, cells, changed),
        K_SUM_DISTINCT => propSum(s, cells, con.sum, changed),
        K_DISTINCT => propGroup(s, cells, false, changed),
        K_APART => propApart(s, cells, changed),
        K_LINK => propLink(s, cells, con.sum, changed),
        K_LINE => propLine(s, cells, con.sum, changed),
        else => propSumFree(s, cells, con.sum, changed),
    };
}

fn enqueue(k: usize) void {
    if (queued[k]) return;
    if (!use_derived and isDerived(cons[k].kind)) return;
    queued[k] = true;
    queue[q_tail] = @intCast(k);
    q_tail = (q_tail + 1) % queue.len;
}

fn enqueueCell(c: usize) void {
    for (watch[c][0..watch_n[c]]) |k| enqueue(k);
}

fn drain(s: *State) bool {
    while (q_head != q_tail) {
        const k: usize = queue[q_head];
        q_head = (q_head + 1) % queue.len;
        queued[k] = false;
        const con = &cons[k];
        var before: [9]u16 = undefined;
        for (con.cells[0..con.len], 0..) |c, i| before[i] = s[c];
        var changed = false;
        if (!runCon(s, k, &changed)) {
            while (q_head != q_tail) : (q_head = (q_head + 1) % queue.len) queued[queue[q_head]] = false;
            return false;
        }
        if (changed) {
            for (con.cells[0..con.len], 0..) |c, i| {
                if (s[c] != before[i]) enqueueCell(c);
            }
        }
    }
    return true;
}

/// Propagate to a fixpoint from scratch.
fn propagate(s: *State) bool {
    if (derived_conflict) return false;
    for (0..con_n) |k| enqueue(k);
    return drain(s);
}

/// Propagate after a single cell changed.
fn propagateCell(s: *State, c: usize) bool {
    enqueueCell(c);
    return drain(s);
}

// ---------------------------------------------------------------- search

/// Also shave before the first guess of every search. Off for the web UI,
/// whose difficulty grades assume plain propagation.
var deep_logic: bool = false;
var trial: bool = false; // inside a shaving trial, where subset logic costs more than it finds
var probing: bool = false; // shave even though the search order is random

/// Bit 1: shaving (trial and error one step deep). Bit 2: set equivalence on
/// the ring patterns. Bit 8: locked candidates, fish, XY-wing and the fork
/// rule. Bit 16: set equivalence between rows and columns, and linear sums.
/// Any non-zero value also turns on subset logic.
var deep_level: u32 = 1;

// The steps beyond plain propagation, easiest first. `tech_use` counts how
// often each one removed a candidate.
const T_LOCKED = 0;
const T_XWING = 1;
const T_SWORDFISH = 2;
const T_XYWING = 3;
const T_FORK = 4;
const T_LINEAR = 5;
const T_LINE_EQ = 6;
const T_RING_EQ = 7;
const T_SHAVE = 8;
const T_COUNT = 9;
var tech_use: [T_COUNT]u32 = @splat(0);
var tech_out: [T_COUNT]u32 = @splat(0); // the counts of the last analysis

/// peer[a] has bit b set when cells a and b can never hold the same digit:
/// they share a house, a diagonal or a cage, lie a knight's move apart, or a
/// clue between them rules out equal digits.
var peer: [81]CellSet = @splat(.{ 0, 0 });

/// A set of cells as two machine words: cells 0 to 63, then 64 to 80.
const CellSet = [2]u64;

fn setPeers(a: u8, b: u8) void {
    if (a == b) return;
    peer[a][b >> 6] |= @as(u64, 1) << @intCast(b & 63);
    peer[b][a >> 6] |= @as(u64, 1) << @intCast(a & 63);
}

fn seesAny(a: u8, b: u8) bool {
    return peer[a][b >> 6] >> @intCast(b & 63) & 1 != 0;
}

/// Take the lowest cell out of a set; null once it is empty.
fn nextCell(set: *CellSet) ?usize {
    for (set, 0..) |*w, h| {
        if (w.* == 0) continue;
        const c = h * 64 + @ctz(w.*);
        w.* &= w.* - 1;
        return c;
    }
    return null;
}

fn buildPeers() void {
    peer = @splat(.{ 0, 0 });
    for (cons[0..con_n]) |*con| {
        const cells = con.cells[0..con.len];
        var all = false;
        switch (con.kind) {
            K_HOUSE, K_CAGE, K_DISTINCT, K_SUM_DISTINCT, K_THERMO => all = true,
            K_APART => for (cells[1..]) |c| setPeers(cells[0], c),
            K_LINK => {
                const op = con.sum >> 8;
                const v = con.sum & 255;
                const differ = switch (op) {
                    LINK_LESS => true,
                    LINK_SUM => v & 1 != 0,
                    LINK_DIFF, LINK_FAR => v >= 1,
                    LINK_RATIO => v >= 2,
                    else => false,
                };
                if (differ) setPeers(cells[0], cells[1]);
            },
            K_LINE => switch (con.sum) {
                LINE_RENBAN => all = true,
                LINE_WHISPER => for (1..cells.len) |i| setPeers(cells[i - 1], cells[i]),
                // A circle is larger than each cell of a shaft of two or more.
                LINE_ARROW => if (cells.len >= 3) {
                    for (cells[1..]) |c| setPeers(cells[0], c);
                },
                else => {},
            },
            else => {},
        }
        if (!all) continue;
        for (cells, 0..) |a, i| {
            for (cells[i + 1 ..]) |b| setPeers(a, b);
        }
    }
}

/// Locked candidates: a cell that sees every place a digit can still go in
/// some house cannot hold that digit itself.
fn lockedCandidates(s: *State, changed: *bool) bool {
    for (cons[0..con_n]) |*con| {
        if (con.kind != K_HOUSE) continue;
        var bit: u16 = 1;
        while (bit <= 256) : (bit <<= 1) {
            var common: CellSet = .{ ~@as(u64, 0), ~@as(u64, 0) };
            var places: u32 = 0;
            for (con.cells[0..con.len]) |c| {
                if (s[c] & bit == 0) continue;
                common[0] &= peer[c][0];
                common[1] &= peer[c][1];
                places += 1;
            }
            if (places == 0) return false;
            while (nextCell(&common)) |x| {
                if (s[x] & bit == 0) continue;
                s[x] &= ~bit;
                if (s[x] == 0) return false;
                changed.* = true;
            }
            if (changed.*) return true;
        }
    }
    return true;
}

/// Fish of size n: a digit confined to n columns across n rows goes nowhere
/// else in those columns, and the same with rows and columns swapped.
fn fish(s: *State, n: u32, changed: *bool) bool {
    for (0..2) |axis| {
        var bit: u16 = 1;
        while (bit <= 256) : (bit <<= 1) {
            var where: [9]u16 = @splat(0); // per line, the positions that may hold the digit
            for (0..81) |c| {
                if (s[c] & bit == 0) continue;
                const line = if (axis == 0) c / 9 else c % 9;
                const pos = if (axis == 0) c % 9 else c / 9;
                where[line] |= @as(u16, 1) << @intCast(pos);
            }
            var set: u16 = 1;
            while (set < 512) : (set += 1) {
                if (@popCount(set) != n) continue;
                var cover: u16 = 0;
                var fits = true;
                for (0..9) |l| {
                    if (set >> @intCast(l) & 1 == 0) continue;
                    if (@popCount(where[l]) < 2) fits = false;
                    cover |= where[l];
                }
                if (!fits or @popCount(cover) != n) continue;
                for (0..9) |l| {
                    if (set >> @intCast(l) & 1 != 0 or where[l] & cover == 0) continue;
                    for (0..9) |p| {
                        if (cover >> @intCast(p) & 1 == 0) continue;
                        const c = if (axis == 0) l * 9 + p else p * 9 + l;
                        if (s[c] & bit == 0) continue;
                        s[c] &= ~bit;
                        if (s[c] == 0) return false;
                        changed.* = true;
                    }
                }
                if (changed.*) return true;
            }
        }
    }
    return true;
}

/// XY-wing: a pivot holding x or y sees one cell holding x or z and another
/// holding y or z. One of those two is z, so no cell seeing both is.
fn xyWing(s: *State, changed: *bool) bool {
    for (0..81) |p| {
        const mp = s[p];
        if (@popCount(mp) != 2) continue;
        var pa = peer[p];
        while (nextCell(&pa)) |a| {
            const ma = s[a];
            if (@popCount(ma) != 2 or @popCount(ma & mp) != 1) continue;
            const z = ma & ~mp;
            const want = (mp & ~ma) | z;
            var pb = peer[p];
            while (nextCell(&pb)) |b| {
                if (s[b] != want) continue;
                var both: CellSet = .{ peer[a][0] & peer[b][0], peer[a][1] & peer[b][1] };
                while (nextCell(&both)) |c| {
                    if (s[c] & z == 0) continue;
                    s[c] &= ~z;
                    if (s[c] == 0) return false;
                    changed.* = true;
                }
                if (changed.*) return true;
            }
        }
    }
    return true;
}

/// A relation between a cell and one other cell, as the cell sees it.
const Rel = struct { other: u8, op: u8, v: u8, first: bool };

fn relations(m: u8, out: *[16]Rel) usize {
    var n: usize = 0;
    for (watch[m][0..watch_n[m]]) |k| {
        const con = &cons[k];
        const cells = con.cells[0..con.len];
        if (con.kind == K_LINK) {
            if (cells[0] == cells[1] or n == out.len) continue;
            const leads = cells[0] == m;
            out[n] = .{ .other = cells[if (leads) 1 else 0], .op = @intCast(con.sum >> 8), .v = @intCast(con.sum & 255), .first = leads };
            n += 1;
            continue;
        }
        const whisper = con.kind == K_LINE and con.sum == LINE_WHISPER;
        if (!whisper and con.kind != K_THERMO) continue;
        for (cells, 0..) |c, i| {
            if (c != m) continue;
            if (i > 0 and n < out.len) {
                out[n] = if (whisper) .{ .other = cells[i - 1], .op = LINK_FAR, .v = 5, .first = true } else .{ .other = cells[i - 1], .op = LINK_LESS, .v = 0, .first = false };
                n += 1;
            }
            if (i + 1 < cells.len and n < out.len) {
                out[n] = if (whisper) .{ .other = cells[i + 1], .op = LINK_FAR, .v = 5, .first = true } else .{ .other = cells[i + 1], .op = LINK_LESS, .v = 0, .first = true };
                n += 1;
            }
        }
    }
    return n;
}

/// The digits of the other cell that go with digit d in the cell itself.
fn relSupport(r: Rel, d: u8, other: u16) u16 {
    var out: u16 = 0;
    var m = other;
    while (m != 0) : (m &= m - 1) {
        const x: u8 = @intCast(@ctz(m) + 1);
        if (if (r.first) linkHolds(r.op, r.v, d, x) else linkHolds(r.op, r.v, x, d)) out |= m & (~m +% 1);
    }
    return out;
}

/// Fork rule: a cell tied to two cells that see each other needs a different
/// partner digit in each. A whisper cell between two cells of one box cannot
/// be 4 or 6, as either would put 9 or 1 on both sides.
fn fork(s: *State, changed: *bool) bool {
    var rel: [16]Rel = undefined;
    for (0..81) |mi| {
        const m: u8 = @intCast(mi);
        if (s[m] & (s[m] - 1) == 0) continue;
        const n = relations(m, &rel);
        if (n < 2) continue;
        var keep = s[m];
        for (0..n) |i| for (i + 1..n) |j| {
            const a = rel[i].other;
            const b = rel[j].other;
            const same = a == b;
            if (!same and !seesAny(a, b)) continue;
            var left = keep;
            while (left != 0) : (left &= left - 1) {
                const d: u8 = @intCast(@ctz(left) + 1);
                const xa = relSupport(rel[i], d, s[a]);
                const xb = relSupport(rel[j], d, s[b]);
                const fits = if (same) xa & xb != 0 else xa != 0 and xb != 0 and (xa != xb or xa & (xa - 1) != 0);
                if (!fits) keep &= ~(left & (~left +% 1));
            }
        };
        if (keep == s[m]) continue;
        if (keep == 0) return false;
        s[m] = keep;
        changed.* = true;
        return true;
    }
    return true;
}

/// Two sets of cells that always hold the same digits, each the same number
/// of times. The ring patterns: two rows from different bands plus two
/// columns from different stacks cover the four boxes where they cross once
/// too often; what the lines hold outside those boxes equals what the boxes
/// hold off the lines. Rows 3 and 7 with columns 3 and 7 give the well-known
/// ring around the centre box against the four corner squares. The line
/// patterns: a row and a column apart from the cell where they cross, and two
/// rows of one band against two columns of one stack apart from the four
/// crossings.
const SetEq = struct { p: [16]u8, n: [16]u8, np: u8 = 16, nn: u8 = 16 };
var set_eq: [729]SetEq = undefined;
var set_eq_n: usize = 0;
var line_eq: [162]SetEq = undefined;
var line_eq_n: usize = 0;

fn buildSetEq() void {
    if (set_eq_n != 0) return;
    for (0..9) |i| for (i + 1..9) |j| {
        if (i / 3 == j / 3) continue;
        for (0..9) |k| for (k + 1..9) |l| {
            if (k / 3 == l / 3) continue;
            var e: SetEq = .{ .p = undefined, .n = undefined };
            var np: usize = 0;
            var nn: usize = 0;
            for (0..81) |c| {
                const r = c / 9;
                const q = c % 9;
                const on_row = r == i or r == j;
                const on_col = q == k or q == l;
                const in_band = r / 3 == i / 3 or r / 3 == j / 3;
                const in_stack = q / 3 == k / 3 or q / 3 == l / 3;
                if ((on_row and (on_col or !in_stack)) or (on_col and !in_band)) {
                    e.p[np] = @intCast(c);
                    np += 1;
                } else if (in_band and in_stack and !on_row and !on_col) {
                    e.n[nn] = @intCast(c);
                    nn += 1;
                }
            }
            set_eq[set_eq_n] = e;
            set_eq_n += 1;
        };
    };
}

/// The cells on rows i and j but not on columns k and l, against the cells on
/// those columns but not on those rows.
fn addLineEq(i: usize, j: usize, k: usize, l: usize) void {
    var e: SetEq = .{ .p = undefined, .n = undefined, .np = 0, .nn = 0 };
    for (0..81) |c| {
        const on_row = c / 9 == i or c / 9 == j;
        const on_col = c % 9 == k or c % 9 == l;
        if (on_row and !on_col) {
            e.p[e.np] = @intCast(c);
            e.np += 1;
        } else if (on_col and !on_row) {
            e.n[e.nn] = @intCast(c);
            e.nn += 1;
        }
    }
    line_eq[line_eq_n] = e;
    line_eq_n += 1;
}

fn buildLineEq() void {
    if (line_eq_n != 0) return;
    for (0..9) |i| for (0..9) |k| addLineEq(i, i, k, k);
    for (0..9) |i| for (i + 1..9) |j| {
        if (i / 3 != j / 3) continue;
        for (0..9) |k| for (k + 1..9) |l| {
            if (k / 3 == l / 3) addLineEq(i, j, k, l);
        };
    };
}

/// One side cannot hold a digit more often than the other side has room for.
fn propSetEq(s: *State, e: *const SetEq, changed: *bool) bool {
    const sides = [2][]const u8{ e.p[0..e.np], e.n[0..e.nn] };
    var fixed: [2][9]u8 = undefined;
    var room: [2][9]u8 = undefined;
    var stale = true;
    for (0..9) |d| {
        const bit = @as(u16, 1) << @intCast(d);
        if (stale) {
            stale = false;
            fixed = @splat(@splat(0));
            room = @splat(@splat(0));
            for (sides, 0..) |side, w| {
                for (side) |c| {
                    var m = s[c];
                    if (m != 0 and m & (m - 1) == 0) fixed[w][@ctz(m)] += 1;
                    while (m != 0) : (m &= m - 1) room[w][@ctz(m)] += 1;
                }
            }
        }
        // Both sides hold the digit equally often: at least as often as
        // either already shows it, at most as often as either has room.
        const lo = @max(fixed[0][d], fixed[1][d]);
        const hi = @min(room[0][d], room[1][d]);
        if (lo > hi) return false;
        for (sides, 0..) |side, w| {
            if (room[w][d] == fixed[w][d]) continue;
            const need = room[w][d] == lo; // every open place is needed
            if (!need and fixed[w][d] != hi) continue; // else as many as the other side allows
            for (side) |c| {
                if (s[c] & bit == 0 or s[c] == bit) continue;
                if (need) s[c] = bit else s[c] &= ~bit;
                changed.* = true;
                stale = true;
            }
        }
    }
    return true;
}

/// Run the patterns from where the last hit was, and stop at the next one.
fn setEqStep(s: *State, list: []const SetEq, at: *usize, changed: *bool) bool {
    for (0..list.len) |i| {
        const k = (at.* + i) % list.len;
        if (!propSetEq(s, &list[k], changed)) return false;
        if (changed.*) {
            at.* = k;
            return true;
        }
    }
    return true;
}

/// A sum of cells times whole numbers with a known total, found by taking
/// clue equations off the 45 of a region until few cells are left.
const Lin = struct { n: u8, cells: [6]u8, coef: [6]i16, target: i32 };
const MAX_LIN = 96;
var lins: [MAX_LIN]Lin = undefined;
var lin_seen: [MAX_LIN][6]u16 = undefined; // candidates when a sum last found nothing
var lin_n: usize = 0;
var lin_dirty: bool = false; // the constraint table changed since the sums were built

/// A clue that fixes a sum: a cage, an arrow (shaft minus circle is zero) or
/// two cells with a known total.
const Eq = struct { n: u8, cells: [9]u8, coef: [9]i8, rhs: i32 };
var eqs: [81 + MAX_LINE + MAX_LINK]Eq = undefined;
var eq_n: usize = 0;

fn addEq(v: *const [81]i8, rhs: i32) void {
    var e: Eq = .{ .n = 0, .cells = undefined, .coef = undefined, .rhs = rhs };
    for (v, 0..) |k, c| {
        if (k == 0) continue;
        if (e.n == 9) return;
        e.cells[e.n] = @intCast(c);
        e.coef[e.n] = k;
        e.n += 1;
    }
    if (e.n == 0) return;
    eqs[eq_n] = e;
    eq_n += 1;
}

fn reduceRegion(in: *const [81]bool, houses: u32) void {
    var coef: [81]i32 = undefined;
    for (0..81) |c| coef[c] = @intFromBool(in[c]);
    var target: i32 = @intCast(45 * houses);
    var used = false;
    while (true) {
        var best: i32 = 0;
        var best_e: usize = 0;
        var best_sign: i32 = 0;
        for (eqs[0..eq_n], 0..) |*e, k| {
            for ([2]i32{ -1, 1 }) |sign| {
                var gain: i32 = 0;
                for (e.cells[0..e.n], e.coef[0..e.n]) |c, x| {
                    gain += @intFromBool(coef[c] != 0);
                    gain -= @intFromBool(coef[c] + sign * x != 0);
                }
                if (gain > best) {
                    best = gain;
                    best_e = k;
                    best_sign = sign;
                }
            }
        }
        if (best == 0) break;
        const e = &eqs[best_e];
        for (e.cells[0..e.n], e.coef[0..e.n]) |c, x| coef[c] += best_sign * x;
        target += best_sign * e.rhs;
        used = true;
    }
    if (!used or lin_n == MAX_LIN) return;
    var l: Lin = .{ .n = 0, .cells = undefined, .coef = undefined, .target = target };
    for (coef, 0..) |k, c| {
        if (k == 0) continue;
        if (l.n == 6) return;
        l.cells[l.n] = @intCast(c);
        l.coef[l.n] = @intCast(k);
        l.n += 1;
    }
    if (l.n == 0) return;
    next: for (lins[0..lin_n]) |*o| {
        if (o.n != l.n) continue;
        const flip: i32 = if (o.coef[0] == l.coef[0]) 1 else -1;
        if (o.target != flip * l.target) continue;
        for (0..l.n) |i| {
            if (o.cells[i] != l.cells[i] or o.coef[i] != flip * l.coef[i]) continue :next;
        }
        return;
    }
    lins[lin_n] = l;
    lin_seen[lin_n] = @splat(0);
    lin_n += 1;
}

/// Build the linear sums of the active puzzle from its cages, arrows and
/// two-cell totals, over the same regions the 45 rule looks at.
fn buildLinear() void {
    lin_dirty = false;
    lin_n = 0;
    eq_n = 0;
    for (0..cage_n) |k| {
        if (cage_len[k] < 2) continue;
        var v: [81]i8 = @splat(0);
        for (cage_cells[k][0..cage_len[k]]) |c| v[c] = 1;
        addEq(&v, cage_sum[k]);
    }
    if (links_on) {
        for (0..user_link_n) |k| {
            const l = user_link[k];
            if (k == link_skip or l[2] != LINK_SUM) continue;
            var v: [81]i8 = @splat(0);
            v[l[0]] += 1;
            v[l[1]] += 1;
            addEq(&v, l[3]);
        }
        for (0..user_line_n) |k| {
            if (k == line_skip or user_line_len[k] < 2 or user_line_kind[k] != LINE_ARROW) continue;
            var v: [81]i8 = @splat(0);
            const cells = user_line_cells[k][0..user_line_len[k]];
            for (cells[1..]) |c| v[c] += 1;
            v[cells[0]] -= 1;
            addEq(&v, 0);
        }
    }
    if (eq_n == 0) return;
    for (0..2) |axis| {
        for (0..9) |lo| {
            for (lo..@min(lo + 4, 9)) |hi| {
                var in: [81]bool = undefined;
                for (0..81) |c| {
                    const v = if (axis == 0) c / 9 else c % 9;
                    in[c] = v >= lo and v <= hi;
                }
                reduceRegion(&in, @intCast(hi - lo + 1));
            }
        }
    }
    for (0..9) |b1| {
        for (b1..9) |b2| {
            const adj = b1 == b2 or (b2 == b1 + 1 and b1 % 3 != 2) or b2 == b1 + 3;
            if (!adj) continue;
            var in: [81]bool = undefined;
            for (0..81) |c| {
                const b = c / 27 * 3 + c % 9 / 3;
                in[c] = b == b1 or b == b2;
            }
            reduceRegion(&in, if (b1 == b2) 1 else 2);
        }
    }
}

var lin_cur: *const Lin = undefined;
var lin_state: *State = undefined;
var lin_val: [6]u8 = undefined;
var lin_ok: [6]u16 = undefined;
var lin_lo: [7]i32 = undefined; // least and most the cells from i on can add
var lin_hi: [7]i32 = undefined;

/// Try every digit for cell `i` onwards, given what is still to be added.
/// Cells that see each other take different digits.
fn linWalk(i: usize, rest: i32) void {
    const l = lin_cur;
    if (i == l.n) {
        for (0..l.n) |j| lin_ok[j] |= @as(u16, 1) << @intCast(lin_val[j] - 1);
        return;
    }
    var m = lin_state[l.cells[i]];
    next: while (m != 0) : (m &= m - 1) {
        const v: u8 = @intCast(@ctz(m) + 1);
        const left = rest - @as(i32, l.coef[i]) * v;
        if (left < lin_lo[i + 1] or left > lin_hi[i + 1]) continue;
        for (0..i) |j| {
            if (lin_val[j] == v and seesAny(l.cells[i], l.cells[j])) continue :next;
        }
        lin_val[i] = v;
        linWalk(i + 1, left);
    }
}

fn propLin(s: *State, l: *const Lin, changed: *bool) bool {
    const n: usize = l.n;
    var lo: [6]i32 = undefined;
    var hi: [6]i32 = undefined;
    var sum_lo: i32 = 0;
    var sum_hi: i32 = 0;
    var ways: u32 = 1;
    for (0..n) |i| {
        const m = s[l.cells[i]];
        if (m == 0) return false;
        const a = @as(i32, l.coef[i]) * low(m);
        const b = @as(i32, l.coef[i]) * high(m);
        lo[i] = @min(a, b);
        hi[i] = @max(a, b);
        sum_lo += lo[i];
        sum_hi += hi[i];
    }
    // Bounds: a digit stays when the other cells can make up the rest.
    for (0..n) |i| {
        var keep: u16 = 0;
        var m = s[l.cells[i]];
        while (m != 0) : (m &= m - 1) {
            const rest = l.target - @as(i32, l.coef[i]) * (@as(i32, @ctz(m)) + 1);
            if (rest >= sum_lo - lo[i] and rest <= sum_hi - hi[i]) keep |= m & (~m +% 1);
        }
        if (!narrow(s, l.cells[i], keep, changed)) return false;
        ways *|= @popCount(keep);
    }
    if (ways > 4096) return true;
    lin_cur = l;
    lin_state = s;
    lin_ok = @splat(0);
    lin_lo[n] = 0;
    lin_hi[n] = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        const m = s[l.cells[i]];
        const a = @as(i32, l.coef[i]) * low(m);
        const b = @as(i32, l.coef[i]) * high(m);
        lin_lo[i] = lin_lo[i + 1] + @min(a, b);
        lin_hi[i] = lin_hi[i + 1] + @max(a, b);
    }
    linWalk(0, l.target);
    for (0..n) |k| {
        if (!narrow(s, l.cells[k], lin_ok[k], changed)) return false;
    }
    return true;
}

fn linearStep(s: *State, changed: *bool) bool {
    for (lins[0..lin_n], 0..) |*l, k| {
        var now: [6]u16 = @splat(0);
        for (0..l.n) |i| now[i] = s[l.cells[i]];
        var same = true;
        for (0..6) |i| same = same and now[i] == lin_seen[k][i];
        if (same) continue;
        if (!propLin(s, l, changed)) return false;
        if (changed.*) return true;
        lin_seen[k] = now;
    }
    return true;
}

var shave_at: usize = 0;
var ring_at: usize = 0;
var line_at: usize = 0;

/// Shave one candidate: a digit that leads straight to a contradiction when
/// tried is removed. Starts looking at the cell of the last hit.
fn shaveStep(s: *State, changed: *bool) void {
    for (0..81) |i| {
        const c = (shave_at + i) % 81;
        var m = s[c];
        if (m & (m - 1) == 0) continue;
        while (m != 0) : (m &= m - 1) {
            const bit = m & (~m + 1);
            var t: State = s.*;
            t[c] = bit;
            trial = true;
            const fits = propagateCell(&t, c);
            trial = false;
            if (fits) continue;
            s[c] &= ~bit;
            shave_at = c;
            changed.* = true;
            return;
        }
    }
}

/// Run the easiest step that removes a candidate. Returns which one it was,
/// T_COUNT when none applies, or null on a contradiction.
fn deepStep(s: *State) ?usize {
    const lv = deep_level;
    var changed = false;
    if (lv & 8 != 0) {
        if (!lockedCandidates(s, &changed)) return null;
        if (changed) return T_LOCKED;
        if (!fish(s, 2, &changed)) return null;
        if (changed) return T_XWING;
        if (!fish(s, 3, &changed)) return null;
        if (changed) return T_SWORDFISH;
        if (!xyWing(s, &changed)) return null;
        if (changed) return T_XYWING;
        if (!fork(s, &changed)) return null;
        if (changed) return T_FORK;
    }
    if (lv & 16 != 0) {
        if (!linearStep(s, &changed)) return null;
        if (changed) return T_LINEAR;
        if (!setEqStep(s, line_eq[0..line_eq_n], &line_at, &changed)) return null;
        if (changed) return T_LINE_EQ;
    }
    if (lv & 2 != 0) {
        if (!setEqStep(s, set_eq[0..set_eq_n], &ring_at, &changed)) return null;
        if (changed) return T_RING_EQ;
    }
    if (lv & 1 != 0) {
        shaveStep(s, &changed);
        if (changed) return T_SHAVE;
    }
    return T_COUNT;
}

/// Everything the solver does before it would have to guess. Starts from a
/// propagated state; after every step that removes a candidate it propagates
/// again and goes back to the easiest step.
fn deepRoot(s: *State) bool {
    if (!deep_logic) return shave(s);
    if (deep_level & 24 != 0) buildPeers();
    if (deep_level & 16 != 0) {
        if (lin_dirty) buildLinear();
        buildLineEq();
    }
    if (deep_level & 2 != 0) buildSetEq();
    shave_at = 0;
    ring_at = 0;
    line_at = 0;
    while (true) {
        const before: State = s.*;
        const t = deepStep(s) orelse return false;
        if (t == T_COUNT) return true;
        tech_use[t] += 1;
        for (0..81) |c| {
            if (s[c] == 0) return false;
            if (s[c] != before[c]) enqueueCell(c);
        }
        if (!drain(s)) return false;
    }
}

/// Shave: a digit that leads straight to a contradiction when tried is not a
/// candidate. Repeats until nothing more falls; false when a cell runs dry.
fn shave(s: *State) bool {
    var again = true;
    while (again) {
        again = false;
        for (0..81) |c| {
            var m = s[c];
            if (m & (m - 1) == 0) continue;
            while (m != 0) {
                const bit = m & (~m + 1);
                m &= m - 1;
                if (s[c] & bit == 0) continue;
                var t: State = s.*;
                t[c] = bit;
                trial = true;
                const fits = propagateCell(&t, c);
                trial = false;
                if (fits) continue;
                s[c] &= ~bit;
                again = true;
                if (!propagateCell(s, c)) return false;
            }
        }
    }
    return true;
}

fn search(s: *State, dirty: usize) void {
    if (found >= limit or nodes > node_cap) return;
    if (!(if (dirty == 81) propagate(s) else propagateCell(s, dirty))) return;
    if (dirty == 81 and deep_logic and (!randomize or probing) and !deepRoot(s)) return;
    var best: usize = 81;
    var bc: u32 = 10;
    for (0..81) |i| {
        const pc: u32 = @popCount(s[i]);
        if (pc > 1 and pc < bc) {
            bc = pc;
            best = i;
        }
    }
    if (best == 81) {
        found += 1;
        if (found == 1) first = s.* else second = s.*;
        return;
    }
    nodes += 1;
    var m = s[best];
    while (m != 0) {
        var bit: u16 = m & (~m +% 1);
        if (randomize) {
            var k = rndBelow(@popCount(m));
            var t = m;
            while (k > 0) : (k -= 1) t &= t - 1;
            bit = t & (~t +% 1);
        }
        m &= ~bit;
        var next = s.*;
        next[best] = bit;
        search(&next, best);
        if (found >= limit or nodes > node_cap) return;
    }
}

fn runSearch(lim: u32, cap: u32, random: bool) void {
    var s: State = given_mask;
    nodes = 0;
    found = 0;
    limit = lim;
    node_cap = cap;
    randomize = random;
    search(&s, 81);
}

fn satisfies(g: *const [81]u8) bool {
    for (0..81) |c| {
        if (given_mask[c] & (@as(u16, 1) << @intCast(g[c] - 1)) == 0) return false;
    }
    for (0..cage_n) |k| {
        var sum: u16 = 0;
        var mask: u16 = 0;
        for (cage_cells[k][0..cage_len[k]]) |c| {
            const bit = @as(u16, 1) << @intCast(g[c] - 1);
            if (mask & bit != 0) return false;
            mask |= bit;
            sum += g[c];
        }
        if (sum != cage_sum[k]) return false;
    }
    for (0..thermo_n) |k| {
        var i: usize = 1;
        while (i < thermo_len[k]) : (i += 1) {
            if (g[thermo_cells[k][i]] <= g[thermo_cells[k][i - 1]]) return false;
        }
    }
    if (links_on) {
        for (0..user_link_n) |k| {
            const l = user_link[k];
            if (k != link_skip and !linkHolds(l[2], l[3], g[l[0]], g[l[1]])) return false;
        }
        for (0..user_line_n) |k| {
            if (k == line_skip or user_line_len[k] < 2) continue;
            if (!lineHolds(g, user_line_cells[k][0..user_line_len[k]], user_line_kind[k])) return false;
        }
    }
    return true;
}

fn remember(st: *const State) void {
    var g: [81]u8 = undefined;
    var differs = false;
    for (0..81) |c| {
        g[c] = @intCast(@ctz(st[c]) + 1);
        if (g[c] != solution[c]) differs = true;
    }
    if (!differs) return;
    wit[wit_next] = g;
    wit_next = (wit_next + 1) % MAX_WIT;
    if (wit_n < MAX_WIT) wit_n += 1;
}

/// True when the current clues admit exactly one solution within the budget.
fn isUnique(cap: u32) bool {
    for (wit[0..wit_n]) |*g| {
        if (satisfies(g)) return false;
    }
    runSearch(2, cap, false);
    if (found >= 2) {
        remember(&first);
        remember(&second);
    }
    return found == 1 and nodes <= cap;
}

// ---------------------------------------------------------------- cages

/// Rebuild compact cage tables from arbitrary labels. Fails when a cage has
/// more than `max_len` cells or repeats a digit.
fn rebuild(labels: *const [81]u8, max_len: usize) bool {
    var map: [256]u8 = @splat(NONE);
    var masks: [81]u16 = @splat(0);
    cage_n = 0;
    for (0..81) |c| {
        const l = labels[c];
        if (l == NONE) {
            cage_of[c] = NONE; // cell belongs to no cage
            continue;
        }
        if (map[l] == NONE) {
            map[l] = @intCast(cage_n);
            cage_len[cage_n] = 0;
            cage_sum[cage_n] = 0;
            cage_n += 1;
        }
        const k = map[l];
        if (cage_len[k] >= max_len) return false;
        const bit = @as(u16, 1) << @intCast(solution[c] - 1);
        if (masks[k] & bit != 0) return false;
        masks[k] |= bit;
        cage_cells[k][cage_len[k]] = @intCast(c);
        cage_len[k] += 1;
        cage_sum[k] += solution[c];
        cage_of[c] = k;
    }
    buildDerived();
    buildCons(true);
    return true;
}

fn addDerived(cells: []const u8, sum: u32) void {
    if (cells.len == 0) {
        if (sum != 0) derived_conflict = true;
        return;
    }
    if (sum < cells.len or sum > 9 * cells.len) {
        derived_conflict = true;
        return;
    }
    if (cells.len > 6 or der_n >= MAX_DERIVED) return;
    var row = true;
    var col = true;
    var box = true;
    const c0: usize = cells[0];
    for (cells, 0..) |c, i| {
        const cc: usize = c;
        der_cells[der_n][i] = c;
        if (cc / 9 != c0 / 9) row = false;
        if (cc % 9 != c0 % 9) col = false;
        if (cc / 27 != c0 / 27 or cc % 9 / 3 != c0 % 9 / 3) box = false;
    }
    const distinct = row or col or box;
    if (distinct and sum > 45) {
        derived_conflict = true;
        return;
    }
    der_len[der_n] = @intCast(cells.len);
    der_sum[der_n] = @intCast(sum);
    der_distinct[der_n] = distinct;
    der_n += 1;
}

/// For a union of houses: cells inside whose cage sticks out (innies) and
/// cells outside whose cage reaches in (outies) both have a forced sum.
/// `houses` is how many rows, columns or boxes the region is made of.
fn addRegion(in: *const [81]bool, houses: u32) void {
    var inside: [81]bool = @splat(false); // cage has a cell inside
    var outside: [81]bool = @splat(false); // cage has a cell outside
    var open = false; // an uncaged cell inside: the cages no longer cover the region
    for (0..81) |c| {
        const k = cage_of[c];
        if (k == NONE) {
            if (in[c]) open = true;
            continue;
        }
        if (in[c]) inside[k] = true else outside[k] = true;
    }
    var innies: [81]u8 = undefined;
    var outies: [81]u8 = undefined;
    var ni: usize = 0;
    var no: usize = 0;
    for (0..81) |c| {
        const k = cage_of[c];
        if (k != NONE and !(inside[k] and outside[k])) continue;
        if (k == NONE and !in[c]) continue;
        if (in[c]) {
            innies[ni] = @intCast(c);
            ni += 1;
        } else {
            outies[no] = @intCast(c);
            no += 1;
        }
    }
    var inside_sum: u32 = 0; // cages entirely inside the region
    var touch_sum: u32 = 0; // every cage with a cell inside
    for (0..cage_n) |k| {
        if (!inside[k]) continue;
        touch_sum += cage_sum[k];
        if (!outside[k]) inside_sum += cage_sum[k];
    }
    const total = 45 * houses;
    if (inside_sum > total) {
        derived_conflict = true;
    } else {
        addDerived(innies[0..ni], total - inside_sum);
    }
    if (!open) {
        if (touch_sum < total) {
            derived_conflict = true;
        } else {
            addDerived(outies[0..no], touch_sum - total);
        }
    }
}

fn buildDerived() void {
    der_n = 0;
    derived_conflict = false;
    // bands of 1..4 adjacent rows or columns
    for (0..2) |axis| {
        for (0..9) |lo| {
            for (lo..@min(lo + 4, 9)) |hi| {
                var in: [81]bool = undefined;
                for (0..81) |c| {
                    const v = if (axis == 0) c / 9 else c % 9;
                    in[c] = v >= lo and v <= hi;
                }
                addRegion(&in, @intCast(hi - lo + 1));
            }
        }
    }
    // single boxes and pairs of adjacent boxes
    for (0..9) |b1| {
        for (b1..9) |b2| {
            const adj = b1 == b2 or (b2 == b1 + 1 and b1 % 3 != 2) or b2 == b1 + 3;
            if (!adj) continue;
            var in: [81]bool = undefined;
            for (0..81) |c| {
                const b = c / 27 * 3 + c % 9 / 3;
                in[c] = b == b1 or b == b2;
            }
            addRegion(&in, if (b1 == b2) 1 else 2);
        }
    }
}

fn neighbours(c: usize, out: *[4]u8) usize {
    var n: usize = 0;
    if (c >= 9) {
        out[n] = @intCast(c - 9);
        n += 1;
    }
    if (c < 72) {
        out[n] = @intCast(c + 9);
        n += 1;
    }
    if (c % 9 != 0) {
        out[n] = @intCast(c - 1);
        n += 1;
    }
    if (c % 9 != 8) {
        out[n] = @intCast(c + 1);
        n += 1;
    }
    return n;
}

fn digitBit(c: usize) u16 {
    return @as(u16, 1) << @intCast(solution[c] - 1);
}

/// Random partition into connected cages without repeated digits. With `sym`
/// the layout has 180 degree rotational symmetry.
/// fill 0: cover the free cells with cages. fill 1: one single-cell cage (a
/// given digit) per free cell. fill 2: leave the free cells without clues.
fn partition(labels: *[81]u8, sym: bool, max_size: u32, fill: u32, use_user: bool) void {
    for (labels, 0..) |*l, c| {
        l.* = if (use_user and user_cage[c] != NONE) 170 + user_cage[c] else NONE;
    }
    var next: u8 = 0;

    if (sym) {
        labels[40] = next;
        var nb: [4]u8 = undefined;
        const n = neighbours(40, &nb);
        const p = nb[rndBelow(@intCast(n))];
        const q = 80 - p;
        if (rndBelow(4) != 0 and digitBit(p) != digitBit(q)) {
            labels[p] = next;
            labels[q] = next;
        }
        next += 1;
    }

    var order: [81]u8 = undefined;
    for (0..81) |i| order[i] = @intCast(i);
    var i: usize = 80;
    while (i > 0) : (i -= 1) {
        const j = rndBelow(@intCast(i + 1));
        const t = order[i];
        order[i] = order[j];
        order[j] = t;
    }

    for (order) |start| {
        if (labels[start] != NONE) continue;
        if (fill == 2) continue;
        if (fill == 1) {
            labels[start] = next;
            next += 1;
            continue;
        }
        const la = next;
        const lb = next + 1;
        next += if (sym) 2 else 1;
        var cells: [9]u8 = undefined;
        var len: usize = 1;
        cells[0] = start;
        labels[start] = la;
        var mask_a = digitBit(start);
        var mask_b: u16 = 0;
        if (sym) {
            labels[80 - start] = lb;
            mask_b = digitBit(80 - start);
        }
        const target = 2 + rndBelow(max_size - 1);
        while (len < target) {
            var cands: [36]u8 = undefined;
            var nc: usize = 0;
            for (cells[0..len]) |c| {
                var nb: [4]u8 = undefined;
                const n = neighbours(c, &nb);
                for (nb[0..n]) |d| {
                    if (labels[d] != NONE) continue;
                    if (mask_a & digitBit(d) != 0) continue;
                    if (sym) {
                        if (labels[80 - d] != NONE) continue;
                        if (mask_b & digitBit(80 - d) != 0) continue;
                    }
                    cands[nc] = d;
                    nc += 1;
                }
            }
            if (nc == 0) break;
            const d = cands[rndBelow(@intCast(nc))];
            labels[d] = la;
            mask_a |= digitBit(d);
            if (sym) {
                labels[80 - d] = lb;
                mask_b |= digitBit(80 - d);
            }
            cells[len] = d;
            len += 1;
        }
    }
}

const DR = [8]i32{ -1, 1, 0, 0, -1, -1, 1, 1 };
const DC = [8]i32{ 0, 0, -1, 1, -1, 1, -1, 1 };

/// Lay random thermometers along paths where the solution already increases.
/// Paths may step diagonally but never cross each other.
fn placeThermos(count: u32, use_user: bool) void {
    thermo_n = 0;
    var used: [81]bool = @splat(false);
    if (use_user) {
        for (0..user_thermo_n) |k| {
            thermo_cells[k] = user_thermo_cells[k];
            thermo_len[k] = user_thermo_len[k];
            for (user_thermo_cells[k][0..user_thermo_len[k]]) |c| used[c] = true;
        }
        thermo_n = user_thermo_n;
    }
    locked_thermos = thermo_n;
    const want = thermo_n + count;
    var diag: [64]bool = @splat(false); // a diagonal already runs through this 2x2 block
    var tries: u32 = 0;
    while (thermo_n < want and thermo_n < MAX_THERMO and tries < 600) : (tries += 1) {
        const start = rndBelow(81);
        if (used[start] or solution[start] > 4) continue;
        var path: [9]u8 = undefined;
        var blocks: [9]u8 = undefined;
        var nb: usize = 0;
        var len: usize = 1;
        path[0] = @intCast(start);
        const target = 3 + rndBelow(4);
        while (len < target) {
            const cur: usize = path[len - 1];
            const r: i32 = @intCast(cur / 9);
            const q: i32 = @intCast(cur % 9);
            var cands: [8]u8 = undefined;
            var cblock: [8]u8 = undefined;
            var nc: usize = 0;
            for (0..8) |k| {
                const r2 = r + DR[k];
                const q2 = q + DC[k];
                if (r2 < 0 or r2 > 8 or q2 < 0 or q2 > 8) continue;
                const d: usize = @intCast(r2 * 9 + q2);
                if (used[d] or solution[d] <= solution[cur]) continue;
                var block: u8 = NONE;
                if (k >= 4) {
                    block = @intCast(@min(r, r2) * 8 + @min(q, q2));
                    if (diag[block]) continue;
                    var clash = false;
                    for (blocks[0..nb]) |b| {
                        if (b == block) clash = true;
                    }
                    if (clash) continue;
                }
                cands[nc] = @intCast(d);
                cblock[nc] = block;
                nc += 1;
            }
            if (nc == 0) break;
            const pick = rndBelow(@intCast(nc));
            path[len] = cands[pick];
            len += 1;
            if (cblock[pick] != NONE) {
                blocks[nb] = cblock[pick];
                nb += 1;
            }
        }
        if (len < 3) continue;
        for (path[0..len]) |c| used[c] = true;
        for (blocks[0..nb]) |b| diag[b] = true;
        thermo_cells[thermo_n] = path;
        thermo_len[thermo_n] = @intCast(len);
        thermo_n += 1;
    }
}

fn labelCount(labels: *const [81]u8, l: u8) usize {
    var n: usize = 0;
    for (labels) |x| {
        if (x == l) n += 1;
    }
    return n;
}

fn relabel(labels: *[81]u8, from: u8, to: u8) void {
    for (labels) |*l| {
        if (l.* == from) l.* = to;
    }
}

/// Solve the way a person would: exhaust the cheap techniques (singles and
/// cage combinations), and only then reach for one 45-rule deduction.
fn grade() void {
    var s: State = given_mask;
    use_derived = false;
    defer use_derived = true;
    rule_steps = 0;
    basic_solved = 0;
    grade_done = false;
    var round: u32 = 0;
    while (round < 400) : (round += 1) {
        if (!propagate(&s)) return;
        var solved: u32 = 0;
        for (s) |m| {
            if (m & (m - 1) == 0) solved += 1;
        }
        if (round == 0) basic_solved = solved;
        if (solved == 81) {
            grade_done = true;
            return;
        }
        var changed = false;
        for (0..con_n) |k| {
            if (!isDerived(cons[k].kind)) continue;
            if (!runCon(&s, k, &changed)) return;
            if (changed) break;
        }
        if (!changed) return; // stuck: needs search
        rule_steps += 1;
    }
}

// ---------------------------------------------------------------- analysis

var an_cand: [81]u16 = @splat(0);
var an_sol: [81]u8 = @splat(0);
var red_cage: [81]u8 = @splat(0); // by hand-set cage id: 1 = puzzle stays unique without it
var red_thermo: [MAX_THERMO]u8 = @splat(0);

/// Make the clues in the user buffers the active puzzle, optionally leaving
/// one cage or one thermometer out. Cages without a sum only forbid repeats.
fn loadUser(skip_cage: usize, skip_thermo: usize) void {
    links_on = true;
    thermo_n = 0;
    for (0..user_thermo_n) |k| {
        if (k == skip_thermo) continue;
        thermo_cells[thermo_n] = user_thermo_cells[k];
        thermo_len[thermo_n] = user_thermo_len[k];
        thermo_n += 1;
    }
    cage_n = 0;
    cage_of = @splat(NONE);
    var shapes: [81][9]u8 = undefined;
    var shape_len: [81]u8 = undefined;
    var shape_n: usize = 0;
    for (0..81) |id| {
        if (id == skip_cage) continue;
        var cells: [9]u8 = undefined;
        var n: usize = 0;
        for (0..81) |c| {
            if (user_cage[c] == id and n < 9) {
                cells[n] = @intCast(c);
                n += 1;
            }
        }
        if (n == 0) continue;
        if (user_sum[id] != 0 and user_sum[id] <= 45) {
            cage_cells[cage_n] = cells;
            cage_len[cage_n] = @intCast(n);
            cage_sum[cage_n] = user_sum[id];
            for (cells[0..n]) |c| cage_of[c] = @intCast(cage_n);
            cage_n += 1;
        } else {
            shapes[shape_n] = cells;
            shape_len[shape_n] = @intCast(n);
            shape_n += 1;
        }
    }
    buildDerived();
    buildCons(true);
    for (0..shape_n) |k| addCon(K_DISTINCT, shapes[k][0..shape_len[k]], 0);
}

/// 0 no solution, 1 exactly one, 2 more than one, 3 at least one (budget ran
/// out before a second was found or ruled out), 4 unknown.
fn classify(cap: u32) u32 {
    runSearch(2, cap, false);
    if (found >= 2) return 2;
    if (nodes > cap) return if (found == 1) 3 else 4;
    return found;
}

/// Analyse the hand-set clues on their own. Fills the candidate masks left by
/// propagation, and when the solution is unique also the solution, the logic
/// grade and which clues could each be dropped without losing uniqueness.
export fn analyze(cap: u32, digits_shown: u32) u32 {
    setGivens(if (digits_shown != 0) .shown else .marks);
    red_digit = @splat(0);
    red_cage = @splat(0);
    red_thermo = @splat(0);
    red_link = @splat(0);
    red_line = @splat(0);
    link_skip = MAX_LINK;
    line_skip = MAX_LINE;
    rule_steps = 0;
    grade_done = false;
    tech_use = @splat(0);
    tech_out = @splat(0);
    loadUser(81, MAX_THERMO);
    var s: State = given_mask;
    if (!propagate(&s)) {
        an_cand = @splat(0);
        return 0;
    }
    if (!deepRoot(&s)) {
        an_cand = @splat(0);
        return 0;
    }
    an_cand = s;
    tech_out = tech_use; // the searches below run the same steps again
    const status = classify(cap);
    if (status != 1) return status;
    last_guesses = nodes;
    for (0..81) |c| {
        an_sol[c] = @intCast(@ctz(first[c]) + 1);
        solution[c] = an_sol[c];
    }
    grade();
    const steps = rule_steps;
    const done = grade_done;
    for (0..81) |id| {
        var present = false;
        for (user_cage) |x| {
            if (x == id) present = true;
        }
        if (!present) continue;
        loadUser(id, MAX_THERMO);
        if (classify(cap) == 1) red_cage[id] = 1;
    }
    for (0..user_thermo_n) |k| {
        loadUser(81, k);
        if (classify(cap) == 1) red_thermo[k] = 1;
    }
    for (0..user_link_n) |k| {
        link_skip = k;
        loadUser(81, MAX_THERMO);
        if (classify(cap) == 1) red_link[k] = 1;
    }
    link_skip = MAX_LINK;
    for (0..user_line_n) |k| {
        line_skip = k;
        loadUser(81, MAX_THERMO);
        if (classify(cap) == 1) red_line[k] = 1;
    }
    line_skip = MAX_LINE;
    loadUser(81, MAX_THERMO);
    for (0..81) |c| {
        const keep = given_mask[c];
        if (keep == ALL) continue;
        given_mask[c] = ALL;
        if (classify(cap) == 1) red_digit[c] = 1;
        given_mask[c] = keep;
    }
    rule_steps = steps;
    grade_done = done;
    return 1;
}

/// Make the clues in the user buffers the active puzzle for `candidates`.
export fn loadClues(digits_shown: u32) void {
    link_skip = MAX_LINK;
    line_skip = MAX_LINE;
    setGivens(if (digits_shown != 0) .shown else .marks);
    loadUser(81, MAX_THERMO);
}
/// Choose the extra global rules (bit 0 diagonals, bit 1 anti-knight).
/// Is there a solution with `digit` in `cell`? 1 yes (it is left in the
/// analysis solution buffer), 0 no, 2 the node budget ran out first.
export fn probe(cell: u32, digit: u32, cap: u32, digits_shown: u32) u32 {
    setGivens(if (digits_shown != 0) .shown else .marks);
    link_skip = MAX_LINK;
    line_skip = MAX_LINE;
    loadUser(81, MAX_THERMO);
    const bit = @as(u16, 1) << @intCast(digit - 1);
    if (given_mask[cell] & bit == 0) return 0;
    given_mask[cell] = bit;
    probing = true;
    runSearch(1, cap, true);
    probing = false;
    if (found == 0) return if (nodes > cap) 2 else 0;
    for (0..81) |c| an_sol[c] = @intCast(@ctz(first[c]) + 1);
    return 1;
}
export fn setDeepLogic(on: u32) void {
    deep_logic = on != 0;
    deep_level = on;
}
/// How often each step beyond plain propagation removed a candidate in the
/// last analysis: locked candidates, X-wing, swordfish, XY-wing, fork rule,
/// linear sums, set equivalence on lines, set equivalence on rings, trial
/// and error.
export fn techniquePtr() [*]u32 {
    return &tech_out;
}
/// 1 when the 81 digits at `ptr` satisfy every clue in the user buffers.
export fn checkGrid(ptr: [*]const u8) u32 {
    link_skip = MAX_LINK;
    line_skip = MAX_LINE;
    setGivens(.shown);
    loadUser(81, MAX_THERMO);
    var g: [81]u8 = undefined;
    for (0..81) |c| {
        if (ptr[c] < 1 or ptr[c] > 9) return 0;
        g[c] = ptr[c];
    }
    // Every group that forbids repeats, which covers the houses, the extra
    // rules and the cages whose sum is still open.
    for (cons[0..con_n]) |*con| {
        const cells = con.cells[0..con.len];
        switch (con.kind) {
            K_HOUSE, K_DISTINCT => {
                var seen: u16 = 0;
                for (cells) |c| {
                    const bit = @as(u16, 1) << @intCast(g[c] - 1);
                    if (seen & bit != 0) return 0;
                    seen |= bit;
                }
            },
            K_APART => for (cells[1..]) |c| {
                if (g[c] == g[cells[0]]) return 0;
            },
            else => {},
        }
    }
    return @intFromBool(satisfies(&g));
}
export fn setRules(mask: u32) void {
    rules = mask;
}
export fn userDigitPtr() [*]u8 {
    return &user_digit;
}
export fn userLineCellPtr() [*]u8 {
    return @ptrCast(&user_line_cells);
}
export fn userLineLenPtr() [*]u8 {
    return &user_line_len;
}
export fn userLineKindPtr() [*]u8 {
    return &user_line_kind;
}
export fn setUserLineCount(n: u32) void {
    user_line_n = @min(n, MAX_LINE);
}
export fn redundantLinePtr() [*]u8 {
    return &red_line;
}
export fn userLinkPtr() [*]u8 {
    return @ptrCast(&user_link);
}
export fn setUserLinkCount(n: u32) void {
    user_link_n = @min(n, MAX_LINK);
}
export fn redundantLinkPtr() [*]u8 {
    return &red_link;
}
export fn userMaskPtr() [*]u16 {
    return &user_mask;
}
export fn userHiddenPtr() [*]u8 {
    return &user_hidden;
}
export fn redundantDigitPtr() [*]u8 {
    return &red_digit;
}
export fn analysisCandPtr() [*]u16 {
    return &an_cand;
}
export fn analysisSolutionPtr() [*]u8 {
    return &an_sol;
}
export fn redundantCagePtr() [*]u8 {
    return &red_cage;
}
export fn redundantThermoPtr() [*]u8 {
    return &red_thermo;
}

// ---------------------------------------------------------------- exports

/// Generate a puzzle. Returns 1 on success, 0 if no unique layout was found.
/// merges: percentage of cell borders to try merging across per round.
/// logic_only: only accept layouts the propagators solve without guessing.
/// thermos: how many thermometers to lay down.
/// removals: percentage of cells whose cage we try to dissolve (100 = every cage).
/// fill: what the generator may add to free cells (0 cages, 1 given digits, 2 nothing).
/// use_user: build around the hand-set clues in the user buffers.
/// digits_shown: the setter's fixed digits are givens in the puzzle; otherwise
/// they only steer which solution grid is invented.
/// Returns 1 on success, 0 when no unique layout was found, 2 when no grid fits the hand-set clues.
export fn generate(seed: u32, sym: u32, max_size: u32, merges: u32, logic_only: u32, thermos: u32, removals: u32, fill: u32, use_user: u32, digits_shown: u32) u32 {
    rs = (@as(u64, seed) << 32) | (seed ^ 0x5DEECE66) | 1;
    for (0..8) |_| _ = rnd();
    const around = use_user != 0;
    links_on = around;
    link_skip = MAX_LINK;
    line_skip = MAX_LINE;
    const symmetric = sym != 0 and !around and fill == 0;
    for (0..81) |c| locked[c] = around and user_cage[c] != NONE;
    // In logic-only mode the first branch already disqualifies a layout, so
    // the uniqueness search may stop there instead of running to the cap.
    const cap: u32 = if (logic_only != 0) 0 else 1000;
    const guess_max: u32 = cap;
    const msize: u32 = if (max_size < 2) 2 else if (max_size > 6) 6 else max_size;

    var labels: [81]u8 = undefined;
    var attempt: u32 = 0;
    while (attempt < 240) : (attempt += 1) {
        // a fresh solved grid every few attempts
        if (attempt % 6 == 0 or fill == 2) {
            use_cages = false;
            buildGridCons(around);
            wit_n = 0;
            wit_next = 0;
            setGivens(if (around) .all else .none);
            runSearch(1, 200_000, true);
            setGivens(if (!around) .none else if (digits_shown != 0) .shown else .marks);
            if (found == 0) return if (around) 2 else 0;
            for (0..81) |c| solution[c] = @intCast(@ctz(first[c]) + 1);
            placeThermos(thermos, around);
        }
        partition(&labels, symmetric, msize, fill, around);
        if (!rebuild(&labels, 9)) continue;
        if (isUnique(cap) and nodes <= guess_max) break;
    } else return 0;
    last_guesses = nodes;

    // Moves: 0..143 merge across a cell border, 144..224 dissolve the cage at a
    // cell, 225..305 remove the thermometer through a cell.
    var edges: [144][2]u8 = undefined;
    var ne: usize = 0;
    for (0..81) |c| {
        if (c % 9 != 8) {
            edges[ne] = .{ @intCast(c), @intCast(c + 1) };
            ne += 1;
        }
        if (c < 72) {
            edges[ne] = .{ @intCast(c), @intCast(c + 9) };
            ne += 1;
        }
    }
    const N_MOVES = 306;
    var moves: [N_MOVES]u16 = undefined;
    for (0..N_MOVES) |k| moves[k] = @intCast(k);
    var failed: [N_MOVES]bool = @splat(false);
    const merge_max: usize = msize + 2;
    const merge_pct = if (fill == 0) @min(merges, 100) else 0;
    const removal_pct = @min(removals, 100);

    // Local search: keep applying random merges and removals while the puzzle
    // stays unique, until a whole round finds nothing.
    // Removing a clue only weakens the puzzle, so a move that failed keeps
    // failing after any removal. A merge is different: it gives up two sums for
    // one but adds "no repeats" across the joined cells, so after a successful
    // merge every failed move is worth another try.
    var round: u32 = 0;
    while (round < 12) : (round += 1) {
        var progress = false;
        var i: usize = N_MOVES - 1;
        while (i > 0) : (i -= 1) {
            const j = rndBelow(@intCast(i + 1));
            const t = moves[i];
            moves[i] = moves[j];
            moves[j] = t;
        }
        // phase 0 absorbs single-cell cages (given digits in disguise) first
        for (0..2) |phase| {
            for (moves) |mv| {
                if (failed[mv]) continue;
                const saved = labels;
                const saved_cells = thermo_cells;
                const saved_len = thermo_len;
                const saved_n = thermo_n;
                var too_big = false;
                if (mv < 144) {
                    const c: usize = edges[mv][0];
                    const d: usize = edges[mv][1];
                    if (labels[c] == labels[d] or labels[c] == NONE or labels[d] == NONE) continue;
                    if (locked[c] or locked[d]) continue;
                    if (phase == 0 and labelCount(&labels, labels[c]) != 1 and labelCount(&labels, labels[d]) != 1) continue;
                    if (rndBelow(100) >= merge_pct) continue;
                    relabel(&labels, labels[d], labels[c]);
                    if (symmetric) {
                        const a2 = labels[80 - c];
                        const b2 = labels[80 - d];
                        if (a2 != b2 and a2 != NONE and b2 != NONE) relabel(&labels, b2, a2);
                    }
                    too_big = labelCount(&labels, labels[c]) > merge_max;
                } else if (mv < 225) {
                    if (phase == 0) continue;
                    const c: usize = mv - 144;
                    const l = labels[c];
                    if (l == NONE or locked[c]) continue;
                    if (rndBelow(100) >= removal_pct) continue;
                    const l2 = labels[80 - c];
                    relabel(&labels, l, NONE);
                    if (symmetric and l2 != NONE) relabel(&labels, l2, NONE);
                } else {
                    if (phase == 0) continue;
                    const c: usize = mv - 225;
                    var th: usize = MAX_THERMO;
                    for (0..thermo_n) |k| {
                        for (thermo_cells[k][0..thermo_len[k]]) |tc| {
                            if (tc == c) th = k;
                        }
                    }
                    if (th == MAX_THERMO or th < locked_thermos) continue;
                    if (rndBelow(100) >= removal_pct) continue;
                    thermo_n -= 1;
                    thermo_cells[th] = thermo_cells[thermo_n];
                    thermo_len[th] = thermo_len[thermo_n];
                }
                if (!too_big and rebuild(&labels, 9) and isUnique(cap)) {
                    last_guesses = nodes;
                    progress = true;
                    if (mv < 144) failed = @splat(false);
                } else {
                    failed[mv] = true;
                    labels = saved;
                    thermo_cells = saved_cells;
                    thermo_len = saved_len;
                    thermo_n = saved_n;
                }
            }
        }
        if (!progress) break;
    }
    _ = rebuild(&labels, 9);
    grade();
    return 1;
}

export fn userCagePtr() [*]u8 {
    return &user_cage;
}
export fn userSumPtr() [*]u16 {
    return &user_sum;
}
export fn userThermoPtr() [*]u8 {
    return @ptrCast(&user_thermo_cells);
}
export fn userThermoLenPtr() [*]u8 {
    return &user_thermo_len;
}
export fn setUserThermoCount(n: u32) void {
    user_thermo_n = @min(n, MAX_THERMO);
}
export fn thermoCount() u32 {
    return @intCast(thermo_n);
}
export fn thermoPtr() [*]u8 {
    return @ptrCast(&thermo_cells);
}
export fn thermoLenPtr() [*]u8 {
    return &thermo_len;
}
export fn ruleSteps() u32 {
    return rule_steps;
}
export fn basicSolved() u32 {
    return basic_solved;
}
export fn gradeDone() u32 {
    return @intFromBool(grade_done);
}

export fn solutionPtr() [*]u8 {
    return &solution;
}
export fn cagePtr() [*]u8 {
    return &cage_of;
}
export fn sumPtr() [*]u16 {
    return &cage_sum;
}
export fn cageCount() u32 {
    return @intCast(cage_n);
}
export fn guesses() u32 {
    return last_guesses;
}
export fn inputPtr() [*]u8 {
    return &user_in;
}
export fn candPtr() [*]u16 {
    return &cand_out;
}

/// Candidates given the digits in the input buffer.
/// level 0: one sweep of direct eliminations (what a careful solver pencils in).
/// level 1: full propagation to a fixpoint, including hidden singles and the 45 rule.
/// Returns 0 when the entries contradict the constraints.
export fn candidates(level: u32) u32 {
    var s: State = undefined;
    for (0..81) |c| {
        const d = user_in[c];
        s[c] = if (d >= 1 and d <= 9) @as(u16, 1) << @intCast(d - 1) else given_mask[c];
    }
    var ok = true;
    if (level == 0) {
        var changed = false;
        for (&HOUSES) |*h| ok = ok and propGroup(&s, h[0..9], false, &changed);
        for (0..thermo_n) |k| ok = ok and propThermo(&s, thermo_cells[k][0..thermo_len[k]], &changed);
        for (0..cage_n) |k| {
            const cells = cage_cells[k][0..cage_len[k]];
            ok = ok and propGroup(&s, cells, false, &changed) and propSum(&s, cells, cage_sum[k], &changed);
        }
    } else {
        ok = propagate(&s);
    }
    cand_out = s;
    return @intFromBool(ok);
}
