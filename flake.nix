{
  description = "A Mix SCM that serves dependencies prebuilt by an external build system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = "0.2.0";

      # The toolchain: a stock beam package set whose elixir carries the three
      # Mix patches from patches/ (see the README — required until upstreamed),
      # plus the SCM itself as a regular BEAM library for ERL_LIBS.
      beamPackagesFor =
        pkgs:
        pkgs.beamPackages.extend (
          final: prev: {
            elixir = prev.elixir_1_20.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                ./patches/0001-Trust-dep-build-in-Mix.Dep.load_paths-1.patch
                ./patches/0002-Trust-dep-build-in-Mix.AppLoader.load_apps-5.patch
                ./patches/0003-Support-a-precompiled-option-on-dependencies.patch
              ];
            });

            mixPrecompiledDeps = final.buildMix {
              name = "mix_precompiled_deps";
              inherit version;
              src = pkgs.lib.fileset.toSource {
                root = ./.;
                fileset = pkgs.lib.fileset.unions [
                  ./lib
                  ./mix.exs
                ];
              };
              beamDeps = [ ];
            };
          }
        );

      librarySrc =
        pkgs:
        pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./lib
            ./test
            ./mix.exs
            ./.formatter.exs
          ];
        };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          beamPackages = beamPackagesFor pkgs;
        in
        {
          default = beamPackages.mixPrecompiledDeps;
          elixir = beamPackages.elixir;
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          beamPackages = beamPackagesFor pkgs;
        in
        {
          tests = pkgs.stdenv.mkDerivation {
            name = "mix-precompiled-deps-tests";
            src = librarySrc pkgs;

            nativeBuildInputs = [
              beamPackages.erlang
              beamPackages.elixir
            ];

            MIX_ENV = "test";
            LANG = "C.UTF-8";

            dontConfigure = true;
            dontInstall = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              mix test --no-deps-check
              touch $out
              runHook postBuild
            '';
          };

          format = pkgs.stdenv.mkDerivation {
            name = "mix-precompiled-deps-format";
            src = librarySrc pkgs;

            nativeBuildInputs = [ beamPackages.elixir ];
            LANG = "C.UTF-8";

            dontConfigure = true;
            dontInstall = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              mix format --check-formatted
              touch $out
              runHook postBuild
            '';
          };

          example-hello = import ./examples/hello {
            inherit pkgs beamPackages;
          };
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          beamPackages = beamPackagesFor pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              beamPackages.erlang
              beamPackages.elixir
            ];
          };
        }
      );
    };
}
