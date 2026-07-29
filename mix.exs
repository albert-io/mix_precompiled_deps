defmodule MixPrecompiledDeps.MixProject do
  use Mix.Project

  @source_url "https://github.com/albert-io/mix_precompiled_deps"
  @version "0.1.0"

  def project do
    [
      app: :mix_precompiled_deps,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: false,
      deps: [],
      description:
        "A Mix SCM that serves dependencies prebuilt by an external build system (Nix, Bazel, ...)",
      package: package(),
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
