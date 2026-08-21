defmodule PtcLlmHttp.HexReleaseScriptTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/ci/hex-release.sh", __DIR__)
  @version Mix.Project.config()[:version]
  @clean_git_environment Enum.map(
                           ~w(
                             GIT_ALTERNATE_OBJECT_DIRECTORIES
                             GIT_COMMON_DIR
                             GIT_CONFIG
                             GIT_CONFIG_COUNT
                             GIT_CONFIG_PARAMETERS
                             GIT_DIR
                             GIT_GRAFT_FILE
                             GIT_IMPLICIT_WORK_TREE
                             GIT_INDEX_FILE
                             GIT_NO_REPLACE_OBJECTS
                             GIT_OBJECT_DIRECTORY
                             GIT_PREFIX
                             GIT_REPLACE_REF_BASE
                             GIT_SHALLOW_FILE
                             GIT_WORK_TREE
                           ),
                           &{&1, nil}
                         )

  test "accepts the current version for a main dry run" do
    assert {"", 0} = run(@version, "dry-run", "refs/heads/main")
  end

  test "accepts combined prerelease and build metadata as SemVer" do
    assert {output, 1} = run("1.2.3-rc.1+build.7", "dry-run", "refs/heads/main")
    assert output =~ "mix.exs version #{@version} does not match 1.2.3-rc.1+build.7"
    refute output =~ "invalid release version"
  end

  test "rejects invalid versions before constructing a tag" do
    assert {output, 64} = run("not-semver", "publish", "refs/heads/main")
    assert output =~ "invalid release version: not-semver"
  end

  test "rejects dispatches outside main" do
    assert {output, 1} = run(@version, "dry-run", "refs/heads/topic")
    assert output =~ "Hex release workflow must be dispatched from main"
  end

  test "publish accepts a remote tag naming the dispatched main commit" do
    repo = fixture_repo(:matching)

    assert {_output, 0} = run("0.0.1", "publish", "refs/heads/main", repo)
    assert {"", 1} = git(["symbolic-ref", "--short", "-q", "HEAD"], repo)
  end

  test "publish rejects a remote tag naming a different commit" do
    repo = fixture_repo(:mismatched)

    assert {output, 1} = run("0.0.1", "publish", "refs/heads/main", repo)
    assert output =~ "refs/tags/v0.0.1 does not name the dispatched main commit"
  end

  defp run(version, mode, github_ref, directory \\ File.cwd!()) do
    System.cmd(@script, [version, mode, github_ref],
      cd: directory,
      env: @clean_git_environment,
      stderr_to_stdout: true
    )
  end

  defp fixture_repo(tag_position) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    root =
      Path.join(
        System.tmp_dir!(),
        "ptc_llm_http_hex_release_#{nonce}"
      )

    repo = Path.join(root, "repo")
    remote = Path.join(root, "remote.git")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(["init", "--bare", remote], root)
    git!(["init", "-b", "main", repo], root)
    git!(["config", "user.name", "Release Test"], repo)
    git!(["config", "user.email", "release-test@example.invalid"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)

    File.write!(
      Path.join(repo, "mix.exs"),
      """
      defmodule HexReleaseFixture.MixProject do
        use Mix.Project
        def project, do: [app: :hex_release_fixture, version: "0.0.1"]
      end
      """
    )

    File.write!(Path.join(repo, "README.md"), "release candidate\n")
    git!(["add", "mix.exs", "README.md"], repo)
    git!(["commit", "-m", "release candidate"], repo)
    git!(["tag", "--annotate", "--no-sign", "--message", "v0.0.1", "v0.0.1"], repo)

    if tag_position == :mismatched do
      File.write!(Path.join(repo, "README.md"), "main advanced\n")
      git!(["add", "README.md"], repo)
      git!(["commit", "-m", "advance main"], repo)
    end

    git!(["remote", "add", "origin", remote], repo)
    git!(["push", "origin", "main", "refs/tags/v0.0.1"], repo)
    repo
  end

  defp git!(arguments, directory) do
    case git(arguments, directory) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(arguments, " ")} failed (#{status}): #{output}")
    end
  end

  defp git(arguments, directory) do
    System.cmd("git", arguments,
      cd: directory,
      env: @clean_git_environment,
      stderr_to_stdout: true
    )
  end
end
