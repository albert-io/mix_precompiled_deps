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
      Mix.SCM.delete(SCM)
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

    test "loads the structured manifest format", %{
      tmp_dir: tmp_dir,
      build: build,
      dest: dest
    } do
      path = Path.join(tmp_dir, "structured.exs")

      File.write!(path, """
      %{
        lock: %{sha256: #{"0" |> String.duplicate(64) |> inspect()}},
        deps: %{
          "ecto" => %{dest: #{inspect(dest)}, build: #{inspect(build)}, version: "3.13.5"}
        }
      }
      """)

      enable!(path)

      assert Manifest.get() == %{
               deps: %{
                 "ecto" => %{dest: dest, build: build, version: "3.13.5"}
               },
               lock_sha256: String.duplicate("0", 64)
             }
    end

    test "raises on malformed dependency entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad-entry.exs")
      File.write!(path, "%{deps: %{\"ecto\" => %{dest: 123}}}")
      enable!(path)

      assert_raise Mix.Error, ~r/to have string dest and build paths/, fn ->
        MixPrecompiledDeps.enabled?()
      end
    end

    test "raises on a malformed lock digest", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad-lock.exs")
      File.write!(path, "%{lock: %{sha256: \"nope\"}, deps: %{}}")
      enable!(path)

      assert_raise Mix.Error, ~r/lowercase SHA-256 digest/, fn ->
        MixPrecompiledDeps.enabled?()
      end
    end
  end

  describe "project registration" do
    setup %{tmp_dir: tmp_dir, build: build, dest: dest} do
      original_env = Mix.env()
      Mix.env(:test)
      System.delete_env("MIX_PRECOMPILED_DEPS")
      Manifest.reload()

      lockfile = Path.join(tmp_dir, "mix.lock")
      File.write!(lockfile, "%{}")

      digest =
        lockfile
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      manifest_dir = Path.join(tmp_dir, "bundle")
      File.mkdir_p!(manifest_dir)

      File.write!(Path.join(manifest_dir, "deps-manifest-test.exs"), """
      %{
        lock: %{sha256: #{inspect(digest)}},
        deps: %{
          "ecto" => %{dest: #{inspect(dest)}, build: #{inspect(build)}, version: "3.13.5"}
        }
      }
      """)

      on_exit(fn -> Mix.env(original_env) end)

      %{manifest_dir: manifest_dir, lockfile: lockfile}
    end

    test "discovers the preferred environment manifest and validates the lock", %{
      tmp_dir: tmp_dir,
      manifest_dir: manifest_dir,
      lockfile: lockfile
    } do
      assert MixPrecompiledDeps.register(
               manifest_dir: manifest_dir,
               project_dir: tmp_dir,
               lockfile: Path.basename(lockfile)
             ) == :ok

      assert System.get_env("MIX_PRECOMPILED_DEPS") ==
               Path.join(manifest_dir, "deps-manifest-test.exs")
    end

    test "raises when the complete lock digest differs", %{
      tmp_dir: tmp_dir,
      manifest_dir: manifest_dir,
      lockfile: lockfile
    } do
      File.write!(lockfile, "%{changed: true}")

      assert_raise Mix.Error, ~r/built from a different mix.lock/, fn ->
        MixPrecompiledDeps.register(
          manifest_dir: manifest_dir,
          project_dir: tmp_dir,
          lockfile: Path.basename(lockfile)
        )
      end
    end

    test "is a no-op when the selected environment has no manifest", %{
      tmp_dir: tmp_dir,
      manifest_dir: manifest_dir
    } do
      Mix.env(:dev)

      assert MixPrecompiledDeps.register(
               manifest_dir: manifest_dir,
               project_dir: tmp_dir
             ) == :noop
    end

    test "raises when the manifest directory pointer is broken", %{tmp_dir: tmp_dir} do
      manifest_dir = Path.join(tmp_dir, "broken")
      File.ln_s!(Path.join(tmp_dir, "missing"), manifest_dir)

      assert_raise File.Error, ~r/could not stat/, fn ->
        MixPrecompiledDeps.register(
          manifest_dir: manifest_dir,
          project_dir: tmp_dir
        )
      end
    end

    test "the project hook runs after Mix selects its preferred environment", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.lock"), "%{}")
      File.mkdir_p!(Path.join(tmp_dir, "bundle"))

      digest =
        tmp_dir
        |> Path.join("mix.lock")
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      File.write!(
        Path.join(tmp_dir, "bundle/deps-manifest-test.exs"),
        "%{lock: %{sha256: #{inspect(digest)}}, deps: %{}}"
      )

      File.write!(Path.join(tmp_dir, "bundle/deps-manifest-dev.exs"), "[:wrong, :environment]")

      File.write!(Path.join(tmp_dir, "mix.exs"), """
      defmodule HookTest.MixProject do
        use Mix.Project

        if Code.ensure_loaded?(MixPrecompiledDeps) do
          use MixPrecompiledDeps, manifest_dir: "bundle"
        end

        def project do
          [app: :hook_test, version: "0.1.0", deps: []]
        end

        def cli do
          [preferred_envs: [format: :test]]
        end
      end
      """)

      test_lib = Path.expand("../_build/test/lib", __DIR__)

      erl_libs =
        [test_lib, System.get_env("ERL_LIBS")]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(":")

      assert {_, 0} =
               System.cmd("mix", ["format", "--check-formatted", "mix.exs"],
                 cd: tmp_dir,
                 env: [{"ERL_LIBS", erl_libs}],
                 stderr_to_stdout: true
               )
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
