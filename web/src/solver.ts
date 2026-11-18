// Typed wrapper around the Zig solver compiled to WebAssembly.
// No DOM access here, so the same module runs in the browser and under Node.

/** A killer cage. `sum` 0 means the sum is not decided yet. */
export interface Cage {
  cells: number[];
  sum: number;
}

/** Everything a solver is given: cages, thermometers (bulb first) and given digits. */
export interface Clues {
  cages: Cage[];
  thermos: number[][];
  /** 81 entries, 0 = no digit. */
  digits: number[];
}

export interface Puzzle extends Clues {
  solution: number[];
  /** Branch points the solver needed; 0 means propagation alone solves it. */
  guesses: number;
  /** 45-rule deductions the graded solve needed. */
  ruleSteps: number;
}

export interface Settings {
  symmetric: boolean;
  noGuessing: boolean;
  /** Largest cage the layout starts from, 3 to 6. */
  maxCage: number;
  /** Share of merge moves the reducer tries, 0 to 100. */
  mergePct: number;
  /** Thermometers the generator lays down itself, 0 to 12. */
  thermos: number;
  /** Share of removal moves the reducer tries, 0 to 100. */
  removePct: number;
  /** What the generator may add to free cells: 0 cages, 1 given digits, 2 nothing. */
  fill: 0 | 1 | 2;
}

export const Status = { None: 0, Unique: 1, Multiple: 2, AtLeastOne: 3, Unknown: 4 } as const;
export type Status = (typeof Status)[keyof typeof Status];

export interface Analysis {
  status: Status;
  /** Candidate bitmask per cell after propagation (bit d-1 = digit d). */
  candidates: number[];
  /** Present when the solution is unique. */
  solution?: number[];
  guesses: number;
  ruleSteps: number;
  /** Per clue: the puzzle stays unique without it. */
  redundantCages: boolean[];
  redundantThermos: boolean[];
  redundantDigits: boolean[];
}

interface Exports {
  memory: WebAssembly.Memory;
  generate(seed: number, sym: number, maxSize: number, merges: number, logic: number, thermos: number, removals: number, fill: number, useUser: number, digitsShown: number): number;
  analyze(cap: number, digitsShown: number): number;
  loadClues(digitsShown: number): void;
  candidates(level: number): number;
  solutionPtr(): number;
  cagePtr(): number;
  sumPtr(): number;
  cageCount(): number;
  guesses(): number;
  ruleSteps(): number;
  thermoCount(): number;
  thermoPtr(): number;
  thermoLenPtr(): number;
  inputPtr(): number;
  candPtr(): number;
  userCagePtr(): number;
  userSumPtr(): number;
  userThermoPtr(): number;
  userThermoLenPtr(): number;
  userDigitPtr(): number;
  setUserThermoCount(n: number): void;
  setRules(mask: number): void;
  analysisCandPtr(): number;
  analysisSolutionPtr(): number;
  redundantCagePtr(): number;
  redundantThermoPtr(): number;
  redundantDigitPtr(): number;
}

/** Extra global rules, combined as a bit set. */
export const Rule = { Diagonals: 1, AntiKnight: 2 } as const;

export const emptyClues = (): Clues => ({ cages: [], thermos: [], digits: new Array<number>(81).fill(0) });
export const clueCount = (c: Clues): number => c.cages.length + c.thermos.length + c.digits.filter(Boolean).length;

export class Solver {
  private readonly x: Exports;

  private constructor(x: Exports) {
    this.x = x;
  }

  static async load(bytes: BufferSource): Promise<Solver> {
    const { instance } = await WebAssembly.instantiate(bytes);
    return new Solver(instance.exports as unknown as Exports);
  }

  /** Choose the extra global rules for every later call. */
  setRules(mask: number): void {
    this.x.setRules(mask);
  }

  private u8(ptr: number, n: number): Uint8Array {
    return new Uint8Array(this.x.memory.buffer, ptr, n);
  }

  private u16(ptr: number, n: number): Uint16Array {
    return new Uint16Array(this.x.memory.buffer, ptr, n);
  }

