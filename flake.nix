{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    crane.url = "github:ipetkov/crane/edb38893982a3338972bb4a2ec7ce7c29ba10fd9";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    snix = {
      url = "git+https://git.snix.dev/snix/snix.git?ref=canon";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, crane, rust-overlay, snix }:
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
          snixSrc = pkgs.runCommand "snix-src" { } ''
            cp -r ${snix}/snix $out
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

          snix-eval = craneLib.buildPackage (snixCommonArgs // {
            pname = "snix-eval";
            cargoArtifacts = craneLib.buildDepsOnly (snixCommonArgs // { pname = "snix-deps"; });
            cargoExtraArgs = "--package snix-cli-eval";
          });

          env = import ./env.nix { nixpkgs = nixpkgs.outPath; inherit system; };

          bench = pkgs.writeShellApplication {
            name = "snix-eval-bench";
            runtimeInputs = [ pkgs.hyperfine pkgs.nix snix-eval ];
            text = ''
              expr="(import ${./env.nix} { nixpkgs = ${nixpkgs.outPath}; }).drvPath"

              echo "CppNix:   $(nix eval --version)"
              echo "snix:     rev ${snix.rev or "unknown"}"
              echo "nixpkgs:  ${nixpkgs.outPath}"
              echo
              echo "Expression: $expr"
              echo

              # Sanity check: both evaluators must instantiate the same top-level .drv.
              cpp_drv=$(nix eval --raw --impure --expr "$expr" 2>/dev/null)
              snix_drv=$(RUST_LOG=error snix-eval --no-warnings -E "$expr" 2>/dev/null | tr -d '"' | awk '{print $2}')
              echo "CppNix drvPath: $cpp_drv"
              echo "snix drvPath: $snix_drv"
              if [ "$cpp_drv" != "$snix_drv" ]; then
                echo "MISMATCH: evaluators disagree on the drv path" >&2
                exit 1
              fi
              echo

              hyperfine --warmup "''${WARMUP:-1}" --runs "''${RUNS:-5}" \
                --command-name cppnix "nix eval --raw --impure --expr '$expr'" \
                --command-name snix "RUST_LOG=error snix-eval --no-warnings -E '$expr'" \
                "$@"
            '';
          };
        in
        {
          inherit snix-eval env bench;
          default = bench;
        });
    };
}
