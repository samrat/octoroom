defmodule Meet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Logs how long each step of a join takes.
    Octoroom.Telemetry.attach_default_logger()

    children = [
      MeetWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:meet, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Meet.PubSub},
      # Start a worker by calling: Meet.Worker.start_link(arg)
      # {Meet.Worker, arg},
      # Start to serve requests, typically the last entry
      MeetWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Meet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MeetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