  private writeClues(clues: Clues): void {
    const cage = this.u8(this.x.userCagePtr(), 81);
    const sum = this.u16(this.x.userSumPtr(), 81);
    cage.fill(255);
    sum.fill(0);
    clues.cages.slice(0, 81).forEach((g, i) => {
      for (const c of g.cells) cage[c] = i;
      sum[i] = g.sum;
    });
    const cells = this.u8(this.x.userThermoPtr(), 16 * 9);
    const len = this.u8(this.x.userThermoLenPtr(), 16);
    const thermos = clues.thermos.slice(0, 16);
    thermos.forEach((t, i) => {
      cells.set(t.slice(0, 9), i * 9);
      len[i] = Math.min(t.length, 9);
    });
    this.x.setUserThermoCount(thermos.length);
    this.u8(this.x.userDigitPtr(), 81).set(clues.digits);
  }

  /**
   * Build one puzzle from a seed. With `around`, the hand-set clues are kept
   * as they are and the generator only adds what uniqueness still needs.
   * Returns "impossible" when no solved grid fits the hand-set clues, and
   * null when this seed produced no unique puzzle.
   */
  generate(seed: number, s: Settings, around: Clues | null, digitsShown = true): Puzzle | "impossible" | null {
    this.writeClues(around ?? emptyClues());
    const code = this.x.generate(seed >>> 0, +s.symmetric, s.maxCage, s.mergePct, +s.noGuessing, s.thermos, s.removePct, s.fill, around ? 1 : 0, +digitsShown);
    if (code === 2) return "impossible";
    if (code !== 1) return null;

    const solution = Array.from(this.u8(this.x.solutionPtr(), 81));
    const cageOf = this.u8(this.x.cagePtr(), 81);
    const sums = this.u16(this.x.sumPtr(), 81);
    const byId = new Map<number, number[]>();
    cageOf.forEach((k, c) => {
      if (k !== 255) byId.set(k, [...(byId.get(k) ?? []), c]);
    });
    // The setter's shown digits are givens. A single-cell cage is one as well.
    const digits = around && digitsShown ? around.digits.slice() : new Array<number>(81).fill(0);
    const cages: Cage[] = [];
    for (const [k, cells] of byId) {
      if (cells.length === 1) digits[cells[0]!] = solution[cells[0]!]!;
      else cages.push({ cells, sum: sums[k]! });
    }
    const tc = this.u8(this.x.thermoPtr(), 16 * 9);
    const tl = this.u8(this.x.thermoLenPtr(), 16);
    const thermos: number[][] = [];
    for (let t = 0; t < this.x.thermoCount(); t++) thermos.push(Array.from(tc.subarray(t * 9, t * 9 + tl[t]!)));
    return { cages, thermos, digits, solution, guesses: this.x.guesses(), ruleSteps: this.x.ruleSteps() };
  }

  /** Judge a clue set on its own: is it solvable, is the solution unique, what is forced. */
  analyze(clues: Clues, digitsShown = true, cap = 20000): Analysis {
    this.writeClues(clues);
    const status = this.x.analyze(cap, +digitsShown) as Status;
    const unique = status === Status.Unique;
    const redCage = this.u8(this.x.redundantCagePtr(), 81);
    const redThermo = this.u8(this.x.redundantThermoPtr(), 16);
    const redDigit = this.u8(this.x.redundantDigitPtr(), 81);
    return {
      status,
      candidates: Array.from(this.u16(this.x.analysisCandPtr(), 81)),
      solution: unique ? Array.from(this.u8(this.x.analysisSolutionPtr(), 81)) : undefined,
      guesses: unique ? this.x.guesses() : 0,
      ruleSteps: unique ? this.x.ruleSteps() : 0,
      redundantCages: clues.cages.map((_, i) => redCage[i] === 1),
      redundantThermos: clues.thermos.map((_, i) => redThermo[i] === 1),
      redundantDigits: clues.digits.map((d, c) => d !== 0 && redDigit[c] === 1),
    };
  }

  /**
   * Candidates for a puzzle given the solver's entries so far.
   * level 0 is one sweep of direct eliminations, level 1 full propagation.
   */
  candidates(puzzle: Clues, entries: number[], level: 0 | 1): { ok: boolean; masks: number[] } {
    this.writeClues(puzzle);
    this.x.loadClues(1);
    this.u8(this.x.inputPtr(), 81).set(entries);
    const ok = this.x.candidates(level) === 1;
    return { ok, masks: Array.from(this.u16(this.x.candPtr(), 81)) };
  }
}
