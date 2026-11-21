defmodule MeetWeb.Router do
  use MeetWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MeetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", MeetWeb do
    pipe_through :browser

    live "/", RoomLive
    live "/r/:room", RoomLive
  end

  if Application.compile_env(:meet, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: MeetWeb.Telemetry,
        metrics_history: {MeetWeb.MetricsStorage, :metrics_history, []},
        additional_pages: [
          octoroom: MeetWeb.OctoroomDashboardPage
        ]
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", MeetWeb do
  #   pipe_through :api
  # end
end
