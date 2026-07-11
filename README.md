# snix-eval-bench

A benchmark comparing eval of **[CppNix](https://github.com/NixOS/nix)**, canon
**[snix](https://snix.dev)**, and the local snix evaluator-optimization branch
(`vm-force-fastpath` — force fast paths, direct thunk entry, sync builtins,
fixed-width operands). All evaluators are checked to produce byte-identical drv
paths before timing. All you have to do to run it is this:

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

Three-way, on an i9-11900H (idle), 2026-07-10. All three evaluators produce
byte-identical drv paths on both workloads.

**Env bench** (`nix run`):

```
cppnix        802.9 ms ±  8.1 ms
snix-canon     2.756 s ± 0.012 s   (3.43× cppnix)
snix-opt       2.182 s ± 0.038 s   (2.72× cppnix, −20.8% vs canon)
```

**NixOS system eval** (`nix run .#nixos`):

```
cppnix         2.798 s ± 0.068 s
snix-canon    20.193 s ± 0.075 s   (7.22× cppnix)
snix-opt      17.782 s ± 0.396 s   (6.35× cppnix, −11.9% vs canon)
```

snix's gap vs CppNix is roughly twice as large on the module-system workload —
that's where the remaining generator/allocator/equality machinery costs live.

### The snix-opt branch

`snix-opt` is the `vm-force-fastpath` branch of the codedown snix fork. Its
commits, in order (links resolve once the branch is pushed):

- [`fde08b8e`](https://github.com/codedownio/snix/commit/fde08b8eb9b1542ca2a674dbaae30e86ae82a190)
  aterm escaping: scalar scan instead of aho-corasick's stream API, which zero-allocated a 64 KiB buffer per call (~300k calls/eval).
- [`325ec2b6`](https://github.com/codedownio/snix/commit/325ec2b6aea9f72bc863b90030a971a385334e98)
  force fast paths: already-forced thunks are resolved inline (no "force" generator), and builtin generators run inline until first suspension (−4.3%).
- [`31e7351d`](https://github.com/codedownio/snix/commit/31e7351d3c881b743903239d282bc254da246087)
  `Op::Force` enters a suspended thunk's bytecode directly — blackhole, run the lambda as a plain frame, memoize on return — instead of spawning a generator (−4.4%).
- [`d6da0278`](https://github.com/codedownio/snix/commit/d6da0278f92b71797b9505b2d8b894dde354d9ba)
  the same direct bytecode entry for builtin-requested forces (`ForceValue` requests) (−0.7%).
- [`f5a47141`](https://github.com/codedownio/snix/commit/f5a47141337f8f68377982eaa75e5c1695f72ca7)
  synchronous builtin calling convention (VM pre-forces strict args, no coroutine at all) + 18 pure accessors converted (noise on these benches; foundation for more).
- [`21264ee5`](https://github.com/codedownio/snix/commit/21264ee53e4776064c0c5abe6e1e4601ddc68d26)
  fixed 4-byte LE bytecode operands replacing vu128 varints — one unaligned load per operand in the interpreter loop (−1.6%).
- [`2415dda6`](https://github.com/codedownio/snix/commit/2415dda69369d6e067d701bde7dad462daceda8f)
  scalar fast paths for `==`/`+`/comparisons and inline-run of the remaining bytecode generator sites (noise here; helps arithmetic-heavy code).
- [`c5dd7411`](https://github.com/codedownio/snix/commit/c5dd7411f00851c538d3176509b40d0facc7d05f)
  amortized-O(1) span lookups via a per-frame cursor instead of a binary search per query (noise; algorithmic cleanup).
- [`a62ff608`](https://github.com/codedownio/snix/commit/a62ff608cc2407b161072ea19e0937edb5b35dee)
  scalar `NixEquality` requests answered inline in `run_generator` — builtin-driven equality (option merging, `lib.elem`) skips the nix_eq generator (−1.8% on the NixOS bench).

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
