defmodule VisionWeb.Router do
  use VisionWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VisionWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VisionWeb do
    pipe_through :browser

    live "/", VisionLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", VisionWeb do
  #   pipe_through :api
  # end
end
