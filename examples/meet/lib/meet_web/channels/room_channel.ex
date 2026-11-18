defmodule MeetWeb.RoomChannel do
  @moduledoc "Signaling between the browser's Octoroom client and `Meet.Room`."
  use Octoroom.Phoenix.Channel, room: Meet.Room
end
