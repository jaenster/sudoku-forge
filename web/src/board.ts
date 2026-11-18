// SVG drawing of the board. Pure view code: it draws what it is handed.

const NS = "http://www.w3.org/2000/svg";

export interface CageView {
  cells: number[];
  label: string;
  /** Drawn by the setter, as opposed to added by the generator. */
  hand: boolean;
  /** Could be removed without losing uniqueness. */
  spare: boolean;
}

export interface ThermoView {
  cells: number[];
  hand: boolean;
  spare: boolean;
}

export interface CellView {
  background: "" | "selected" | "peer" | "stroke";
  digit: number;
  digitStyle: "given" | "hand" | "entry" | "wrong" | "revealed" | "forced" | "ghost" | "spare";
  /** Candidate bitmask to show as pencil marks, 0 for none. */
  marks: number;
}

function el(name: string, attrs: Record<string, string | number>, text?: string | number): SVGElement {
  const e = document.createElementNS(NS, name);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  if (text !== undefined) e.textContent = String(text);
  return e;
}

const x0 = (c: number): number => (c % 9) * 100;
const y0 = (c: number): number => Math.floor(c / 9) * 100;

/** Dashed outline of cages, inset from the cell edges so neighbours never touch. */
function cagePath(map: number[], include: (cage: number) => boolean): string {
  const same = (c: number, dr: number, dc: number): boolean => {
    const r = Math.floor(c / 9) + dr;
    const q = (c % 9) + dc;
    return r >= 0 && r < 9 && q >= 0 && q < 9 && map[r * 9 + q] === map[c];
  };
  const I = 7;
  let d = "";
  for (let c = 0; c < 81; c++) {
    if (map[c] === -1 || !include(map[c]!)) continue;
    const xl = x0(c), yt = y0(c), xr = xl + 100, yb = yt + 100;
    const U = same(c, -1, 0), D = same(c, 1, 0), L = same(c, 0, -1), R = same(c, 0, 1);
    const xa = L ? xl : xl + I, xb = R ? xr : xr - I, ya = U ? yt : yt + I, yc = D ? yb : yb - I;
    if (!U) d += `M${xa} ${yt + I}H${xb}`;
    if (!D) d += `M${xa} ${yb - I}H${xb}`;
    if (!L) d += `M${xl + I} ${ya}V${yc}`;
    if (!R) d += `M${xr - I} ${ya}V${yc}`;
    // inner corners: both sides continue but the diagonal cell belongs elsewhere
    if (U && L && !same(c, -1, -1)) d += `M${xl} ${yt + I}H${xl + I}V${yt}`;
    if (U && R && !same(c, -1, 1)) d += `M${xr} ${yt + I}H${xr - I}V${yt}`;
    if (D && L && !same(c, 1, -1)) d += `M${xl} ${yb - I}H${xl + I}V${yb}`;
    if (D && R && !same(c, 1, 1)) d += `M${xr} ${yb - I}H${xr - I}V${yb}`;
  }
  return d;
}

export function draw(svg: SVGSVGElement, cages: CageView[], thermos: ThermoView[], cells: CellView[], diagonals = false): void {
  svg.replaceChildren();

  cells.forEach((cell, c) => {
    svg.append(el("rect", { x: x0(c), y: y0(c), width: 100, height: 100, class: `cellbg ${cell.background}` }));
  });

  for (let i = 1; i < 9; i++) {
    if (i % 3 === 0) continue;
    svg.append(el("line", { x1: i * 100, y1: 0, x2: i * 100, y2: 900, class: "thin" }));
    svg.append(el("line", { x1: 0, y1: i * 100, x2: 900, y2: i * 100, class: "thin" }));
  }

  if (diagonals) {
    svg.append(el("line", { x1: 0, y1: 0, x2: 900, y2: 900, class: "diagonal" }));
    svg.append(el("line", { x1: 900, y1: 0, x2: 0, y2: 900, class: "diagonal" }));
  }

  for (const t of thermos) {
    const cls = (t.hand ? " hand" : "") + (t.spare ? " spare" : "");
    const pt = (c: number): string => `${x0(c) + 50} ${y0(c) + 50}`;
    svg.append(el("circle", { cx: x0(t.cells[0]!) + 50, cy: y0(t.cells[0]!) + 50, r: 33, class: "bulb" + cls }));
    if (t.cells.length > 1) svg.append(el("path", { d: "M" + t.cells.map(pt).join("L"), class: "thermo" + cls }));
  }

  const map = new Array<number>(81).fill(-1);
  cages.forEach((g, i) => g.cells.forEach((c) => (map[c] = i)));
  for (const [hand, spare] of [[false, false], [true, false], [false, true], [true, true]] as const) {
    const d = cagePath(map, (i) => cages[i]!.hand === hand && cages[i]!.spare === spare);
    if (d) svg.append(el("path", { d, class: "cage" + (hand ? " hand" : "") + (spare ? " spare" : "") }));
  }

  let boxes = "M0 0H900V900H0Z";
  for (const v of [300, 600]) boxes += `M${v} 0V900M0 ${v}H900`;
  svg.append(el("path", { d: boxes, class: "thick" }));

  for (const g of cages) {
    const c = Math.min(...g.cells);
    svg.append(el("text", { x: x0(c) + 13, y: y0(c) + 28, class: "sum" + (g.hand ? " hand" : "") + (g.spare ? " spare" : "") }, g.label));
  }

  cells.forEach((cell, c) => {
    if (cell.digit) {
      svg.append(el("text", { x: x0(c) + 50, y: y0(c) + 72, class: `digit ${cell.digitStyle}` }, cell.digit));
    } else if (cell.marks) {
      const only = (cell.marks & (cell.marks - 1)) === 0;
      for (let k = 0; k < 9; k++) {
        if (!((cell.marks >> k) & 1)) continue;
        svg.append(el("text", { x: x0(c) + 28 + (k % 3) * 22, y: y0(c) + 52 + Math.floor(k / 3) * 18, class: "mark" + (only ? " only" : "") }, k + 1));
      }
    }
  });
}

/** Board cell under a pointer event, or -1. With `strict` only the middle of a cell counts. */
export function cellAt(svg: SVGSVGElement, e: PointerEvent, strict: boolean): number {
  const r = svg.getBoundingClientRect();
  const x = ((e.clientX - r.left) / r.width) * 912 - 6;
  const y = ((e.clientY - r.top) / r.height) * 912 - 6;
  if (x < 0 || y < 0 || x >= 900 || y >= 900) return -1;
  if (strict && (x % 100 < 20 || x % 100 > 80 || y % 100 < 20 || y % 100 > 80)) return -1;
  return Math.floor(y / 100) * 9 + Math.floor(x / 100);
}
