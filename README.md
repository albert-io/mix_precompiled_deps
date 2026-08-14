# mix_precompiled_deps

A [`Mix.SCM`](https://hexdocs.pm/mix/Mix.SCM.html) that serves dependencies
prebuilt by an external, content-addressed build system — Nix, Bazel, or
anything that can produce per-dependency BEAM builds — straight from their
immutable outputs.

With it, `mix compile`, `mix test`, `mix dialyzer`, `mix format`, and
friends run against store-resident dependencies natively:

- no `deps/` checkouts and no per-dependency compilation into `_build/`
- no synthesized Mix metadata (`.mix/compile.elixir_scm` forgeries, `.app`
  rewriting, mtime pinning)
- no Hex installation required — the whole dependency tree resolves from
  the manifest
- dialyzer PLTs built against the store paths are valid on every machine
  that shares the store (no path rebasing)
- Mix's compile-time configuration check (`compile_env`) stays fully
  active, so a dependency compiled against stale config is reported
  instead of silently used

## How it works

Three artifacts meet when `mix` runs:

1. **Per-dependency builds**, produced by the external build system: each
   dependency's pristine source tree and its compiled BEAM application
   directory (containing `ebin/`). nixpkgs' `buildMix`/`buildRebar3` — and
   therefore [deps_nix](https://github.com/code-supply/deps_nix), which
   generates calls to them — already lay out exactly this
   (`$out/src` and `$out/lib/erlang/lib/<name>-<version>`).
2. **A manifest**: an `.exs` file mapping each dependency name to those two
   paths, stamped with a digest of the `mix.lock` it was generated from.
3. **This SCM**, registered from `mix.exs` and activated by pointing
   `MIX_PRECOMPILED_DEPS` at the manifest. It claims every Hex-bound
   dependency in the tree and hands Mix the immutable store paths; Mix
   never compiles, cleans, fetches, or writes to them.

The SCM package itself is provided by the external build system on
`ERL_LIBS` (from a Nix devShell or build sandbox) rather than declared as a
project dependency — it must be loadable before the dependency tree is
resolved. That is also why the `mix.exs` hook is wrapped in
`Code.ensure_loaded?/1`: in ordinary environments the module is simply
absent and everything behaves as stock.

With `MIX_PRECOMPILED_DEPS` unset, registration is a no-op — `mix
deps.get`, `mix deps.update`, and Hex workflows are untouched.

## Requirements: a patched Mix

Mix hardcodes the assumption that every dependency's compiled output lives
under the project's own `_build/<env>/lib/`. Three small patches lift that
assumption — shipped in [`patches/`](patches/) (against Elixir v1.20) and as
the
[albert-io/elixir@precompiled-deps](https://github.com/albert-io/elixir/tree/precompiled-deps)
branch, until they are upstreamed:

1. `Mix.Dep.load_paths/1` trusts a dependency's `:build` path instead of
   reconstructing `<build_lib>/<app>/ebin`
2. `Mix.AppLoader.load_apps/5` — the same fix for the second
   reconstruction site
3. A `:precompiled` dependency option: exempt from the
   non-fetchable-deps-are-always-recompiled rule, and `mix deps.compile`
   skips (ok) or raises actionably (stale/forced) instead of deleting and
   rebuilding a read-only build directory

All three are behavior-preserving for the built-in SCMs, where `:build` is
always `<build_lib>/<app>` — they only make it *possible* for an SCM to
place compiled dependencies elsewhere. **On an unpatched Elixir the SCM
will not work**: Mix would attempt to recompile store paths.

On Nix, apply them with a package-set override that also builds the SCM as
an ordinary BEAM library (this is `beamPackagesFor` in
[`flake.nix`](flake.nix), which this repo's CI exercises):

```nix
beamPackages = pkgs.beamPackages.extend (final: prev: {
  elixir = prev.elixir_1_20.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      "${src}/patches/0001-Trust-dep-build-in-Mix.Dep.load_paths-1.patch"
      "${src}/patches/0002-Trust-dep-build-in-Mix.AppLoader.load_apps-5.patch"
      "${src}/patches/0003-Support-a-precompiled-option-on-dependencies.patch"
    ];
  });

  # The SCM itself, for ERL_LIBS.
  mixPrecompiledDeps = final.buildMix {
    name = "mix_precompiled_deps";
    version = "0.2.0";
    inherit src;
    beamDeps = [ ];
  };
});
```

## Quickstart

A complete, runnable example lives in [`examples/hello`](examples/hello): a
toy project with one dependency (`jason`) whose `mix test` runs as a flake
check with the dependency served from the Nix store — no `deps/`, no Hex,
no network:

```console
$ nix flake check github:albert-io/mix_precompiled_deps
```

(from a checkout: `nix build .#checks.x86_64-linux.example-hello`)

It is four small pieces:

**1. The project hook** — [`examples/hello/mix.exs`](examples/hello/mix.exs)
installs the SCM after `use Mix.Project`:

```elixir
defmodule Hello.MixProject do
  use Mix.Project

  if Code.ensure_loaded?(MixPrecompiledDeps) do
    MixPrecompiledDeps.install(__MODULE__)
  end

  # ... project/0, deps/0 as usual, with {:jason, "~> 1.4"}
end
```

**2. The dependency, built by Nix** — stock nixpkgs builders produce the
layout the manifest needs
([`examples/hello/default.nix`](examples/hello/default.nix)); for a real
project, [deps_nix](https://github.com/code-supply/deps_nix) generates
these from `mix.lock`:

```nix
jason = beamPackages.buildMix {
  name = "jason";
  version = "1.4.5";
  src = beamPackages.fetchHex {
    pkg = "jason";
    version = "1.4.5";
    sha256 = "b0c823996..."; # the package's outer checksum — last hash in mix.lock
  };
  beamDeps = [ ];
};
```

**3. The manifest** — rendered by Nix, so every path is a store path and
the lock digest comes from the exact `mix.lock` being built:

```nix
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
```

**4. The check** — point `MIX_PRECOMPILED_DEPS` at the manifest, put the
SCM on `ERL_LIBS`, and run `mix` normally:

```nix
pkgs.stdenv.mkDerivation {
  name = "example-hello";
  src = ./.;
  nativeBuildInputs = [ beamPackages.erlang beamPackages.elixir ];

  MIX_ENV = "test";
  MIX_PRECOMPILED_DEPS = manifest;

  buildPhase = ''
    export HOME=$TMPDIR
    export ERL_LIBS=${beamPackages.mixPrecompiledDeps}/lib/erlang/lib

    mix compile --warnings-as-errors
    mix test
    touch $out
  '';
}
```

At `mix` startup the hook sees `MIX_PRECOMPILED_DEPS`, validates the
manifest and its lock digest against `mix.lock`, and registers the SCM.
Dependency resolution then walks the tree as usual — `jason` resolves at
its store paths, and its *optional* `decimal` dependency, absent from the
manifest, is pruned exactly like an unfetched Hex dependency. Nothing under
`deps/` or `_build/*/lib/` ever exists; the dependency check still runs for
real (no `--no-deps-check` anywhere).

## Persistent local opt-in

`MIX_PRECOMPILED_DEPS` is per-invocation, which suits hermetic build
sandboxes. For a development checkout where every plain `mix` command
should use store-served dependencies, pass a directory instead:

```elixir
MixPrecompiledDeps.install(__MODULE__, manifest_dir: ".external-build")
```

The hook then looks for `deps-manifest-#{Mix.env()}.exs` in that directory
whenever the environment variable is unset. Symlink per-environment
manifests there (and register them as GC roots, if the store is Nix) and
every `mix test`, `mix dialyzer`, or `mix format` in the checkout works
flag-free. The explicit environment variable takes precedence; a missing
directory or environment manifest is a no-op; a broken directory symlink
raises instead of silently falling back to regular dependencies.

Because each manifest embeds its lock digest, a `git pull` that changes
`mix.lock` makes every `mix` command fail loudly until the manifests are
regenerated — a stale opt-in can never be silently used.

## Manifest reference

An `.exs` file evaluating to lock metadata and a map of dependency entries:

```elixir
%{
  lock: %{sha256: "..."},
  deps: %{
    "ecto" => %{
      dest: "/nix/store/...-ecto-3.13.5/src",
      build: "/nix/store/...-ecto-3.13.5/lib/erlang/lib/ecto-3.13.5",
      version: "3.13.5"
    }
  },
}
```

- `lock.sha256` — optional lowercase SHA-256 of the complete project
  lockfile; a mismatch fails before the SCM is registered
- `dest` — the dependency's source tree: used for dependency resolution
  (its `mix.exs`/`rebar.config`), `import_deps` in `.formatter.exs`, etc.
- `build` — its compiled BEAM application directory (containing `ebin/`)
- `version` — optional per-dependency fallback check for manifests without
  a complete lock digest

The original flat dependency map (no `lock`/`deps` nesting) remains
accepted for compatibility.

Both paths are treated as immutable: Mix never compiles, cleans, fetches,
or writes to them. When a dependency is reported out of date, rebuild it
with the external build system and regenerate the manifest.

Coverage rules:

- Dependencies declared somewhere in the tree but **absent from the
  manifest** (optional dependencies, `dev`/`test`-only dependencies of
  dependencies) are claimed with a nonexistent path, so Mix prunes them
  exactly like unfetched Hex dependencies.
- A **required** dependency missing from the manifest surfaces loudly as
  "not available" — the signal that the manifest is stale.
- Dependencies declared with explicit `:path`/`:git` options are left to
  their own SCMs.
- Entries needed only for dependency *resolution* (e.g. `dev`-only
  top-level deps while running in `:test`) may point `build` at the source
  tree too — it is never loaded, only resolved.

## When something fails

The system is designed to fail loudly rather than reuse a wrong build.
The errors you can encounter, and what each means:

- **`MIX_PRECOMPILED_DEPS was built from a different mix.lock`** — the
  manifest's lock digest does not match the project's current `mix.lock`.
  Rebuild the dependency set and regenerate the manifest with the external
  build system.
- **A dependency is "not available"** — a required dependency is missing
  from the manifest. Same cause, same fix: the manifest is stale or was
  generated from an incomplete dependency set.
- **`cannot compile dependencies: ... These dependencies are precompiled
  and immutable`** (from `mix deps.compile`, or a dependency reported out
  of date after a config change) — the dependency's recorded compile-time
  configuration (`compile_env`) or other build inputs no longer match the
  project. Rebuild it externally with the correct configuration; Mix
  intentionally refuses to rebuild an immutable build directory in place.
- **`cannot checkout dependency ...`** — something asked Mix to fetch a
  manifest-served dependency (`mix deps.get` with the manifest active).
  Fetching is the external build system's job; run the ordinary Hex
  workflow without `MIX_PRECOMPILED_DEPS` set instead.

## License

Apache-2.0
