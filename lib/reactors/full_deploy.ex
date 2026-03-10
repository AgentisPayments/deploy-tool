defmodule Deploy.Reactors.FullDeploy do
  @moduledoc """
  Composed reactor for the full deployment workflow.

  Orchestrates three phases:
  1. Setup - Creates workspace and deploy branch
  2. MergePRs - Validates and merges PRs into deploy branch
  3. DeployPR - Bumps version, creates PR, requests review

  This reactor can be used to generate mermaid diagrams representing
  the complete deployment flow.
  """

  use Reactor

  middlewares do
    middleware Deploy.Reactors.Middleware.EventBroadcaster
  end

  # Config inputs (used to build derived values)
  input :repo_url
  input :github_token
  input :deploy_date
  input :client
  input :owner
  input :repo

  # PR selection
  input :pr_numbers

  # Validation options
  input :skip_reviews
  input :skip_ci
  input :skip_conflicts
  input :skip_validation

  # Deploy PR options
  input :reviewers

  # Phase 1: Setup
  compose :setup, Deploy.Reactors.Setup do
    argument :repo_url, input(:repo_url)
    argument :github_token, input(:github_token)
    argument :deploy_date, input(:deploy_date)
  end

  # Phase 2: Merge PRs (with conflict resolution)
  compose :merge_prs, Deploy.Reactors.MergeWithResolution do
    argument :deploy_branch, result(:setup, [:branch])
    argument :workspace, result(:setup, [:workspace])
    argument :client, input(:client)
    argument :owner, input(:owner)
    argument :repo, input(:repo)
    argument :pr_numbers, input(:pr_numbers)
    argument :skip_reviews, input(:skip_reviews)
    argument :skip_ci, input(:skip_ci)
    argument :skip_conflicts, input(:skip_conflicts)
    argument :skip_validation, input(:skip_validation)
  end

  # Phase 3: Create Deploy PR
  compose :deploy_pr, Deploy.Reactors.DeployPR do
    argument :workspace, result(:setup, [:workspace])
    argument :deploy_branch, result(:setup, [:branch])
    argument :merged_prs, result(:merge_prs)
    argument :client, input(:client)
    argument :owner, input(:owner)
    argument :repo, input(:repo)
    argument :reviewers, input(:reviewers)
  end

  # Aggregate final result
  step :deploy_pr_prepared, Deploy.Reactors.Steps.ReturnMap do
    argument :branch, result(:setup, [:branch])
    argument :workspace, result(:setup, [:workspace])
    argument :merged_prs, result(:merge_prs)
    argument :pr_number, result(:deploy_pr, [:number])
    argument :pr_url, result(:deploy_pr, [:url])

    max_retries 0
  end

  return :deploy_pr_prepared
end
