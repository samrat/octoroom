defmodule HelloWeb.RoomChannel do
  @moduledoc "Signaling between the browser's Octoroom client and `Hello.Room`."
  use Octoroom.Phoenix.Channel, room: Hello.Room
end
