defmodule Octoroom.Agent.Cascaded.LLMTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Cascaded.LLM
  alias ReqLLM.{Message, Response, StreamChunk, ToolCall}
  alias ReqLLM.Message.ContentPart

  test "builds Gemini tool result messages for ReqLLM continuation" do
    assert [
             %ReqLLM.Message{
               role: :tool,
               tool_call_id: "call-1",
               name: "set_voice_focus",
               content: [%ReqLLM.Message.ContentPart{type: :text, text: content}],
               metadata: %{tool_output: %{result: "ok"}}
             }
           ] =
             LLM.tool_result_messages(:google, [
               %{call_id: "call-1", name: "set_voice_focus", response: %{result: "ok"}}
             ])

    assert Jason.decode!(content) == %{"result" => "ok"}
  end

  test "streams Gemini deltas and returns a normalized final response" do
    parent = self()

    stream_fun = fn model, input, opts ->
      send(parent, {:stream_request, model, input, opts})
      {:ok, :stream_response}
    end

    process_stream_fun = fn :stream_response, callbacks ->
      callbacks[:on_result].("Captured")
      callbacks[:on_result].(" it.")
      callbacks[:on_thinking].("checking")

      callbacks[:on_tool_call].(
        StreamChunk.tool_call("set_voice_focus", %{"focus" => "Launch"}, %{id: "call-1"})
      )

      callbacks[:on_meta].(StreamChunk.meta(%{finish_reason: :stop}))

      {:ok,
       %Response{
         id: "response-1",
         model: "gemini-3.5-flash",
         context: [],
         message: %Message{
           role: :assistant,
           content: [ContentPart.text("Captured it.")],
           tool_calls: [ToolCall.new("call-1", "set_voice_focus", ~s({"focus":"Launch"}))]
         },
         usage: %{input_tokens: 10, output_tokens: 4},
         finish_reason: :tool_calls,
         provider_meta: %{request_id: "req-1"}
       }}
    end

    assert {:ok,
            %{
              text: "Captured it.",
              function_calls: [
                %{id: "call-1", name: "set_voice_focus", args: %{"focus" => "Launch"}}
              ],
              continuation: [%Message{role: :assistant}]
            }} =
             LLM.stream_turn(
               provider: :google,
               model: "gemini-3.5-flash",
               token: "unused",
               input: [%{role: "user", content: "Capture this"}],
               max_tokens: 160,
               reasoning_effort: :minimal,
               stream_fun: stream_fun,
               process_stream_fun: process_stream_fun,
               on_event: fn event -> send(parent, {:stream_event, event}) end
             )

    assert_receive {:stream_request, %{provider: :google, id: "gemini-3.5-flash"},
                    [%{role: "user", content: "Capture this"}], opts}

    assert Keyword.fetch!(opts, :max_tokens) == 160
    assert Keyword.fetch!(opts, :reasoning_effort) == :minimal
    assert Keyword.fetch!(opts, :tool_choice) == :auto

    assert_receive {:stream_event, {:text_delta, "Captured"}}
    assert_receive {:stream_event, {:text_delta, " it."}}
    assert_receive {:stream_event, {:thinking_delta, "checking"}}

    assert_receive {:stream_event,
                    {:tool_call_delta,
                     %{
                       id: "call-1",
                       name: "set_voice_focus",
                       args: %{"focus" => "Launch"}
                     }}}

    assert_receive {:stream_event, {:metadata, %{finish_reason: :stop}}}

    assert_receive {:stream_event,
                    {:tool_calls,
                     [
                       %{id: "call-1", name: "set_voice_focus", args: %{"focus" => "Launch"}}
                     ]}}

    assert_receive {:stream_event,
                    {:done,
                     %{
                       finish_reason: :tool_calls,
                       usage: %{input_tokens: 10, output_tokens: 4},
                       provider_meta: %{request_id: "req-1"}
                     }}}
  end

  test "routes OpenRouter turns through ReqLLM with provider options" do
    parent = self()

    stream_fun = fn model, input, opts ->
      send(parent, {:stream_request, model, input, opts})
      {:ok, :stream_response}
    end

    process_stream_fun = fn :stream_response, callbacks ->
      callbacks[:on_result].("Hi.")

      {:ok,
       %Response{
         id: "response-1",
         model: "nvidia/nemotron-3.5-lightning",
         context: [],
         message: %Message{role: :assistant, content: [ContentPart.text("Hi.")]},
         finish_reason: :stop
       }}
    end

    assert {:ok, %{text: "Hi.", function_calls: []}} =
             LLM.stream_turn(
               provider: :openrouter,
               model: "nvidia/nemotron-3.5-lightning",
               input: [%{role: "user", content: "Hello"}],
               reasoning_effort: :none,
               provider_options: [openrouter_provider: %{sort: "latency"}],
               stream_fun: stream_fun,
               process_stream_fun: process_stream_fun
             )

    assert_receive {:stream_request,
                    %{provider: :openrouter, id: "nvidia/nemotron-3.5-lightning"}, _input, opts}

    assert Keyword.fetch!(opts, :reasoning_effort) == :none
    assert Keyword.fetch!(opts, :provider_options) == [openrouter_provider: %{sort: "latency"}]

    assert [%Message{role: :tool}] =
             LLM.tool_result_messages(:openrouter, [
               %{call_id: "call-1", name: "set_voice_focus", response: %{result: "ok"}}
             ])
  end
end
