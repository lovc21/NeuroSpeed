{
  description = "NeuroSpeed chess engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, zig-overlay, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        
        zigVersion = pkgs.zigpkgs."0.14.1";
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            zigVersion
            pkgs.zls
          ];

          shellHook = ''
            echo "Zig $(zig version)"
          '';
        };
      }
    );
}
