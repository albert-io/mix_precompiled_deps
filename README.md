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

## Usage

Point `MIX_PRECOMPILED_DEPS` at a manifest file and install the project hook
after `use Mix.Project`:

```elixir
defmodule MyApp.MixProject do
  use Mix.Project

  if Code.ensure_loaded?(MixPrecompiledDeps) do
    use MixPrecompiledDeps
  end
end
```

The hook runs after Mix selects the task's preferred environment. Registration
is a no-op when the environment variable is unset, so normal Mix workflows
(`mix deps.get`, `mix deps.update`, Hex) are untouched.

For a persistent local opt-in, pass a directory containing
`deps-manifest-<env>.exs` files:

```elixir
use MixPrecompiledDeps, manifest_dir: ".external-build"
```

The explicit environment variable takes precedence. A missing directory or
environment manifest is a no-op; a broken directory symlink raises instead of
silently falling back to regular dependencies.

The package itself is expected to be provided by the external build system
(e.g. on `ERL_LIBS` from a Nix devShell or build sandbox) rather than declared
as a dependency — it must be loadable before the dependency tree is resolved.

## The manifest

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

- `lock.sha256` — optional lowercase SHA-256 of the complete project lockfile;
  a mismatch fails before the SCM is registered
- `dest` — the dependency's source tree: used for dependency resolution
  (its `mix.exs`/`rebar.config`), `import_deps` in `.formatter.exs`, etc.
- `build` — its compiled BEAM application directory (containing `ebin/`)
- `version` — optional per-dependency fallback check for manifests without a
  complete lock digest

The original flat dependency map remains accepted for compatibility.

Both paths are treated as immutable: Mix never compiles, cleans, fetches,
or writes to them. When a dependency is reported out of date, rebuild it
with the external build system and regenerate the manifest.

Dependencies that are declared somewhere in the tree but absent from the
manifest (optional dependencies, `dev`/`test`-only dependencies of
dependencies) are claimed with a nonexistent path so Mix prunes them
exactly like unfetched Hex dependencies. A *required* dependency missing
from the manifest surfaces loudly as "not available" — the signal that the
manifest is stale. Dependencies declared with explicit `:path`/`:git`
options are left to their own SCMs.

Entries covering only dependency *resolution* (e.g. `dev`-only top-level
deps while running in `:test`) may point `build` at the source tree too —
it is never loaded, only resolved.

## Requirements

Three small Mix patches, until they are upstreamed — shipped in
[`patches/`](patches/) (against Elixir v1.20.2) and as the
[albert-io/elixir@precompiled-deps](https://github.com/albert-io/elixir/tree/precompiled-deps)
branch:

1. `Mix.Dep.load_paths/1` trusts a dependency's `:build` path instead of
   reconstructing `<build_lib>/<app>/ebin`
2. `Mix.AppLoader.load_apps/5` — the same fix for the second
   reconstruction site
3. A `:precompiled` dependency option: exempt from the
   non-fetchable-deps-are-always-recompiled rule, and `mix deps.compile`
   skips (ok) or raises actionably (stale/forced) instead of deleting and
   rebuilding a read-only build directory

All three are behavior-preserving for the built-in SCMs. On an unpatched
Elixir, Mix would attempt to recompile store paths — the SCM will not work.

## License

Apache-2.0
