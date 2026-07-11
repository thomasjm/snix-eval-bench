{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    crane.url = "github:ipetkov/crane/edb38893982a3338972bb4a2ec7ce7c29ba10fd9";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # codedown's snix fork: adds the full-snix realise path (store composition + build service) and
    # the `fullsnix-phase-stats` timing line the realise benchmark reads. Upstream canon can eval but
    # doesn't emit the phase breakdown.
    snix = {
      url = "github:codedownio/snix/main";
      flake = false;
    };
    # The local evaluator-optimization branch (force fast paths, direct thunk
    # entry, sync builtins, fixed-width operands, ...). The compare benches run
    # CppNix vs canon snix vs this.
    snix-optimized = {
      url = "git+file:///home/tom/tools/snix?ref=vm-force-fastpath";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, rust-overlay, snix, snix-optimized }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          craneLib = (crane.mkLib pkgs).overrideToolchain pkgs.rust-bin.stable.latest.default;

          # The cargo workspace lives in the snix/ subdir. snix-cli-eval's build scripts want
          # a PROTO_ROOT with snix/{castore,store,build} entries, and snix-build wants a
          # sandbox shell path at compile time (unused here — the benchmark never builds).
          mkSnixEval = name: snixInput:
            let
              snixSrc = pkgs.runCommand "${name}-src" { } ''
                cp -r ${snixInput}/snix $out
                chmod -R u+w $out
                mkdir -p $out/proto-root/snix
                ln -s $out/castore $out/proto-root/snix/castore
                ln -s $out/store $out/proto-root/snix/store
                ln -s $out/build $out/proto-root/snix/build
              '';

              snixCommonArgs = {
                src = snixSrc;
                version = "0.0.1";
                nativeBuildInputs = [ pkgs.protobuf pkgs.pkg-config ];
                buildInputs = [ pkgs.openssl ];
                PROTO_ROOT = "${snixSrc}/proto-root";
                SNIX_BUILD_SANDBOX_SHELL = "/homeless-shelter";
                doCheck = false;
              };
            in
            craneLib.buildPackage (snixCommonArgs // {
              pname = name;
              cargoArtifacts = craneLib.buildDepsOnly (snixCommonArgs // { pname = "${name}-deps"; });
              # xp-store-composition-cli: enables --experimental-store-composition, which the realise
              # benchmark needs to point snix at a castore store.
              cargoExtraArgs = "--package snix-cli-eval --features xp-store-composition-cli";
            });

          snix-eval = mkSnixEval "snix-eval" snix;
          snix-eval-opt = mkSnixEval "snix-eval-opt" snix-optimized;

          env = import ./env.nix { nixpkgs = nixpkgs.outPath; inherit system; };

          # Common comparison harness: sanity-check that all three evaluators
          # (CppNix, canon snix, the optimized snix branch) produce the same
          # drv path for `expr`, then hyperfine them. `defaultRuns` can be
          # overridden at runtime via RUNS (and warmup via WARMUP).
          mkCompareBench = { name, expr, defaultRuns ? 5 }: pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [ pkgs.hyperfine pkgs.nix ];
            text = ''
              expr=${pkgs.lib.escapeShellArg expr}
              snix_canon=${snix-eval}/bin/snix-eval
              snix_opt=${snix-eval-opt}/bin/snix-eval

              echo "CppNix:     $(nix eval --version)"
              echo "snix-canon: rev ${snix.rev or "unknown"}"
              echo "snix-opt:   rev ${snix-optimized.rev or snix-optimized.dirtyRev or "unknown"}"
              echo "nixpkgs:    ${nixpkgs.outPath}"
              echo
              echo "Expression: $expr"
              echo

              snix_drv() { RUST_LOG=error "$1" --no-warnings -E "$expr" 2>/dev/null | grep -E '^=> ' | tr -d '"' | awk '{print $2}'; }

              # Sanity check: all evaluators must instantiate the same drv.
              cpp_drv=$(nix eval --raw --impure --expr "$expr" 2>/dev/null)
              canon_drv=$(snix_drv "$snix_canon")
              opt_drv=$(snix_drv "$snix_opt")
              echo "CppNix drvPath:     $cpp_drv"
              echo "snix-canon drvPath: $canon_drv"
              echo "snix-opt drvPath:   $opt_drv"
              if [ "$cpp_drv" != "$canon_drv" ] || [ "$cpp_drv" != "$opt_drv" ]; then
                echo "MISMATCH: evaluators disagree on the drv path" >&2
                exit 1
              fi
              echo

              hyperfine --warmup "''${WARMUP:-1}" --runs "''${RUNS:-${toString defaultRuns}}" \
                --command-name cppnix "nix eval --raw --impure --expr '$expr'" \
                --command-name snix-canon "RUST_LOG=error $snix_canon --no-warnings -E '$expr'" \
                --command-name snix-opt "RUST_LOG=error $snix_opt --no-warnings -E '$expr'" \
                "$@"
            '';
          };

          bench = mkCompareBench {
            name = "snix-eval-bench";
            expr = "(import ${./env.nix} { nixpkgs = ${nixpkgs.outPath}; }).drvPath";
          };

          # NixOS benchmark: evaluate a minimal-but-real NixOS system through the
          # module system to `.system.drvPath`. This exercises a very different
          # profile than the env bench: heavy attrset traffic, option merging
          # (equality checks), and functional combinators. Run: nix run .#nixos
          nixos-bench = mkCompareBench {
            name = "snix-nixos-bench";
            expr = ''(import ${nixpkgs.outPath}/nixos { configuration = { fileSystems."/" = { device = "/dev/sda"; fsType = "ext4"; }; boot.loader.grub.device = "/dev/sda"; system.stateVersion = "26.11"; }; }).system.drvPath'';
            defaultRuns = 3;
          };
          # Realise benchmark: not just eval, but evaluate-AND-realise the closure through a
          # castore store composition, substituting from cache.nixos.org. Uses LOCAL castore
          # backends (objectstore blobs + redb dir/pathinfo), isolating snix's own realise cost
          # (substitution + ingest + store round-trips) from any remote-store layer. Forces the
          # output path via `readDir`, and dumps the `fullsnix-phase-stats` breakdown for a cold
          # run (fresh store) and a warm run (store reused).
          realise = pkgs.writeShellApplication {
            name = "snix-realise-bench";
            runtimeInputs = [ snix-eval pkgs.coreutils pkgs.gnugrep ];
            text = ''
              env_file="''${1:-${./env-realise.nix}}"
              castore=$(mktemp -d)
              mkdir -p "$castore/blobs"
              sub='nix+https://cache.nixos.org?trusted_public_keys[0]=cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='
              cat > "$castore/comp.toml" <<EOF
              [blobservices.root]
              type = "objectstore"
              object_store_url = "file://$castore/blobs"
              object_store_options = {}
              [directoryservices.mem]
              type = "memory"
              [directoryservices.dredb]
              type = "redb"
              path = "$castore/dir.redb"
              [directoryservices.root]
              type = "cache"
              near = "&mem"
              far = "&dredb"
              [pathinfoservices.localcache]
              type = "redb"
              path = "$castore/pi.redb"
              [pathinfoservices.root]
              type = "cache"
              near = "&localcache"
              far = "$sub"
              EOF

              # env_file returns a list of packages; force each package's output (readDir realises it
              # in snix), so the whole set is substituted from cache.nixos.org — no derivation is built.
              expr="(let ps = (import $env_file {}); in builtins.foldl' (acc: p: builtins.seq (builtins.readDir p.outPath) acc) (builtins.length ps) ps)"
              echo "snix:    rev ${snix.rev or "unknown"}"
              echo "env:     $env_file"
              echo "castore: $castore  (local objectstore blobs + redb dir/pathinfo; far = cache.nixos.org)"
              echo

              run() {
                RUST_LOG=error snix-eval \
                  --experimental-store-composition "$castore/comp.toml" \
                  --build-service-addr "dummy:" \
                  --no-warnings -E "$expr" 2>&1
              }

              echo "=== COLD: fresh castore, substitutes the whole closure from cache.nixos.org ==="
              out=$(run)
              echo "$out" | grep -E '^=> ' | head -1
              echo "$out" | grep 'fullsnix-phase-stats' || echo "(no phase-stats line — is this the codedown snix fork?)"
              echo

              echo "=== WARM: same castore reused, everything now local (no cache.nixos.org) ==="
              out=$(run)
              echo "$out" | grep 'fullsnix-phase-stats' || true
              echo
              echo "phase legend: pathinfo_get = store 'is this path present?' lookups (a network"
              echo "round-trip against a remote store; local redb here), substitute/fetch ="
              echo "cache.nixos.org NAR fetch+ingest, nar_calc = NAR hashing,"
              echo "blob_read/dir_get/descend = castore reads."
            '';
          };
        in
        {
          inherit snix-eval snix-eval-opt env bench realise;
          nixos = nixos-bench;
          default = bench;
        });
    };
}
