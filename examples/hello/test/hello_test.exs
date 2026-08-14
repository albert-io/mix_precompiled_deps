defmodule HelloTest do
  use ExUnit.Case

  doctest Hello

  test "round-trips through the precompiled Jason" do
    assert Hello.greet("store") |> Jason.decode!() == %{"greeting" => "hello", "to" => "store"}
  end
end
