defmodule Deploy.Reactors.Steps.CreateDeployPR do
  @moduledoc """
  Creates the deploy pull request targeting staging.

  Compensation: closes the PR.
  """

  use Reactor.Step

  require Logger

  @impl true
  def run(
        %{client: client, owner: owner, repo: repo, deploy_branch: deploy_branch},
        _context,
        _options
      ) do
    title = format_title(deploy_branch)

    attrs = %{
      title: title,
      head: deploy_branch,
      base: "staging",
      body: ""
    }

    with {:ok, body} <- Deploy.GitHub.create_pr(client, owner, repo, attrs) do
      {:ok, %{number: body["number"], url: body["html_url"]}}
    end
  end

  @impl true
  def compensate(%{number: pr_number}, arguments, _context, _options) do
    client = arguments.client
    owner = arguments.owner
    repo = arguments.repo

    Logger.info("Compensating: closing deploy PR ##{pr_number}")

    case Deploy.GitHub.update_pr(client, owner, repo, pr_number, %{state: "closed"}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to close deploy PR ##{pr_number}: #{inspect(reason)}")
        :ok
    end
  end

  # deploy-20260201 → "Deploy 2026-02-01"
  defp format_title("deploy-" <> date) do
    <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>> = date
    "Deploy: #{y}-#{m}-#{d}"
  end

  defp format_title(branch), do: "Deploy: #{branch}"
end
