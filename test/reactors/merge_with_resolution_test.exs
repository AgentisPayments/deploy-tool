defmodule Deploy.Reactors.MergeWithResolutionTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  defp stub_client(plug), do: Req.new(plug: plug)

  test "happy path: no conflicts, PRs merge successfully" do
    call_count = :counters.new(1, [:atomics])

    client = stub_client(fn conn ->
      :counters.add(call_count, 1, 1)
      count = :counters.get(call_count, 1)

      case {conn.method, count} do
        # AttemptMerge partition check: PR is open
        {"GET", 1} ->
          Req.Test.json(conn, %{"state" => "open", "merged_at" => nil})

        # FetchApprovedPRs
        {"GET", 2} ->
          Req.Test.json(conn, %{
            "number" => 1,
            "title" => "Feature",
            "head" => %{"ref" => "feature-1"}
          })

        # ValidatePRs: reviews
        {"GET", 3} ->
          Req.Test.json(conn, [
            %{"user" => %{"login" => "r"}, "state" => "APPROVED", "submitted_at" => "2026-01-01T00:00:00Z"}
          ])

        # ValidatePRs: CI
        {"GET", 4} ->
          Req.Test.json(conn, %{"check_runs" => [
            %{"name" => "test", "status" => "completed", "conclusion" => "success"}
          ]})

        # ChangePRBases
        {"PATCH", 5} ->
          Req.Test.json(conn, %{"number" => 1, "base" => %{"ref" => "deploy-20260301"}})

        # MergePRs: check_mergeable
        {"GET", 6} ->
          Req.Test.json(conn, %{"mergeable" => true})

        # MergePRs: merge
        {"PUT", 7} ->
          Req.Test.json(conn, %{"merged" => true, "sha" => "abc123"})
      end
    end)

    Deploy.Git.Mock
    |> expect(:cmd, fn ["pull", "origin", "deploy-20260301"], _opts ->
      {"Already up to date.", 0}
    end)

    inputs = %{
      deploy_branch: "deploy-20260301",
      workspace: "/tmp/test-workspace",
      client: client,
      owner: "o",
      repo: "r",
      pr_numbers: [1],
      skip_reviews: false,
      skip_ci: false,
      skip_conflicts: false,
      skip_validation: false
    }

    assert {:ok, [merged]} = Reactor.run(Deploy.Reactors.MergeWithResolution, inputs)
    assert merged.number == 1
    assert merged.sha == "abc123"
  end
end
