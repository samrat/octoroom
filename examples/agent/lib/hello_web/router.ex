defmodule HelloWeb.Router do
  use HelloWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HelloWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HelloWeb do
    pipe_through :browser

    live "/", AgentLive
  end

  if Application.compile_env(:hello, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: HelloWeb.Telemetry,
        metrics_history: {HelloWeb.MetricsStorage, :metrics_history, []},
        additional_pages: [
          octoroom: HelloWeb.OctoroomDashboardPage
        ]
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", HelloWeb do
  #   pipe_through :api
  # end
end
