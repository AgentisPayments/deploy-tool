defmodule Deploy.Reactors.Steps.AttemptMerge do
  @moduledoc """
  Retry-capable wrapper step that runs the MergePRs sub-reactor and handles
  merge conflicts via ConflictResolver.

  On conflict, calls the resolver inline for human-approved resolution, then
  loops back to retry the merge. Already-merged PRs are filtered out via
  GitHub API (idempotency).

  Skipped PRs (user chose "skip" during conflict resolution) are tracked in an
  ETS table keyed by deployment_id and excluded from subsequent retries.
  """

  use Reactor.Step

  require Logger

  @ets_table :attempt_merge_state
  @max_conflict_rounds 10

  @impl true
  def run(arguments, context, _options) do
    ensure_ets_table()
    deployment_id = Map.get(context, :deployment_id)

    merge_with_resolution(arguments, deployment_id, 0)
  end

  defp merge_with_resolution(_arguments, _deployment_id, round) when round >= @max_conflict_rounds do
    {:error, "exceeded maximum conflict resolution rounds (#{@max_conflict_rounds})"}
  end

  defp merge_with_resolution(arguments, deployment_id, round) do
    skipped = get_skipped_prs(deployment_id)
    pr_numbers = arguments.pr_numbers

    # Filter out skipped PRs
    active_pr_numbers = Enum.reject(pr_numbers, &(&1 in skipped))

    # Filter out already-merged PRs via GitHub API
    {already_merged, to_merge} =
      partition_by_merge_status(arguments.client, arguments.owner, arguments.repo, active_pr_numbers)

    if to_merge == [] do
      {:ok, already_merged}
    else
      inputs = %{
        deploy_branch: arguments.deploy_branch,
        workspace: arguments.workspace,
        client: arguments.client,
        owner: arguments.owner,
        repo: arguments.repo,
        pr_numbers: to_merge,
        skip_reviews: Map.get(arguments, :skip_reviews, false),
        skip_ci: Map.get(arguments, :skip_ci, false),
        skip_conflicts: Map.get(arguments, :skip_conflicts, false),
        skip_validation: Map.get(arguments, :skip_validation, false)
      }

      case Reactor.run(Deploy.Reactors.MergePRs, inputs) do
        {:ok, newly_merged} ->
          {:ok, already_merged ++ newly_merged}

        {:error, errors} ->
          case extract_merge_conflict(errors) do
            {:merge_conflict, pr_number} ->
              case handle_conflict(arguments, deployment_id, pr_number) do
                :retry ->
                  merge_with_resolution(arguments, deployment_id, round + 1)

                {:error, reason} ->
                  {:error, reason}
              end

            nil ->
              {:error, errors}
          end
      end
    end
  end

  defp handle_conflict(arguments, deployment_id, pr_number) do
    Logger.info("AttemptMerge: merge conflict on PR ##{pr_number}, starting resolution")

    case Deploy.GitHub.get_pr(arguments.client, arguments.owner, arguments.repo, pr_number) do
      {:ok, %{"head" => %{"ref" => head_ref}, "title" => title, "body" => body}} ->
        claude_client = build_claude_client()

        opts = %{
          deployment_id: deployment_id,
          pr_context: %{number: pr_number, title: title, description: body},
          claude_client: claude_client
        }

        result = Deploy.ConflictResolver.resolve(
          arguments.workspace,
          arguments.deploy_branch,
          pr_number,
          head_ref,
          opts
        )

        Logger.info("AttemptMerge: ConflictResolver returned #{inspect(result)}")

        case result do
          :ok ->
            Logger.info("Conflict resolved for PR ##{pr_number}, retrying merge")
            :retry

          {:skip, ^pr_number} ->
            Logger.info("PR ##{pr_number} skipped by user, retrying without it")
            add_skipped_pr(deployment_id, pr_number)
            :retry

          {:error, reason} ->
            Logger.error("Conflict resolution failed for PR ##{pr_number}: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, pr_data} ->
        Logger.error("AttemptMerge: PR ##{pr_number} response missing expected fields: #{inspect(Map.keys(pr_data))}")
        {:error, "unexpected PR response shape"}

      {:error, reason} ->
        Logger.error("Failed to fetch PR ##{pr_number}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Private: Merge conflict extraction
  # ============================================================================

  defp extract_merge_conflict(errors) when is_list(errors) do
    Enum.find_value(errors, &extract_merge_conflict/1)
  end

  # Reactor.Error.Invalid{errors: [...]} — Splode wrapper from Reactor.run
  defp extract_merge_conflict(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &extract_merge_conflict/1)
  end

  # Reactor.Error.Invalid.RunStepError{error: reason}
  defp extract_merge_conflict(%{error: error}), do: extract_merge_conflict(error)
  defp extract_merge_conflict(%{message: msg}) when is_binary(msg), do: parse_conflict_string(msg)

  defp extract_merge_conflict(error) when is_binary(error), do: parse_conflict_string(error)

  defp extract_merge_conflict(error) do
    # Fallback: convert to string and try to parse
    parse_conflict_string(inspect(error))
  end

  defp parse_conflict_string(str) do
    case Regex.run(~r/\{:merge_conflict, (\d+)\}/, str) do
      [_, pr_str] -> {:merge_conflict, String.to_integer(pr_str)}
      nil -> nil
    end
  end

  # ============================================================================
  # Private: PR merge status partitioning
  # ============================================================================

  defp partition_by_merge_status(_client, _owner, _repo, []), do: {[], []}

  defp partition_by_merge_status(client, owner, repo, pr_numbers) do
    Enum.reduce(pr_numbers, {[], []}, fn pr_number, {merged, unmerged} ->
      case Deploy.GitHub.get_pr(client, owner, repo, pr_number) do
        {:ok, %{"state" => "closed", "merged_at" => merged_at} = pr} when not is_nil(merged_at) ->
          merged_pr = %{
            number: pr_number,
            title: pr["title"],
            sha: get_in(pr, ["merge_commit_sha"])
          }

          {[merged_pr | merged], unmerged}

        _ ->
          {merged, [pr_number | unmerged]}
      end
    end)
    |> then(fn {merged, unmerged} ->
      {Enum.reverse(merged), Enum.reverse(unmerged)}
    end)
  end

  # ============================================================================
  # Private: Claude client
  # ============================================================================

  defp build_claude_client do
    case Deploy.Config.anthropic_api_key() do
      nil ->
        Logger.warning("ANTHROPIC_API_KEY not set — conflict resolution will skip LLM proposals")
        nil

      key ->
        Deploy.Claude.client(key)
    end
  end

  # ============================================================================
  # Private: ETS-based skip tracking
  # ============================================================================

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_skipped_prs(nil), do: []

  defp get_skipped_prs(deployment_id) do
    case :ets.lookup(@ets_table, {:skipped, deployment_id}) do
      [{_, prs}] -> prs
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp add_skipped_pr(nil, _pr_number), do: :ok

  defp add_skipped_pr(deployment_id, pr_number) do
    current = get_skipped_prs(deployment_id)
    :ets.insert(@ets_table, {{:skipped, deployment_id}, [pr_number | current]})
  rescue
    ArgumentError -> :ok
  end
end
