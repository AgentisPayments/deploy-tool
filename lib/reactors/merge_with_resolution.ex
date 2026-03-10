defmodule Deploy.Reactors.MergeWithResolution do
  @moduledoc """
  Wrapper reactor that adds conflict resolution to the merge phase.

  Contains a single `AttemptMerge` step that wraps `Reactor.run(MergePRs, ...)`.
  When a merge conflict is detected, the step's `compensate/4` calls the
  ConflictResolver for human-approved resolution, then returns `:retry`.

  Replaces `compose :merge_prs, Deploy.Reactors.MergePRs` in FullDeploy.
  """

  use Reactor

  middlewares do
    middleware Deploy.Reactors.Middleware.EventBroadcaster
  end

  input :deploy_branch
  input :workspace
  input :client
  input :owner
  input :repo
  input :pr_numbers

  input :skip_reviews
  input :skip_ci
  input :skip_conflicts
  input :skip_validation

  step :attempt_merge, Deploy.Reactors.Steps.AttemptMerge do
    argument :deploy_branch, input(:deploy_branch)
    argument :workspace, input(:workspace)
    argument :client, input(:client)
    argument :owner, input(:owner)
    argument :repo, input(:repo)
    argument :pr_numbers, input(:pr_numbers)
    argument :skip_reviews, input(:skip_reviews)
    argument :skip_ci, input(:skip_ci)
    argument :skip_conflicts, input(:skip_conflicts)
    argument :skip_validation, input(:skip_validation)

    max_retries 5
  end

  return :attempt_merge
end
