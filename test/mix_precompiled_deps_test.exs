defmodule MixPrecompiledDepsTest do
  use ExUnit.Case, async: false

  alias MixPrecompiledDeps.{Manifest, SCM}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    build = Path.join(tmp_dir, "store/ecto-3.13.5/lib/erlang/lib/ecto-3.13.5")
    dest = Path.join(tmp_dir, "store/ecto-3.13.5/src")
    File.mkdir_p!(Path.join(build, "ebin"))
    File.mkdir_p!(dest)

    manifest_path = Path.join(tmp_dir, "manifest.exs")

    File.write!(manifest_path, """
    %{
      "ecto" => %{
        dest: #{inspect(dest)},
        build: #{inspect(build)},
        version: "3.13.5"
      },
      "unversioned" => %{
        dest: #{inspect(dest)},
        build: #{inspect(build)}
      }
    }
    """)

    on_exit(fn ->
      System.delete_env("MIX_PRECOMPILED_DEPS")
      Manifest.reload()
    end)

    %{manifest_path: manifest_path, build: build, dest: dest}
  end

  defp enable!(manifest_path) do
    System.put_env("MIX_PRECOMPILED_DEPS", manifest_path)
    Manifest.reload()
  end

  describe "enabled?/0 and register/0" do
    test "disabled without the env var" do
      System.delete_env("MIX_PRECOMPILED_DEPS")
      Manifest.reload()

      refute MixPrecompiledDeps.enabled?()
      assert MixPrecompiledDeps.register() == :noop
    end

    test "registers the SCM first when enabled", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      assert MixPrecompiledDeps.enabled?()
      assert MixPrecompiledDeps.register() == :ok
      assert [MixPrecompiledDeps.SCM | _] = Mix.SCM.available()
    after
      Mix.SCM.delete(MixPrecompiledDeps.SCM)
    end

    test "raises on a manifest that is not a map", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.exs")
      File.write!(path, "[:not, :a, :map]")
      enable!(path)

      assert_raise Mix.Error, ~r/to evaluate to a map/, fn ->
        MixPrecompiledDeps.enabled?()
      end
    end

    test "raises on a missing manifest file", %{tmp_dir: tmp_dir} do
      enable!(Path.join(tmp_dir, "nope.exs"))

      assert_raise Mix.Error, ~r/could not load/, fn ->
        MixPrecompiledDeps.enabled?()
      end
    end
  end

  describe "accepts_options/2" do
    test "claims manifest deps with their store paths", %{
      manifest_path: manifest_path,
      build: build,
      dest: dest
    } do
      enable!(manifest_path)

      opts = SCM.accepts_options(:ecto, [])
      assert opts[:dest] == dest
      assert opts[:build] == build
      assert opts[:precompiled] == true
      assert opts[:precompiled_version] == "3.13.5"
    end

    test "leaves path/git deps to their SCMs", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      assert SCM.accepts_options(:someday, path: "../someday") == nil
      assert SCM.accepts_options(:someday, git: "https://example.com/x.git") == nil
      assert SCM.accepts_options(:someday, github: "x/y") == nil
    end

    test "claims absent hex-bound deps as unavailable", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      opts = SCM.accepts_options(:simple_sat, optional: true)
      assert opts[:precompiled] == true
      refute SCM.checked_out?(opts)
    end
  end

  describe "checked_out?/1 and lock_status/1" do
    test "checked_out? reflects the build dir", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      opts = SCM.accepts_options(:ecto, [])
      assert SCM.checked_out?(opts)
    end

    test "lock_status is :ok when versions agree", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      opts = SCM.accepts_options(:ecto, [])
      lock = {:hex, :ecto, "3.13.5", "abc", [:mix], [], "hexpm", "def"}
      assert SCM.lock_status(Keyword.put(opts, :lock, lock)) == :ok
    end

    test "lock_status is :outdated on version drift", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      opts = SCM.accepts_options(:ecto, [])
      lock = {:hex, :ecto, "3.14.0", "abc", [:mix], [], "hexpm", "def"}
      assert SCM.lock_status(Keyword.put(opts, :lock, lock)) == :outdated
    end

    test "lock_status is :ok without a version or lock", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      opts = SCM.accepts_options(:unversioned, [])
      lock = {:hex, :unversioned, "9.9.9", "abc", [:mix], [], "hexpm", "def"}
      assert SCM.lock_status(Keyword.put(opts, :lock, lock)) == :ok

      opts = SCM.accepts_options(:ecto, [])
      assert SCM.lock_status(opts) == :ok
    end
  end

  describe "immutability" do
    test "checkout and update raise", %{manifest_path: manifest_path} do
      enable!(manifest_path)

      opts = SCM.accepts_options(:ecto, []) |> Keyword.put(:app, :ecto)

      assert_raise Mix.Error, ~r/prebuilt through the MIX_PRECOMPILED_DEPS manifest/, fn ->
        SCM.checkout(opts)
      end

      assert_raise Mix.Error, ~r/prebuilt through the MIX_PRECOMPILED_DEPS manifest/, fn ->
        SCM.update(opts)
      end
    end
  end
end
