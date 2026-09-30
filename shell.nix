{ pkgs ? import <nixpkgs> {} }:

# Everything here is for the Wayland backend. The macOS backend only needs
# Zig plus the system SDK from Xcode or the Command Line Tools.
pkgs.mkShell {
  nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.pkg-config
    pkgs.wayland-scanner
  ];
  buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.wayland
    pkgs.wayland-protocols
    pkgs.wlr-protocols
    pkgs.libxkbcommon
    pkgs.sqlite
  ];
}
