defmodule VisionWeb.RoomChannel do
  @moduledoc "Signaling between the browser's Octoroom client and `Vision.Room`."
  use Octoroom.Phoenix.Channel, room: Vision.Room
end
