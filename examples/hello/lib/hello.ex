defmodule Hello do
  @moduledoc """
  A minimal project whose only dependency, `jason`, is served prebuilt from
  the Nix store when compiled as a flake check. See `../../README.md`.
  """

  @doc """
  Returns a JSON greeting.

      iex> Hello.greet("world") |> Jason.decode!()
      %{"greeting" => "hello", "to" => "world"}

  """
  def greet(name) do
    Jason.encode!(%{greeting: "hello", to: name})
  end
end
