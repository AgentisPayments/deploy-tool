defmodule DeployWeb.NewDeploymentLive do
  @moduledoc """
  LiveView for starting a new deployment.
  """

  use DeployWeb, :live_view

  alias Deploy.Deployments.Runner

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "New Deployment",
        selected_prs: [],
        deploy_date: Deploy.Config.deploy_date(),
        skip_reviews: false,
        skip_ci: false,
        skip_conflicts: false,
        error: nil,
        submitting: false
      )
      |> start_async(:load_prs, fn ->
        client = Deploy.GitHub.client(Deploy.Config.github_token())
        owner = Deploy.Config.github_owner()
        repo = Deploy.Config.github_repo()
        Deploy.GitHub.list_prs(client, owner, repo)
      end)

    {:ok, socket}
  end

  @impl true
  def handle_async(:load_prs, {:ok, {:ok, raw_prs}}, socket) do
    prs =
      raw_prs
      |> Enum.reject(fn pr -> String.starts_with?(pr["title"] || "", "Deploy") end)
      |> Enum.map(fn pr ->
        %{
          number: pr["number"],
          title: pr["title"],
          author: get_in(pr, ["user", "login"]) || "ghost",
          labels: Enum.map(pr["labels"] || [], & &1["name"])
        }
      end)

    {:noreply, push_event(socket, "prs_loaded", %{prs: prs})}
  end

  def handle_async(:load_prs, {:ok, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Failed to load PRs for picker: #{inspect(reason)}")
    {:noreply, push_event(socket, "prs_loaded", %{prs: []})}
  end

  def handle_async(:load_prs, {:exit, reason}, socket) do
    require Logger
    Logger.warning("PR loading crashed: #{inspect(reason)}")
    {:noreply, push_event(socket, "prs_loaded", %{prs: []})}
  end

  @impl true
  def handle_event("add_pr", %{"number" => number} = params, socket) do
    number = to_integer(number)
    title = params["title"]

    selected = socket.assigns.selected_prs

    if Enum.any?(selected, &(&1.number == number)) do
      {:noreply, socket}
    else
      pr = %{number: number, title: title}
      {:noreply, assign(socket, selected_prs: selected ++ [pr], error: nil)}
    end
  end

  def handle_event("remove_pr", %{"number" => number}, socket) do
    number = to_integer(number)
    selected = Enum.reject(socket.assigns.selected_prs, &(&1.number == number))
    {:noreply, assign(socket, selected_prs: selected)}
  end

  def handle_event("remove_last_pr", _params, socket) do
    case socket.assigns.selected_prs do
      [] -> {:noreply, socket}
      prs -> {:noreply, assign(socket, selected_prs: Enum.drop(prs, -1))}
    end
  end

  def handle_event("validate", params, socket) do
    {:noreply,
     assign(socket,
       skip_reviews: params["skip_reviews"] == "true",
       skip_ci: params["skip_ci"] == "true",
       skip_conflicts: params["skip_conflicts"] == "true",
       error: nil
     )}
  end

  def handle_event("submit", params, socket) do
    require Logger
    Logger.info("Submit params: #{inspect(params)}")
    pr_numbers = Enum.map(socket.assigns.selected_prs, & &1.number)

    cond do
      pr_numbers == [] ->
        {:noreply, assign(socket, error: "Please select at least one PR")}

      socket.assigns.submitting ->
        {:noreply, socket}

      true ->
        socket = assign(socket, submitting: true, error: nil)

        opts = build_opts(pr_numbers, params) |> Keyword.put(:created_by_id, socket.assigns.current_user.id)
        Logger.info("Built opts: #{inspect(opts)}")

        case Runner.start_deployment(opts) do
          {:ok, _pid, deployment} ->
            {:noreply,
             socket
             |> put_flash(:info, "Deployment started!")
             |> push_navigate(to: ~p"/deployments/#{deployment.id}")}

          {:error, {:deployment_exists, id}} ->
            {:noreply,
             socket
             |> assign(submitting: false, error: nil)
             |> put_flash(:error, "A deployment is already active")
             |> push_navigate(to: ~p"/deployments/#{id}")}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               submitting: false,
               error: "Failed to start deployment: #{inspect(reason)}"
             )}
        end
    end
  end

  defp build_opts(pr_numbers, params) do
    opts = [pr_numbers: pr_numbers]

    opts =
      if params["skip_reviews"] == "true",
        do: Keyword.put(opts, :skip_reviews, true),
        else: opts

    opts =
      if params["skip_ci"] == "true",
        do: Keyword.put(opts, :skip_ci, true),
        else: opts

    opts =
      if params["skip_conflicts"] == "true",
        do: Keyword.put(opts, :skip_conflicts, true),
        else: opts

    opts
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)
end
