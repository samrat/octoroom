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

  # Other scopes may use custom stacks.
  # scope "/api", MeetWeb do
  #   pipe_through :api
  # end
end
