# snix-eval-bench

A benchmark comparing eval of **[CppNix](https://github.com/NixOS/nix)** and
**[snix](https://snix.dev)**. All you have to do to run it is this:

```bash
nix run
```

There is also a **realise** benchmark, which measures what nox's full-snix mode actually pays —
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

What it shows for a 6-package env (hello, coreutils, jq, ripgrep, tree, which):

```
COLD (fresh store):  wall 9.4s   pathinfo_get 1512 lookups   substitute 42 paths (14s, cache.nixos.org)
WARM (store reused): wall 3.4s   pathinfo_get 1512 lookups (0.2s local)   substitute 1
```

Realising a *six-package* env does **~1500 `pathinfo_get` "is this path present?" lookups + ~2600
castore reads**, and it scales with closure size. Locally (redb) those are cheap. But in nox each one
is a **gRPC round-trip to nox-store → Postgres/SeaweedFS**, so full-snix is dominated by store
round-trip latency, not by eval. The lever is batching/caching the pathinfo + directory queries and a
lower-latency castore backend — not "make eval faster".

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
