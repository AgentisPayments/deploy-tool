defmodule Deploy.Claude do
  @moduledoc """
  Anthropic Messages API client for LLM-assisted conflict resolution.

  Sends conflict context to Claude and validates the response.
  """

  require Logger

  @base_url "https://api.anthropic.com"
  @model "claude-sonnet-4-5-20250929"
  @max_tokens 8192

  @conflict_markers ["<<<<<<<", "=======", ">>>>>>>"]

  @doc """
  Creates a configured Req client for the Anthropic API.
  """
  def client(api_key) do
    Req.new(
      base_url: @base_url,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]
    )
  end

  @doc """
  Asks Claude to resolve a merge conflict for a single file.

  ## Parameters
  - `client` - Req client configured with API key
  - `pr_context` - Map with `:number`, `:title`, `:description`
  - `file_path` - Path of the conflicted file
  - `conflict` - Map with `:ours`, `:theirs`, `:conflicted` content

  ## Returns
  - `{:ok, resolved_content}` on success
  - `{:error, :unresolvable}` when Claude responds with UNRESOLVABLE
  - `{:error, :conflict_markers}` when response contains conflict markers
  - `{:error, reason}` on API failure
  """
  def resolve_conflict(client, pr_context, file_path, conflict) do
    prompt = build_prompt(pr_context, file_path, conflict)

    body = %{
      model: @model,
      max_tokens: @max_tokens,
      messages: [
        %{role: "user", content: prompt}
      ]
    }

    case Req.post(client, url: "/v1/messages", json: body) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        validate_response(text)

      {:ok, %{status: status, body: body}} ->
        {:error, "Anthropic API error (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp build_prompt(pr_context, file_path, conflict) do
    lang_hint = language_hint(file_path)

    """
    You are resolving a git merge conflict during a deployment.

    ## Context
    PR ##{pr_context.number}: #{pr_context.title}
    PR Description: #{pr_context[:description] || "No description provided"}

    This PR's branch is being rebased onto the deploy branch. The following
    file has a conflict.

    ## File: #{file_path}#{lang_hint}

    ### Deploy branch version (ours):
    ```
    #{conflict.ours}
    ```

    ### PR branch version (theirs):
    ```
    #{conflict.theirs}
    ```

    ### Conflicted file with markers:
    ```
    #{conflict.conflicted}
    ```

    ## Instructions

    Resolve this conflict by producing the correct merged file content.
    Preserve the intent of both changes where possible. If the changes are
    genuinely incompatible and you cannot determine the correct resolution,
    respond with exactly: UNRESOLVABLE

    Return only the resolved file content, with no explanation or markdown
    formatting.
    """
  end

  defp validate_response(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "UNRESOLVABLE" ->
        {:error, :unresolvable}

      Enum.any?(@conflict_markers, &String.contains?(trimmed, &1)) ->
        {:error, :conflict_markers}

      true ->
        {:ok, trimmed}
    end
  end

  @extension_languages %{
    ".ex" => "Elixir",
    ".exs" => "Elixir",
    ".js" => "JavaScript",
    ".jsx" => "JavaScript (JSX)",
    ".ts" => "TypeScript",
    ".tsx" => "TypeScript (TSX)",
    ".py" => "Python",
    ".rb" => "Ruby",
    ".rs" => "Rust",
    ".go" => "Go",
    ".java" => "Java",
    ".kt" => "Kotlin",
    ".swift" => "Swift",
    ".css" => "CSS",
    ".scss" => "SCSS",
    ".html" => "HTML",
    ".json" => "JSON",
    ".yml" => "YAML",
    ".yaml" => "YAML",
    ".md" => "Markdown",
    ".sql" => "SQL",
    ".sh" => "Shell",
    ".bash" => "Bash"
  }

  defp language_hint(file_path) do
    ext = Path.extname(file_path)

    case Map.get(@extension_languages, ext) do
      nil -> ""
      lang -> " (#{lang})"
    end
  end
end
