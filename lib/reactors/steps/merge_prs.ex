defmodule Deploy.Reactors.Steps.MergePRs do
  @moduledoc """
  Merges PRs sequentially via rebase merge.

  This is a point of no return — compensation logs a warning but cannot undo merges.
  """

  use Reactor.Step

  require Logger

  @impl true
  def run(%{client: client, owner: owner, repo: repo, prs: prs} = arguments, _context, _options) do
    skip_conflicts = Map.get(arguments, :skip_conflicts, false)

    prs
    |> Enum.reduce_while({:ok, []}, fn pr, {:ok, acc} ->
      with :ok <- maybe_update_branch(client, owner, repo, pr.number, acc),
           :ok <- check_mergeable(client, owner, repo, pr.number, skip_conflicts),
           {:ok, body} <- Deploy.GitHub.merge_pr(client, owner, repo, pr.number, merge_method: "rebase") do
        merged = %{
          number: pr.number,
          title: pr.title,
          sha: body["sha"]
        }

        Logger.info("Merged PR ##{pr.number}: #{pr.title}")
        {:cont, {:ok, [merged | acc]}}
      else
        {:error, reason} ->
          {:halt, {:error, "Failed to merge PR ##{pr.number}: #{inspect(reason)}"}}
      end
    end)
    |> then(fn
      {:ok, merged} -> {:ok, Enum.reverse(merged)}
      error -> error
    end)
  end

  # After the first merge, the base branch has changed so subsequent
  # PRs need their branches updated before they can merge.
  defp maybe_update_branch(_client, _owner, _repo, _pr_number, []), do: :ok

  defp maybe_update_branch(client, owner, repo, pr_number, _previous_merges) do
    case Deploy.GitHub.update_branch(client, owner, repo, pr_number) do
      {:ok, _} -> poll_until_mergeable(client, owner, repo, pr_number)
      {:error, reason} -> {:error, reason}
    end
  end

  # Check mergeable status before merge (with polling for nil)
  defp check_mergeable(_client, _owner, _repo, _pr_number, true), do: :ok

  defp check_mergeable(client, owner, repo, pr_number, false) do
    case poll_mergeable(client, owner, repo, pr_number) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:merge_conflict, pr_number}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp poll_mergeable(client, owner, repo, pr_number, attempts \\ 5) do
    case Deploy.GitHub.get_pr(client, owner, repo, pr_number) do
      {:ok, %{"mergeable" => true}} ->
        {:ok, true}

      {:ok, %{"mergeable" => false}} ->
        {:ok, false}

      {:ok, %{"mergeable" => nil}} when attempts > 0 ->
        Process.sleep(1_000)
        poll_mergeable(client, owner, repo, pr_number, attempts - 1)

      {:ok, %{"mergeable" => nil}} ->
        # Assume conflict if still nil after polling
        {:ok, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # update_branch returns 202 (async). Poll the PR until GitHub
  # reports it as mergeable, meaning the branch update is complete.
  defp poll_until_mergeable(client, owner, repo, pr_number, attempts \\ 10) do
    case Deploy.GitHub.get_pr(client, owner, repo, pr_number) do
      {:ok, %{"mergeable" => true}} ->
        :ok

      {:ok, _} when attempts > 0 ->
        Logger.info("PR ##{pr_number} not yet mergeable, waiting...")
        Process.sleep(2_000)
        poll_until_mergeable(client, owner, repo, pr_number, attempts - 1)

      {:ok, _} ->
        {:error, "PR ##{pr_number} still not mergeable after polling"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def compensate(_result, _arguments, _context, _options) do
    Logger.warning("MergePRs compensation called — merges cannot be undone")
    :ok
  end
end
