{
  description = "NeuroSpeed chess engine";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c8f90650c15282fa8656a041bfbbd2403997a9a7";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      version = builtins.head (builtins.match ".*\\.version = \"([^\"]+)\".*" (builtins.readFile ./build.zig.zon));

      meta = {
        description = "NeuroSpeed UCI chess engine with NNUE evaluation";
        homepage = "https://github.com/lovc21/NeuroSpeed";
        mainProgram = "NeuroSpeed";
        platforms = [ system ];
      };

      # cpu decides which NNUE kernel gets compiled in, znver5 has the AVX-512 VNNI fast path
      mkNeuroSpeed = { cpu ? "znver5" }: pkgs.stdenv.mkDerivation {
        pname = "neurospeed";
        inherit version meta;
        src = self;

        nativeBuildInputs = [ pkgs.zig_0_16.hook ];

        # the hook would append -Dcpu=baseline --release=safe otherwise
        dontSetZigDefaultFlags = true;
        zigBuildFlags = [ "--release=fast" "-Dcpu=${cpu}" ];
        zigCheckFlags = [ "--release=fast" "-Dcpu=${cpu}" ];
        doCheck = true;
      };

      # release hashes per cpu, empty entry = no prebuilt binary yet so the source build is used
      # after tagging a release run `nix build .#neurospeed-bin` once and paste the hash it prints
      release_hashes = {
        znver5 = null;
        x86_64_v3 = null;
      };

      mkNeuroSpeedBin = { cpu, hash }: pkgs.stdenvNoCC.mkDerivation {
        pname = "neurospeed-bin";
        inherit version meta;

        src = pkgs.fetchurl {
          url = "https://github.com/lovc21/NeuroSpeed/releases/download/v${version}/NeuroSpeed-${version}-x86_64-linux-${cpu}.tar.gz";
          inherit hash;
        };
        sourceRoot = ".";

        installPhase = ''
          install -Dm755 NeuroSpeed $out/bin/NeuroSpeed
        '';
      };

      # prebuilt binary when a release exists for the cpu, otherwise compile it
      neurospeedFor = cpu:
        if release_hashes.${cpu} or null != null
        then mkNeuroSpeedBin { inherit cpu; hash = release_hashes.${cpu}; }
        else mkNeuroSpeed { inherit cpu; };
    in {
      packages.${system} = {
        default = self.packages.${system}.neurospeed;
        neurospeed = neurospeedFor "znver5";
        neurospeed-generic = neurospeedFor "x86_64_v3";
        neurospeed-src = mkNeuroSpeed { };
        neurospeed-bin = mkNeuroSpeedBin { cpu = "znver5"; hash = if release_hashes.znver5 != null then release_hashes.znver5 else lib.fakeHash; };
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/NeuroSpeed";
      };

      overlays.default = final: prev: {
        neurospeed = self.packages.${system}.neurospeed;
        neurospeed-generic = self.packages.${system}.neurospeed-generic;
      };

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
