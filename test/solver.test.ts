import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { decode, encodeClues, encodeSeed } from "../web/src/share.ts";
import { emptyClues, Rule, Solver, Status, type Clues, type Puzzle, type Settings } from "../web/src/solver.ts";

const solver = await Solver.load(readFileSync("build/solver.wasm"));

const base: Settings = { symmetric: true, noGuessing: true, maxCage: 4, mergePct: 100, thermos: 6, removePct: 100, fill: 0 };
const rows = Array.from({ length: 9 }, (_, i) => Array.from({ length: 9 }, (_, j) => i * 9 + j));
const cols = Array.from({ length: 9 }, (_, i) => Array.from({ length: 9 }, (_, j) => j * 9 + i));
const boxes = Array.from({ length: 9 }, (_, i) => Array.from({ length: 9 }, (_, j) => (Math.floor(i / 3) * 3 + Math.floor(j / 3)) * 9 + (i % 3) * 3 + (j % 3)));
const orth = (a: number, b: number): boolean => Math.abs(a - b) === 9 || (Math.abs(a - b) === 1 && Math.floor(a / 9) === Math.floor(b / 9));

/** Every structural promise a generated puzzle makes. */
function checkPuzzle(p: Puzzle): void {
  for (const house of [...rows, ...cols, ...boxes]) assert.equal(new Set(house.map((c) => p.solution[c])).size, 9, "house holds 1 to 9");
  const seen = new Set<number>();
  for (const g of p.cages) {
    assert.ok(g.cells.length >= 2 && g.cells.length <= 9);
    assert.equal(g.cells.reduce((n, c) => n + p.solution[c]!, 0), g.sum, "cage sum");
    assert.equal(new Set(g.cells.map((c) => p.solution[c])).size, g.cells.length, "no repeat in cage");
    for (const c of g.cells) {
      assert.ok(!seen.has(c), "cages do not overlap");
      seen.add(c);
    }
    const reach = new Set([g.cells[0]!]);
    const todo = [g.cells[0]!];
    while (todo.length) {
      const c = todo.pop()!;
      for (const d of g.cells) if (!reach.has(d) && orth(c, d)) (reach.add(d), todo.push(d));
    }
    assert.equal(reach.size, g.cells.length, "cage is connected");
  }
  for (const t of p.thermos) for (let i = 1; i < t.length; i++) assert.ok(p.solution[t[i]!]! > p.solution[t[i - 1]!]!, "thermometer rises");
  p.digits.forEach((d, c) => d && assert.equal(d, p.solution[c], "given matches solution"));
}

const generated = (seed: number, s: Settings, around: Clues | null = null): Puzzle => {
  const p = solver.generate(seed, s, around);
  assert.ok(p && p !== "impossible", `seed ${seed} gave a puzzle`);
  return p;
};

test("generated puzzles are valid, unique and need no guessing", () => {
  solver.setRules(0);
  for (let seed = 1; seed <= 25; seed++) {
    const p = generated(seed * 7919, base);
    checkPuzzle(p);
    assert.equal(p.guesses, 0);
    // An independent pass through the analyser must agree and find the same grid.
    const a = solver.analyze(p);
    assert.equal(a.status, Status.Unique);
    assert.deepEqual(a.solution, p.solution);
    assert.ok(solver.candidates(p, p.solution, 1).ok, "solution is accepted");
    const wrong = p.solution.slice();
    wrong[0] = (wrong[0]! % 9) + 1;
    assert.ok(!solver.candidates(p, wrong, 1).ok, "a wrong digit is rejected");
  }
});

test("the same seed and settings always give the same puzzle", () => {
  solver.setRules(0);
  const a = generated(424242, base);
  generated(99, { ...base, fill: 1 });
  assert.deepEqual(generated(424242, base), a);
});

test("every fill mode works, including puzzles with no cages", () => {
  solver.setRules(0);
  for (let seed = 1; seed <= 10; seed++) {
    const givensOnly = generated(seed * 31, { ...base, fill: 1 });
    checkPuzzle(givensOnly);
    assert.equal(givensOnly.cages.length, 0);
    assert.ok(givensOnly.digits.some(Boolean));
    checkPuzzle(generated(seed * 31, { ...base, noGuessing: false }));
  }
});

