defmodule Mix.Tasks.Deploy.TestConflict do
  @moduledoc """
  Creates a local fixture repo with scripted conflicts and runs the
  ConflictResolver against it for manual verification.

  ## Usage

      mix deploy.test_conflict [--live-api]

  ## Options

      --live-api    Use real Anthropic API instead of mock (requires ANTHROPIC_API_KEY)

  ## What It Does

  1. Runs `test/support/create_conflict_repo.sh` to create a bare repo with conflict scenarios
  2. Runs ConflictResolver git operations against the workspace
  3. Prints the conflict details and resolution result
  """

  use Mix.Task

  require Logger

  @shortdoc "Test conflict resolution against a local fixture repo"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [live_api: :boolean])

    Mix.shell().info("Creating fixture repo...")

    script = Path.join([File.cwd!(), "test", "support", "create_conflict_repo.sh"])

    {output, 0} = System.cmd("bash", [script], stderr_to_stdout: true)

    env =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    workspace = env["WORKSPACE"]
    deploy_branch = env["DEPLOY_BRANCH"]

    Mix.shell().info("Workspace: #{workspace}")
    Mix.shell().info("Deploy branch: #{deploy_branch}")

    # Use real git for manual testing
    Application.put_env(:deploy, :git_module, Deploy.Git.System)

    # Step 1: Fetch the conflicting PR
    Mix.shell().info("\n--- Fetching feature-conflict PR ---")

    # Simulate PR #1 by fetching the branch directly
    {_, 0} =
      System.cmd("git", ["fetch", "origin", "feature-conflict:pr-1"],
        cd: workspace,
        stderr_to_stdout: true
      )

    # Step 2: Attempt rebase
    Mix.shell().info("\n--- Attempting rebase ---")

    case Deploy.ConflictResolver.attempt_rebase(workspace, 1, deploy_branch) do
      :ok ->
        Mix.shell().info("Rebase succeeded — no conflicts!")

      {:conflict, files} ->
        Mix.shell().info("Conflict detected in: #{inspect(files)}")

        # Step 3: Check bailout
        case Deploy.ConflictResolver.check_bailout(workspace, files) do
          {:bailout, reason} ->
            Mix.shell().info("Bailout: #{reason}")

          :ok ->
            # Step 4: Read conflicts
            {:ok, conflicts} = Deploy.ConflictResolver.read_conflicts(workspace, files)

            for {file, data} <- conflicts do
              Mix.shell().info("\n=== #{file} ===")
              Mix.shell().info("--- Ours (deploy branch) ---")
              Mix.shell().info(data.ours)
              Mix.shell().info("--- Theirs (PR branch) ---")
              Mix.shell().info(data.theirs)
              Mix.shell().info("--- Conflicted ---")
              Mix.shell().info(data.conflicted)
            end

            if opts[:live_api] do
              resolve_with_api(workspace, conflicts)
            else
              Mix.shell().info("\nSkipping API resolution (use --live-api to test with real API)")
            end
        end

        # Clean up: abort the rebase
        Deploy.ConflictResolver.abort_rebase(workspace)

      {:error, reason} ->
        Mix.shell().error("Rebase failed: #{reason}")
    end

    # Clean up
    Mix.shell().info("\nCleaning up...")
    File.rm_rf!(env["BARE_REPO"])
    File.rm_rf!(workspace)
    Mix.shell().info("Done.")
  end

  defp resolve_with_api(_workspace, conflicts) do
    api_key = Deploy.Config.anthropic_api_key()

    if api_key do
      client = Deploy.Claude.client(api_key)
      pr_context = %{number: 1, title: "Feature conflict", description: "Test PR"}

      for {file, data} <- conflicts do
        Mix.shell().info("\n--- Asking Claude to resolve #{file} ---")

        case Deploy.Claude.resolve_conflict(client, pr_context, file, data) do
          {:ok, resolved} ->
            Mix.shell().info("Resolved content:")
            Mix.shell().info(resolved)

          {:error, reason} ->
            Mix.shell().info("Resolution failed: #{inspect(reason)}")
        end
      end
    else
      Mix.shell().info("ANTHROPIC_API_KEY not set, skipping API resolution")
    end
  end
end
