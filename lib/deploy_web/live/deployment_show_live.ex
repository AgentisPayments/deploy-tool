defmodule DeployWeb.DeploymentShowLive do
  @moduledoc """
  LiveView for viewing a deployment with real-time updates.
  """

  use DeployWeb, :live_view

  alias Deploy.Deployments
  alias Deploy.Deployments.Events
  alias Deploy.Deployments.Registry
  alias Deploy.Deployments.Runner

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Deployments.get_deployment(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Deployment not found")
         |> push_navigate(to: ~p"/")}

      deployment ->
        deployment = Deployments.load_deployment_with_assocs(deployment)

        if connected?(socket) do
          Events.subscribe(deployment.id)
        end

        {:ok,
         assign(socket,
           page_title: "Deployment ##{deployment.id}",
           deployment: deployment,
           steps: deployment.steps,
           merged_prs: deployment.merged_prs,
           error: nil,
           is_active: Registry.is_active?(deployment.id),
           conflict: nil
         )}
    end
  end

  @impl true
  def handle_event("resume", _params, socket) do
    deployment = socket.assigns.deployment

    # Carry over skip options from the original deployment
    opts = [
      pr_numbers: deployment.pr_numbers,
      deploy_date: deployment.deploy_date,
      resume: true,
      skip_reviews: deployment.skip_reviews,
      skip_ci: deployment.skip_ci,
      skip_conflicts: deployment.skip_conflicts
    ]

    case Runner.start_deployment(opts) do
      {:ok, _pid, new_deployment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deployment resumed!")
         |> push_navigate(to: ~p"/deployments/#{new_deployment.id}")}

      {:error, {:deployment_exists, existing_id}} ->
        {:noreply,
         socket
         |> put_flash(:error, "A deployment is already active")
         |> push_navigate(to: ~p"/deployments/#{existing_id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(error: "Failed to resume: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel", _params, socket) do
    deployment = socket.assigns.deployment

    case Registry.lookup(deployment.id) do
      {:ok, pid} ->
        Runner.cancel(pid)

        {:noreply,
         socket
         |> put_flash(:info, "Deployment cancelled")}

      :error ->
        {:noreply,
         socket
         |> assign(error: "Deployment is not running")}
    end
  end

  def handle_event("approve_resolution", _params, socket) do
    conflict = socket.assigns.conflict
    deployment_id = socket.assigns.deployment.id
    topic = "deployment:#{deployment_id}:conflicts"

    Phoenix.PubSub.broadcast(
      Deploy.PubSub,
      topic,
      {:conflict_decision, conflict.id, :approve, conflict.proposals}
    )

    {:noreply, assign(socket, conflict: nil)}
  end

  def handle_event("manual_resolution", _params, socket) do
    conflict = socket.assigns.conflict
    deployment_id = socket.assigns.deployment.id
    topic = "deployment:#{deployment_id}:conflicts"

    Phoenix.PubSub.broadcast(
      Deploy.PubSub,
      topic,
      {:conflict_decision, conflict.id, :manual}
    )

    {:noreply, assign(socket, conflict: nil)}
  end

  def handle_event("skip_pr", _params, socket) do
    conflict = socket.assigns.conflict
    deployment_id = socket.assigns.deployment.id
    topic = "deployment:#{deployment_id}:conflicts"

    Phoenix.PubSub.broadcast(
      Deploy.PubSub,
      topic,
      {:conflict_decision, conflict.id, :skip}
    )

    {:noreply, assign(socket, conflict: nil)}
  end

  @impl true
  def handle_info({:step_started, _id, phase, step_name}, socket) do
    now = DateTime.utc_now()
    steps = update_step_status(socket.assigns.steps, phase, step_name, :in_progress, %{started_at: now})
    {:noreply, assign(socket, steps: steps)}
  end

  def handle_info({:step_completed, _id, phase, step_name, _result}, socket) do
    now = DateTime.utc_now()
    steps = update_step_status(socket.assigns.steps, phase, step_name, :completed, %{completed_at: now})
    {:noreply, assign(socket, steps: steps)}
  end

  def handle_info({:step_failed, _id, phase, step_name, error}, socket) do
    now = DateTime.utc_now()
    steps = update_step_status(socket.assigns.steps, phase, step_name, :failed, %{completed_at: now})
    {:noreply, assign(socket, steps: steps, error: format_error(error))}
  end

  def handle_info({:pr_merged, _id, pr_number, pr_title}, socket) do
    new_pr = %{pr_number: pr_number, pr_title: pr_title}
    merged_prs = socket.assigns.merged_prs ++ [new_pr]
    {:noreply, assign(socket, merged_prs: merged_prs)}
  end

  def handle_info({:deployment_completed, _id, _result}, socket) do
    deployment = Deployments.get_deployment!(socket.assigns.deployment.id)
    deployment = Deployments.load_deployment_with_assocs(deployment)

    {:noreply,
     assign(socket,
       deployment: deployment,
       steps: deployment.steps,
       merged_prs: deployment.merged_prs,
       is_active: false
     )}
  end

  def handle_info({:deployment_failed, _id, error}, socket) do
    deployment = Deployments.get_deployment!(socket.assigns.deployment.id)
    deployment = Deployments.load_deployment_with_assocs(deployment)

    {:noreply,
     assign(socket,
       deployment: deployment,
       steps: deployment.steps,
       error: format_error(error),
       is_active: false
     )}
  end

  def handle_info({:deployment_started, _id}, socket) do
    deployment = Deployments.get_deployment!(socket.assigns.deployment.id)
    deployment = Deployments.load_deployment_with_assocs(deployment)

    {:noreply,
     assign(socket,
       deployment: deployment,
       steps: deployment.steps,
       is_active: true
     )}
  end

  def handle_info({:conflict_proposed, conflict_id, data}, socket) do
    conflict = Map.put(data, :id, conflict_id)
    {:noreply, assign(socket, conflict: conflict)}
  end

  def handle_info({:phase_started, _id, _phase}, socket), do: {:noreply, socket}
  def handle_info({:phase_completed, _id, _phase}, socket), do: {:noreply, socket}
  def handle_info(_event, socket), do: {:noreply, socket}

  defp update_step_status(steps, phase, step_name, status, extra \\ %{}) do
    Enum.map(steps, fn step ->
      if step.phase == phase and step.step_name == step_name do
        step |> Map.put(:status, status) |> Map.merge(extra)
      else
        step
      end
    end)
  end

  defp format_error(error), do: Deploy.ErrorFormatter.format(error)

  # Helper for template to format step errors from database
  defp format_step_error(nil), do: nil
  defp format_step_error(error), do: Deploy.ErrorFormatter.format(error)

  defp step_status_icon(status) do
    case status do
      :pending -> {"clock", "text-gray-400"}
      :in_progress -> {"arrow-path", "text-blue-500 animate-spin"}
      :completed -> {"check-circle", "text-green-500"}
      :failed -> {"x-circle", "text-red-500"}
      :skipped -> {"minus-circle", "text-gray-400"}
      _ -> {"question-mark-circle", "text-gray-400"}
    end
  end

  # Phase order derived from reactor composition
  @phase_order Deploy.Reactors.StepMapper.get_phase_order(Deploy.Reactors.FullDeploy)

  defp group_steps_by_phase(steps) do
    steps
    |> Enum.group_by(& &1.phase)
    |> Enum.sort_by(fn {phase, _} ->
      Enum.find_index(@phase_order, &(&1 == phase)) || 999
    end)
  end

  defp phase_display_name(phase) do
    phase
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
    |> String.replace(" Pr", " PR")
    |> String.replace(" Prs", " PRs")
  end

  defp phase_status(steps) do
    cond do
      Enum.any?(steps, &(&1.status == :failed)) -> :failed
      Enum.all?(steps, &(&1.status == :completed)) -> :completed
      Enum.any?(steps, &(&1.status == :in_progress)) -> :in_progress
      true -> :pending
    end
  end
end
