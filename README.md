# snix-eval-bench

A benchmark comparing eval of **[CppNix](https://github.com/NixOS/nix)** and
**[snix](https://snix.dev)**. All you have to do to run it is this:

```bash
nix run
```

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
