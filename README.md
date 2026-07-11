# snix-eval-bench

A benchmark comparing eval of **[CppNix](https://github.com/NixOS/nix)** and
**[snix](https://snix.dev)**. All you have to do to run it is this:

```bash
nix run
```

There is also a **NixOS** benchmark, which evaluates a minimal-but-real NixOS system through
the module system to `.system.drvPath` — a very different profile from the env bench (heavy
attrset traffic, option-merge equality checks, functional combinators; snix's gap vs CppNix is
roughly twice as large here). Both evaluators are checked to produce the byte-identical system
drv before timing:

```bash
nix run .#nixos                   # RUNS=n / WARMUP=n env vars override the defaults
```

And a **realise** benchmark, which measures what nox's full-snix mode actually pays —
evaluate *and realise* a closure through a castore store composition, substituting from
cache.nixos.org — and dumps a phase-timing breakdown:

```bash
nix run .#realise                 # small 6-package env (env-realise.nix)
nix run .#realise -- ./env.nix    # the large 40-package env
```

### Why the realise benchmark exists

The eval benchmark forces `.drvPath` (instantiate only) against in-memory stores, so snix is only
~3.85× CppNix. But full-snix in nox forces `.outPath` (via `readDir`), which *realises* the closure
against a real castore store — and that's where the time actually goes. The realise benchmark uses
**local** castore backends (objectstore blobs + redb dir/pathinfo, far side = cache.nixos.org) to
isolate snix's own realise cost from nox's extra gRPC-to-nox-store layer.

### The diagnosis

The first run showed realising a *six-package* env did **~1500 `pathinfo_get` "is this path present?"
lookups + ~2600 directory reads** — and it scales with closure size. Locally (redb) those are cheap,
but in nox each one is a **gRPC round-trip to nox-store → Postgres/SeaweedFS**, so full-snix was
dominated by store round-trip latency, not by eval:

```
BEFORE:  pathinfo_get 1462 lookups   descend 0.9s   dir_get 0.03s   substitute (network)
```

### The fixes (landed in snix + nox)

Two changes collapse that overhead — the current default pin/composition here includes both:

1. **PathInfo memo** (snix `build-glue`): eval resolves the same store path (the nixpkgs source) over
   and over; memoizing the resolved `PathInfo` by digest turns those redundant lookups into cache hits.
2. **In-process `memory` directory near-cache** (composition): serves repeated directory reads from
   decoded in-RAM values instead of redb disk reads.

```
AFTER:   pathinfo_get 9 lookups      descend 0.1s   dir_get 0.002s   substitute (network) ← now the only real cost
```

`pathinfo_get` **1462 → 9** and `descend` **0.9s → 0.1s**. What's left is the actual work
(`substitute`: fetching NARs from cache.nixos.org + ingesting into castore), which is network- and
ingest-bound — the next lever is concurrency/prefetch of the substitution, not more read-caching.

## The workload

[`env.nix`](./env.nix) is a `symlinkJoin` over a few dozen common packages from a pinned
nixpkgs, including a `python3.withPackages` set. The benchmark forces its `.drvPath`, which
instantiates and hashes the full derivation graph (several thousand derivations).

## Results

On my AMD Ryzen 9 9950X:

```
Benchmark 1: cppnix
  Time (mean ± σ):      1.156 s ±  0.057 s    [User: 0.800 s, System: 0.164 s]
  Range (min … max):    1.093 s …  1.294 s    10 runs

Benchmark 2: snix
  Time (mean ± σ):      4.445 s ±  0.120 s    [User: 4.112 s, System: 0.306 s]
  Range (min … max):    4.226 s …  4.636 s    10 runs

Summary
  cppnix ran
    3.85 ± 0.22 times faster than snix
```

## Methodology notes

- Both evaluators read the same pinned nixpkgs from the store; `config` and
  `overlays` are pinned empty so the evaluation doesn't depend on user
  configuration.
- `snix-eval` runs with in-memory stores and a dummy build service (its
  defaults); forcing `drvPath` only instantiates, it never builds or
  substitutes.
- `nix-instantiate` *writes the `.drv` files to `/nix/store`* on the first run;
  the hyperfine warmup run absorbs that, and subsequent runs only re-derive and
  stat them. If anything this handicaps CppNix relative to snix (which keeps
  derivations in memory), so the measured gap is a lower bound.
- `--no-warnings` keeps snix from printing (many thousand) "feature not yet
  implemented" warnings for `builtins.addErrorContext` /
  `builtins.unsafeGetAttrPos` call sites; printing them costs several additional
  seconds.
