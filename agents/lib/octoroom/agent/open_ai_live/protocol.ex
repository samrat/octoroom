defmodule Octoroom.Agent.OpenAILive.Protocol do
  @moduledoc """
  OpenAI Live API (`wss://api.openai.com/v1/live/sessions`, `gpt-live-1.1` /
  `gpt-live-1`) wire format: client events sent to OpenAI and the events
  server frames decode to. Pure, so it's tested without a socket.
  """

  alias Octoroom.Agent.Tool
  alias Octoroom.Agent.ToolAdapters.OpenAI, as: OpenAITools

  @default_voice "marin"
  @default_sample_rate 24_000
  @supported_sample_rates [16_000, 24_000]
  @default_transport :webrtc
  @supported_transports [:webrtc, :websocket]
  @idle_timeout_range 5..60

  def default_voice, do: @default_voice
  def default_sample_rate, do: @default_sample_rate
  def supported_sample_rates, do: @supported_sample_rates
  def default_transport, do: @default_transport

  @doc "Validates `:transport` (`:webrtc` or `:websocket`)."
  def transport(value) when value in @supported_transports, do: value

  def transport(other) do
    raise ArgumentError,
          "OpenAI Live :transport must be one of #{inspect(@supported_transports)}, got: #{inspect(other)}"
  end

  @doc """
  The `session.start` frame, the first event sent on a primary WebSocket.

  Options:
    * `:model` (needed, e.g. `"gpt-live-1.1"`)
    * `:voice` (default `"marin"`)
    * `:sample_rate` (`16_000` or `24_000`, default `24_000`)
    * `:instructions` (system prompt)
    * `:delegation` (`:client`, `[type: :client]`, `[model: "...", ...]` for
      Responses delegation, or a raw delegation map)
    * `:tools` (`%Octoroom.Agent.Tool{}` structs or OpenAI tool maps, merged
      into Responses delegation when configured)
    * `:idle_timeout_s` (integer in `5..60`, seconds of inactivity before
      standby; WebRTC only)
    * `:wake_policy` (`:speech`, `[type: :speech, vad_threshold: 0.5]`, or a
      raw wake policy map; WebRTC only)
    * `:initial_items` (list of initial conversation item maps)
    * `:event_id` (optional client event id)
  """
  def session_start_frame(opts) do
    session = session_config(opts, include_audio_format: true)

    %{type: "session.start", session: session}
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  @doc """
  The JSON request body for `POST /v1/live/sessions` over WebRTC.

  Omits `audio.format` because WebRTC negotiates media format in SDP.
  """
  def webrtc_session_request(opts, sdp) when is_binary(sdp) do
    %{
      session: session_config(opts, include_audio_format: false),
      transport: %{type: "webrtc", sdp: sdp}
    }
  end

  defp session_config(opts, include_audio_format: include_format?) do
    tools = Keyword.get(opts, :tools, [])
    voice = Keyword.get(opts, :voice, @default_voice)

    audio =
      if include_format? do
        rate = sample_rate(Keyword.get(opts, :sample_rate, @default_sample_rate))
        %{format: %{type: "audio/pcm", rate: rate}, output: %{voice: voice}}
      else
        %{output: %{voice: voice}}
      end

    %{
      model: model_name(Keyword.fetch!(opts, :model)),
      audio: audio
    }
    |> put_instructions(Keyword.get(opts, :instructions))
    |> put_delegation(Keyword.get(opts, :delegation), tools)
    |> put_idle_timeout_s(Keyword.get(opts, :idle_timeout_s))
    |> put_wake_policy(Keyword.get(opts, :wake_policy))
    |> put_initial_items(Keyword.get(opts, :initial_items))
  end

  @doc "Validates `idle_timeout_s` (`nil` or an integer in `5..60`)."
  def idle_timeout_s(nil), do: nil

  def idle_timeout_s(seconds) when is_integer(seconds) and seconds in @idle_timeout_range,
    do: seconds

  def idle_timeout_s(other) do
    raise ArgumentError,
          "idle_timeout_s must be an integer between #{@idle_timeout_range.first} and #{@idle_timeout_range.last}, got: #{inspect(other)}"
  end

  @doc """
  Builds and validates `session.wake_policy` (`nil`/`false`, `:speech`,
  `[type: :speech, vad_threshold: 0.5]`, or a raw map).
  """
  def wake_policy(nil), do: nil
  def wake_policy(false), do: nil
  def wake_policy(type) when type in [:speech, "speech"], do: %{type: "speech"}

  def wake_policy(%{type: "speech"} = map) do
    if Map.has_key?(map, :vad_threshold), do: validate_vad_threshold!(map.vad_threshold)
    map
  end

  def wake_policy(%{"type" => "speech"} = map) do
    if Map.has_key?(map, "vad_threshold"), do: validate_vad_threshold!(map["vad_threshold"])
    map
  end

  def wake_policy(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:type, :vad_threshold])

    case Keyword.get(opts, :type, :speech) do
      type when type in [:speech, "speech"] ->
        threshold = opts[:vad_threshold]
        if threshold != nil, do: validate_vad_threshold!(threshold)
        maybe_put(%{type: "speech"}, :vad_threshold, threshold)

      other ->
        raise ArgumentError, "wake_policy :type must be :speech, got: #{inspect(other)}"
    end
  end

  def wake_policy(other) do
    raise ArgumentError,
          "wake_policy expects :speech, [type: :speech, vad_threshold: ...], or a map, got: #{inspect(other)}"
  end

  defp validate_vad_threshold!(value) when is_number(value) and value >= 0 and value <= 1, do: :ok

  defp validate_vad_threshold!(other) do
    raise ArgumentError,
          "wake_policy :vad_threshold must be a number between 0 and 1, got: #{inspect(other)}"
  end

  @doc "Validates a PCM sample rate supported by OpenAI Live (`16_000` or `24_000`)."
  def sample_rate(rate) when rate in @supported_sample_rates, do: rate

  def sample_rate(other) do
    raise ArgumentError,
          "OpenAI Live sample_rate must be one of #{inspect(@supported_sample_rates)}, got: #{inspect(other)}"
  end

  @doc """
  Builds and validates the `session.delegation` object from `:delegation` and
  optional agent `tools`.
  """
  def delegation(config, tools \\ [])
  def delegation(nil, _tools), do: nil
  def delegation(false, _tools), do: nil
  def delegation(:client, _tools), do: %{type: "client"}

  def delegation(%{type: "client"}, _tools), do: %{type: "client"}

  def delegation(%{"type" => "client"}, _tools), do: %{type: "client"}

  def delegation(%{type: "responses", responses: %{} = responses} = map, tools) do
    merged = merge_response_tools(responses, tools)
    %{map | responses: merged}
  end

  def delegation(%{"type" => "responses", "responses" => %{} = responses} = map, tools) do
    merged = merge_response_tools(responses, tools)
    %{map | "responses" => merged}
  end

  def delegation(opts, tools) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :type,
        :model,
        :instructions,
        :max_output_tokens,
        :tools,
        :tool_choice,
        :parallel_tool_calls
      ])

    case Keyword.get(opts, :type, :responses) do
      type when type in [:client, "client"] ->
        if Keyword.delete(opts, :type) != [] do
          raise ArgumentError,
                "client delegation takes no extra options, got: #{inspect(Keyword.delete(opts, :type))}"
        end

        %{type: "client"}

      type when type in [:responses, "responses"] ->
        model = Keyword.get(opts, :model)

        if not (is_binary(model) and model != "") do
          raise ArgumentError,
                "responses delegation needs a non-empty :model, got: #{inspect(model)}"
        end

        responses =
          %{model: model_name(model)}
          |> maybe_put(:instructions, opts[:instructions])
          |> maybe_put(:max_output_tokens, opts[:max_output_tokens])
          |> maybe_put(:tool_choice, opts[:tool_choice])
          |> maybe_put(:parallel_tool_calls, opts[:parallel_tool_calls])
          |> put_response_tools(opts[:tools], tools)

        %{type: "responses", responses: responses}

      other ->
        raise ArgumentError,
              "delegation :type must be :responses or :client, got: #{inspect(other)}"
    end
  end

  def delegation(other, _tools) do
    raise ArgumentError,
          "delegation expects :client, [model: \"...\", ...], or a delegation map, got: #{inspect(other)}"
  end

  def session_update_frame(session) when is_map(session),
    do: %{type: "session.update", session: session}

  def session_close_frame, do: %{type: "session.close"}

  def audio_input_frame(audio) when is_binary(audio),
    do: %{type: "session.input_audio.append", audio: Base.encode64(audio)}

  def input_audio_mute_frame, do: %{type: "session.input_audio.mute"}
  def input_audio_unmute_frame, do: %{type: "session.input_audio.unmute"}

  def instructions_append_frame(content, opts \\ []) when is_binary(content) do
    %{
      type: "session.instructions.append",
      delegation_id: Keyword.get(opts, :delegation_id),
      content: content
    }
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def thinking_append_frame(content, opts \\ []) when is_binary(content) do
    %{
      type: "session.thinking.append",
      delegation_id: Keyword.get(opts, :delegation_id),
      content: content
    }
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def commentary_append_frame(content, opts \\ []) when is_binary(content) do
    %{
      type: "session.commentary.append",
      delegation_id: Keyword.get(opts, :delegation_id),
      content: content
    }
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def tool_output_frame(call_id, output, opts \\ []) when is_binary(call_id) do
    %{
      type: "response.item.create",
      item: %{
        type: "function_call_output",
        call_id: call_id,
        output: encode_tool_output(output)
      }
    }
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def response_create_frame, do: %{type: "response.create"}

  @doc "The model name without any `openai:` prefix."
  def model_name("openai:" <> model), do: model
  def model_name(model) when is_binary(model), do: model

  @doc """
  Decodes one incoming WebSocket frame into `{:ok, [event]}` or `{:error, reason}`.
  """
  def decode_frame(frame, opts \\ [])
  def decode_frame({:binary, data}, opts), do: decode_json(data, opts)
  def decode_frame({:text, data}, opts), do: decode_json(data, opts)
  def decode_frame(data, opts) when is_binary(data), do: decode_json(data, opts)

  defp decode_json(data, opts) do
    case Jason.decode(data) do
      {:ok, decoded} -> {:ok, events(decoded, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp events(%{"type" => "session.started"} = frame, _opts),
    do: [{:session_started, frame["session"] || %{}}]

  defp events(%{"type" => "session.updated"} = frame, _opts),
    do: [{:session_updated, frame["session"] || %{}}]

  defp events(%{"type" => "session.closed"} = frame, _opts),
    do: [{:session_closed, frame["reason"], frame}]

  defp events(%{"type" => "session.output_audio.delta", "delta" => delta}, opts)
       when is_binary(delta) do
    rate = Keyword.get(opts, :sample_rate, @default_sample_rate)
    [{:audio, Base.decode64!(delta), sample_rate: rate}]
  end

  defp events(%{"type" => "session.input_transcript.delta", "delta" => delta}, _opts)
       when is_binary(delta),
       do: [{:transcription, :user, delta}]

  defp events(%{"type" => "session.output_transcript.delta", "delta" => delta}, _opts)
       when is_binary(delta),
       do: [{:transcription, :assistant, delta}]

  defp events(%{"type" => "session.delegation.created"} = frame, _opts),
    do: [{:delegation_created, frame["delegation"] || %{}}]

  defp events(%{"type" => "response.event", "event" => %{} = inner} = frame, _opts),
    do: decode_response_event(frame["delegation_id"], inner)

  defp events(%{"type" => "error", "error" => error}, _opts), do: [{:error, error}]

  defp events(%{"type" => "session.paused"} = frame, _opts), do: [{:session_paused, frame}]
  defp events(%{"type" => "session.resumed"} = frame, _opts), do: [{:session_resumed, frame}]

  defp events(%{"type" => type} = frame, _opts)
       when type in [
              "session.instructions.appended",
              "session.thinking.appended",
              "session.commentary.appended",
              "session.input_audio.muted",
              "session.input_audio.unmuted",
              "session.usage.updated"
            ],
       do: [{:ack, type, frame}]

  defp events(frame, _opts), do: [{:raw, frame}]

  defp decode_response_event(delegation_id, %{"type" => "response.output_item.done"} = inner) do
    case inner["item"] || inner["output_item"] do
      %{"type" => "function_call", "name" => name} = item when is_binary(name) ->
        call_id = item["call_id"] || item["id"]

        if is_binary(call_id) do
          [{:tool_call, [%{id: call_id, name: name, args: decode_args(item["arguments"])}]}]
        else
          [{:response_event, delegation_id, inner}]
        end

      _other ->
        [{:response_event, delegation_id, inner}]
    end
  end

  defp decode_response_event(delegation_id, inner), do: [{:response_event, delegation_id, inner}]

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(_other), do: %{}

  defp encode_tool_output(output) when is_binary(output), do: output
  defp encode_tool_output(output), do: Jason.encode!(output)

  defp put_instructions(session, text) when is_binary(text) and text != "",
    do: Map.put(session, :instructions, text)

  defp put_instructions(session, _none), do: session

  defp put_delegation(session, config, tools) do
    case delegation(config, tools) do
      nil -> session
      built -> Map.put(session, :delegation, built)
    end
  end

  defp put_idle_timeout_s(session, value) do
    case idle_timeout_s(value) do
      nil -> session
      seconds -> Map.put(session, :idle_timeout_s, seconds)
    end
  end

  defp put_wake_policy(session, value) do
    case wake_policy(value) do
      nil -> session
      policy -> Map.put(session, :wake_policy, policy)
    end
  end

  defp put_initial_items(session, [_ | _] = items), do: Map.put(session, :initial_items, items)
  defp put_initial_items(session, _none), do: session

  defp put_response_tools(responses, configured_tools, agent_tools) do
    all = format_tools(configured_tools || []) ++ format_tools(agent_tools || [])
    if all == [], do: responses, else: Map.put(responses, :tools, all)
  end

  defp merge_response_tools(responses, agent_tools) do
    extra = format_tools(agent_tools || [])

    if extra == [] do
      responses
    else
      key = if Map.has_key?(responses, "tools"), do: "tools", else: :tools
      existing = Map.get(responses, key) || []
      Map.put(responses, key, existing ++ extra)
    end
  end

  defp format_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      %Tool{} = tool -> OpenAITools.to_responses_tool(tool)
      tool when is_map(tool) -> tool
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
