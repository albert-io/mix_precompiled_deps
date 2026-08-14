# Runs this example project's `mix test` as a flake check, with its one
# dependency (jason) built by Nix and served straight from the store.
#
# `beamPackages` must carry the patched elixir and the SCM package — see
# `beamPackagesFor` in the repository flake.
{ pkgs, beamPackages }:
let
  inherit (pkgs) lib;

  # The dependency, built by Nix with the stock nixpkgs BEAM builders.
  # `sha256` is the package's outer checksum — the last hash in mix.lock.
  # (deps_nix generates exactly these calls for a whole mix.lock.)
  jasonSrc = beamPackages.fetchHex {
    pkg = "jason";
    version = "1.4.5";
    sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
  };

  jason = beamPackages.buildMix {
    name = "jason";
    version = "1.4.5";
    src = jasonSrc;
    beamDeps = [ ];
  };

  # The manifest: dependency name -> where its source and compiled BEAM
  # application live. buildMix already lays both out per entry:
  #   $out/src                        (pristine source)
  #   $out/lib/erlang/lib/<name>-<v>  (compiled, contains ebin/)
  # The lock digest pins the manifest to the mix.lock it was built from.
  manifest = pkgs.writeText "hello-deps-manifest.exs" ''
    %{
      lock: %{sha256: "${builtins.hashFile "sha256" ./mix.lock}"},
      deps: %{
        "jason" => %{
          dest: "${jason}/src",
          build: "${jason}/lib/erlang/lib/jason-1.4.5",
          version: "1.4.5"
        }
      }
    }
  '';
in
pkgs.stdenv.mkDerivation {
  name = "example-hello";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./mix.exs
      ./mix.lock
      ./.formatter.exs
      ./lib
      ./test
    ];
  };

  nativeBuildInputs = [
    beamPackages.erlang
    beamPackages.elixir
  ];

  MIX_ENV = "test";
  MIX_PRECOMPILED_DEPS = manifest;
  LANG = "C.UTF-8";

  dontConfigure = true;
  dontInstall = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR

    # The SCM package rides on the code path, not on the dependency tree —
    # it must be loadable before dependencies are resolved.
    export ERL_LIBS=${beamPackages.mixPrecompiledDeps}/lib/erlang/lib

    # No `mix deps.get`, no Hex, no network: the dependency check runs for
    # real against the manifest (note: no --no-deps-check anywhere).
    mix deps
    mix compile --warnings-as-errors
    mix test

    touch $out
    runHook postBuild
  '';
}
