# Sudoku Forge

A workbench for setting sudoku variants. You draw clues, and a constraint
solver tells you live whether a solution exists, whether it is the only one,
which clues are spare, and how little it would take to pin the puzzle down.
It also generates complete puzzles on its own.

The solver is written in Zig, compiled to WebAssembly, and driven by a
TypeScript web UI. The build is one self-contained `index.html`.

## What it does

- **Design mode.** Draw killer cages, thermometers and digits. After every
  edit the page reports: no solution, exactly one, or more than one; how many
  cells logic already forces; whether the puzzle solves without guessing; and
  which clues could each be removed without losing uniqueness. While the
  puzzle is still open, a background search looks for the fewest extra given
  digits that would make it unique and shows them on the board.
- **Generator.** Builds a solved grid, lays out clues, then reduces: it keeps
  merging cages and deleting cages, thermometers and givens for as long as the
  solution stays unique. It can build around your hand-set clues, which it
  never changes, and it can add cages, only given digits, or nothing.
- **Play mode.** Solve the result with pencil marks, mistake marking and the
  solution on request.
- **Share codes.** A generated puzzle is its seed plus settings, about eleven
  characters. Hand-set clues are bit-packed into a longer code. Either goes in
  the URL fragment.

## Clue and rule types

| Type | Status |
|---|---|
| Rows, columns, boxes | built in |
| Killer cages (sum, no repeats); a cage without a sum only forbids repeats | supported |
| Thermometers | supported |
| Given digits | supported |
| Both diagonals hold 1 to 9 | supported |
| Anti-knight | supported |
| Arrows, kropki dots, XV, German whispers, renban, palindromes, even/odd cells, inequality signs, little killer and other outside clues, anti-king, non-consecutive | not yet |
| Set equivalence (for example the Phistomefel ring) as a deduction | not yet; the solver only uses the sum form, the 45 rule |
| Irregular regions, other grid sizes | not yet |

## How the solver works

Each cell holds a 9-bit candidate mask. Every constraint is a propagator in
one table, and propagation runs as a worklist: only constraints watching a
cell that just changed run again.

- **All different** on houses and cages, with hidden singles on houses.
- **Cage sums** against a compile-time table of digit combinations.
- **Thermometers** by bounds along the chain.
- **The 45 rule.** For bands of rows or columns and for boxes, the cells that
  stick in or out of the band have a forced sum, derived from the cage sums.

Uniqueness is a search for a second solution. The generator remembers every
alternative grid it finds and rejects later candidates that admit one without
searching again. With "solvable without guessing" on, a layout is rejected at
its first branch.

Grading replays the solve the way a person would: cheap techniques until
stuck, then one 45-rule deduction at a time. That count is the "45 rule used N
times" figure.

## Limits worth knowing

- "Without guessing" means solvable by the propagators above. It is narrower
  than everything a human solver might use, and says nothing about elegance.
- The search for the fewest extra givens is a best-of-N search, not a proof of
  the minimum.
- "Spare" is judged one clue at a time. Two spare clues cannot always both go.
- Analysis gives up counting after a node budget and then reports "too open
  to count".
- A seed code depends on the generator. `GENERATOR_VERSION` in
  `web/src/share.ts` must be bumped whenever a change makes old seeds produce
  different puzzles; old seed links then stop opening.

## Layout

```
core/solver.zig       the solver, generator and analyser (no std, freestanding)
web/src/solver.ts     typed wrapper around the wasm module, no DOM
web/src/share.ts      share codes
web/src/board.ts      SVG drawing
web/src/main.ts       UI state and wiring
test/solver.test.ts   tests, run against the real wasm
scripts/build-wasm.ts compiles the core and embeds it for the web build
```

## Develop

Needs Zig 0.17 and Node 22.18 or newer (tests and scripts run TypeScript
directly).

```sh
npm install
npm run dev     # build the wasm, then serve with Vite
npm test        # build the wasm, then run the tests
npm run build   # type-check and write dist/index.html
```

Set `ZIG=/path/to/zig` if `zig` is not on your `PATH`.

A native front end (Qt or otherwise) can link `core/solver.zig` directly: it
exposes a plain C ABI and keeps no browser assumptions.
