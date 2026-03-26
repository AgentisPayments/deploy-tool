defmodule Mix.Tasks.Deploy.SeedConflict do
  @moduledoc """
  Creates 3 issues and 3 PRs on the configured GitHub repo where PR #3
  has a non-trivial merge conflict with PR #2.

  ## Usage

      mix deploy.seed_conflict

  ## What It Does

  1. Clones the repo to a temp directory
  2. Creates 3 feature branches off `staging`:
     - `seed/feat-1` — adds a new file (no conflict)
     - `seed/feat-2` — modifies `text.md` and `version.txt`
     - `seed/feat-3` — modifies the same files differently (conflicts with feat-2)
  3. Pushes the branches to the remote
  4. Creates 3 GitHub issues
  5. Creates 3 PRs that close the corresponding issues

  ## Cleanup

      mix deploy.seed_conflict --cleanup

  Closes the PRs and deletes the remote branches.
  """

  use Mix.Task

  require Logger

  @shortdoc "Seed 3 issues + PRs on fake-repo with a merge conflict scenario"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: [cleanup: :boolean])

    token = Deploy.Config.github_token()
    owner = Deploy.Config.github_owner()
    repo = Deploy.Config.github_repo()
    repo_url = Deploy.Config.repo_url()
    client = Deploy.GitHub.client(token)

    if opts[:cleanup] do
      cleanup(client, owner, repo)
    else
      seed(client, owner, repo, repo_url, token)
    end
  end

  defp seed(client, owner, repo, repo_url, token) do
    workspace = Path.join(System.tmp_dir!(), "seed-conflict-#{System.unique_integer([:positive])}")

    Mix.shell().info("Cloning #{repo_url} into #{workspace}...")

    auth_url = inject_token(repo_url, token)
    {_, 0} = System.cmd("git", ["clone", auth_url, workspace], stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "deploy-tool@test.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Deploy Tool"], cd: workspace)

    {_, 0} = System.cmd("git", ["checkout", "staging"], cd: workspace, stderr_to_stdout: true)

    # --- Branch 1: adds a new file, no conflict ---
    Mix.shell().info("\nCreating seed/feat-1 (no conflict)...")
    {_, 0} = System.cmd("git", ["checkout", "-b", "seed/feat-1", "staging"], cd: workspace, stderr_to_stdout: true)

    File.write!(Path.join(workspace, "CHANGELOG.md"), """
    # Changelog

    ## v2.11.0 (Unreleased)

    ### Added
    - New notification system for deployment alerts
    - Email and SMS integration endpoints

    ### Changed
    - Improved error handling in backend services

    ### Fixed
    - Fixed race condition in concurrent deployments
    """)

    git_commit!(workspace, "Add CHANGELOG.md")
    git_push!(workspace, "seed/feat-1")

    # --- Branch 2: modifies text.md and version.txt ---
    Mix.shell().info("Creating seed/feat-2 (modifies text.md + version.txt)...")
    {_, 0} = System.cmd("git", ["checkout", "-b", "seed/feat-2", "staging"], cd: workspace, stderr_to_stdout: true)

    File.write!(Path.join(workspace, "text.md"), """
    # Project Documentation

    ## Overview
    This project provides a deployment orchestration tool
    that automates the release process.

    ## Features
    - Automated PR validation and merging
    - Version bumping across all packages
    - Deploy branch management

    ## Configuration
    Set the following environment variables:
    - `GITHUB_TOKEN` — GitHub personal access token
    - `DEPLOY_REPO_URL` — Repository URL to deploy

    ## Usage
    Run `mix deploy` to start a new deployment.
    """)

    File.write!(Path.join(workspace, "version.txt"), "2.11.0\n")
    File.write!(Path.join(workspace, "backend/version.txt"), "2.11.0\n")

    File.write!(Path.join(workspace, "frontend/package.json"), """
    {
      "name": "frontend",
      "version": "2.11.0",
      "description": "Frontend application",
      "scripts": {
        "build": "vite build",
        "dev": "vite dev",
        "test": "vitest"
      }
    }
    """)

    git_commit!(workspace, "Update docs, bump all versions to 2.11.0")
    git_push!(workspace, "seed/feat-2")

    # --- Branch 3: modifies the same files differently (conflicts with feat-2) ---
    Mix.shell().info("Creating seed/feat-3 (conflicts with feat-2)...")
    {_, 0} = System.cmd("git", ["checkout", "-b", "seed/feat-3", "staging"], cd: workspace, stderr_to_stdout: true)

    File.write!(Path.join(workspace, "text.md"), """
    # Deployment Tool

    ## About
    A comprehensive deployment pipeline that handles
    the entire release lifecycle from PR review to production.

    ## Key Capabilities
    - Smart merge conflict detection and resolution
    - LLM-assisted conflict resolution via Claude
    - Automated CI/CD status checking
    - Review enforcement with configurable policies

    ## Getting Started
    1. Set `GITHUB_TOKEN` and `DEPLOY_REPO_URL`
    2. Run the Phoenix server: `mix phx.server`
    3. Navigate to the deployments page
    4. Select PRs and start a deployment

    ## Architecture
    The tool uses the Reactor pattern for orchestrating
    multi-step deployment workflows with compensation support.
    """)

    File.write!(Path.join(workspace, "version.txt"), "3.0.0-rc.1\n")
    File.write!(Path.join(workspace, "backend/version.txt"), "3.0.0-rc.1\n")

    File.write!(Path.join(workspace, "frontend/package.json"), """
    {
      "name": "deploy-frontend",
      "version": "3.0.0-rc.1",
      "description": "Deployment tool frontend",
      "scripts": {
        "build": "vite build",
        "dev": "vite dev --host",
        "test": "vitest run",
        "lint": "eslint src/"
      },
      "dependencies": {
        "phoenix_live_view": "^1.0.0"
      }
    }
    """)

    git_commit!(workspace, "Rewrite docs, bump to 3.0.0-rc.1, add lint script and deps")
    git_push!(workspace, "seed/feat-3")

    # --- Create issues ---
    Mix.shell().info("\nCreating GitHub issues...")

    {:ok, issue1} = create_issue(client, owner, repo, "Add CHANGELOG", """
    We need a CHANGELOG.md to track release notes across versions.
    """)

    {:ok, issue2} = create_issue(client, owner, repo, "Update docs and bump to 2.11.0", """
    Rewrite text.md with proper project documentation and bump all version
    files to 2.11.0 for the upcoming release.
    """)

    {:ok, issue3} = create_issue(client, owner, repo, "Major rewrite: docs, versions, and tooling", """
    Comprehensive rewrite of documentation with architecture details.
    Bump to 3.0.0-rc.1. Add lint script and Phoenix LiveView dependency
    to frontend package.json.
    """)

    Mix.shell().info("  Created issue ##{issue1["number"]}: #{issue1["title"]}")
    Mix.shell().info("  Created issue ##{issue2["number"]}: #{issue2["title"]}")
    Mix.shell().info("  Created issue ##{issue3["number"]}: #{issue3["title"]}")

    # --- Create PRs ---
    Mix.shell().info("\nCreating pull requests...")

    {:ok, pr1} = Deploy.GitHub.create_pr(client, owner, repo, %{
      title: "Add CHANGELOG",
      body: "Closes ##{issue1["number"]}\n\nAdds a CHANGELOG.md with initial release notes.",
      head: "seed/feat-1",
      base: "staging"
    })

    {:ok, pr2} = Deploy.GitHub.create_pr(client, owner, repo, %{
      title: "Update docs and bump to 2.11.0",
      body: "Closes ##{issue2["number"]}\n\nRewrites `text.md` with project docs. Bumps all version files to 2.11.0.",
      head: "seed/feat-2",
      base: "staging"
    })

    {:ok, pr3} = Deploy.GitHub.create_pr(client, owner, repo, %{
      title: "Major rewrite: docs, versions, and tooling",
      body: "Closes ##{issue3["number"]}\n\nRewrites `text.md` with architecture docs. Bumps to 3.0.0-rc.1. Adds lint and deps to frontend.\n\n> **Note:** This will conflict with ##{pr2["number"]} in `text.md`, `version.txt`, `backend/version.txt`, and `frontend/package.json`.",
      head: "seed/feat-3",
      base: "staging"
    })

    Mix.shell().info("  Created PR ##{pr1["number"]}: #{pr1["title"]}")
    Mix.shell().info("  Created PR ##{pr2["number"]}: #{pr2["title"]}")
    Mix.shell().info("  Created PR ##{pr3["number"]}: #{pr3["title"]}")

    Mix.shell().info("""

    Done! Created:
      - 3 issues (##{issue1["number"]}, ##{issue2["number"]}, ##{issue3["number"]})
      - 3 PRs (##{pr1["number"]}, ##{pr2["number"]}, ##{pr3["number"]})
      - PR ##{pr3["number"]} will conflict with PR ##{pr2["number"]}

    To clean up: mix deploy.seed_conflict --cleanup
    """)

    File.rm_rf!(workspace)
  end

  defp cleanup(client, owner, repo) do
    Mix.shell().info("Cleaning up seed branches and PRs...")

    for branch <- ["seed/feat-1", "seed/feat-2", "seed/feat-3"] do
      case Req.get(client, url: "/repos/#{owner}/#{repo}/pulls", params: %{head: "#{owner}:#{branch}", state: "open"}) do
        {:ok, %{status: 200, body: prs}} ->
          for pr <- prs do
            Mix.shell().info("  Closing PR ##{pr["number"]}: #{pr["title"]}")
            Deploy.GitHub.close_pr(client, owner, repo, pr["number"])
          end

        _ ->
          :ok
      end

      case Req.delete(client, url: "/repos/#{owner}/#{repo}/git/refs/heads/#{branch}") do
        {:ok, %{status: 204}} ->
          Mix.shell().info("  Deleted branch #{branch}")

        {:ok, %{status: 422, body: %{"message" => "Reference does not exist"}}} ->
          Mix.shell().info("  Branch #{branch} already deleted")

        {:ok, %{status: status}} ->
          Mix.shell().info("  Failed to delete #{branch} (#{status})")

        _ ->
          :ok
      end
    end

    Mix.shell().info("Cleanup done.")
  end

  defp inject_token(url, token) do
    uri = URI.parse(url)
    %{uri | userinfo: token} |> URI.to_string()
  end

  defp git_commit!(workspace, message) do
    {_, 0} = System.cmd("git", ["add", "-A"], cd: workspace, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-m", message], cd: workspace, stderr_to_stdout: true)
  end

  defp git_push!(workspace, branch) do
    {_, 0} = System.cmd("git", ["push", "--force", "-u", "origin", branch], cd: workspace, stderr_to_stdout: true)
  end

  defp create_issue(client, owner, repo, title, body) do
    case Req.post(client, url: "/repos/#{owner}/#{repo}/issues", json: %{title: title, body: body}) do
      {:ok, %{status: 201, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "Failed to create issue (#{status}): #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