test("hand-set clues are kept exactly and built around", () => {
  solver.setRules(0);
  const mine = emptyClues();
  mine.cages.push({ cells: [0, 1, 2], sum: 6 }, { cells: [40, 41, 50], sum: 0 }, { cells: [5, 6, 7, 8, 17, 26, 35, 44], sum: 0 });
  mine.thermos.push([10, 20, 30, 31]);
  mine.digits[80] = 9;
  for (let seed = 1; seed <= 10; seed++) {
    const p = generated(seed * 1337, { ...base, thermos: 3 }, mine);
    checkPuzzle(p);
    const cageKeys = new Set(p.cages.map((g) => g.cells.join()));
    for (const g of mine.cages) assert.ok(cageKeys.has(g.cells.join()), "hand cage survives unchanged");
    assert.equal(p.cages.find((g) => g.cells.join() === "0,1,2")!.sum, 6);
    assert.deepEqual(p.thermos[0], [10, 20, 30, 31]);
    assert.equal(p.solution[80], 9);
    assert.equal(p.digits[80], 9);
    assert.equal(solver.analyze(p).status, Status.Unique);
  }
  const hidden = solver.generate(5, base, mine, false);
  assert.ok(hidden && hidden !== "impossible");
  assert.equal(hidden.solution[80], 9, "a hidden digit still steers the grid");
  assert.equal(hidden.digits[80], 0, "but is not handed to the solver");
});

test("contradictory clues are reported", () => {
  solver.setRules(0);
  const bad = emptyClues();
  bad.cages.push({ cells: [0, 1, 2], sum: 5 });
  assert.equal(solver.generate(1, base, bad), "impossible");
  assert.equal(solver.analyze(bad).status, Status.None);
  const clash = emptyClues();
  clash.digits[0] = 5;
  clash.digits[1] = 5;
  assert.equal(solver.analyze(clash).status, Status.None);
});

test("analysis tells open, unique and spare apart", () => {
  solver.setRules(0);
  const open = emptyClues();
  open.thermos.push([0, 1, 2, 3, 4, 5, 6, 7, 8]);
  const a = solver.analyze(open);
  assert.equal(a.status, Status.Multiple);
  assert.deepEqual(a.candidates.slice(0, 9), [1, 2, 4, 8, 16, 32, 64, 128, 256], "a full-row thermometer forces 1 to 9");

  const p = generated(2024, { ...base, fill: 1, thermos: 0 });
  const tight = solver.analyze(p);
  assert.equal(tight.status, Status.Unique);
  assert.ok(tight.redundantDigits.every((r) => !r), "a reduced puzzle has no spare given");

  const padded: Clues = { ...p, digits: p.digits.slice() };
  const extra = padded.digits.findIndex((d) => d === 0);
  padded.digits[extra] = p.solution[extra]!;
  const loose = solver.analyze(padded);
  assert.equal(loose.status, Status.Unique);
  assert.ok(loose.redundantDigits[extra], "the added given is reported as spare");
});

test("extra rules shape the solution", () => {
  const knight = [-19, -17, -11, -7, 7, 11, 17, 19];
  solver.setRules(Rule.Diagonals | Rule.AntiKnight);
  for (let seed = 1; seed <= 5; seed++) {
    const p = generated(seed * 11, { ...base, thermos: 0 });
    checkPuzzle(p);
    assert.equal(new Set(rows.map((_, i) => p.solution[i * 10])).size, 9, "main diagonal");
    assert.equal(new Set(rows.map((_, i) => p.solution[i * 8 + 8])).size, 9, "anti-diagonal");
    for (let c = 0; c < 81; c++) {
      for (const k of knight) {
        const d = c + k;
        if (d < 0 || d > 80 || Math.abs((d % 9) - (c % 9)) > 2) continue;
        assert.notEqual(p.solution[c], p.solution[d], "knight's move apart");
      }
    }
    assert.equal(solver.analyze(p).status, Status.Unique);
  }
  solver.setRules(0);
});

test("share codes round-trip and seed codes stay short", () => {
  const code = encodeSeed(4294967295, base, 3);
  assert.ok(code.length <= 12, `seed code is ${code.length} characters`);
  assert.match(code, /^[0-9A-Za-z]+$/);
  assert.deepEqual(decode(code), { kind: "seed", rules: 3, seed: 4294967295, settings: base });
  assert.deepEqual(decode("https://example.org/forge/#" + code), decode(code));

  solver.setRules(0);
  const p = generated(77, base);
  const clues: Clues = { cages: p.cages, thermos: p.thermos, digits: p.digits };
  const packed = encodeClues(clues, true, true, 0);
  assert.match(packed, /^[0-9A-Za-z]+$/);
  assert.deepEqual(decode(packed), { kind: "clues", rules: 0, clues, play: true, digitsShown: true });
  assert.equal(decode("not a code!"), null);
  assert.equal(decode(""), null);
});
