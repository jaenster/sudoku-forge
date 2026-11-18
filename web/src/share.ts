// Short share codes. A generated puzzle is fully determined by its seed and
// settings, so its code is about ten characters. Hand-set clues are bit-packed.
// Codes use only letters and digits so they survive as a URL fragment anywhere.

import type { Clues, Settings } from "./solver.ts";

/** Bump when the generator changes in a way that makes old seeds give different puzzles. */
export const GENERATOR_VERSION = 1;

export type Shared =
  | { kind: "seed"; rules: number; seed: number; settings: Settings }
  | { kind: "clues"; rules: number; clues: Clues; play: boolean; digitsShown: boolean };

const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

class BitWriter {
  private value = 1n; // leading 1 keeps leading zero bits
  put(v: number, bits: number): void {
    this.value = (this.value << BigInt(bits)) | BigInt(v & (2 ** bits - 1));
  }
  toString(): string {
    let v = this.value;
    let out = "";
    while (v > 0n) {
      out = ALPHABET[Number(v % 62n)] + out;
      v /= 62n;
    }
    return out;
  }
}

class BitReader {
  private readonly bits: string;
  private pos = 1; // skip the leading 1
  constructor(text: string) {
    let v = 0n;
    for (const ch of text) {
      const i = ALPHABET.indexOf(ch);
      if (i < 0) throw new Error("bad character");
      v = v * 62n + BigInt(i);
    }
    this.bits = v.toString(2);
  }
  get(bits: number): number {
    if (this.pos + bits > this.bits.length) throw new Error("code too short");
    const v = parseInt(this.bits.slice(this.pos, this.pos + bits), 2);
    this.pos += bits;
    return v;
  }
}

// King moves, used to store a thermometer as a bulb plus one direction per step.
const DIRS = [-10, -9, -8, -1, 1, 8, 9, 10];

export function encodeSeed(seed: number, s: Settings, rules: number): string {
  const w = new BitWriter();
  w.put(GENERATOR_VERSION, 4);
  w.put(rules, 4);
  w.put(seed >>> 16, 16);
  w.put(seed & 0xffff, 16);
  w.put(+s.symmetric, 1);
  w.put(+s.noGuessing, 1);
  w.put(s.maxCage - 3, 2);
  w.put(Math.round(s.mergePct / 10), 4);
  w.put(s.thermos, 4);
  w.put(Math.round(s.removePct / 10), 4);
  w.put(s.fill, 2);
  return "g" + w.toString();
}

export function encodeClues(clues: Clues, play: boolean, digitsShown: boolean, rules: number): string {
  const w = new BitWriter();
  w.put(rules, 4);
  w.put(+play, 1);
  w.put(+digitsShown, 1);
  w.put(clues.cages.length, 7);
  for (const g of clues.cages) {
    w.put(g.cells.length - 1, 4);
    w.put(g.sum, 6);
    for (const c of g.cells) w.put(c, 7);
  }
  w.put(clues.thermos.length, 5);
  for (const t of clues.thermos) {
    w.put(t.length - 2, 3);
    w.put(t[0]!, 7);
    for (let i = 1; i < t.length; i++) w.put(DIRS.indexOf(t[i]! - t[i - 1]!), 3);
  }
  const set = clues.digits.flatMap((d, c) => (d ? [[c, d] as const] : []));
  w.put(set.length, 7);
  for (const [c, d] of set) {
    w.put(c, 7);
    w.put(d - 1, 4);
  }
  return "c" + w.toString();
}

/** Decode a share code, or the fragment of a pasted link. Returns null when it is not one. */
export function decode(text: string): Shared | null {
  const code = text.trim().replace(/^.*#/, "");
  try {
    const r = new BitReader(code.slice(1));
    if (code[0] === "g") {
      if (r.get(4) !== GENERATOR_VERSION) return null;
      const rules = r.get(4);
      const seed = r.get(16) * 65536 + r.get(16);
      const settings: Settings = {
        symmetric: r.get(1) === 1,
        noGuessing: r.get(1) === 1,
        maxCage: r.get(2) + 3,
        mergePct: r.get(4) * 10,
        thermos: r.get(4),
        removePct: r.get(4) * 10,
        fill: Math.min(r.get(2), 2) as 0 | 1 | 2,
      };
      return { kind: "seed", rules, seed, settings };
    }
    if (code[0] === "c") {
      const rules = r.get(4);
      const play = r.get(1) === 1;
      const digitsShown = r.get(1) === 1;
      const clues: Clues = { cages: [], thermos: [], digits: new Array<number>(81).fill(0) };
      const cell = (): number => {
        const c = r.get(7);
        if (c > 80) throw new Error("bad cell");
        return c;
      };
      for (let n = r.get(7); n > 0; n--) {
        const size = r.get(4) + 1;
        const sum = r.get(6);
        const cells: number[] = [];
        for (let i = 0; i < size; i++) cells.push(cell());
        if (size > 9 || sum > 45) throw new Error("bad cage");
        clues.cages.push({ cells, sum });
      }
      for (let n = r.get(5); n > 0; n--) {
        const len = r.get(3) + 2;
        const t = [cell()];
        for (let i = 1; i < len; i++) {
          const next = t[i - 1]! + DIRS[r.get(3)]!;
          if (next < 0 || next > 80) throw new Error("bad thermometer");
          t.push(next);
        }
        clues.thermos.push(t);
      }
      for (let n = r.get(7); n > 0; n--) {
        const c = cell();
        const d = r.get(4) + 1;
        if (d > 9) throw new Error("bad digit");
        clues.digits[c] = d;
      }
      return { kind: "clues", rules, clues, play, digitsShown };
    }
  } catch {
    return null;
  }
  return null;
}
