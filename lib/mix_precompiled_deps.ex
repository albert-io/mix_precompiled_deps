defmodule MixPrecompiledDeps do
  @moduledoc """
  Precompiled dependencies for Mix.

  Registers `MixPrecompiledDeps.SCM`, a `Mix.SCM` that serves dependencies
  prebuilt by an external, content-addressed build system such as Nix or
  Bazel, straight from their immutable build outputs — no `deps/` checkouts,
  no per-dependency compilation into `_build`, and no Hex requirement.

  ## Usage

  Call `register/0` at the top of your project's `mix.exs` (before the
  project module is defined):

      if Code.ensure_loaded?(MixPrecompiledDeps) do
        MixPrecompiledDeps.register()
      end

  Registration is a no-op unless the `MIX_PRECOMPILED_DEPS` environment
  variable points to a manifest file, so regular Mix workflows
  (`mix deps.get`, `mix deps.update`, Hex resolution) are unaffected when
  it is unset.

  ## The manifest

  `MIX_PRECOMPILED_DEPS` names an `.exs` file that evaluates to a map of
  dependency names to entries:

      %{
        "ecto" => %{
          dest: "/nix/store/...-ecto/src",
          build: "/nix/store/...-ecto/lib/erlang/lib/ecto-3.13.5",
          version: "3.13.5"
        },
        ...
      }

  `:dest` points at the dependency's source tree (used for dependency
  resolution, `import_deps` in `.formatter.exs`, and friends), `:build` at
  its compiled BEAM application directory (containing `ebin/`). Both are
  expected to be immutable. `:version` is optional; when present it is
  compared against the project's `mix.lock` entry so a manifest generated
  from an older lock is reported as outdated instead of silently used.

  Dependencies claimed by the SCM are marked `:precompiled`: Mix never
  compiles, cleans, or fetches them. When one is reported out of date
  (for example because its recorded compile-time configuration no longer
  matches the project's), rebuild it with the external build system and
  regenerate the manifest.

  ## Requirements

  Requires an Elixir whose Mix honors a dependency's `:build` path and the
  `:precompiled` option (see the README for the three small patches this
  needs until they are upstreamed).
  """

  @doc """
  Registers the precompiled SCM if `MIX_PRECOMPILED_DEPS` is set.

  Returns `:ok` when the SCM was registered, `:noop` otherwise. Safe to
  call unconditionally from `mix.exs`.
  """
  @spec register() :: :ok | :noop
  def register do
    if enabled?() do
      Mix.SCM.prepend(MixPrecompiledDeps.SCM)
      :ok
    else
      :noop
    end
  end

  @doc """
  Returns `true` when a `MIX_PRECOMPILED_DEPS` manifest is configured.
  """
  @spec enabled?() :: boolean
  def enabled? do
    MixPrecompiledDeps.Manifest.get() != nil
  end
end
