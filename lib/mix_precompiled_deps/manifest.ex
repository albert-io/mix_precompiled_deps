defmodule MixPrecompiledDeps.Manifest do
  @moduledoc false

  @env_var "MIX_PRECOMPILED_DEPS"
  @key {__MODULE__, :manifest}
  @legacy_lock_key "__mix_lock_sha256__"

  @doc """
  Returns the normalized manifest, or `nil` when `#{@env_var}` is unset.

  The manifest is loaded once per VM and cached.
  """
  @spec get() :: %{deps: %{optional(String.t()) => map}, lock_sha256: String.t() | nil} | nil
  def get do
    case :persistent_term.get(@key, :unset) do
      :unset ->
        manifest =
          case System.get_env(@env_var) do
            nil -> nil
            path -> load!(path)
          end

        :persistent_term.put(@key, manifest)
        manifest

      manifest ->
        manifest
    end
  end

  @doc false
  @spec reload() :: :ok
  def reload do
    :persistent_term.erase(@key)
    :ok
  end

  defp load!(path) do
    case Code.eval_file(path) do
      {%{} = manifest, _binding} ->
        normalize!(manifest, path)

      {other, _binding} ->
        Mix.raise(
          "expected #{@env_var} manifest #{path} to evaluate to a map, got: #{inspect(other)}"
        )
    end
  rescue
    e in [File.Error, Code.LoadError] ->
      Mix.raise("could not load #{@env_var} manifest #{path}: #{Exception.message(e)}")
  end

  defp normalize!(%{deps: %{} = deps} = manifest, path) do
    lock_sha256 = get_in(manifest, [:lock, :sha256])
    validate!(deps, lock_sha256, path)
  end

  defp normalize!(manifest, path) do
    {lock_sha256, deps} = Map.pop(manifest, @legacy_lock_key)
    validate!(deps, lock_sha256, path)
  end

  defp validate!(deps, lock_sha256, path) do
    if lock_sha256 != nil and
         (not is_binary(lock_sha256) or not Regex.match?(~r/\A[0-9a-f]{64}\z/, lock_sha256)) do
      Mix.raise("expected lock.sha256 in #{path} to be a lowercase SHA-256 digest")
    end

    Enum.each(deps, fn
      {name, %{dest: dest, build: build} = entry}
      when is_binary(name) and is_binary(dest) and is_binary(build) ->
        if entry[:version] != nil and not is_binary(entry.version) do
          Mix.raise("expected dependency #{inspect(name)} version in #{path} to be a string")
        end

      {name, _entry} ->
        Mix.raise(
          "expected dependency #{inspect(name)} in #{path} to have string dest and build paths"
        )
    end)

    %{deps: deps, lock_sha256: lock_sha256}
  end
end
