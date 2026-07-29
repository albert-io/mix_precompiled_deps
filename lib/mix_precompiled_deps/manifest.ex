defmodule MixPrecompiledDeps.Manifest do
  @moduledoc false

  @env_var "MIX_PRECOMPILED_DEPS"
  @key {__MODULE__, :manifest}

  @doc """
  Returns the loaded manifest map, or `nil` when `#{@env_var}` is unset.

  The manifest is loaded once per VM and cached.
  """
  @spec get() :: %{optional(String.t()) => map} | nil
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
        manifest

      {other, _binding} ->
        Mix.raise(
          "expected #{@env_var} manifest #{path} to evaluate to a map, got: #{inspect(other)}"
        )
    end
  rescue
    e in [File.Error, Code.LoadError] ->
      Mix.raise("could not load #{@env_var} manifest #{path}: #{Exception.message(e)}")
  end
end
