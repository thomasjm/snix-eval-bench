# A SMALL set of packages for the realise benchmark. Returned as a *list* (not a symlinkJoin): the
# benchmark forces each package's output path, substituting its closure from cache.nixos.org. A
# symlinkJoin would be a fresh derivation that has to be *built*, which isn't what we're measuring —
# we want pure substitution + store round-trips. Every package here is in cache.nixos.org, so nothing
# is built.
#
# Self-contained (fetches its own pinned nixpkgs via fetchTarball) so the sources flow through castore
# during eval — the same shape the nox full-snix suite uses.
{ system ? builtins.currentSystem }:

let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/daf6dc47aa4b44791372d6139ab7b25269184d55.tar.gz";
    sha256 = "sha256-wxX7u6D2rpkJLWkZ2E932SIvDJW8+ON/0Yy8+a5vsDU=";
  };
  pkgs = import nixpkgs { inherit system; config = { }; overlays = [ ]; };

in

with pkgs; [ hello coreutils jq ripgrep tree which ]
