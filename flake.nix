{
  description = "NeuroSpeed dev environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c8f90650c15282fa8656a041bfbbd2403997a9a7";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          zig_0_16
          just
          cutechess
          stockfish
          perf
          llvmPackages_22.bolt
          flamegraph
          python3
        ];
      };
    };
}
