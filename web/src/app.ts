// Browser shell for the designer. All state, layout and drawing logic lives
// in the WebAssembly module (native/app.zig); this file is its canvas backend.
import { APP_WASM_BASE64 } from "./generated/app-wasm.ts";

interface App {
  memory: WebAssembly.Memory;
  ioPtr(): number;
  ioLen(): number;
  start(dark: number): void;
  frame(w: number, h: number): void;
  pointerDown(x: number, y: number): void;
  pointerMove(x: number, y: number): void;
  pointerUp(): void;
  key(code: number): void;
  tick(): number;
  pasteText(n: number): void;
  loadText(n: number): number;
}

const MIN_W = 760;
const MIN_H = 860;
const canvas = document.getElementById("app") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
let app: App;
let width = MIN_W;
let height = MIN_H;
let dirty = true;

const str = (ptr: number, n: number) => decoder.decode(new Uint8Array(app.memory.buffer, ptr, n));
const css = (c: number) => `rgba(${c >>> 24},${(c >>> 16) & 255},${(c >>> 8) & 255},${(c & 255) / 255})`;
const font = (size: number, bold: number) =>
  `${bold ? 600 : 400} ${size}px -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif`;

const env = {
  js_fill_rect(x: number, y: number, w: number, h: number, c: number) {
    ctx.fillStyle = css(c);
    ctx.fillRect(x, y, w, h);
  },
  js_stroke_rect(x: number, y: number, w: number, h: number, lw: number, c: number) {
    ctx.setLineDash([]);
    ctx.strokeStyle = css(c);
    ctx.lineWidth = lw;
    ctx.strokeRect(x, y, w, h);
  },
  js_line(x1: number, y1: number, x2: number, y2: number, lw: number, c: number, dashed: number) {
    ctx.setLineDash(dashed ? [4, 3] : []);
    ctx.lineCap = "butt";
    ctx.strokeStyle = css(c);
    ctx.lineWidth = lw;
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);
    ctx.stroke();
  },
  js_polyline(ptr: number, n: number, lw: number, c: number) {
    const p = new Float64Array(app.memory.buffer, ptr, n * 2);
    ctx.setLineDash([]);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.strokeStyle = css(c);
    ctx.lineWidth = lw;
    ctx.beginPath();
    ctx.moveTo(p[0] ?? 0, p[1] ?? 0);
    for (let i = 1; i < n; i++) ctx.lineTo(p[i * 2] ?? 0, p[i * 2 + 1] ?? 0);
    ctx.stroke();
  },
  js_circle(cx: number, cy: number, r: number, c: number) {
    ctx.fillStyle = css(c);
    ctx.beginPath();
    ctx.arc(cx, cy, Math.max(r, 0), 0, Math.PI * 2);
    ctx.fill();
  },
  js_text(x: number, y: number, size: number, bold: number, c: number, align: number, ptr: number, n: number) {
    ctx.font = font(size, bold);
    ctx.fillStyle = css(c);
    ctx.textBaseline = "middle";
    ctx.textAlign = align === 0 ? "left" : align === 1 ? "center" : "right";
    ctx.fillText(str(ptr, n), x, y);
  },
  js_text_width(size: number, bold: number, ptr: number, n: number) {
    ctx.font = font(size, bold);
    return ctx.measureText(str(ptr, n)).width;
  },
  js_copy(ptr: number, n: number) {
    const text = str(ptr, n);
    navigator.clipboard?.writeText(text).catch(() => window.prompt("Copy this:", text));
  },
  js_request_paste() {
    navigator.clipboard?.readText().then(pasteText).catch(() => {});
  },
};

/// Copy text into the module's buffer; returns how many bytes went in.
function give(text: string): number {
  const bytes = encoder.encode(text.trim());
  const n = Math.min(bytes.length, app.ioLen());
  new Uint8Array(app.memory.buffer, app.ioPtr(), n).set(bytes.subarray(0, n));
  return n;
}

function pasteText(text: string) {
  const n = give(text);
  if (n === 0) return;
  app.pasteText(n);
  dirty = true;
}

function resize() {
  width = Math.max(window.innerWidth, MIN_W);
  height = Math.max(window.innerHeight, MIN_H);
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(width * dpr);
  canvas.height = Math.round(height * dpr);
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;
  dirty = true;
}

function paint() {
  if (dirty) {
    dirty = false;
    const dpr = window.devicePixelRatio || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    app.frame(width, height);
  }
  requestAnimationFrame(paint);
}

const SPECIAL: Record<string, number> = {
  ArrowUp: 0xf700,
  ArrowDown: 0xf701,
  ArrowLeft: 0xf702,
  ArrowRight: 0xf703,
  Backspace: 0x7f,
  Delete: 0xf728,
  Tab: 9,
  Escape: 27,
};

function onKey(ev: KeyboardEvent) {
  const name = ev.key;
  let code = 0;
  if (ev.metaKey || ev.ctrlKey) {
    const k = name.toLowerCase();
    if (k === "z") code = ev.shiftKey ? 0xe001 : 0xe000;
    else if (k === "y") code = 0xe001;
    else if (k === "c") code = 0xe002;
    else return; // paste arrives as its own event, the rest is the browser's
  } else if (name in SPECIAL) code = SPECIAL[name] ?? 0;
  else if (name.length === 1) code = name.charCodeAt(0);
  else return;
  ev.preventDefault();
  app.key(code);
  dirty = true;
}

async function main() {
  const bytes = Uint8Array.from(atob(APP_WASM_BASE64), (ch) => ch.charCodeAt(0));
  const { instance } = await WebAssembly.instantiate(bytes, { env });
  app = instance.exports as unknown as App;
  const dark = window.matchMedia("(prefers-color-scheme: dark)");
  app.start(dark.matches ? 1 : 0);

  // A puzzle can ride along in the address: .../#SF1...
  const hash = decodeURIComponent(location.hash.slice(1));
  if (hash.startsWith("SF1")) app.loadText(give(hash));

  const at = (ev: PointerEvent): [number, number] => {
    const r = canvas.getBoundingClientRect();
    return [ev.clientX - r.left, ev.clientY - r.top];
  };
  canvas.addEventListener("pointerdown", (ev) => {
    canvas.focus();
    canvas.setPointerCapture(ev.pointerId);
    app.pointerDown(...at(ev));
    dirty = true;
  });
  canvas.addEventListener("pointermove", (ev) => {
    if (ev.buttons === 0 && ev.pointerType === "mouse") return;
    app.pointerMove(...at(ev));
    dirty = true;
  });
  const up = () => {
    app.pointerUp();
    dirty = true;
  };
  canvas.addEventListener("pointerup", up);
  canvas.addEventListener("pointercancel", up);
  window.addEventListener("keydown", onKey);
  window.addEventListener("paste", (ev) => {
    const text = ev.clipboardData?.getData("text") ?? "";
    if (text) {
      ev.preventDefault();
      pasteText(text);
    }
  });
  window.addEventListener("resize", resize);
  setInterval(() => {
    if (app.tick()) dirty = true;
  }, 20);
  resize();
  canvas.focus();
  requestAnimationFrame(paint);
}

main().catch((err) => {
  const p = document.createElement("p");
  p.id = "fail";
  p.textContent = `Sudoku Forge could not start: ${err}`;
  document.body.append(p);
});
