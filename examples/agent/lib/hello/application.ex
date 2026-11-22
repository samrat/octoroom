defmodule Hello.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Logs how long each step of a join and each agent async stage take.
    Octoroom.Telemetry.attach_default_logger()
    Octoroom.Agent.Telemetry.attach_default_logger()

    children = [
      HelloWeb.Telemetry,
      Hello.Clinic,
      {DNSCluster, query: Application.get_env(:hello, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Hello.PubSub},
      # Start a worker by calling: Hello.Worker.start_link(arg)
      # {Hello.Worker, arg},
      # Start to serve requests, typically the last entry
      HelloWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Hello.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HelloWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
