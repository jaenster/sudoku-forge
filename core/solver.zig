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
fn setGivens(active: bool) void {
    for (0..81) |c| {
        const d = user_digit[c];
        given_mask[c] = if (active and d >= 1 and d <= 9) @as(u16, 1) << @intCast(d - 1) else ALL;
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
const K_APART = 6; // first cell differs from every other cell listed (anti-knight)

// Extra global rules, as a bit set chosen by the setter.
const RULE_DIAGONALS = 1; // both long diagonals hold 1 to 9
const RULE_ANTI_KNIGHT = 2; // cells a chess knight's move apart differ
var rules: u32 = 0;

fn isDerived(kind: u8) bool {
    return kind == K_SUM_DISTINCT or kind == K_SUM_FREE;
}
const Con = struct { kind: u8, len: u8, sum: u16, cells: [9]u8 };
const MAX_CON = 27 + 2 + 81 + 81 + MAX_THERMO + MAX_DERIVED;
const MAX_WATCH = 112;
var cons: [MAX_CON]Con = undefined;
var con_n: usize = 0;
var watch: [81][MAX_WATCH]u16 = undefined; // constraints touching each cell
var watch_n: [81]u8 = @splat(0);
var queue: [512]u16 = undefined;
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
    for (0..thermo_n) |k| addCon(K_THERMO, thermo_cells[k][0..thermo_len[k]], 0);
    for (0..cage_n) |k| addCon(K_CAGE, cage_cells[k][0..cage_len[k]], cage_sum[k]);
    for (0..der_n) |k| {
        addCon(if (der_distinct[k]) K_SUM_DISTINCT else K_SUM_FREE, der_cells[k][0..der_len[k]], der_sum[k]);
    }
}

/// Constraints for inventing a solved grid: the sudoku rules plus, when asked,
/// the hand-set cage shapes, sums and thermometers.
fn buildGridCons(use_user: bool) void {
    buildCons(false);
    if (!use_user) return;
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

fn search(s: *State, dirty: usize) void {
    if (found >= limit or nodes > node_cap) return;
    if (!(if (dirty == 81) propagate(s) else propagateCell(s, dirty))) return;
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
    setGivens(digits_shown != 0);
    red_digit = @splat(0);
    red_cage = @splat(0);
    red_thermo = @splat(0);
    rule_steps = 0;
    grade_done = false;
    loadUser(81, MAX_THERMO);
    var s: State = given_mask;
    if (!propagate(&s)) {
        an_cand = @splat(0);
        return 0;
    }
    an_cand = s;
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
    setGivens(digits_shown != 0);
    loadUser(81, MAX_THERMO);
}
/// Choose the extra global rules (bit 0 diagonals, bit 1 anti-knight).
export fn setRules(mask: u32) void {
    rules = mask;
}
export fn userDigitPtr() [*]u8 {
    return &user_digit;
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
            setGivens(around);
            runSearch(1, 200_000, true);
            setGivens(around and digits_shown != 0);
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
