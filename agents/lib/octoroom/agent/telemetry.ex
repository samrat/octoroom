defmodule Octoroom.Agent.Telemetry do
  @moduledoc """
  The `:telemetry` events `octoroom_agents` emits.

  Durations on span events (`:start` / `:first_output` / `:stop` / `:exception`)
  are in Erlang native time units, matching `:telemetry.span/3`,
  `Telemetry.Metrics` (`unit: {:native, :millisecond}`), and OpenTelemetry
  bridges. `[:octoroom_agent, :turn, :latency]` reports milliseconds with
  explicit `*_ms` keys.

  When run under `Octoroom.Agent.Worker`, metadata includes `room_id`,
  `agent_id`, and (for front ends) `input`.

  ## Async stages (`Octoroom.Agent.Pipeline.Core`)

  Every `{:async, key, fun}` (and `{:async, key, fun, meta}`) effect emitted by
  a processor — including `:llm`, `:tts`, `:decisions`, `:tools`, `:transcriber`,
  and custom stages — is wrapped in a lifecycle span so every `:start` closes
  with a matching `:stop` or `:exception`:

    * `[:octoroom_agent, :processor, :async, :start]`: measurements
      `system_time`, `monotonic_time`. Metadata: `processor` (stage name),
      `module`, `task` (low-cardinality atom: e.g. `:reply`, `:speak`,
      `:evaluate`, `:run`, `:transcribe`), `key`, `task_id`, `generation`,
      `uninterruptible`, optional `trigger` (triggering frame module), and
      stage-specific fields (`provider`, `model`, `voice`, `chars`, `modality`,
      `audio_ms`, `sync_tools`, `async_tools`, `call_count`, `turn_id`, ...).
    * `[:octoroom_agent, :processor, :async, :first_output]`: emitted once per
      streaming task when its `handle_async/3` pushes its first output frame
      (TTFT for `:llm`, TTFB for `:tts`). Measurements `duration`,
      `monotonic_time`; metadata adds `frame` (pushed frame module).
    * `[:octoroom_agent, :processor, :async, :stop]`: measurements `duration`,
      `monotonic_time`, `outputs` (count of frames pushed during streaming),
      and optional `first_output_duration` (native time to first pushed frame,
      present on streaming tasks that emitted output). Metadata adds `status`
      (`:ok`, `:error`, `:cancelled`, `:interrupted`, or `:terminated`) and
      `reason` when `status` is `:error` or `:terminated`.
    * `[:octoroom_agent, :processor, :async, :exception]`: the task crashed or
      died. Measurements `duration`, `monotonic_time`, `outputs`, optional
      `first_output_duration`; metadata adds `kind` (`:error`, `:exit`,
      `:throw`) and `reason`.

  ## Tools (`Octoroom.Agent.ToolDispatcher`)

    * `[:octoroom_agent, :tool, :call, :start | :stop | :exception]`: standard
      `:telemetry.span/3` around each individual tool handler invocation (both
      blocking and non-blocking, across cascaded, half-cascaded, Gemini Live,
      and OpenAI Live). Metadata: `room_id`, `agent_id`, `tool`, `call_id`,
      and on `:stop`, `result` (`:ok`, `:error`, or `:unknown`).

  ## Pipeline & synchronous frames (`Octoroom.Agent.Pipeline.Core`)

    * `[:octoroom_agent, :pipeline, :init]`: measurements `stages`; metadata
      `stages` (list of stage names).
    * `[:octoroom_agent, :pipeline, :interruption]`: measurements
      `killed_tasks`, `dropped_frames`; metadata `generation`.
    * `[:octoroom_agent, :processor, :frame, :start | :stop | :exception]`:
      synchronous `handle_frame/3` execution for non-audio frames (`InputAudio`
      and `OutputAudio` are excluded). Measurements `duration` (on `:stop` and
      `:exception`); metadata `processor`, `frame`, `generation`.

  ## Live speech-to-speech (`OpenAILive`, `GeminiLive`)

    * `[:octoroom_agent, :live, :session]`: session lifecycle events (`event`:
      `:started`, `:paused`, `:resumed`, `:disconnected`, `:closed`, `:error`).
      Includes `duration_ms` on `:started` (connect time). Metadata: `room_id`,
      `agent_id`, `provider` (`:openai` | `:gemini`), `model`, `voice`,
      `transport` (`:webrtc` | `:websocket`), `event`, optional `reason`.
    * `[:octoroom_agent, :live, :response, :start | :first_audio | :stop]`:
      per spoken reply from a speech-to-speech model. `:stop` includes
      `duration` (native), `duration_ms`, `audio_ms` (length of spoken audio),
      `outputs` (audio chunk count), and optional `response_latency_ms`
      (user turn/transcript end to first audio). Metadata: `room_id`,
      `agent_id`, `provider`, `model`, `voice`, `transport`, `status`
      (`:ok` | `:interrupted` | `:error`), `speaker`, `typed`, `user_text`,
      `assistant_text`.

  ## Turns (`Octoroom.Agent.Worker`)

    * `[:octoroom_agent, :turn, :decided]`: emitted when a front end finishes a
      turn (or a user types one) and the gate decides `:reply`, `:wait`, or
      `:listen`. Measurements `speech_to_decided_ms`, `system_time`,
      `monotonic_time`, and optional `decision_ms`. Metadata: `room_id`,
      `agent_id`, `input`, `speaker`, `text`, `outcome`, `why`, `decision`,
      `stt_provider`, `stt_model`.
    * `[:octoroom_agent, :turn, :floor_wait]`: emitted when a `:wait` turn
      either starts replying (`outcome: :replied`) or yields because someone
      else spoke (`outcome: :yielded`). Measurements `duration_ms`,
      `system_time`, `monotonic_time`; metadata `room_id`, `agent_id`, `input`,
      `speaker`, `outcome`.
    * `[:octoroom_agent, :turn, :latency]`: emitted when a reply's first audio
      reaches the outlet. Measurements `transcript_ms`, `audio_ms`, `wait_ms`,
      `processing_ms` (`audio_ms - wait_ms`), `stt_and_decision_ms`, and
      optional `llm_ms` (ms since the speaker's VAD speech end). Metadata:
      `room_id`, `agent_id`, `turn_id`, `input`, `speaker`, `stt_provider`,
      `stt_model`.
  """

  require Logger

  @doc "Every event name above, for `:telemetry.attach_many/4`."
  def events do
    [
      [:octoroom_agent, :pipeline, :init],
      [:octoroom_agent, :pipeline, :interruption],
      [:octoroom_agent, :processor, :frame, :start],
      [:octoroom_agent, :processor, :frame, :stop],
      [:octoroom_agent, :processor, :frame, :exception],
      [:octoroom_agent, :processor, :async, :start],
      [:octoroom_agent, :processor, :async, :first_output],
      [:octoroom_agent, :processor, :async, :stop],
      [:octoroom_agent, :processor, :async, :exception],
      [:octoroom_agent, :tool, :call, :start],
      [:octoroom_agent, :tool, :call, :stop],
      [:octoroom_agent, :tool, :call, :exception],
      [:octoroom_agent, :live, :session],
      [:octoroom_agent, :live, :response, :start],
      [:octoroom_agent, :live, :response, :first_audio],
      [:octoroom_agent, :live, :response, :stop],
      [:octoroom_agent, :turn, :decided],
      [:octoroom_agent, :turn, :floor_wait],
      [:octoroom_agent, :turn, :latency]
    ]
  end

  @logged_events [
    [:octoroom_agent, :processor, :async, :stop],
    [:octoroom_agent, :processor, :async, :exception],
    [:octoroom_agent, :tool, :call, :stop],
    [:octoroom_agent, :tool, :call, :exception],
    [:octoroom_agent, :live, :session],
    [:octoroom_agent, :live, :response, :stop],
    [:octoroom_agent, :turn, :latency]
  ]

  @doc """
  Logs one line per completed async stage, tool call, and turn latency:

      [info] Octoroom.Agent room-1/assistant llm:reply ok in 412 ms (first 148 ms, 12 outputs, google/gemini-3.5-flash)
      [info] Octoroom.Agent room-1/assistant tts:speak ok in 305 ms (first 112 ms, 8 outputs, inworld/inworld-tts-2)
      [info] Octoroom.Agent room-1/assistant tool whoami ok in 4 ms
      [info] Octoroom.Agent room-1/assistant turn latency: transcript 320 ms, llm 510 ms, audio 680 ms

  Options: `:level` (default `:info`). Call once in your application's `start/2`;
  `detach_default_logger/0` undoes it.
  """
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :info)

    :telemetry.attach_many(
      __MODULE__.DefaultLogger,
      @logged_events,
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc "Detaches the handler `attach_default_logger/1` attached."
  def detach_default_logger, do: :telemetry.detach(__MODULE__.DefaultLogger)

  @doc false
  def handle_event(event, measurements, meta, %{level: level}) do
    Logger.log(level, fn -> format(event, measurements, meta) end)
  end

  @doc false
  def format([:octoroom_agent, :processor, :async, :stop], m, meta) do
    ms = to_ms(m.duration)

    details =
      [
        if(m[:first_output_duration], do: "first #{to_ms(m.first_output_duration)} ms"),
        if(m[:outputs] && m.outputs > 0, do: "#{m.outputs} outputs"),
        target(meta),
        if(meta[:reason], do: "reason=#{inspect(meta.reason)}")
      ]
      |> Enum.reject(&is_nil/1)

    suffix = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"

    "Octoroom.Agent #{scope(meta)} #{meta.processor}:#{meta.task} #{meta.status} in #{ms} ms#{suffix}"
  end

  def format([:octoroom_agent, :processor, :async, :exception], m, meta) do
    ms = to_ms(m.duration)

    "Octoroom.Agent #{scope(meta)} #{meta.processor}:#{meta.task} exception in #{ms} ms " <>
      "(#{meta.kind}: #{inspect(meta.reason)})"
  end

  def format([:octoroom_agent, :tool, :call, :stop], m, meta) do
    "Octoroom.Agent #{scope(meta)} tool #{meta.tool} #{meta.result} in #{to_ms(m.duration)} ms"
  end

  def format([:octoroom_agent, :tool, :call, :exception], m, meta) do
    "Octoroom.Agent #{scope(meta)} tool #{meta.tool} exception in #{to_ms(m.duration)} ms " <>
      "(#{meta.kind}: #{inspect(meta.reason)})"
  end

  def format([:octoroom_agent, :live, :session], m, meta) do
    extra =
      [
        if(m[:duration_ms], do: "in #{m.duration_ms} ms"),
        target(meta),
        if(meta[:transport], do: to_string(meta.transport)),
        if(meta[:reason], do: "reason=#{inspect(meta.reason)}")
      ]
      |> Enum.reject(&is_nil/1)

    suffix = if extra == [], do: "", else: " (#{Enum.join(extra, ", ")})"
    "Octoroom.Agent #{scope(meta)} live session #{meta.event}#{suffix}"
  end

  def format([:octoroom_agent, :live, :response, :stop], m, meta) do
    details =
      [
        if(m[:response_latency_ms], do: "latency #{m.response_latency_ms} ms"),
        if(m[:audio_ms] && m.audio_ms > 0, do: "#{m.audio_ms} ms audio"),
        target(meta),
        if(meta[:transport], do: to_string(meta.transport))
      ]
      |> Enum.reject(&is_nil/1)

    suffix = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"

    "Octoroom.Agent #{scope(meta)} live response #{meta.status} in #{m.duration_ms} ms#{suffix}"
  end

  def format([:octoroom_agent, :turn, :latency], m, meta) do
    parts =
      [
        "transcript #{m.transcript_ms} ms",
        if(m[:wait_ms] && m.wait_ms > 0, do: "wait #{m.wait_ms} ms"),
        if(m[:llm_ms], do: "llm #{m.llm_ms} ms"),
        "audio #{m.audio_ms} ms"
      ]
      |> Enum.reject(&is_nil/1)

    "Octoroom.Agent #{scope(meta)} turn latency: #{Enum.join(parts, ", ")}"
  end

  defp scope(meta) do
    case {meta[:room_id], meta[:agent_id]} do
      {room, agent} when is_binary(room) and is_binary(agent) -> "#{room}/#{agent}"
      {nil, agent} when is_binary(agent) -> agent
      {room, nil} when is_binary(room) -> room
      _ -> "pipeline"
    end
  end

  defp target(meta) do
    case {meta[:provider], meta[:model]} do
      {provider, model} when not is_nil(provider) and is_binary(model) -> "#{provider}/#{model}"
      {nil, model} when is_binary(model) -> model
      {provider, nil} when not is_nil(provider) -> to_string(provider)
      _ -> nil
    end
  end

  defp to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
