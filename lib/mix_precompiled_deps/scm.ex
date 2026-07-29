defmodule MixPrecompiledDeps.SCM do
  @moduledoc """
  A `Mix.SCM` for dependencies prebuilt by an external build system.

  See `MixPrecompiledDeps` for the manifest format and usage. Do not
  register this module directly; call `MixPrecompiledDeps.register/0`
  so registration stays gated on the `MIX_PRECOMPILED_DEPS` environment
  variable.
  """

  @behaviour Mix.SCM

  alias MixPrecompiledDeps.Manifest

  # Dependencies that are Hex-bound but absent from the external build
  # graph (optional deps and dev/test-only deps of deps) are claimed with
  # this nonexistent path, so they are reported unavailable and pruned
  # exactly like an unfetched Hex dependency — without requiring Hex. A
  # required dependency missing from the manifest surfaces loudly as
  # "not available", signalling a stale manifest.
  @unavailable_prefix "/mix-precompiled-deps-unavailable"

  @impl true
  def fetchable? do
    false
  end

  @impl true
  def format(_opts) do
    "precompiled"
  end

  @impl true
  def format_lock(_opts) do
    nil
  end

  @impl true
  def accepts_options(app, opts) do
    cond do
      entry = Manifest.get()[Atom.to_string(app)] ->
        opts
        |> Keyword.put(:dest, entry.dest)
        |> Keyword.put(:build, entry.build)
        |> Keyword.put(:precompiled, true)
        |> Keyword.put(:precompiled_version, entry[:version])

      opts[:path] || opts[:git] || opts[:github] ->
        nil

      true ->
        path = "#{@unavailable_prefix}/#{app}"

        opts
        |> Keyword.put(:dest, path)
        |> Keyword.put(:build, path)
        |> Keyword.put(:precompiled, true)
    end
  end

  @impl true
  def checked_out?(opts) do
    File.dir?(opts[:build])
  end

  @impl true
  def lock_status(opts) do
    # The manifest is generated from mix.lock; a version mismatch means it
    # is stale and must be regenerated, not that Mix should fetch anything.
    with version when is_binary(version) <- opts[:precompiled_version],
         lock when is_tuple(lock) <- opts[:lock],
         locked when is_binary(locked) <- lock_version(lock),
         true <- locked != version do
      :outdated
    else
      _ -> :ok
    end
  end

  defp lock_version(lock) when elem(lock, 0) == :hex, do: elem(lock, 2)
  defp lock_version(_lock), do: nil

  @impl true
  def equal?(opts1, opts2) do
    opts1[:build] == opts2[:build]
  end

  @impl true
  def managers(_opts) do
    []
  end

  @impl true
  def checkout(opts) do
    Mix.raise(
      "cannot checkout dependency #{inspect(opts[:app])} because it is provided " <>
        "prebuilt through the MIX_PRECOMPILED_DEPS manifest. It must be fetched " <>
        "and built by the external build system instead"
    )
  end

  @impl true
  def update(opts) do
    checkout(opts)
  end
end
