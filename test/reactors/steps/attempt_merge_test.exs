defmodule Deploy.Reactors.Steps.AttemptMergeTest do
  use ExUnit.Case, async: false

  import Mox

  alias Deploy.Reactors.Steps.AttemptMerge

  setup :verify_on_exit!

  defp stub_client(plug), do: Req.new(plug: plug)

  @base_arguments %{
    deploy_branch: "deploy-20260301",
    workspace: "/workspace",
    client: nil,
    owner: "o",
    repo: "r",
    pr_numbers: [1],
    skip_reviews: false,
    skip_ci: false,
    skip_conflicts: false,
    skip_validation: false
  }

  @context %{deployment_id: 999}

  describe "run/3" do
    test "happy path: MergePRs succeeds → returns merged list" do
      call_count = :counters.new(1, [:atomics])

      client = stub_client(fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case {conn.method, count} do
          # partition_by_merge_status: GET /repos/o/r/pulls/1 (open PR)
          {"GET", 1} ->
            Req.Test.json(conn, %{"state" => "open", "merged_at" => nil})

          # FetchApprovedPRs: GET /repos/o/r/pulls/1
          {"GET", 2} ->
            Req.Test.json(conn, %{
              "number" => 1,
              "title" => "Feature",
              "head" => %{"ref" => "feature-1"}
            })

          # ValidatePRs: GET /repos/o/r/pulls/1/reviews
          {"GET", 3} ->
            Req.Test.json(conn, [
              %{"user" => %{"login" => "r"}, "state" => "APPROVED", "submitted_at" => "2026-01-01T00:00:00Z"}
            ])

          # ValidatePRs: GET /repos/o/r/commits/feature-1/check-runs
          {"GET", 4} ->
            Req.Test.json(conn, %{"check_runs" => [
              %{"name" => "test", "status" => "completed", "conclusion" => "success"}
            ]})

          # ChangePRBases: PATCH /repos/o/r/pulls/1
          {"PATCH", 5} ->
            Req.Test.json(conn, %{"number" => 1, "base" => %{"ref" => "deploy-20260301"}})

          # MergePRs: check_mergeable GET /repos/o/r/pulls/1
          {"GET", 6} ->
            Req.Test.json(conn, %{"mergeable" => true})

          # MergePRs: PUT /repos/o/r/pulls/1/merge
          {"PUT", 7} ->
            Req.Test.json(conn, %{"merged" => true, "sha" => "abc123"})
        end
      end)

      Deploy.Git.Mock
      |> expect(:cmd, fn ["pull", "origin", "deploy-20260301"], _opts ->
        {"Already up to date.", 0}
      end)

      arguments = %{@base_arguments | client: client}
      assert {:ok, merged} = AttemptMerge.run(arguments, @context, [])
      assert [%{number: 1, title: "Feature", sha: "abc123"}] = merged
    end

    test "filters out already-merged PRs on retry" do
      client = stub_client(fn conn ->
        # partition_by_merge_status returns PR as merged
        Req.Test.json(conn, %{
          "state" => "closed",
          "merged_at" => "2026-03-01T00:00:00Z",
          "title" => "Already Merged",
          "merge_commit_sha" => "deadbeef"
        })
      end)

      arguments = %{@base_arguments | client: client}
      assert {:ok, [merged]} = AttemptMerge.run(arguments, @context, [])
      assert merged.number == 1
      assert merged.title == "Already Merged"
    end

    test "merge conflict triggers handle_conflict, propagates error on failure" do
      call_count = :counters.new(1, [:atomics])

      client = stub_client(fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case {conn.method, count} do
          # partition check: PR is open
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

          # check_mergeable: PR has conflict
          {"GET", 6} ->
            Req.Test.json(conn, %{"mergeable" => false})

          # handle_conflict: get_pr for resolution — return 404 to short-circuit
          {"GET", 7} ->
            Plug.Conn.send_resp(conn, 404, Jason.encode!(%{"message" => "Not Found"}))
        end
      end)

      arguments = %{@base_arguments | client: client}
      assert {:error, _reason} = AttemptMerge.run(arguments, @context, [])
    end
  end
end
