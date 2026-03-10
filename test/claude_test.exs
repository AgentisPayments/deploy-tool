defmodule Deploy.ClaudeTest do
  use ExUnit.Case, async: true

  alias Deploy.Claude

  defp stub_client(plug), do: Req.new(plug: plug)

  @pr_context %{number: 42, title: "Add feature", description: "A new feature"}
  @file_path "lib/app.ex"
  @conflict %{
    ours: "defmodule App do\n  def hello, do: :world\nend\n",
    theirs: "defmodule App do\n  def hello, do: :universe\nend\n",
    conflicted: "defmodule App do\n<<<<<<< HEAD\n  def hello, do: :world\n=======\n  def hello, do: :universe\n>>>>>>> feature\nend\n"
  }

  describe "resolve_conflict/4" do
    test "returns resolved content on success" do
      client = stub_client(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] =~ "claude"
        assert [%{"role" => "user", "content" => prompt}] = decoded["messages"]
        assert prompt =~ "PR #42"
        assert prompt =~ "Add feature"
        assert prompt =~ "lib/app.ex"
        assert prompt =~ "hello, do: :world"
        assert prompt =~ "hello, do: :universe"

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "defmodule App do\n  def hello, do: :both\nend\n"}]
        })
      end)

      assert {:ok, resolved} = Claude.resolve_conflict(client, @pr_context, @file_path, @conflict)
      assert resolved =~ ":both"
    end

    test "returns {:error, :unresolvable} when response is UNRESOLVABLE" do
      client = stub_client(fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "UNRESOLVABLE"}]
        })
      end)

      assert {:error, :unresolvable} =
               Claude.resolve_conflict(client, @pr_context, @file_path, @conflict)
    end

    test "returns {:error, :conflict_markers} when response contains markers" do
      bad_response = "defmodule App do\n<<<<<<< HEAD\n  def hello, do: :world\n=======\n  def hello, do: :universe\n>>>>>>> feature\nend"

      client = stub_client(fn conn ->
        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => bad_response}]
        })
      end)

      assert {:error, :conflict_markers} =
               Claude.resolve_conflict(client, @pr_context, @file_path, @conflict)
    end

    test "returns error on API failure (non-200)" do
      client = stub_client(fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, msg} = Claude.resolve_conflict(client, @pr_context, @file_path, @conflict)
      assert msg =~ "429"
    end

    test "includes language hint from file extension" do
      client = stub_client(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [%{"content" => prompt}] = decoded["messages"]
        assert prompt =~ "(Elixir)"

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "resolved"}]
        })
      end)

      assert {:ok, _} = Claude.resolve_conflict(client, @pr_context, "lib/app.ex", @conflict)
    end

    test "includes language hint for TypeScript" do
      client = stub_client(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [%{"content" => prompt}] = decoded["messages"]
        assert prompt =~ "(TypeScript)"

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "resolved"}]
        })
      end)

      assert {:ok, _} = Claude.resolve_conflict(client, @pr_context, "src/app.ts", @conflict)
    end

    test "handles missing PR description" do
      context = %{number: 1, title: "Fix"}

      client = stub_client(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [%{"content" => prompt}] = decoded["messages"]
        assert prompt =~ "No description provided"

        Req.Test.json(conn, %{
          "content" => [%{"type" => "text", "text" => "resolved"}]
        })
      end)

      assert {:ok, _} = Claude.resolve_conflict(client, context, @file_path, @conflict)
    end
  end

  describe "client/1" do
    test "creates Req client with correct headers" do
      client = Claude.client("sk-test-key")
      assert %Req.Request{} = client

      assert client.headers["x-api-key"] == ["sk-test-key"]
      assert client.headers["anthropic-version"] == ["2023-06-01"]
    end
  end
end
