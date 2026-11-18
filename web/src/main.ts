import "./style.css";
import { SOLVER_WASM_BASE64 } from "./generated/solver-wasm.ts";
import { cellAt, draw, type CageView, type CellView, type ThermoView } from "./board.ts";
import { decode, encodeClues, encodeSeed, type Shared } from "./share.ts";
import { clueCount, emptyClues, Rule, Solver, Status, type Analysis, type Clues, type Puzzle, type Settings } from "./solver.ts";

type Mode = "design" | "play";
type Tool = "cage" | "thermo" | "digit" | "erase";
type Goal = "balanced" | "sparse" | "deep";

interface Suggestion {
  /** A completed puzzle built around the current clues. */
  puzzle: Puzzle | null;
  /** Given digits it adds, by cell. */
  added: Map<number, number>;
  tries: number;
  done: boolean;
  impossible: boolean;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => document.getElementById(id) as T;
const input = (id: string): HTMLInputElement => $<HTMLInputElement>(id);
const board = document.getElementById("board") as unknown as SVGSVGElement;
const statusEl = $("status");

let solver: Solver;
let mode: Mode = "play";

// ---- design state: the setter's own clues
let tool: Tool = "cage";
let clues: Clues = emptyClues();
let digitsShown = true;
let selCage = -1;
let stroke: number[] | null = null;
let analysis: Analysis | null = null;
let suggestion: Suggestion | null = null;
let editVersion = 0;

// ---- play state: a finished puzzle
let puzzle: Puzzle | null = null;
/** Set when the puzzle came from a seed alone, which makes its share code tiny. */
let puzzleSource: { seed: number; settings: Settings } | null = null;
/** Which clues of the puzzle were hand-set, for colouring. */
let hand = { cages: new Set<string>(), bulbs: new Set<number>(), digits: new Set<number>() };
let entries = new Array<number>(81).fill(0);
let sel = 40;
let marks: "off" | "basic" | "full" = "off";
let check = false;
let reveal = false;

// ---- search state
let searching = false;
let runId = 0;
let stopFlag = false;
let tried = 0;
let genMs = 0;
let bestSeed = 0;
let lastHash = "";

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const randomSeed = (): number => 1 + Math.floor(Math.random() * 999_999_999);
const key = (cells: number[]): string => cells.slice().sort((a, b) => a - b).join(",");
const plural = (n: number, one: string, many = one + "s"): string => `${n} ${n === 1 ? one : many}`;
const popcount = (m: number): number => m.toString(2).replaceAll("0", "").length;

// ------------------------------------------------------------------ controls

function settings(): Settings {
  return {
    symmetric: input("sym").checked,
    noGuessing: input("logic").checked,
    maxCage: +input("maxsize").value,
    mergePct: +input("merges").value,
    thermos: +input("thermos").value,
    removePct: +input("removals").value,
    fill: +$<HTMLSelectElement>("fill").value as 0 | 1 | 2,
  };
}

function applySettings(s: Settings): void {
  input("sym").checked = s.symmetric;
  input("logic").checked = s.noGuessing;
  input("maxsize").value = String(s.maxCage);
  input("merges").value = String(s.mergePct);
  input("thermos").value = String(s.thermos);
  input("removals").value = String(s.removePct);
  $<HTMLSelectElement>("fill").value = String(s.fill);
  syncOutputs();
}

function syncOutputs(): void {
  for (const id of ["maxsize", "merges", "thermos", "removals", "budget"]) {
    const unit = id === "budget" ? " s" : id === "merges" || id === "removals" ? " %" : "";
    $<HTMLOutputElement>(id + "Out").value = input(id).value + unit;
  }
}

const rules = (): number => (input("ruleDiagonals").checked ? Rule.Diagonals : 0) | (input("ruleKnight").checked ? Rule.AntiKnight : 0);

function applyRules(mask: number): void {
  input("ruleDiagonals").checked = (mask & Rule.Diagonals) !== 0;
  input("ruleKnight").checked = (mask & Rule.AntiKnight) !== 0;
  solver.setRules(mask);
}

const toggle = (b: Element, on: boolean): void => b.setAttribute("aria-pressed", String(on));

// ------------------------------------------------------------------ play mode

/** Higher is better. Given digits cost the most: they hand the solver an answer. */
function score(p: Puzzle, goal: Goal): number {
  const caged = p.cages.reduce((n, g) => n + g.cells.length, 0);
  const givens = p.digits.filter(Boolean).length;
  const depth = Math.min(p.ruleSteps, 25);
  const guessing = p.guesses ? 5 + Math.log2(1 + p.guesses) : 0;
  if (goal === "sparse") return -caged - 2 * p.cages.length - 6 * givens - guessing;
  if (goal === "deep") return 2 * depth - 3 * givens - 0.2 * caged - guessing;
  return depth - 0.5 * caged - p.cages.length - 5 * givens - guessing;
}

function setPuzzle(p: Puzzle, source: typeof puzzleSource, from: Clues | null): void {
  puzzle = p;
  puzzleSource = source;
  hand = {
    cages: new Set(from?.cages.map((g) => key(g.cells))),
    bulbs: new Set(from?.thermos.map((t) => t[0]!)),
    digits: new Set(from?.digits.flatMap((d, c) => (d ? [c] : []))),
  };
  entries = new Array<number>(81).fill(0);
}

/** Build layouts from consecutive seeds until the time budget runs out, keeping the best. */
async function search(single: boolean): Promise<void> {
  const id = ++runId;
  const seed0 = Math.max(1, Math.min(4294967295, Math.floor(+input("seed").value) || 1));
  const s = settings();
  const around = clueCount(clues) > 0 ? structuredClone(clues) : null;
  const shown = digitsShown;
  const goal = $<HTMLSelectElement>("goal").value as Goal;
  const budget = single ? 0 : +input("budget").value * 1000;
  const t0 = performance.now();
  let best: { puzzle: Puzzle; seed: number; score: number } | null = null;
  let impossible = false;
  searching = true;
  stopFlag = false;
  tried = 0;
  $("new").textContent = "Stop";
  statusEl.textContent = "Searching…";
  await sleep(10);
  for (let seed = seed0; id === runId; seed = (seed % 4294967295) + 1) {
    const p = solver.generate(seed, s, around, shown);
    tried++;
    if (p === "impossible") {
      impossible = true;
      break;
    }
    if (p) {
      const sc = score(p, goal);
      if (!best || sc > best.score) {
        best = { puzzle: p, seed, score: sc };
        setPuzzle(p, around ? null : { seed, settings: s }, around);
      }
    }
    genMs = performance.now() - t0;
    if (best) render();
    else statusEl.textContent = `Searching, ${tried} layouts tried`;
    if (stopFlag || genMs >= budget) break;
    await sleep(0);
  }
  if (id !== runId) return;
  searching = false;
  $("new").textContent = "New puzzle";
  if (!best) {
    puzzle = null;
    render();
    statusEl.innerHTML = impossible
      ? `<span class="pill bad">No grid fits your clues. Check the sums and that thermometers have room to rise.</span>`
      : `<span class="pill bad">No unique puzzle found${s.fill === 2 ? " without adding clues. Let the computer add cages or given digits, or draw more" : ". Try more search time, or allow guessing"}.</span>`;
    return;
  }
  bestSeed = best.seed;
  input("seed").value = String(best.seed);
  render();
}

function generate(): Promise<void> {
  if (mode !== "play") setMode("play", false);
  return search(false);
}

function renderPlay(): void {
  if (!puzzle) {
    draw(board, [], [], blankCells(), input("ruleDiagonals").checked);
    return;
  }
  const p = puzzle;
  const cageOf = new Array<number>(81).fill(-1);
  p.cages.forEach((g, i) => g.cells.forEach((c) => (cageOf[c] = i)));
  const sr = Math.floor(sel / 9), sc = sel % 9;
  const level = marks === "full" ? 1 : 0;
  const cand = marks === "off" ? null : solver.candidates(p, entries, level);
  const consistent = solver.candidates(p, entries, 1).ok;

  const cells: CellView[] = [];
  for (let c = 0; c < 81; c++) {
    const r = Math.floor(c / 9), q = c % 9;
    const peer = r === sr || q === sc || (Math.floor(r / 3) === Math.floor(sr / 3) && Math.floor(q / 3) === Math.floor(sc / 3)) || (cageOf[c] !== -1 && cageOf[c] === cageOf[sel]);
    const given = p.digits[c]!;
    const entry = entries[c]!;
    cells.push({
      background: c === sel ? "selected" : peer ? "peer" : "",
      digit: given || entry || (reveal ? p.solution[c]! : 0),
      digitStyle: given ? (hand.digits.has(c) ? "hand" : "given") : entry ? (check && entry !== p.solution[c] ? "wrong" : "entry") : "revealed",
      marks: cand ? cand.masks[c]! : 0,
    });
  }
  const cages: CageView[] = p.cages.map((g) => ({ cells: g.cells, label: String(g.sum), hand: hand.cages.has(key(g.cells)), spare: false }));
  const thermos: ThermoView[] = p.thermos.map((t) => ({ cells: t, hand: hand.bulbs.has(t[0]!), spare: false }));
  draw(board, cages, thermos, cells, input("ruleDiagonals").checked);

  const givens = p.digits.filter(Boolean).length;
  const filled = entries.filter(Boolean).length;
  const solved = p.solution.every((v, c) => (p.digits[c] || entries[c]) === v);
  const caged = p.cages.reduce((n, g) => n + g.cells.length, 0);
  const pills: string[] = [];
  if (searching) pills.push(`<span class="pill">Searching, ${tried} layouts tried</span>`);
  const parts = [p.cages.length ? `${plural(p.cages.length, "cage")} over ${caged} cells` : "", p.thermos.length ? plural(p.thermos.length, "thermometer") : "", givens ? plural(givens, "given digit") : ""].filter(Boolean);
  pills.push(`<span class="pill">${parts.join(", ") || "No clues"}</span>`);
  if (hand.cages.size + hand.bulbs.size + hand.digits.size) pills.push(`<span class="pill">Built around your clues</span>`);
  pills.push(
    p.guesses === 0
      ? `<span class="pill good">Pure logic, ${p.ruleSteps ? `45 rule used ${plural(p.ruleSteps, "time")}` : "singles and sums only"}</span>`
      : `<span class="pill">Solver branched ${plural(p.guesses, "time")}</span>`,
  );
  if (solved) pills.push(`<span class="pill good">Solved</span>`);
  else if (!consistent) pills.push(`<span class="pill bad">Entries contradict the clues</span>`);
  else if (filled) pills.push(`<span class="pill">${filled} of ${81 - givens} filled</span>`);
  if (!searching && tried) pills.push(`<span>best of ${tried} in ${(genMs / 1000).toFixed(1)} s, seed ${bestSeed}</span>`);
  statusEl.innerHTML = pills.join("");
}

// ------------------------------------------------------------------ design mode

const blankCells = (): CellView[] => Array.from({ length: 81 }, () => ({ background: "", digit: 0, digitStyle: "given", marks: 0 }) as CellView);
const orth = (a: number, b: number): boolean => Math.abs(a - b) === 9 || (Math.abs(a - b) === 1 && Math.floor(a / 9) === Math.floor(b / 9));
const king = (a: number, b: number): boolean => a !== b && Math.abs((a % 9) - (b % 9)) <= 1 && Math.abs(Math.floor(a / 9) - Math.floor(b / 9)) <= 1;
const sumRange = (n: number): [number, number] => [(n * (n + 1)) / 2, (n * (19 - n)) / 2];

function connected(cells: number[]): boolean {
  const seen = new Set([cells[0]!]);
  const todo = [cells[0]!];
  while (todo.length) {
    const c = todo.pop()!;
    for (const d of cells) {
      if (!seen.has(d) && orth(c, d)) {
        seen.add(d);
        todo.push(d);
      }
    }
  }
  return seen.size === cells.length;
}

const open = (a: Analysis | null): boolean => a !== null && (a.status === Status.Multiple || a.status === Status.AtLeastOne || a.status === Status.Unknown);

/** Call after every change to the clues: re-analyse and restart the background search. */
function edited(): void {
  editVersion++;
  if (selCage >= clues.cages.length) selCage = -1;
  solver.setRules(rules());
  analysis = clueCount(clues) > 0 ? solver.analyze(clues, digitsShown, 2000) : null;
  suggestion = null;
  if (open(analysis) && digitsShown) {
    suggestion = { puzzle: null, added: new Map(), tries: 0, done: false, impossible: false };
    void suggest(editVersion, suggestion);
  }
  syncDesignPanel();
  render();
}

/** While the setter thinks, look for the fewest extra given digits that pin the puzzle down. */
async function suggest(version: number, sg: Suggestion): Promise<void> {
  await sleep(200);
  const base = structuredClone(clues);
  const s: Settings = { ...settings(), symmetric: false, fill: 1, thermos: 0, mergePct: 0, removePct: 100 };
  const singles = new Set(base.cages.filter((g) => g.cells.length === 1).map((g) => g.cells[0]!));
  let seed = randomSeed();
  for (let i = 0; i < 400; i++) {
    if (version !== editVersion || mode !== "design" || searching) return;
    const p = solver.generate(seed++, s, base, true);
    sg.tries = i + 1;
    if (p === "impossible") {
      sg.impossible = true;
      break;
    }
    let improved = false;
    if (p) {
      const added = new Map<number, number>();
      p.digits.forEach((d, c) => {
        if (d && !base.digits[c] && !singles.has(c)) added.set(c, d);
      });
      if (!sg.puzzle || added.size < sg.added.size) {
        sg.puzzle = p;
        sg.added = added;
        improved = true;
      }
    }
    if (improved || i % 10 === 9) {
      syncDesignPanel();
      render();
    }
    await sleep(0);
  }
  sg.done = true;
  if (version === editVersion && mode === "design") {
    syncDesignPanel();
    render();
  }
}

function renderDesign(): void {
  const a = analysis;
  const show = input("deductions").checked && a !== null && a.status !== Status.None;
  const selCells = new Set(selCage >= 0 ? clues.cages[selCage]?.cells : []);
  const cells: CellView[] = [];
  for (let c = 0; c < 81; c++) {
    const own = clues.digits[c]!;
    const cand = show ? a!.candidates[c]! : 0;
    const forced = cand && (cand & (cand - 1)) === 0 ? 32 - Math.clz32(cand) : 0;
    const ghost = suggestion?.added.get(c) ?? 0;
    cells.push({
      background: stroke?.includes(c) ? "stroke" : selCells.has(c) || (tool === "digit" && c === sel) ? "selected" : "",
      digit: own || forced || ghost,
      digitStyle: own ? (a?.redundantDigits[c] ? "spare" : "hand") : forced ? "forced" : "ghost",
      marks: !own && !forced && !ghost && cand && popcount(cand) <= 3 ? cand : 0,
    });
  }
  const cages: CageView[] = clues.cages.map((g, i) => ({
    cells: g.cells,
    label: g.sum ? String(g.sum) : "?",
    hand: true,
    spare: a?.redundantCages[i] ?? false,
  }));
  const thermos: ThermoView[] = clues.thermos.map((t, i) => ({ cells: t, hand: true, spare: a?.redundantThermos[i] ?? false }));
  if (stroke && tool === "thermo") thermos.push({ cells: stroke, hand: true, spare: false });
  draw(board, cages, thermos, cells, input("ruleDiagonals").checked);

  const n = clues.digits.filter(Boolean).length;
  statusEl.innerHTML = clueCount(clues)
    ? `<span class="pill">${plural(clues.cages.length, "cage")}, ${plural(clues.thermos.length, "thermometer")}, ${plural(n, "digit")}</span>`
    : `<span>Nothing drawn yet.</span>`;
}

function liveHtml(): string {
  const a = analysis;
  if (!a) return `<p>Draw a cage, a thermometer or a digit. This box then says whether a solution exists and how much is still open.</p>`;
  const out: string[] = [];
  const forced = a.candidates.filter((m) => m && (m & (m - 1)) === 0).length;
  if (a.status === Status.None) {
    out.push(`<span class="pill bad">No solution</span>`, `<p>These clues contradict each other. Remove or change the last one.</p>`);
    return out.join("");
  }
  if (a.status === Status.Unique) {
    out.push(`<span class="pill good">Exactly one solution</span>`);
    out.push(a.guesses === 0 ? `<p><strong>Solvable without guessing.</strong> The 45 rule is needed ${plural(a.ruleSteps, "time")}.</p>` : `<p><strong>Needs guessing.</strong> The solver branched ${plural(a.guesses, "time")}.</p>`);
    const spare = a.redundantCages.filter(Boolean).length + a.redundantThermos.filter(Boolean).length + a.redundantDigits.filter(Boolean).length;
    out.push(spare ? `<p><strong>${plural(spare, "clue is", "clues are")} spare</strong>, drawn faint: each could go on its own and the solution stays unique.</p>` : `<p><strong>Every clue is needed.</strong> Remove any one and the solution is no longer unique.</p>`);
    if (!digitsShown && a.solution) {
      const off = clues.digits.filter((d, c) => d && d !== a.solution![c]).length;
      if (off) out.push(`<p>The solution disagrees with ${plural(off, "hidden digit")} of yours.</p>`);
    }
    return out.join("");
  }
  out.push(a.status === Status.Multiple ? `<span class="pill">More than one solution</span>` : `<span class="pill">Too open to count</span>`);
  out.push(`<p><strong>${forced} of 81 cells</strong> are already forced by logic.</p>`);
  const sg = suggestion;
  if (!digitsShown) out.push(`<p>Hidden digits are not counted as clues here.</p>`);
  else if (sg?.impossible) out.push(`<p>No full grid fits these clues.</p>`);
  else if (sg?.puzzle) out.push(`<p><strong>${plural(sg.added.size, "more given digit")}</strong> would pin it down, shown in green. ${sg.done ? "Best" : "Best so far"} of ${plural(sg.tries, "layout")} tried.</p>`);
  else if (sg) out.push(`<p>${sg.done ? `No completion found in ${plural(sg.tries, "layout")}.` : "Looking for the fewest extra given digits…"}</p>`);
  return out.join("");
}

function syncDesignPanel(): void {
  $("designPanel").hidden = mode !== "design";
  $("solvePanel").hidden = mode !== "play";
  board.classList.toggle("design", mode === "design");
  for (const b of $("mode").children) toggle(b, (b as HTMLElement).dataset.v === mode);
  for (const b of $("tool").children) toggle(b, (b as HTMLElement).dataset.t === tool);
  $("toolHint").textContent =
    tool === "cage" ? "Drag across neighbouring cells to draw a cage of up to nine cells. Tap a cage to select it and give it a sum."
    : tool === "thermo" ? "Drag from the bulb along the path, diagonals allowed. Digits rise along it."
    : tool === "digit" ? "Tap a cell, then type or tap the digit you want there."
    : "Tap a cell to remove the cage, thermometer and digit on it.";
  const g = clues.cages[selCage];
  input("cageSum").disabled = !g;
  if (document.activeElement !== input("cageSum")) input("cageSum").value = g?.sum ? String(g.sum) : "";
  $("live").innerHTML = liveHtml();
  const unique = analysis?.status === Status.Unique;
  const spare = unique && (analysis!.redundantCages.some(Boolean) || analysis!.redundantThermos.some(Boolean) || analysis!.redundantDigits.some(Boolean));
  $<HTMLButtonElement>("playThis").disabled = !unique;
  $<HTMLButtonElement>("strip").disabled = !spare;
  $<HTMLButtonElement>("accept").disabled = !suggestion?.puzzle;
  $<HTMLButtonElement>("build").disabled = analysis?.status === Status.None;
  $<HTMLButtonElement>("clearClues").disabled = clueCount(clues) === 0;
  updateShare();
}

function finishStroke(): void {
  if (!stroke) return;
  const cells = stroke;
  stroke = null;
  if (tool === "cage") {
    const hit = clues.cages.findIndex((g) => g.cells.includes(cells[0]!));
    if (cells.length === 1 && hit >= 0) {
      selCage = hit;
      syncDesignPanel();
      render();
      return;
    }
    clues.cages = clues.cages
      .map((g) => {
        const rest = g.cells.filter((c) => !cells.includes(c));
        return rest.length === g.cells.length ? g : { cells: rest, sum: 0 };
      })
      .filter((g) => g.cells.length > 0 && connected(g.cells));
    clues.cages.push({ cells: cells.slice().sort((a, b) => a - b), sum: 0 });
    selCage = clues.cages.length - 1;
  } else if (tool === "thermo" && cells.length >= 2) {
    clues.thermos = clues.thermos.filter((t) => !t.some((c) => cells.includes(c)));
    if (clues.thermos.length < 12) clues.thermos.push(cells);
  }
  edited();
}

/** Drop spare clues one at a time until every remaining clue is needed. */
function stripSpare(): void {
  for (let i = 0; i < 200; i++) {
    const a = solver.analyze(clues, digitsShown, 2000);
    if (a.status !== Status.Unique) break;
    const options: (() => void)[] = [];
    a.redundantDigits.forEach((r, c) => r && options.push(() => (clues.digits[c] = 0)));
    a.redundantCages.forEach((r, k) => r && options.push(() => clues.cages.splice(k, 1)));
    a.redundantThermos.forEach((r, k) => r && options.push(() => clues.thermos.splice(k, 1)));
    if (!options.length) break;
    options[Math.floor(Math.random() * options.length)]!();
  }
  selCage = -1;
  edited();
}

function playThis(): void {
  const a = analysis;
  if (a?.status !== Status.Unique || !a.solution) return;
  const sol = a.solution;
  const p: Puzzle = {
    cages: clues.cages.map((g) => ({ cells: g.cells, sum: g.sum || g.cells.reduce((n, c) => n + sol[c]!, 0) })),
    thermos: clues.thermos.map((t) => t.slice()),
    digits: digitsShown ? clues.digits.slice() : new Array<number>(81).fill(0),
    solution: sol,
    guesses: a.guesses,
    ruleSteps: a.ruleSteps,
  };
  setPuzzle(p, null, clues);
  tried = 0;
  setMode("play", false);
}

function acceptSuggestion(): void {
  const sg = suggestion;
  if (!sg?.puzzle) return;
  const sol = sg.puzzle.solution;
  for (const g of clues.cages) if (!g.sum) g.sum = g.cells.reduce((n, c) => n + sol[c]!, 0);
  for (const [c, d] of sg.added) clues.digits[c] = d;
  edited();
}

// ------------------------------------------------------------------ shared

function render(): void {
  if (mode === "design") renderDesign();
  else renderPlay();
  updateShare();
}

function setMode(m: Mode, fill = true): void {
  mode = m;
  stroke = null;
  if (m === "design") edited();
  else {
    editVersion++; // stops the background suggestion search
    syncDesignPanel();
    if (!puzzle && fill) void search(false);
    else render();
  }
}

function put(v: number): void {
  if (mode === "play") {
    if (!puzzle || puzzle.digits[sel]) return;
    entries[sel] = v;
    render();
  } else if (tool === "digit") {
    clues.digits[sel] = v;
    edited();
  }
}

function currentCode(): string {
  const r = rules();
  if (mode === "design") return clueCount(clues) ? encodeClues(clues, false, digitsShown, r) : "";
  if (!puzzle) return "";
  return puzzleSource ? encodeSeed(puzzleSource.seed, puzzleSource.settings, r) : encodeClues(puzzle, true, true, r);
}

const standalone = ((): boolean => {
  try {
    return window.top === window;
  } catch {
    return false;
  }
})();

const shareText = (code: string): string => (code && standalone ? `${location.href.split("#")[0]}#${code}` : code);

function updateShare(): void {
  if (document.activeElement !== input("code")) input("code").value = shareText(currentCode());
}

function openShared(sh: Shared): void {
  applyRules(sh.rules);
  if (sh.kind === "seed") {
    applySettings(sh.settings);
    clues = emptyClues();
    input("seed").value = String(sh.seed);
    mode = "play";
    syncDesignPanel();
    void search(true);
    return;
  }
  const a = solver.analyze(sh.clues, sh.digitsShown, 20000);
  if (sh.play && a.status === Status.Unique && a.solution) {
    clues = emptyClues();
    runId++;
    searching = false;
    tried = 0;
    setPuzzle({ ...sh.clues, solution: a.solution, guesses: a.guesses, ruleSteps: a.ruleSteps }, null, null);
    setMode("play", false);
    return;
  }
  clues = sh.clues;
  digitsShown = sh.digitsShown;
  input("digitsShown").checked = digitsShown;
  setMode("design");
}

function wire(): void {
  for (let v = 1; v <= 10; v++) {
    const b = document.createElement("button");
    b.textContent = v === 10 ? "⌫" : String(v);
    b.setAttribute("aria-label", v === 10 ? "Erase" : "Digit " + v);
    b.addEventListener("click", () => put(v === 10 ? 0 : v));
    $("pad").append(b);
  }

  board.addEventListener("pointerdown", (e) => {
    const c = cellAt(board, e, false);
    if (c < 0) return;
    board.focus();
    sel = c;
    if (mode === "play" || tool === "digit") {
      render();
      return;
    }
    e.preventDefault();
    if (tool === "erase") {
      clues.cages = clues.cages.filter((g) => !g.cells.includes(c));
      clues.thermos = clues.thermos.filter((t) => !t.includes(c));
      clues.digits[c] = 0;
      selCage = -1;
      edited();
      return;
    }
    try {
      board.setPointerCapture(e.pointerId);
    } catch {
      // capture is a convenience; dragging still works inside the board
    }
    stroke = [c];
    render();
  });
  board.addEventListener("pointermove", (e) => {
    if (!stroke || stroke.length >= 9) return;
    const c = cellAt(board, e, true);
    if (c < 0 || stroke.includes(c)) return;
    if (tool === "cage" ? !stroke.some((d) => orth(c, d)) : !king(c, stroke[stroke.length - 1]!)) return;
    stroke.push(c);
    render();
  });
  board.addEventListener("pointerup", finishStroke);
  board.addEventListener("pointercancel", () => {
    stroke = null;
    render();
  });

  document.addEventListener("keydown", (e) => {
    const t = e.target as HTMLElement;
    if (t.matches("input, button, select") || e.metaKey || e.ctrlKey || e.altKey) return;
    const move = ({ ArrowUp: -9, ArrowDown: 9, ArrowLeft: -1, ArrowRight: 1 } as Record<string, number>)[e.key];
    if (move) {
      const n = sel + move;
      if (n >= 0 && n < 81 && (Math.abs(move) === 9 || Math.floor(n / 9) === Math.floor(sel / 9))) sel = n;
      e.preventDefault();
      render();
    } else if (/^[1-9]$/.test(e.key)) put(+e.key);
    else if (e.key === "Backspace" || e.key === "Delete" || e.key === "0") put(0);
  });

  $("mode").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest("button");
    if (b) setMode(b.dataset.v as Mode);
  });
  $("tool").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest("button");
    if (!b) return;
    tool = b.dataset.t as Tool;
    syncDesignPanel();
    render();
  });
  input("cageSum").addEventListener("input", () => {
    const g = clues.cages[selCage];
    if (!g) return;
    const v = Math.floor(+input("cageSum").value) || 0;
    const [lo, hi] = sumRange(g.cells.length);
    g.sum = v >= lo && v <= hi ? v : 0;
    edited();
    if (v && !g.sum) statusEl.innerHTML = `<span class="pill bad">A cage of ${plural(g.cells.length, "cell")} sums to between ${lo} and ${hi}</span>`;
  });
  input("digitsShown").addEventListener("change", () => {
    digitsShown = input("digitsShown").checked;
    edited();
  });
  input("deductions").addEventListener("change", render);
  $("playThis").addEventListener("click", playThis);
  $("strip").addEventListener("click", stripSpare);
  $("accept").addEventListener("click", acceptSuggestion);
  $("build").addEventListener("click", () => {
    input("seed").value = String(randomSeed());
    void generate();
  });
  $("clearClues").addEventListener("click", () => {
    clues = emptyClues();
    selCage = -1;
    edited();
  });

  for (const id of ["ruleDiagonals", "ruleKnight"]) {
    input(id).addEventListener("change", () => {
      solver.setRules(rules());
      if (mode === "design") edited();
      else void generate();
    });
  }

  $("new").addEventListener("click", () => {
    if (searching) {
      stopFlag = true;
      return;
    }
    input("seed").value = String(randomSeed());
    void generate();
  });
  $("regen").addEventListener("click", () => {
    if (mode !== "play") setMode("play", false);
    void search(true);
  });
  for (const id of ["maxsize", "merges", "thermos", "removals", "budget"]) input(id).addEventListener("input", syncOutputs);
  for (const id of ["sym", "logic", "maxsize", "merges", "thermos", "removals", "goal", "fill"]) {
    $(id).addEventListener("change", () => {
      if (mode === "design") edited();
      else void generate();
    });
  }
  input("seed").addEventListener("change", () => void search(true));

  $("marks").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest("button");
    if (!b) return;
    marks = b.dataset.m as typeof marks;
    for (const x of $("marks").children) toggle(x, x === b);
    render();
  });
  $("check").addEventListener("click", (e) => {
    check = !check;
    toggle(e.currentTarget as Element, check);
    render();
  });
  $("reveal").addEventListener("click", (e) => {
    reveal = !reveal;
    toggle(e.currentTarget as Element, reveal);
    render();
  });
  $("clear").addEventListener("click", () => {
    entries.fill(0);
    render();
  });

  $("copy").addEventListener("click", async () => {
    const code = currentCode();
    if (!code) return;
    lastHash = "#" + code;
    try {
      location.hash = code;
    } catch {
      // some frames do not allow changing the fragment; the code still copies
    }
    try {
      await navigator.clipboard.writeText(shareText(code));
      $("copy").textContent = "Copied";
    } catch {
      input("code").select();
      $("copy").textContent = "Select and copy the code above";
    }
    setTimeout(() => ($("copy").textContent = "Copy link"), 2000);
  });
  input("code").addEventListener("change", () => {
    const sh = decode(input("code").value);
    if (sh) openShared(sh);
    else statusEl.innerHTML = `<span class="pill bad">That is not a puzzle code</span>`;
  });
  window.addEventListener("hashchange", () => {
    if (location.hash === lastHash) return;
    lastHash = location.hash;
    const sh = decode(location.hash);
    if (sh) openShared(sh);
  });
}

async function start(): Promise<void> {
  try {
    const bytes = Uint8Array.from(atob(SOLVER_WASM_BASE64), (ch) => ch.charCodeAt(0));
    solver = await Solver.load(bytes);
  } catch (err) {
    statusEl.innerHTML = `<span class="pill bad">The WebAssembly solver could not start in this browser: ${String(err instanceof Error ? err.message : err)}</span>`;
    return;
  }
  wire();
  syncOutputs();
  const sh = location.hash.length > 1 ? decode(location.hash) : null;
  lastHash = location.hash;
  if (sh) {
    openShared(sh);
    return;
  }
  input("seed").value = String(randomSeed());
  syncDesignPanel();
  void search(false);
}

void start();
