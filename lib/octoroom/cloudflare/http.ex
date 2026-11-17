defmodule Octoroom.Cloudflare.HTTP do
  @moduledoc """
  `Octoroom.Cloudflare` over Cloudflare's HTTP API. Needs `:app_id` and
  `:app_secret` in the config. `:request_fun` (default `&Req.request/1`) is
  for tests.
  """

  @behaviour Octoroom.Cloudflare

  require Logger

  @base_url "https://rtc.live.cloudflare.com/v1/apps"

  @impl true
  def new_session(config) do
    # `POST /sessions/new` must have no body: even `{}` is a 400.
    case request(config, :post, "/sessions/new", nil) do
      {:ok, %{"sessionId" => id}} -> {:ok, id}
      {:ok, body} -> {:error, {:unexpected_cloudflare_response, body}}
      error -> error
    end
  end

  @impl true
  def push_tracks(config, session, offer, tracks) do
    body = %{
      sessionDescription: %{type: "offer", sdp: offer},
      tracks: for(t <- tracks, do: %{location: "local", mid: t.mid, trackName: t.track_name})
    }

    with {:ok, resp} <- request(config, :post, "/sessions/#{session}/tracks/new", body),
         :ok <- no_track_errors(resp),
         {:ok, sdp} <- fetch_sdp(resp) do
      {:ok, %{sdp: sdp}}
    end
  end

  @impl true
  def pull_tracks(config, session, tracks) do
    body = %{
      tracks:
        for(
          t <- tracks,
          do: %{location: "remote", sessionId: t.session_id, trackName: t.track_name}
        )
    }

    with {:ok, resp} <- request(config, :post, "/sessions/#{session}/tracks/new", body) do
      pulled =
        for t <- resp["tracks"] || [] do
          base = %{session_id: t["sessionId"], track_name: t["trackName"]}

          if t["errorCode"],
            do: Map.put(base, :error, t["errorCode"]),
            else: Map.put(base, :mid, t["mid"])
        end

      {:ok,
       %{
         sdp: get_in(resp, ["sessionDescription", "sdp"]),
         renegotiate: resp["requiresImmediateRenegotiation"] == true,
         tracks: pulled
       }}
    end
  end

  @impl true
  def renegotiate(config, session, answer) do
    body = %{sessionDescription: %{type: "answer", sdp: answer}}

    case request(config, :put, "/sessions/#{session}/renegotiate", body) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def close_tracks(config, session, mids, offer) do
    body = %{tracks: Enum.map(mids, &%{mid: &1}), force: is_nil(offer)}

    body =
      if offer, do: Map.put(body, :sessionDescription, %{type: "offer", sdp: offer}), else: body

    with {:ok, resp} <- request(config, :put, "/sessions/#{session}/tracks/close", body),
         :ok <- no_track_errors(resp) do
      {:ok, %{sdp: get_in(resp, ["sessionDescription", "sdp"])}}
    end
  end

  @impl true
  def new_adapters(config, tracks) do
    with {:ok, resp} <- request(config, :post, "/adapters/websocket/new", %{tracks: tracks}),
         :ok <- no_track_errors(resp) do
      {:ok,
       for(
         t <- resp["tracks"] || [],
         do: %{adapter_id: t["adapterId"], session_id: t["sessionId"]}
       )}
    end
  end

  @impl true
  def close_adapters(_config, []), do: :ok

  def close_adapters(config, ids) do
    body = %{tracks: Enum.map(ids, &%{adapterId: &1})}

    case request(config, :post, "/adapters/websocket/close", body) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl true
  def session_state(config, session), do: request(config, :get, "/sessions/#{session}", nil)

  @doc """
  One API call. Returns the decoded body, or an error for HTTP failures and
  for an error Cloudflare reports at the top level of a 2xx body.
  """
  def request(config, method, path, body) do
    request_fun = Map.get(config, :request_fun, &Req.request/1)
    started = System.monotonic_time(:millisecond)

    opts =
      [
        method: method,
        url: "#{@base_url}/#{config.app_id}#{path}",
        auth: {:bearer, config.app_secret},
        retry: false,
        # Pulling a track Cloudflare has no packets for yet is held ~8 s.
        receive_timeout: 20_000
      ]
      |> then(fn opts -> if body, do: Keyword.put(opts, :json, body), else: opts end)

    result = request_fun.(opts)
    elapsed = System.monotonic_time(:millisecond) - started

    :telemetry.execute([:octoroom, :cloudflare, :request], %{duration_ms: elapsed}, %{
      method: method,
      path: path
    })

    Logger.debug("Cloudflare #{method} #{path} in #{elapsed} ms")
    handle_response(path, result)
  end

  defp handle_response(path, {:ok, %{status: status, body: body}}) when status in 200..299 do
    body = if is_map(body), do: body, else: %{}

    if body["errorCode"],
      do: {:error, {:cloudflare, path, body["errorCode"], body["errorDescription"]}},
      else: {:ok, body}
  end

  defp handle_response(path, {:ok, %{status: status, body: body}}),
    do: {:error, {:cloudflare, path, status, body}}

  defp handle_response(path, {:error, reason}), do: {:error, {:cloudflare, path, reason}}

  defp no_track_errors(resp) do
    case for(%{"errorCode" => _} = t <- resp["tracks"] || [], do: t) do
      [] -> :ok
      errors -> {:error, {:cloudflare, :track_errors, errors}}
    end
  end

  defp fetch_sdp(%{"sessionDescription" => %{"sdp" => sdp}}) when is_binary(sdp), do: {:ok, sdp}
  defp fetch_sdp(body), do: {:error, {:unexpected_cloudflare_response, body}}
end
