{ pkgs ? import <nixpkgs> {
  config = {
    allowUnfree = true;
  };
} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    zig
    pkg-config
    goreleaser

    nodejs_20
    
    ripgrep
    (pkgs.callPackage ./.nixpkgs/claude-code.nix {})
  ];
  
  shellHook = ''
  '';
}
