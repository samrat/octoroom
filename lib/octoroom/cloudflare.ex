defmodule Octoroom.Cloudflare do
  @moduledoc """
  The Cloudflare Realtime SFU operations Octoroom uses, as a behaviour.
  `Octoroom.Cloudflare.HTTP` calls the real API; tests use an in-memory fake.

  `config` is a map with at least `:client` (the implementing module); the
  HTTP client also needs `:app_id` and `:app_secret`.
  """

  @type config :: %{required(:client) => module, optional(atom) => term}
  @type session_id :: String.t()
  @type sdp :: String.t()
  @type mid :: String.t()

  @typedoc "One track of a pull: added (with its mid) or refused (with Cloudflare's error code)."
  @type pulled ::
          %{session_id: session_id, track_name: String.t(), mid: mid}
          | %{session_id: session_id, track_name: String.t(), error: String.t()}

  @doc "Creates an empty session (one peer connection)."
  @callback new_session(config) :: {:ok, session_id} | {:error, term}

  @doc "Publishes local tracks from the client's `offer`. Returns Cloudflare's answer."
  @callback push_tracks(config, session_id, offer :: sdp, [%{mid: mid, track_name: String.t()}]) ::
              {:ok, %{sdp: sdp}} | {:error, term}

  @doc """
  Pulls remote tracks into a session in one call. Per-track failures (such as
  `empty_track_error`) come back in `tracks`; the offer covers the tracks that
  were added. When `renegotiate` is true, the client's answer goes to
  `renegotiate/3`.
  """
  @callback pull_tracks(config, session_id, [%{session_id: session_id, track_name: String.t()}]) ::
              {:ok, %{sdp: sdp | nil, renegotiate: boolean, tracks: [pulled]}} | {:error, term}

  @doc "Completes a Cloudflare-initiated renegotiation with the client's answer."
  @callback renegotiate(config, session_id, answer :: sdp) :: :ok | {:error, term}

  @doc """
  Closes tracks in a session. With the client's `offer` (made after stopping
  the transceivers) it returns Cloudflare's answer; with `nil` the close is
  forced and no answer comes back.
  """
  @callback close_tracks(config, session_id, [mid], offer :: sdp | nil) ::
              {:ok, %{sdp: sdp | nil}} | {:error, term}

  @doc "Creates WebSocket adapters. Each result carries `:adapter_id` and, for ingest, `:session_id`."
  @callback new_adapters(config, [map]) :: {:ok, [map]} | {:error, term}

  @doc "Closes WebSocket adapters, so Cloudflare stops dialing and billing."
  @callback close_adapters(config, [String.t()]) :: :ok | {:error, term}

  @doc "Reads back a session's tracks."
  @callback session_state(config, session_id) :: {:ok, map} | {:error, term}

  @doc "The config from `config :octoroom, cloudflare: [...]`, with the HTTP client by default."
  def config do
    :octoroom
    |> Application.get_env(:cloudflare, [])
    |> Map.new()
    |> Map.put_new(:client, Octoroom.Cloudflare.HTTP)
  end

  def new_session(%{client: c} = config), do: c.new_session(config)

  def push_tracks(%{client: c} = config, session, offer, tracks),
    do: c.push_tracks(config, session, offer, tracks)

  def pull_tracks(%{client: c} = config, session, tracks),
    do: c.pull_tracks(config, session, tracks)

  def renegotiate(%{client: c} = config, session, answer),
    do: c.renegotiate(config, session, answer)

  def close_tracks(%{client: c} = config, session, mids, offer),
    do: c.close_tracks(config, session, mids, offer)

  def new_adapters(%{client: c} = config, tracks), do: c.new_adapters(config, tracks)
  def close_adapters(%{client: c} = config, ids), do: c.close_adapters(config, ids)
  def session_state(%{client: c} = config, session), do: c.session_state(config, session)
end
