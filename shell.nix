{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.wayland-scanner
  ];
  buildInputs = [
    pkgs.wayland
    pkgs.wayland-protocols
    pkgs.wlr-protocols
    pkgs.libxkbcommon
  ];
}
