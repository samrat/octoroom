defmodule Octoroom.Agent.NuanceLive.Protocol do
  @moduledoc """
  Nuance Live API (`https://api.nuancelabs.ai`) REST payloads, `nuance_live`
  data channel events, `clock-sync` responses, and `message.part` reassembly.
  Pure, so it can be tested without network or LiveKit.
  """

  alias Octoroom.Agent.Tool
  alias Octoroom.Agent.ToolAdapters.OpenAI, as: OpenAITools

  @default_base_url "https://api.nuancelabs.ai"
  @default_persona "sam"
  @supported_personas ~w(sam sonia mira)
  @nuance_topic "nuance_live"
  @clock_sync_topic "clock-sync"
  @max_packet_bytes 64_000

  def default_base_url, do: @default_base_url
  def default_persona, do: @default_persona
  def supported_personas, do: @supported_personas
  def nuance_topic, do: @nuance_topic
  def clock_sync_topic, do: @clock_sync_topic
  def max_packet_bytes, do: @max_packet_bytes

  @doc "Validates `:persona` (`\"sam\"`, `\"sonia\"`, or `\"mira\"`)."
  def persona(nil), do: @default_persona
  def persona(id) when id in @supported_personas, do: id
  def persona(id) when is_atom(id), do: persona(Atom.to_string(id))

  def persona(other) do
    raise ArgumentError,
          "Nuance Live :persona must be one of #{inspect(@supported_personas)}, got: #{inspect(other)}"
  end

  @doc "Validates `:expressiveness` (`nil` or a number in `0..2`)."
  def expressiveness(nil), do: nil

  def expressiveness(val) when is_number(val) and val >= 0 and val <= 2,
    do: val

  def expressiveness(other) do
    raise ArgumentError,
          "Nuance Live :expressiveness must be a number between 0 and 2, got: #{inspect(other)}"
  end

  @doc """
  Builds and validates `interface_setup.delegation` from `:delegation` and
  optional agent `tools`.

  Supported forms:
    * `nil` (default): if `tools` is non-empty, builds `responses` delegation
      with `model: "default"`; otherwise `%{type: "none"}` so unconfigured
      sessions don't silently drop client hand-offs.
    * `:none` / `"none"` -> `%{type: "none"}`
    * `:client` / `"client"` -> `%{type: "client"}`
    * `[model: "...", ...]` -> `%{type: "responses", responses: ...}`
    * raw map -> passed through, merging any `%Octoroom.Agent.Tool{}` structs
  """
  def delegation(config, tools \\ [])
  def delegation(nil, []), do: %{type: "none"}

  def delegation(nil, [_ | _] = tools),
    do: delegation([model: "default"], tools)

  def delegation(false, _tools), do: %{type: "none"}
  def delegation(:none, _tools), do: %{type: "none"}
  def delegation("none", _tools), do: %{type: "none"}
  def delegation(:client, _tools), do: %{type: "client"}
  def delegation("client", _tools), do: %{type: "client"}
  def delegation(%{type: "none"} = map, _tools), do: map
  def delegation(%{"type" => "none"} = map, _tools), do: map
  def delegation(%{type: "client"} = map, _tools), do: map
  def delegation(%{"type" => "client"} = map, _tools), do: map

  def delegation(%{type: "responses", responses: %{} = responses} = map, tools) do
    %{map | responses: merge_response_tools(responses, tools)}
  end

  def delegation(%{"type" => "responses", "responses" => %{} = responses} = map, tools) do
    %{map | "responses" => merge_response_tools(responses, tools)}
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
        :parallel_tool_calls,
        :reasoning,
        :service_tier,
        :text,
        :acknowledgement_delay_ms
      ])

    case Keyword.get(opts, :type, :responses) do
      type when type in [:none, "none"] ->
        %{type: "none"}

      type when type in [:client, "client"] ->
        %{type: "client"}
        |> maybe_put(:acknowledgement_delay_ms, opts[:acknowledgement_delay_ms])

      type when type in [:responses, "responses"] ->
        model = Keyword.get(opts, :model, "default")

        if not (is_binary(model) and model != "") do
          raise ArgumentError,
                "Nuance Live responses delegation needs a non-empty :model, got: #{inspect(model)}"
        end

        responses =
          %{model: model}
          |> maybe_put(:instructions, opts[:instructions])
          |> maybe_put(:max_output_tokens, opts[:max_output_tokens])
          |> maybe_put(:tool_choice, opts[:tool_choice])
          |> maybe_put(:parallel_tool_calls, opts[:parallel_tool_calls])
          |> maybe_put(:reasoning, opts[:reasoning])
          |> maybe_put(:service_tier, opts[:service_tier])
          |> maybe_put(:text, opts[:text])
          |> put_response_tools(opts[:tools], tools)

        %{type: "responses", responses: responses}
        |> maybe_put(:acknowledgement_delay_ms, opts[:acknowledgement_delay_ms])

      other ->
        raise ArgumentError,
              "Nuance Live delegation :type must be :responses, :client, or :none, got: #{inspect(other)}"
    end
  end

  def delegation(other, _tools) do
    raise ArgumentError,
          "Nuance Live delegation expects :none, :client, [model: \"...\", ...], or a map, got: #{inspect(other)}"
  end

  @doc "Validates `:runtime_tools` (`stay_quiet`, `end_call`, `call_time`)."
  def runtime_tools(nil), do: nil

  def runtime_tools(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:stay_quiet, :end_call, :call_time])
    runtime_tools(Map.new(opts))
  end

  def runtime_tools(map) when is_map(map) do
    allowed = ~w(stay_quiet end_call call_time)

    Enum.reduce(map, %{}, fn {k, v}, acc ->
      key = to_string(k)

      unless key in allowed do
        raise ArgumentError,
              "Nuance Live runtime_tools key must be one of #{inspect(allowed)}, got: #{inspect(k)}"
      end

      unless is_boolean(v) or is_nil(v) do
        raise ArgumentError,
              "Nuance Live runtime_tools :#{key} must be a boolean or nil, got: #{inspect(v)}"
      end

      if is_nil(v), do: acc, else: Map.put(acc, key, v)
    end)
  end

  def runtime_tools(other) do
    raise ArgumentError,
          "Nuance Live :runtime_tools expects a keyword list or map, got: #{inspect(other)}"
  end

  @doc "Sanitizes an end_user_id to `[A-Za-z0-9_.:-]` (1..128 chars)."
  def sanitize_end_user_id(nil), do: nil

  def sanitize_end_user_id(id) when is_binary(id) do
    cleaned = id |> String.replace(~r/[^A-Za-z0-9_.:-]/, "_") |> String.slice(0, 128)
    if cleaned == "", do: nil, else: cleaned
  end

  @doc "Builds the `POST /session-tokens` request JSON body."
  def session_token_request(opts) when is_list(opts) do
    tools = Keyword.get(opts, :tools, [])
    persona_id = persona(Keyword.get(opts, :persona))
    instructions = Keyword.get(opts, :instructions)
    delegation = delegation(Keyword.get(opts, :delegation), tools)
    runtime_tools = runtime_tools(Keyword.get(opts, :runtime_tools))
    expressiveness = expressiveness(Keyword.get(opts, :expressiveness))

    camera? =
      Keyword.get(opts, :camera, false) or Keyword.get(opts, :camera_input, false)

    end_user_id = sanitize_end_user_id(Keyword.get(opts, :end_user_id))

    personality =
      %{persona_id: persona_id}
      |> maybe_put(:system_prompt, non_empty_string(instructions))

    interface_setup =
      %{
        delegation: delegation,
        video: %{input: %{camera: camera?}}
      }
      |> then(fn m ->
        if is_map(runtime_tools) and map_size(runtime_tools) > 0,
          do: Map.put(m, :runtime_tools, runtime_tools),
          else: m
      end)

    %{
      interface: "nuance_live",
      personality: personality,
      interface_setup: interface_setup
    }
    |> maybe_put(:expressiveness, expressiveness)
    |> maybe_put(:end_user_id, end_user_id)
  end

  @doc "Builds the `POST /conversation` request JSON body."
  def conversation_request(opts) when is_list(opts) do
    %{}
    |> maybe_put(:timezone, non_empty_string(Keyword.get(opts, :timezone)))
    |> maybe_put(:max_session_seconds, Keyword.get(opts, :max_session_seconds))
    |> then(fn body ->
      if Keyword.get(opts, :green_screen, false),
        do: Map.put(body, :green_screen, true),
        else: body
    end)
  end

  # -- Client events (sent on `nuance_live` topic) --

  def response_create_frame(opts \\ []) do
    response =
      %{}
      |> maybe_put(:instructions, non_empty_string(Keyword.get(opts, :instructions)))
      |> maybe_put(:tool_choice, Keyword.get(opts, :tool_choice))

    %{type: "response.create"}
    |> then(fn m -> if map_size(response) > 0, do: Map.put(m, :response, response), else: m end)
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def thinking_append_frame(content, opts \\ []) when is_binary(content),
    do: append_frame("session.thinking.append", content, opts)

  def instructions_append_frame(content, opts \\ []) when is_binary(content),
    do: append_frame("session.instructions.append", content, opts)

  def commentary_append_frame(content, opts \\ []) when is_binary(content),
    do: append_frame("session.commentary.append", content, opts)

  defp append_frame(type, content, opts) do
    %{
      type: type,
      delegation_id: Keyword.get(opts, :delegation_id),
      content: content
    }
    |> maybe_put(:while_speaking, Keyword.get(opts, :while_speaking))
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def user_message_item_frame(text, opts \\ []) when is_binary(text) do
    %{
      type: "response.item.create",
      item: %{
        type: "message",
        role: "user",
        content: text
      }
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

  def interrupt_frame(opts \\ []) do
    %{type: "session.output_audio.interrupt"}
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
  end

  def input_audio_mute_frame, do: %{type: "session.input_audio.mute"}
  def input_audio_unmute_frame, do: %{type: "session.input_audio.unmute"}
  def session_close_frame, do: %{type: "session.close"}

  # -- Clock sync (`clock-sync` topic) --

  @doc """
  If `payload` is a `clock_sync_ping`, returns `{:ok, pong_json}` where `t1`
  and `t2` are Unix timestamps in seconds.
  """
  def handle_clock_sync(payload, received_at_s, sent_at_s \\ nil) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "clock_sync_ping", "seq" => seq, "t0" => t0}} ->
        t2 = sent_at_s || System.system_time(:microsecond) / 1_000_000

        pong = %{
          type: "clock_sync_pong",
          seq: seq,
          t0: t0,
          t1: received_at_s,
          t2: t2
        }

        {:ok, Jason.encode!(pong)}

      _ ->
        :ignore
    end
  end

  # -- Server events & `message.part` reassembly --

  @doc """
  Handles one incoming JSON binary from the `nuance_live` topic, maintaining
  `parts` state for `message.part` reassembly.

  Returns `{:ok, [event], new_parts}` or `{:error, reason, new_parts}`.
  """
  def decode_packet(data, parts \\ []) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => "message.part", "index" => idx, "count" => count, "text" => text}}
      when is_integer(idx) and is_integer(count) and is_binary(text) ->
        handle_part(idx, count, text, parts)

      {:ok, %{} = frame} ->
        {:ok, decode_event(frame), []}

      {:error, reason} ->
        {:error, reason, []}
    end
  end

  defp handle_part(idx, count, text, parts) do
    parts =
      cond do
        idx == length(parts) -> parts
        idx == 0 -> []
        true -> :drop
      end

    case parts do
      :drop ->
        {:ok, [], []}

      parts ->
        parts = parts ++ [text]

        if idx == count - 1 do
          joined = IO.iodata_to_binary(parts)

          case Jason.decode(joined) do
            {:ok, %{} = frame} -> {:ok, decode_event(frame), []}
            {:error, reason} -> {:error, reason, []}
          end
        else
          {:ok, [], parts}
        end
    end
  end

  @doc "Decodes a parsed `nuance_live` JSON map into internal events."
  def decode_event(%{"type" => "session.started"} = frame),
    do: [{:session_started, frame["session"] || %{}}]

  def decode_event(%{"type" => "session.updated"} = frame),
    do: [{:session_updated, frame["session"] || %{}}]

  def decode_event(%{"type" => "session.closed"} = frame),
    do: [{:session_closed, frame["reason"], frame}]

  def decode_event(%{"type" => "session.input_transcript.delta", "delta" => delta})
      when is_binary(delta),
      do: [{:transcription_delta, :user, delta}]

  def decode_event(%{"type" => "session.input_transcript.done", "transcript" => text} = frame)
      when is_binary(text),
      do: [
        {:transcription_done, :user, text,
         %{event_id: frame["event_id"], replaces_event_id: frame["replaces_event_id"]}}
      ]

  def decode_event(%{"type" => "session.output_transcript.delta", "delta" => delta})
      when is_binary(delta),
      do: [{:transcription, :assistant, delta}]

  def decode_event(%{"type" => "session.output_audio.done"} = frame),
    do: [{:output_audio_done, frame["reason"] || "completed", frame}]

  def decode_event(%{"type" => "session.delegation.created"} = frame),
    do: [{:delegation_created, frame["delegation"] || %{}}]

  def decode_event(%{"type" => "response.event", "event" => %{} = inner} = frame),
    do: decode_response_event(frame["delegation_id"], inner)

  def decode_event(%{"type" => "error", "error" => error}),
    do: [{:error, error}]

  def decode_event(%{"type" => "info"} = frame),
    do: [{:info, frame}]

  def decode_event(%{"type" => type} = frame)
      when type in [
             "session.thinking.appended",
             "session.instructions.appended",
             "session.commentary.appended",
             "session.input_audio.muted",
             "session.input_audio.unmuted",
             "session.usage.updated",
             "session.quiet.started",
             "session.quiet.ended"
           ],
      do: [{:ack, type, frame}]

  def decode_event(frame), do: [{:raw, frame}]

  defp decode_response_event(delegation_id, %{"type" => "response.output_item.done"} = inner) do
    case inner["item"] || inner["output_item"] do
      %{"type" => "function_call", "name" => name} = item when is_binary(name) ->
        call_id = item["call_id"] || item["id"]

        if is_binary(call_id) do
          [
            {:tool_call, delegation_id,
             [%{id: call_id, name: name, args: decode_args(item["arguments"])}]}
          ]
        else
          [{:response_event, delegation_id, inner}]
        end

      _other ->
        [{:response_event, delegation_id, inner}]
    end
  end

  defp decode_response_event(delegation_id, %{"type" => "response.completed"} = inner),
    do: [{:response_completed, delegation_id, inner}]

  defp decode_response_event(delegation_id, %{"type" => "response.failed"} = inner),
    do: [{:response_failed, delegation_id, inner}]

  defp decode_response_event(delegation_id, inner),
    do: [{:response_event, delegation_id, inner}]

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

  defp non_empty_string(str) when is_binary(str) and str != "", do: str
  defp non_empty_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
