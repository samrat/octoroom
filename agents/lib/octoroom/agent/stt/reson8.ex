defmodule Octoroom.Agent.STT.Reson8 do
  @moduledoc """
  Reson8 realtime speech-to-text over its WebSocket API.

  Reads `RESON8_API_KEY`. `:model` is `"rumble-2"` (the default) or
  `"resonant-1"`. Interim results are on, so the owner gets partials.
  `:language_hints` become Reson8's `language` (auto-detected without
  them). Besides `Octoroom.Agent.STT`'s options it takes Reson8's
  `:phrases` (a list), `:bias_strength`, `:custom_model_id`,
  `:filler_mode` and `:number_format`.

  Reson8 reports errors after connecting only as close codes, so they come
  as `{:disconnected, reason, _}`.
  """

  @behaviour Octoroom.Agent.STT

  use WebSockex

  require Logger

  alias Octoroom.Agent.{SpeechProvider, STT}

  @endpoint "wss://api.reson8.dev/v1/speech-to-text/realtime"

  @query_options ~w(bias_strength custom_model_id filler_mode number_format)a

  # The flush that `close/1` sends; its confirmation ends the session.
  @close_id "close"

  @impl STT
  def default_options, do: [model: "rumble-2", sample_rate: 16_000]

  @impl STT
  def start_link(opts) do
    with {:ok, api_key} <- SpeechProvider.api_key(opts, "RESON8_API_KEY") do
      WebSockex.start_link(
        "#{@endpoint}?#{query(opts)}",
        __MODULE__,
        %{
          owner: Keyword.get(opts, :owner, self()),
          # Finals that came while a `finalize/1` was outstanding: they go
          # out as one `{:final, text}` when Reson8 confirms the flush.
          flushes: 0,
          flushed: [],
          next_id: 0,
          terminating?: false
        },
        extra_headers: [{"Authorization", "ApiKey #{api_key}"}],
        async: true,
        handle_initial_conn_failure: true
      )
    end
  end

  @impl STT
  def send_audio(pid, audio) when is_binary(audio), do: WebSockex.cast(pid, {:send_audio, audio})

  @doc """
  Flushes the audio sent so far instead of waiting for Reson8's
  endpointing. Answered with one `{:final, text}` when Reson8 confirms the
  flush, with `""` if nothing was pending.
  """
  @impl STT
  def finalize(pid), do: WebSockex.cast(pid, :finalize)

  @impl STT
  def close(pid), do: WebSockex.cast(pid, :terminate_session)

  defp query(opts) do
    %{
      "model" => Keyword.get(opts, :model),
      "encoding" => "pcm_s16le",
      "sample_rate" => Keyword.fetch!(opts, :sample_rate),
      "channels" => 1,
      "include_interim" => true,
      "language" => join(Keyword.get(opts, :language_hints)),
      "phrases" => join(Keyword.get(opts, :phrases))
    }
    |> Map.merge(Map.new(@query_options, &{Atom.to_string(&1), Keyword.get(opts, &1)}))
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> URI.encode_query()
  end

  defp join(list) when is_list(list), do: Enum.join(list, ",")
  defp join(value), do: value

  @impl true
  def handle_connect(_conn, state) do
    STT.notify(state.owner, :connected)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, event} -> dispatch_event(event, state)
      {:error, reason} -> {:ok, notify(state, {:warning, {:decode_error, reason}})}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_audio, audio}, %{terminating?: false} = state)
      when byte_size(audio) > 0,
      do: {:reply, {:binary, audio}, state}

  def handle_cast({:send_audio, _audio}, state), do: {:ok, state}

  def handle_cast(:finalize, state) do
    id = Integer.to_string(state.next_id)

    {:reply, flush_request(id), %{state | flushes: state.flushes + 1, next_id: state.next_id + 1}}
  end

  def handle_cast(:terminate_session, %{terminating?: true} = state), do: {:ok, state}

  def handle_cast(:terminate_session, state),
    do: {:reply, flush_request(@close_id), %{state | terminating?: true}}

  @impl true
  def handle_disconnect(disconnect, state) do
    notify(state, {:disconnected, disconnect.reason, %{intentional?: state.terminating?}})
    {:ok, state}
  end

  defp flush_request(id), do: {:text, Jason.encode!(%{"type" => "flush_request", "id" => id})}

  defp dispatch_event(%{"type" => "transcript", "text" => text} = event, state)
       when is_binary(text) do
    text = String.trim(text)

    cond do
      # Without `is_final`, a transcript is final: Reson8 only sends the
      # field with interim results on.
      not Map.get(event, "is_final", true) ->
        if text != "", do: notify(state, {:partial, text})
        {:ok, state}

      state.flushes > 0 ->
        {:ok, %{state | flushed: [text | state.flushed]}}

      text != "" ->
        {:ok, notify(state, {:final, text})}

      true ->
        {:ok, state}
    end
  end

  defp dispatch_event(%{"type" => "flush_confirmation", "id" => @close_id}, state) do
    state = if state.flushes > 0, do: flush(state), else: state
    notify(state, :finished)
    {:close, state}
  end

  defp dispatch_event(%{"type" => "flush_confirmation"}, %{flushes: flushes} = state)
       when flushes > 0,
       do: {:ok, flush(state)}

  defp dispatch_event(%{"type" => "flush_confirmation"}, state), do: {:ok, state}

  defp dispatch_event(event, state) do
    Logger.debug("Unhandled Reson8 event: #{inspect(event)}")
    {:ok, state}
  end

  defp flush(state) do
    text = state.flushed |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
    %{notify(state, {:final, text}) | flushes: state.flushes - 1, flushed: []}
  end

  defp notify(state, event) do
    STT.notify(state.owner, event)
    state
  end
end
