defmodule Deploy.Config do
  @moduledoc """
  Configuration for the deployment tool.

  In production, you'd pull these from environment variables
  or application config.
  """

  def repo_url do
    System.get_env("DEPLOY_REPO_URL") ||
      raise "DEPLOY_REPO_URL environment variable not set"
  end

  def github_token do
    System.get_env("GITHUB_TOKEN") ||
      raise "GITHUB_TOKEN environment variable not set"
  end

  def slack_webhook_url do
    System.get_env("SLACK_WEBHOOK_URL")
  end

  def anthropic_api_key do
    System.get_env("ANTHROPIC_API_KEY")
  end

  def github_owner do
    # Extract from repo URL, e.g., "myorg" from "https://github.com/myorg/myrepo.git"
    repo_url()
    |> URI.parse()
    |> Map.get(:path)
    |> String.trim_leading("/")
    |> String.split("/")
    |> List.first()
  end

  def github_repo do
    # Extract from repo URL, e.g., "myrepo" from "https://github.com/myorg/myrepo.git"
    repo_url()
    |> URI.parse()
    |> Map.get(:path)
    |> String.trim_leading("/")
    |> String.split("/")
    |> List.last()
    |> String.trim_trailing(".git")
  end

  def deploy_date do
    Date.utc_today()
    |> Calendar.strftime("%Y%m%d")
  end
end
