defmodule MixPrecompiledDeps do
  @moduledoc """
  Precompiled dependencies for Mix.

  Registers `MixPrecompiledDeps.SCM`, a `Mix.SCM` that serves dependencies
  prebuilt by an external, content-addressed build system such as Nix or
  Bazel, straight from their immutable build outputs — no `deps/` checkouts,
  no per-dependency compilation into `_build`, and no Hex requirement.

  ## Usage

  Install the project hook after `use Mix.Project`:

      defmodule MyApp.MixProject do
        use Mix.Project

        if Code.ensure_loaded?(MixPrecompiledDeps) do
          use MixPrecompiledDeps
        end
      end

  The hook runs after Mix selects the task's preferred environment and
  registers the SCM when `MIX_PRECOMPILED_DEPS` points to a manifest.
  Regular Mix workflows (`mix deps.get`, `mix deps.update`, Hex resolution)
  are unaffected when it is unset.

  For a local opt-in directory containing environment-specific manifests,
  pass `:manifest_dir`:

      use MixPrecompiledDeps, manifest_dir: ".external-build"

  The hook looks for `deps-manifest-#{Mix.env()}.exs` in that directory when
  `MIX_PRECOMPILED_DEPS` is unset. A missing directory or environment
  manifest is a no-op; a broken directory pointer raises.

  ## The manifest

  `MIX_PRECOMPILED_DEPS` names an `.exs` file with lock metadata and a map
  of dependency names to entries:

      %{
        lock: %{sha256: "..."},
        deps: %{
          "ecto" => %{
            dest: "/nix/store/...-ecto/src",
            build: "/nix/store/...-ecto/lib/erlang/lib/ecto-3.13.5",
            version: "3.13.5"
          }
        },
      }

  `:dest` points at the dependency's source tree (used for dependency
  resolution, `import_deps` in `.formatter.exs`, and friends), `:build` at
  its compiled BEAM application directory (containing `ebin/`). Both are
  expected to be immutable. `lock.sha256` is optional; when present it is
  compared against the project's complete lockfile. `:version` is also
  optional and provides a per-dependency fallback check for manifests
  without a lock digest.

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

  alias MixPrecompiledDeps.Manifest

  @doc """
  Installs a hook that registers precompiled dependencies after Mix has
  selected the task's preferred environment.

  ## Options

    * `:manifest_dir` - a directory relative to `mix.exs` containing
      `deps-manifest-<env>.exs` files

  """
  defmacro __using__(opts) do
    quote do
      Module.register_attribute(__MODULE__, :mix_precompiled_deps, persist: true)

      Module.put_attribute(
        __MODULE__,
        :mix_precompiled_deps,
        unquote(Macro.escape(opts))
      )

      @after_compile MixPrecompiledDeps
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    opts =
      env.module.__info__(:attributes)
      |> Keyword.fetch!(:mix_precompiled_deps)
      |> Keyword.put(:project_dir, Path.dirname(env.file))

    register(opts)
  end

  @doc """
  Registers the precompiled SCM if `MIX_PRECOMPILED_DEPS` is set.

  Returns `:ok` when the SCM was registered, `:noop` otherwise. Safe to
  call unconditionally from `mix.exs`.
  """
  @spec register(keyword) :: :ok | :noop
  def register(opts \\ []) do
    set_manifest_from_dir(opts)

    if enabled?() do
      validate_lock!(Manifest.get(), opts)
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
    Manifest.get() != nil
  end

  defp set_manifest_from_dir(opts) do
    with nil <- System.get_env("MIX_PRECOMPILED_DEPS"),
         manifest_dir when is_binary(manifest_dir) <- opts[:manifest_dir] do
      project_dir = Path.expand(opts[:project_dir] || File.cwd!())
      root = Path.expand(manifest_dir, project_dir)
      path = Path.join(root, "deps-manifest-#{Mix.env()}.exs")

      case File.lstat(path) do
        {:ok, _} ->
          System.put_env("MIX_PRECOMPILED_DEPS", path)
          Manifest.reload()

        {:error, :enoent} ->
          validate_root(root)

        {:error, reason} ->
          raise File.Error, reason: reason, action: "stat", path: path
      end
    end
  end

  defp validate_root(root) do
    with {:ok, _} <- File.lstat(root),
         {:error, reason} <- File.stat(root) do
      raise File.Error, reason: reason, action: "stat", path: root
    else
      _ -> :ok
    end
  end

  defp validate_lock!(%{lock_sha256: nil}, _opts), do: :ok

  defp validate_lock!(%{lock_sha256: expected}, opts) do
    project_dir = Path.expand(opts[:project_dir] || File.cwd!())
    lockfile = opts[:lockfile] || Mix.Project.config()[:lockfile] || "mix.lock"

    actual =
      lockfile
      |> Path.expand(project_dir)
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    if expected != actual do
      Mix.raise("""
      MIX_PRECOMPILED_DEPS was built from a different #{lockfile}.
      Rebuild the dependency manifest with the external build system.
      """)
    end
  end
end
