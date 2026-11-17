defmodule Octoroom.Cloudflare.HTTP do
  @moduledoc """
  `Octoroom.Cloudflare` over Cloudflare's HTTP API. Needs `:app_id` and
  `:app_secret` in the config. `:request_fun` (default `&Req.request/1`) is
  for tests.

  Calls Cloudflare didn't carry out are retried, up to `:attempts` in all
  (default 3) with `:backoff_ms` (default 200) doubling in between: 429,
  502, 503 and 504 for every call, and transport errors (the request may not
  have arrived) only for `GET`s, which are safe to repeat. Pulling or
  pushing twice would add tracks twice.
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
  def session_state(config, session) do
    case request(config, :get, "/sessions/#{session}", nil) do
      {:ok, %{"tracks" => tracks}} ->
        {:ok, %{tracks: Enum.map(tracks, &session_track/1)}}

      {:ok, body} when map_size(body) == 0 ->
        {:ok, %{tracks: []}}

      # 410 "Session appears to be disconnected" (observed 2026-11-17): its
      # peer connection is gone.
      {:error, {:cloudflare, _path, 410, _}} ->
        {:error, :disconnected}

      {:error, {:cloudflare, _path, "session_error", _}} ->
        {:error, :disconnected}

      {:ok, body} ->
        {:error, {:unexpected_cloudflare_response, body}}

      error ->
        error
    end
  end

  defp session_track(t) do
    %{
      location: if(t["location"] == "remote", do: :remote, else: :local),
      track_name: t["trackName"],
      mid: t["mid"],
      session_id: t["sessionId"],
      status:
        case t["status"] do
          "active" -> :active
          "inactive" -> :inactive
          other -> other
        end
    }
  end

  @doc """
  One API call. Returns the decoded body, or an error for HTTP failures and
  for an error Cloudflare reports at the top level of a 2xx body.
  """
  def request(config, method, path, body) do
    attempts = Map.get(config, :attempts, 3)
    backoff = Map.get(config, :backoff_ms, 200)
    request(config, method, path, body, 1, attempts, backoff)
  end

  defp request(config, method, path, body, attempt, attempts, backoff) do
    result = request_once(config, method, path, body)

    if attempt < attempts and retry?(method, path, result) do
      Logger.info(
        "Cloudflare #{method} #{path} failed (#{inspect(result)}), retrying in #{backoff} ms"
      )

      Process.sleep(backoff)
      request(config, method, path, body, attempt + 1, attempts, backoff * 2)
    else
      result
    end
  end

  # Cloudflare answered that it didn't carry the call out.
  defp retry?(_method, _path, {:error, {:cloudflare, _, status, _}})
       when status in [429, 502, 503, 504],
       do: true

  # The request may not have arrived: only safe to repeat when idempotent.
  defp retry?(method, _path, {:error, {:cloudflare, _, %{__exception__: true}}}),
    do: method == :get

  defp retry?(_method, _path, _result), do: false

  defp request_once(config, method, path, body) do
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
