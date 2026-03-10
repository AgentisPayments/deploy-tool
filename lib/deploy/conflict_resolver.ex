defmodule Deploy.ConflictResolver do
  @moduledoc """
  Handles merge conflict resolution through local git operations.

  Works entirely with local git (fetch, rebase, read conflicts, apply resolution,
  force-push). Does not use the GitHub API directly — the AttemptMerge step
  above handles that.
  """

  require Logger

  @pubsub Deploy.PubSub
  @max_conflict_files 5
  @lockfiles ~w(mix.lock package-lock.json yarn.lock pnpm-lock.yaml Gemfile.lock composer.lock Cargo.lock poetry.lock)

  # ============================================================================
  # Full Resolution Flow
  # ============================================================================

  @doc """
  Resolves a merge conflict for a PR by rebasing onto the deploy branch,
  asking Claude for a resolution proposal, and waiting for human approval.

  ## Parameters
  - `workspace` - Path to the local git workspace
  - `deploy_branch` - Name of the deploy branch to rebase onto
  - `pr_number` - The PR number
  - `head_ref` - The PR's head branch ref (for force-push)
  - `opts` - Options map with:
    - `:deployment_id` - Required for PubSub routing
    - `:pr_context` - Map with `:number`, `:title`, `:description`
    - `:claude_client` - Configured Req client for Anthropic API (optional)

  ## Returns
  - `:ok` if the conflict was resolved and force-pushed
  - `{:skip, pr_number}` if the user chose to skip this PR
  - `{:error, reason}` on failure
  """
  def resolve(workspace, deploy_branch, pr_number, head_ref, opts) do
    deployment_id = opts[:deployment_id]
    pr_context = opts[:pr_context] || %{number: pr_number, title: "PR ##{pr_number}"}
    claude_client = opts[:claude_client]

    Logger.info("ConflictResolver.resolve: workspace=#{workspace} deploy_branch=#{deploy_branch} pr=#{pr_number} head_ref=#{head_ref}")
    Logger.info("ConflictResolver.resolve: workspace exists?=#{File.dir?(workspace)}")

    # Subscribe to the conflicts topic for decisions
    conflict_topic = "deployment:#{deployment_id}:conflicts"
    Phoenix.PubSub.subscribe(@pubsub, conflict_topic)

    with :ok <- log_step("update_deploy_branch", update_deploy_branch(workspace, deploy_branch)),
         :ok <- log_step("fetch_pr", fetch_pr(workspace, pr_number)) do
      case attempt_rebase(workspace, pr_number, deploy_branch) do
        :ok ->
          # No conflict — rebase succeeded cleanly
          force_push_branch(workspace, pr_number, head_ref)

        {:conflict, files} ->
          resolve_conflict_loop(workspace, deploy_branch, pr_number, head_ref, files, opts, pr_context, claude_client, deployment_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  after
    deployment_id = opts[:deployment_id]
    Phoenix.PubSub.unsubscribe(@pubsub, "deployment:#{deployment_id}:conflicts")
  end

  defp resolve_conflict_loop(workspace, _deploy_branch, pr_number, head_ref, files, opts, pr_context, claude_client, deployment_id) do
    case resolve_single_conflict(workspace, pr_number, files, opts, pr_context, claude_client, deployment_id) do
      :ok ->
        # Conflict resolved locally, continue rebase (may hit another commit's conflicts)
        case continue_rebase(workspace) do
          :ok ->
            force_push_branch(workspace, pr_number, head_ref)

          {:conflict, next_files} ->
            resolve_conflict_loop(workspace, nil, pr_number, head_ref, next_files, opts, pr_context, claude_client, deployment_id)

          {:error, reason} ->
            abort_rebase(workspace)
            {:error, reason}
        end

      :manual ->
        # User resolved externally on GitHub — abort local rebase and return success
        abort_rebase(workspace)
        :ok

      {:skip, _} = skip ->
        abort_rebase(workspace)
        skip

      {:error, reason} ->
        abort_rebase(workspace)
        {:error, reason}
    end
  end

  defp resolve_single_conflict(workspace, pr_number, files, _opts, pr_context, claude_client, deployment_id) do
    case check_bailout(workspace, files) do
      {:bailout, reason} ->
        broadcast_proposal(deployment_id, pr_number, pr_context, files, nil, nil, reason)
        wait_for_decision(workspace, pr_number, deployment_id)

      :ok ->
        {:ok, conflict_data} = read_conflicts(workspace, files)
        proposals = propose_resolutions(claude_client, pr_context, conflict_data)
        broadcast_proposal(deployment_id, pr_number, pr_context, files, proposals, conflict_data, nil)
        wait_for_decision(workspace, pr_number, deployment_id)
    end
  end

  defp propose_resolutions(nil, _pr_context, _conflict_data), do: nil

  defp propose_resolutions(claude_client, pr_context, conflict_data) do
    Enum.reduce(conflict_data, %{}, fn {file, data}, acc ->
      case Deploy.Claude.resolve_conflict(claude_client, pr_context, file, data) do
        {:ok, resolved} ->
          Map.put(acc, file, resolved)

        {:error, reason} ->
          Logger.warning("Claude could not resolve #{file}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp broadcast_proposal(deployment_id, pr_number, pr_context, files, proposals, conflict_data, bailout_reason) do
    conflict_id = "conflict-#{deployment_id}-#{pr_number}-#{System.unique_integer([:positive])}"

    event = {:conflict_proposed, conflict_id, %{
      pr_number: pr_number,
      pr_context: pr_context,
      files: files,
      proposals: proposals,
      conflict_data: conflict_data,
      bailout_reason: bailout_reason
    }}

    Phoenix.PubSub.broadcast(@pubsub, "deployment:#{deployment_id}", event)
  end

  defp wait_for_decision(workspace, pr_number, _deployment_id) do
    receive do
      {:conflict_decision, _conflict_id, :approve, resolutions} ->
        case apply_resolution(workspace, resolutions) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:conflict_decision, _conflict_id, :manual} ->
        :manual

      {:conflict_decision, _conflict_id, :skip} ->
        {:skip, pr_number}
    end
  end

  # ============================================================================
  # Git Operations
  # ============================================================================

  @doc """
  Updates the local deploy branch to match the remote.

  MergePRs operates via the GitHub API, so the local deploy branch falls
  behind after PRs are merged remotely. This ensures the local branch has
  the latest state before we attempt to rebase a PR onto it.
  """
  def update_deploy_branch(workspace, deploy_branch, remote \\ "origin") do
    with :ok <- git(["fetch", remote, "#{deploy_branch}:refs/remotes/#{remote}/#{deploy_branch}"], workspace),
         :ok <- git(["checkout", deploy_branch], workspace),
         :ok <- git(["reset", "--hard", "#{remote}/#{deploy_branch}"], workspace) do
      :ok
    end
  end

  @doc """
  Fetches a PR's head ref into a local branch named `pr-{number}`.
  """
  def fetch_pr(workspace, pr_number, remote \\ "origin") do
    git(["fetch", remote, "pull/#{pr_number}/head:pr-#{pr_number}"], workspace)
  end

  @doc """
  Checks out the PR branch and attempts to rebase it onto the deploy branch.

  Returns:
  - `:ok` if the rebase succeeds with no conflicts
  - `{:conflict, files}` if the rebase hits conflicts, where `files` is a list of conflicted file paths
  """
  def attempt_rebase(workspace, pr_number, deploy_branch) do
    branch = "pr-#{pr_number}"

    with :ok <- git(["checkout", branch], workspace) do
      case Deploy.Git.cmd(["rebase", deploy_branch], cd: workspace) do
        {_output, 0} ->
          :ok

        {_output, _code} ->
          case list_conflicted_files(workspace) do
            {:ok, files} -> {:conflict, files}
            error -> error
          end
      end
    end
  end

  @doc """
  Reads the conflict state for each file, returning a map of
  `%{file_path => %{ours: content, theirs: content, conflicted: content}}`.

  - `:2:file` is "ours" (the deploy branch side during rebase)
  - `:3:file` is "theirs" (the PR branch side during rebase)
  - The working tree copy contains conflict markers
  """
  def read_conflicts(workspace, files) do
    results =
      Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
        with {:ok, ours} <- git_output(["show", ":2:#{file}"], workspace),
             {:ok, theirs} <- git_output(["show", ":3:#{file}"], workspace),
             {:ok, conflicted} <- read_file(workspace, file) do
          entry = %{ours: ours, theirs: theirs, conflicted: conflicted}
          {:cont, {:ok, Map.put(acc, file, entry)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    results
  end

  @doc """
  Writes resolved file contents and stages them with `git add`.
  `resolutions` is a map of `%{file_path => resolved_content}`.
  """
  def apply_resolution(workspace, resolutions) do
    Enum.reduce_while(resolutions, :ok, fn {file, content}, :ok ->
      file_path = Path.join(workspace, file)

      with :ok <- File.write(file_path, content),
           :ok <- git(["add", file], workspace) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Continues the rebase after conflicts have been resolved.

  Returns:
  - `:ok` if the rebase completes successfully
  - `{:conflict, files}` if another commit in the rebase has conflicts
  """
  def continue_rebase(workspace) do
    case Deploy.Git.cmd(["rebase", "--continue"], cd: workspace, env: [{"GIT_EDITOR", "true"}]) do
      {_output, 0} ->
        :ok

      {_output, _code} ->
        case list_conflicted_files(workspace) do
          {:ok, files} -> {:conflict, files}
          error -> error
        end
    end
  end

  @doc """
  Aborts an in-progress rebase.
  """
  def abort_rebase(workspace) do
    git(["rebase", "--abort"], workspace)
  end

  @doc """
  Force-pushes the local PR branch to the remote head ref using --force-with-lease.
  """
  def force_push_branch(workspace, pr_number, head_ref, remote \\ "origin") do
    branch = "pr-#{pr_number}"
    git(["push", "--force-with-lease", remote, "#{branch}:#{head_ref}"], workspace)
  end

  # ============================================================================
  # Bailout Detection
  # ============================================================================

  @doc """
  Checks whether the conflicted files should trigger a bailout (skip LLM resolution).

  Returns:
  - `:ok` if resolution can proceed
  - `{:bailout, :too_many_files}` if more than the threshold
  - `{:bailout, :binary}` if any file is binary
  - `{:bailout, :lockfile}` if any file is a lockfile
  """
  def check_bailout(workspace, files) do
    cond do
      length(files) > @max_conflict_files ->
        {:bailout, :too_many_files}

      Enum.any?(files, &lockfile?/1) ->
        {:bailout, :lockfile}

      Enum.any?(files, &binary_file?(workspace, &1)) ->
        {:bailout, :binary}

      true ->
        :ok
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp git(args, workspace) do
    case Deploy.Git.cmd(args, cd: workspace) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "git #{hd(args)} failed (exit #{code}): #{output}"}
    end
  end

  defp git_output(args, workspace) do
    case Deploy.Git.cmd(args, cd: workspace) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "git #{hd(args)} failed (exit #{code}): #{output}"}
    end
  end

  defp read_file(workspace, file) do
    Path.join(workspace, file)
    |> File.read()
    |> case do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read #{file}: #{inspect(reason)}"}
    end
  end

  defp list_conflicted_files(workspace) do
    case Deploy.Git.cmd(["diff", "--name-only", "--diff-filter=U"], cd: workspace) do
      {output, 0} ->
        files = output |> String.trim() |> String.split("\n", trim: true)
        {:ok, files}

      {output, code} ->
        {:error, "git diff failed (exit #{code}): #{output}"}
    end
  end

  defp binary_file?(workspace, file) do
    case Deploy.Git.cmd(["diff", "--numstat", "--cached", file], cd: workspace) do
      {output, 0} -> String.starts_with?(output, "-\t-\t")
      _ -> false
    end
  end

  defp lockfile?(file) do
    Path.basename(file) in @lockfiles
  end

  defp log_step(name, result) do
    case result do
      :ok ->
        Logger.info("ConflictResolver #{name}: ok")
        :ok

      {:error, reason} = err ->
        Logger.error("ConflictResolver #{name}: FAILED — #{inspect(reason)}")
        err
    end
  end
end
