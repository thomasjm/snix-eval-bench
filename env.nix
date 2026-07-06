{ nixpkgs, system ? builtins.currentSystem }:

let
  pkgs = import nixpkgs { inherit system; config = {}; overlays = []; };

in

pkgs.symlinkJoin {
  name = "bench-environment";
  paths = with pkgs; [
    (pkgs.python3.withPackages (ps: with ps; [
      numpy
      pandas
      matplotlib
      requests
      ipython
      setuptools
      pip
    ]))

    bash
    binutils
    cargo
    cmake
    coreutils
    curl
    findutils
    gawk
    gcc
    git
    gnugrep
    gnumake
    gnupg
    gnused
    go
    htop
    jq
    nodejs
    openssh
    openssl
    ripgrep
    rsync
    rustc
    sqlite
    tmux
    unzip
    vim
    wget
    xz
    zip
    zlib
    zsh
    zstd
  ];
}
