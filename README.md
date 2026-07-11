# snix-eval-bench

Benchmarks comparing **[CppNix](https://github.com/NixOS/nix)**, canon
**[snix](https://snix.dev)**, and the `vm-force-fastpath` optimization branch of
snix. All evaluators must produce byte-identical drv paths before timing.

```bash
nix run             # env bench: force .drvPath of env.nix (~40 packages)
nix run .#nixos     # NixOS system eval through the module system
nix run .#realise   # eval AND realise a closure via a castore store
```

`RUNS=n` / `WARMUP=n` override the hyperfine defaults.

## Results

i9-11900H (idle), 2026-07-10:

**Env bench:**

```
cppnix        827.3 ms ± 26.4 ms
snix-canon     2.796 s ± 0.036 s   (3.38× cppnix)
snix-opt       2.231 s ± 0.036 s   (2.70× cppnix, −20.2% vs canon)
```

**NixOS system eval:**

```
cppnix         2.805 s ± 0.032 s
snix-canon    20.237 s ± 0.058 s   (7.21× cppnix)
snix-opt      15.235 s ± 0.206 s   (5.43× cppnix, −24.7% vs canon)
```

The gap is ~2× larger on the module-system workload: heavy attrset traffic,
option-merge equality, functional combinators.

## The snix-opt branch

Commits in order (links resolve once the branch is pushed):

- [`fde08b8e`](https://github.com/codedownio/snix/commit/fde08b8eb9b1542ca2a674dbaae30e86ae82a190)
  aterm escaping: scalar scan instead of aho-corasick's 64 KiB-buffer stream API.
- [`325ec2b6`](https://github.com/codedownio/snix/commit/325ec2b6aea9f72bc863b90030a971a385334e98)
  forced thunks resolve inline; builtin generators run inline until first suspension (−4.3%).
- [`31e7351d`](https://github.com/codedownio/snix/commit/31e7351d3c881b743903239d282bc254da246087)
  `Op::Force` enters suspended thunks' bytecode directly, no generator (−4.4%).
- [`d6da0278`](https://github.com/codedownio/snix/commit/d6da0278f92b71797b9505b2d8b894dde354d9ba)
  same direct entry for builtin-requested forces (−0.7%).
- [`f5a47141`](https://github.com/codedownio/snix/commit/f5a47141337f8f68377982eaa75e5c1695f72ca7)
  sync builtin calling convention + 18 pure accessors (noise; foundation).
- [`21264ee5`](https://github.com/codedownio/snix/commit/21264ee53e4776064c0c5abe6e1e4601ddc68d26)
  fixed 4-byte bytecode operands, vu128 dropped (−1.6%).
- [`2415dda6`](https://github.com/codedownio/snix/commit/2415dda69369d6e067d701bde7dad462daceda8f)
  scalar fast paths for `==`/`+`/comparisons; inline-run remaining generator sites (noise).
- [`c5dd7411`](https://github.com/codedownio/snix/commit/c5dd7411f00851c538d3176509b40d0facc7d05f)
  amortized-O(1) span lookups via per-frame cursor (noise).
- [`a62ff608`](https://github.com/codedownio/snix/commit/a62ff608cc2407b161072ea19e0937edb5b35dee)
  scalar `NixEquality` requests answered inline (−1.8% NixOS).
- [`d43da5b4`](https://github.com/codedownio/snix/commit/d43da5b43be1b9c9169fb33395b36dee76b0254e)
  non-scalar `NixEquality` children run nested, skipping outer-loop round trips (−1.5% NixOS).
- [`926c82c7`](https://github.com/codedownio/snix/commit/926c82c79f8cc6d68159de89b1c8693600f41ac0)
  sync `nix_eq` with generator escape hatch: forced-operand comparisons need no
  coroutine at all (**−13.8% NixOS**, −1.2% env).

## The realise benchmark

The eval benches only instantiate; a deployment that also *realises* the
closure against a castore store pays much more, and that's where the time
goes. `.#realise` uses local castore backends (far side = cache.nixos.org) to
isolate snix's realise cost, and prints a phase breakdown. Past finding: ~1500 redundant `pathinfo_get`s + ~2600
dir reads per small env, fixed by a PathInfo memo (snix `build-glue`) and an
in-process `memory` directory near-cache (composition) — `pathinfo_get`
1462 → 9, `descend` 0.9 s → 0.1 s. What remains is network fetch + ingest.

## Methodology notes

- Same pinned nixpkgs for all evaluators; `config`/`overlays` pinned empty.
- snix runs with in-memory stores and a dummy build service; `drvPath` only
  instantiates.
- CppNix writes `.drv` files on the first run; the warmup absorbs that. If
  anything the gap is a lower bound.
- `--no-warnings` suppresses thousands of snix not-yet-implemented warnings,
  which would otherwise cost seconds.
