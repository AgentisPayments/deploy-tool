defmodule Deploy.ConflictResolverTest do
  use ExUnit.Case, async: false

  import Mox

  alias Deploy.ConflictResolver

  setup :verify_on_exit!

  describe "fetch_pr/3" do
    test "calls git fetch with correct refspec" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: "/workspace"] ->
        {"", 0}
      end)

      assert :ok = ConflictResolver.fetch_pr("/workspace", 42)
    end

    test "returns error on fetch failure" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: "/workspace"] ->
        {"fatal: remote error", 128}
      end)

      assert {:error, msg} = ConflictResolver.fetch_pr("/workspace", 42)
      assert msg =~ "git fetch failed"
    end

    test "uses custom remote" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["fetch", "upstream", "pull/5/head:pr-5"], [cd: "/workspace"] ->
        {"", 0}
      end)

      assert :ok = ConflictResolver.fetch_pr("/workspace", 5, "upstream")
    end
  end

  describe "attempt_rebase/3" do
    test "returns :ok when rebase succeeds" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["checkout", "pr-10"], [cd: "/workspace"] ->
        {"Switched to branch 'pr-10'", 0}
      end)
      |> expect(:cmd, fn ["rebase", "deploy-20260101"], [cd: "/workspace"] ->
        {"Successfully rebased", 0}
      end)

      assert :ok = ConflictResolver.attempt_rebase("/workspace", 10, "deploy-20260101")
    end

    test "returns {:conflict, files} when rebase hits conflicts" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["checkout", "pr-10"], [cd: "/workspace"] ->
        {"Switched to branch 'pr-10'", 0}
      end)
      |> expect(:cmd, fn ["rebase", "deploy-20260101"], [cd: "/workspace"] ->
        {"CONFLICT (content): Merge conflict in lib/app.ex", 1}
      end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: "/workspace"] ->
        {"lib/app.ex\nlib/helper.ex\n", 0}
      end)

      assert {:conflict, ["lib/app.ex", "lib/helper.ex"]} =
               ConflictResolver.attempt_rebase("/workspace", 10, "deploy-20260101")
    end

    test "returns error when checkout fails" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["checkout", "pr-10"], [cd: "/workspace"] ->
        {"error: pathspec 'pr-10' did not match", 1}
      end)

      assert {:error, msg} = ConflictResolver.attempt_rebase("/workspace", 10, "deploy-20260101")
      assert msg =~ "git checkout failed"
    end
  end

  describe "read_conflicts/2" do
    test "returns ours/theirs/conflicted for each file" do
      workspace = System.tmp_dir!() |> Path.join("cr_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))

      conflicted = """
      defmodule App do
      <<<<<<< HEAD
        def hello, do: :world
      =======
        def hello, do: :universe
      >>>>>>> feature
      end
      """

      File.write!(Path.join(workspace, "lib/app.ex"), conflicted)

      Deploy.Git.Mock
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] ->
        {"defmodule App do\n  def hello, do: :world\nend\n", 0}
      end)
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] ->
        {"defmodule App do\n  def hello, do: :universe\nend\n", 0}
      end)

      assert {:ok, conflicts} = ConflictResolver.read_conflicts(workspace, ["lib/app.ex"])
      assert Map.has_key?(conflicts, "lib/app.ex")
      assert conflicts["lib/app.ex"].ours =~ "hello, do: :world"
      assert conflicts["lib/app.ex"].theirs =~ "hello, do: :universe"
      assert conflicts["lib/app.ex"].conflicted =~ "<<<<<<<"

      File.rm_rf!(workspace)
    end

    test "returns error when git show fails" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["show", ":2:missing.ex"], [cd: "/workspace"] ->
        {"fatal: path 'missing.ex' does not exist", 128}
      end)

      assert {:error, _} = ConflictResolver.read_conflicts("/workspace", ["missing.ex"])
    end
  end

  describe "apply_resolution/2" do
    test "writes files and stages them" do
      workspace = System.tmp_dir!() |> Path.join("cr_apply_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))

      Deploy.Git.Mock
      |> expect(:cmd, fn ["add", "lib/app.ex"], [cd: ^workspace] ->
        {"", 0}
      end)

      resolutions = %{"lib/app.ex" => "defmodule App do\n  def hello, do: :resolved\nend\n"}
      assert :ok = ConflictResolver.apply_resolution(workspace, resolutions)
      assert File.read!(Path.join(workspace, "lib/app.ex")) =~ ":resolved"

      File.rm_rf!(workspace)
    end

    test "stages multiple files" do
      workspace = System.tmp_dir!() |> Path.join("cr_multi_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))

      Deploy.Git.Mock
      |> expect(:cmd, fn ["add", "lib/a.ex"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["add", "lib/b.ex"], [cd: ^workspace] -> {"", 0} end)

      resolutions = %{
        "lib/a.ex" => "content a",
        "lib/b.ex" => "content b"
      }

      assert :ok = ConflictResolver.apply_resolution(workspace, resolutions)

      File.rm_rf!(workspace)
    end

    test "returns error when git add fails" do
      workspace = System.tmp_dir!() |> Path.join("cr_fail_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))

      Deploy.Git.Mock
      |> expect(:cmd, fn ["add", "lib/app.ex"], [cd: ^workspace] ->
        {"fatal: error", 128}
      end)

      resolutions = %{"lib/app.ex" => "content"}
      assert {:error, _} = ConflictResolver.apply_resolution(workspace, resolutions)

      File.rm_rf!(workspace)
    end
  end

  describe "continue_rebase/1" do
    test "returns :ok when rebase continues successfully" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["rebase", "--continue"], opts ->
        assert opts[:cd] == "/workspace"
        {"Successfully rebased", 0}
      end)

      assert :ok = ConflictResolver.continue_rebase("/workspace")
    end

    test "returns {:conflict, files} when next commit also conflicts" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["rebase", "--continue"], opts ->
        assert opts[:cd] == "/workspace"
        {"CONFLICT (content): Merge conflict in lib/other.ex", 1}
      end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: "/workspace"] ->
        {"lib/other.ex\n", 0}
      end)

      assert {:conflict, ["lib/other.ex"]} = ConflictResolver.continue_rebase("/workspace")
    end
  end

  describe "abort_rebase/1" do
    test "calls git rebase --abort" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["rebase", "--abort"], [cd: "/workspace"] ->
        {"", 0}
      end)

      assert :ok = ConflictResolver.abort_rebase("/workspace")
    end
  end

  describe "force_push_branch/4" do
    test "pushes with --force-with-lease" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["push", "--force-with-lease", "origin", "pr-42:feature-branch"],
                         [cd: "/workspace"] ->
        {"", 0}
      end)

      assert :ok = ConflictResolver.force_push_branch("/workspace", 42, "feature-branch")
    end

    test "returns error on push failure" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["push", "--force-with-lease", "origin", "pr-42:feature-branch"],
                         [cd: "/workspace"] ->
        {"rejected", 1}
      end)

      assert {:error, msg} = ConflictResolver.force_push_branch("/workspace", 42, "feature-branch")
      assert msg =~ "git push failed"
    end
  end

  describe "check_bailout/2" do
    test "returns :ok for normal files under threshold" do
      Deploy.Git.Mock
      |> expect(:cmd, 3, fn ["diff", "--numstat", "--cached", _file], [cd: "/workspace"] ->
        {"1\t1\tlib/a.ex", 0}
      end)

      assert :ok = ConflictResolver.check_bailout("/workspace", ["lib/a.ex", "lib/b.ex", "lib/c.ex"])
    end

    test "returns {:bailout, :too_many_files} when over threshold" do
      files = Enum.map(1..6, &"lib/file#{&1}.ex")
      assert {:bailout, :too_many_files} = ConflictResolver.check_bailout("/workspace", files)
    end

    test "returns {:bailout, :binary} for binary files" do
      Deploy.Git.Mock
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "image.png"], [cd: "/workspace"] ->
        {"-\t-\timage.png", 0}
      end)

      assert {:bailout, :binary} = ConflictResolver.check_bailout("/workspace", ["image.png"])
    end

    test "returns {:bailout, :lockfile} for lockfiles" do
      assert {:bailout, :lockfile} = ConflictResolver.check_bailout("/workspace", ["mix.lock"])
    end

    test "returns {:bailout, :lockfile} for package-lock.json" do
      assert {:bailout, :lockfile} = ConflictResolver.check_bailout("/workspace", ["package-lock.json"])
    end

    test "lockfile check takes precedence when mixed with normal files" do
      assert {:bailout, :lockfile} =
               ConflictResolver.check_bailout("/workspace", ["lib/app.ex", "mix.lock"])
    end
  end

  describe "resolve/5" do
    @workspace "/workspace"
    @deployment_id 123
    @pr_number 42
    @head_ref "feature-branch"
    @pr_context %{number: 42, title: "Add feature", description: "A new feature"}

    defp stub_claude_client(response) do
      Req.new(plug: fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => response}]
        })
      end)
    end

    defp base_opts(extra \\ %{}) do
      Map.merge(%{
        deployment_id: @deployment_id,
        pr_context: @pr_context,
        claude_client: nil
      }, extra)
    end

    defp send_decision_after(decision, delay \\ 10) do
      test_pid = self()
      _conflict_topic = "deployment:#{@deployment_id}:conflicts"

      spawn(fn ->
        # Subscribe to get the proposal event
        Phoenix.PubSub.subscribe(Deploy.PubSub, "deployment:#{@deployment_id}")
        Process.sleep(delay)

        case decision do
          {:approve, resolutions} ->
            send(test_pid, {:conflict_decision, nil, :approve, resolutions})

          :manual ->
            send(test_pid, {:conflict_decision, nil, :manual})

          :skip ->
            send(test_pid, {:conflict_decision, nil, :skip})
        end
      end)
    end

    test "full flow: conflict → Claude → approval → resolution applied → force push" do
      workspace = System.tmp_dir!() |> Path.join("resolve_full_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/app.ex"), "conflicted content with <<<<<<< markers")

      resolutions = %{"lib/app.ex" => "resolved content"}

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: ^workspace] -> {"", 0} end)
      # attempt_rebase: checkout
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: ^workspace] -> {"", 0} end)
      # attempt_rebase: rebase fails
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: ^workspace] -> {"CONFLICT", 1} end)
      # list conflicted files
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/app.ex\n", 0} end)
      # check_bailout: not binary
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/app.ex"], [cd: ^workspace] -> {"1\t1\tlib/app.ex", 0} end)
      # read_conflicts: ours
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] -> {"ours content", 0} end)
      # read_conflicts: theirs
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] -> {"theirs content", 0} end)
      # apply_resolution: git add
      |> expect(:cmd, fn ["add", "lib/app.ex"], [cd: ^workspace] -> {"", 0} end)
      # continue_rebase
      |> expect(:cmd, fn ["rebase", "--continue"], opts ->
        assert opts[:cd] == workspace
        {"", 0}
      end)
      # force_push_branch
      |> expect(:cmd, fn ["push", "--force-with-lease", "origin", "pr-42:feature-branch"], [cd: ^workspace] -> {"", 0} end)

      claude_client = stub_claude_client("resolved content")

      send_decision_after({:approve, resolutions})

      assert :ok =
               ConflictResolver.resolve(
                 workspace,
                 "deploy-20260301",
                 @pr_number,
                 @head_ref,
                 base_opts(%{claude_client: claude_client})
               )

      File.rm_rf!(workspace)
    end

    test "skip flow: user skips PR → rebase aborted" do
      workspace = System.tmp_dir!() |> Path.join("resolve_skip_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/app.ex"), "conflicted <<<<<<< markers")

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: ^workspace] -> {"CONFLICT", 1} end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/app.ex\n", 0} end)
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/app.ex"], [cd: ^workspace] -> {"1\t1\tlib/app.ex", 0} end)
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] -> {"ours", 0} end)
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] -> {"theirs", 0} end)
      |> expect(:cmd, fn ["rebase", "--abort"], [cd: ^workspace] -> {"", 0} end)

      send_decision_after(:skip)

      assert {:skip, 42} =
               ConflictResolver.resolve(
                 workspace,
                 "deploy-20260301",
                 @pr_number,
                 @head_ref,
                 base_opts()
               )

      File.rm_rf!(workspace)
    end

    test "manual flow: user resolved manually → rebase aborted" do
      workspace = System.tmp_dir!() |> Path.join("resolve_manual_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/app.ex"), "conflicted <<<<<<< markers")

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: ^workspace] -> {"CONFLICT", 1} end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/app.ex\n", 0} end)
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/app.ex"], [cd: ^workspace] -> {"1\t1\tlib/app.ex", 0} end)
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] -> {"ours", 0} end)
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] -> {"theirs", 0} end)
      # abort rebase from resolve_conflict_loop when decision is :manual
      |> expect(:cmd, fn ["rebase", "--abort"], [cd: ^workspace] -> {"", 0} end)

      send_decision_after(:manual)

      assert :ok =
               ConflictResolver.resolve(
                 workspace,
                 "deploy-20260301",
                 @pr_number,
                 @head_ref,
                 base_opts()
               )

      File.rm_rf!(workspace)
    end

    test "bailout flow: too many files → broadcast without proposals" do
      files = Enum.map(1..6, &"lib/file#{&1}.ex")
      file_list = Enum.join(files, "\n") <> "\n"

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: @workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: @workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: @workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: @workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: @workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: @workspace] -> {"CONFLICT", 1} end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: @workspace] -> {file_list, 0} end)
      |> expect(:cmd, fn ["rebase", "--abort"], [cd: @workspace] -> {"", 0} end)

      send_decision_after(:skip)

      assert {:skip, 42} =
               ConflictResolver.resolve(
                 @workspace,
                 "deploy-20260301",
                 @pr_number,
                 @head_ref,
                 base_opts()
               )
    end

    test "multi-commit: resolves conflict on first commit, then second" do
      workspace = System.tmp_dir!() |> Path.join("resolve_multi_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/app.ex"), "conflicted <<<<<<< markers")
      File.write!(Path.join(workspace, "lib/other.ex"), "conflicted <<<<<<< markers")

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: ^workspace] -> {"", 0} end)
      # checkout
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: ^workspace] -> {"", 0} end)
      # rebase fails (commit 1)
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: ^workspace] -> {"CONFLICT", 1} end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/app.ex\n", 0} end)
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/app.ex"], [cd: ^workspace] -> {"1\t1\t", 0} end)
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] -> {"ours1", 0} end)
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] -> {"theirs1", 0} end)
      # apply first resolution
      |> expect(:cmd, fn ["add", "lib/app.ex"], [cd: ^workspace] -> {"", 0} end)
      # continue rebase → conflict on commit 2
      |> expect(:cmd, fn ["rebase", "--continue"], opts ->
        assert opts[:cd] == workspace
        {"CONFLICT", 1}
      end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/other.ex\n", 0} end)
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/other.ex"], [cd: ^workspace] -> {"1\t1\t", 0} end)
      |> expect(:cmd, fn ["show", ":2:lib/other.ex"], [cd: ^workspace] -> {"ours2", 0} end)
      |> expect(:cmd, fn ["show", ":3:lib/other.ex"], [cd: ^workspace] -> {"theirs2", 0} end)
      # apply second resolution
      |> expect(:cmd, fn ["add", "lib/other.ex"], [cd: ^workspace] -> {"", 0} end)
      # continue rebase → success
      |> expect(:cmd, fn ["rebase", "--continue"], opts ->
        assert opts[:cd] == workspace
        {"", 0}
      end)
      # force push
      |> expect(:cmd, fn ["push", "--force-with-lease", "origin", "pr-42:feature-branch"], [cd: ^workspace] -> {"", 0} end)

      # Send two approve decisions (one per commit conflict)
      test_pid = self()
      spawn(fn ->
        Process.sleep(10)
        send(test_pid, {:conflict_decision, nil, :approve, %{"lib/app.ex" => "resolved1"}})
        Process.sleep(10)
        send(test_pid, {:conflict_decision, nil, :approve, %{"lib/other.ex" => "resolved2"}})
      end)

      assert :ok =
               ConflictResolver.resolve(
                 workspace,
                 "deploy-20260301",
                 @pr_number,
                 @head_ref,
                 base_opts()
               )

      File.rm_rf!(workspace)
    end

    test "Claude returns UNRESOLVABLE → broadcasts without proposals for that file" do
      workspace = System.tmp_dir!() |> Path.join("resolve_unresolvable_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/app.ex"), "conflicted <<<<<<< markers")

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: ^workspace] -> {"CONFLICT", 1} end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/app.ex\n", 0} end)
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/app.ex"], [cd: ^workspace] -> {"1\t1\t", 0} end)
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] -> {"ours", 0} end)
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] -> {"theirs", 0} end)
      |> expect(:cmd, fn ["rebase", "--abort"], [cd: ^workspace] -> {"", 0} end)

      claude_client = stub_claude_client("UNRESOLVABLE")

      send_decision_after(:skip)

      assert {:skip, 42} =
               ConflictResolver.resolve(
                 workspace,
                 "deploy-20260301",
                 @pr_number,
                 @head_ref,
                 base_opts(%{claude_client: claude_client})
               )

      File.rm_rf!(workspace)
    end

    test "PubSub: broadcast proposal is received by subscribers" do
      workspace = System.tmp_dir!() |> Path.join("resolve_pubsub_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(workspace, "lib"))
      File.write!(Path.join(workspace, "lib/app.ex"), "conflicted <<<<<<< markers")

      Phoenix.PubSub.subscribe(Deploy.PubSub, "deployment:#{@deployment_id}")

      Deploy.Git.Mock
      # update_deploy_branch
      |> expect(:cmd, fn ["fetch", "origin", "deploy-20260301:refs/remotes/origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["reset", "--hard", "origin/deploy-20260301"], [cd: ^workspace] -> {"", 0} end)
      # fetch_pr
      |> expect(:cmd, fn ["fetch", "origin", "pull/42/head:pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["checkout", "pr-42"], [cd: ^workspace] -> {"", 0} end)
      |> expect(:cmd, fn ["rebase", "deploy-20260301"], [cd: ^workspace] -> {"CONFLICT", 1} end)
      |> expect(:cmd, fn ["diff", "--name-only", "--diff-filter=U"], [cd: ^workspace] -> {"lib/app.ex\n", 0} end)
      |> expect(:cmd, fn ["diff", "--numstat", "--cached", "lib/app.ex"], [cd: ^workspace] -> {"1\t1\tlib/app.ex", 0} end)
      |> expect(:cmd, fn ["show", ":2:lib/app.ex"], [cd: ^workspace] -> {"ours", 0} end)
      |> expect(:cmd, fn ["show", ":3:lib/app.ex"], [cd: ^workspace] -> {"theirs", 0} end)
      |> expect(:cmd, fn ["rebase", "--abort"], [cd: ^workspace] -> {"", 0} end)

      send_decision_after(:skip)

      ConflictResolver.resolve(
        workspace,
        "deploy-20260301",
        @pr_number,
        @head_ref,
        base_opts()
      )

      assert_received {:conflict_proposed, _conflict_id, %{
        pr_number: 42,
        files: ["lib/app.ex"],
        proposals: nil,
        conflict_data: %{"lib/app.ex" => %{ours: "ours", theirs: "theirs", conflicted: _}}
      }}

      File.rm_rf!(workspace)
    end
  end
end
