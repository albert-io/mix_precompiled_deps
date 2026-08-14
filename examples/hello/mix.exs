defmodule Hello.MixProject do
  use Mix.Project

  # No-op when the package is absent (ordinary environments) or when no
  # manifest is configured, so `mix deps.get` and friends work as usual.
  if Code.ensure_loaded?(MixPrecompiledDeps) do
    MixPrecompiledDeps.install(__MODULE__)
  end

  def project do
    [
      app: :hello,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end
end
