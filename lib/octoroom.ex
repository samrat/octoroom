defmodule Octoroom do
  @moduledoc """
  Voice rooms for Phoenix apps, carried by Cloudflare Realtime SFU.

  See `Octoroom.Room` for writing a room and `docs/design.md` for the design.
  """

  @events Octoroom.Events

  @doc """
  Subscribes the calling process to a room's events. It then receives
  `{:octoroom, room_id, event}` messages, where `event` is one of:

    * `{:joined, participant}` and `{:left, participant}`
    * `{:updated, participant}`: its metadata changed
    * `{:published, participant}`: its mic is live at Cloudflare
    * `{:subscriptions, participant_id, track_names}`: what it now hears
  """
  def subscribe(room_id), do: Registry.register(@events, room_id, nil)

  def unsubscribe(room_id), do: Registry.unregister(@events, room_id)

  @doc false
  def broadcast(room_id, event) do
    Registry.dispatch(@events, room_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:octoroom, room_id, event})
    end)
  end

  @doc false
  def ice_servers,
    do: Application.get_env(:octoroom, :ice_servers, [%{urls: "stun:stun.cloudflare.com:3478"}])
end
