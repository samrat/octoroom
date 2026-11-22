defmodule Octoroom.Agent.Processors.ContextTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors.Context
  alias Octoroom.Agent.Restore

  defp start, do: processor(:context, Context) |> Harness.start!(ctx: %{owner: self()})

  defp history(harness), do: Harness.state(harness, :context).history

  defp last_request(harness),
    do: harness |> Harness.outputs(Frames.LLMContext) |> List.last() |> Map.fetch!(:messages)

  test "a reply keeps its place while turns heard during its audio come after it" do
    harness =
      start()
      |> Harness.push(%Frames.Transcription{
        text: "Tell me a story.",
        speaker: "Alice",
        turn_id: 1
      })
      # Bob talks while the reply plays: history only.
      |> Harness.push(%Frames.Transcription{
        text: "Nice.",
        speaker: "Bob",
        turn_id: 2,
        respond: false
      })
      |> Harness.push(%Frames.AssistantMessage{text: "Once upon a time."}, :upstream)

    assert history(harness) == [
             %{role: "user", content: "[Alice] Tell me a story."},
             %{role: "assistant", content: "Once upon a time."},
             %{role: "user", content: "[Bob] Nice."}
           ]
  end

  test "an interrupted reply says so, and an empty one leaves no trace" do
    harness =
      start()
      |> Harness.push(%Frames.Transcription{text: "Tell me a story.", turn_id: 1})
      |> Harness.push(%Frames.AssistantMessage{text: "Once upon", interrupted?: true}, :upstream)
      |> Harness.push(%Frames.Transcription{text: "Stop.", turn_id: 2})
      |> Harness.push(%Frames.AssistantMessage{text: "", interrupted?: true}, :upstream)

    assert history(harness) == [
             %{role: "user", content: "Tell me a story."},
             %{role: "assistant", content: "Once upon… [interrupted]"},
             %{role: "user", content: "Stop."}
           ]

    # The app's conversation event has just the words.
    assert_received {:voice_pipeline, _,
                     {:conversation,
                      %{role: "assistant", text: "Once upon", status: "interrupted"}}}
  end

  test "a reply's reserved place is never sent to the LLM" do
    harness =
      start()
      |> Harness.push(%Frames.Transcription{text: "Hi.", turn_id: 1})
      # A second turn starts a reply before the first one came back.
      |> Harness.push(%Frames.Transcription{text: "Hello?", turn_id: 2})

    assert last_request(harness) == [
             %{role: "user", content: "Hi."},
             %{role: "user", content: "Hello?"}
           ]

    # Replies fill their places in order.
    harness =
      harness
      |> Harness.push(%Frames.AssistantMessage{text: "Hi!"}, :upstream)
      |> Harness.push(%Frames.AssistantMessage{text: "Yes?"}, :upstream)

    assert history(harness) == [
             %{role: "user", content: "Hi."},
             %{role: "assistant", content: "Hi!"},
             %{role: "user", content: "Hello?"},
             %{role: "assistant", content: "Yes?"}
           ]
  end

  test "a reply still playing is in the requests of replies that start meanwhile" do
    harness =
      start()
      |> Harness.push(%Frames.Transcription{text: "Talk for a while.", turn_id: 1})
      |> Harness.push(%Frames.AssistantDraft{text: "Sure, here is a long answer."}, :upstream)
      |> Harness.push(%Frames.Transcription{text: "Stop.", turn_id: 2})

    assert last_request(harness) == [
             %{role: "user", content: "Talk for a while."},
             %{role: "assistant", content: "Sure, here is a long answer."},
             %{role: "user", content: "Stop."}
           ]

    # The heard version replaces the draft.
    harness =
      Harness.push(
        harness,
        %Frames.AssistantMessage{text: "Sure, here", interrupted?: true},
        :upstream
      )

    assert [_, %{role: "assistant", content: "Sure, here… [interrupted]"}, _, _] =
             history(harness)
  end

  test "the app sees a playing reply in its place, then the same item updated" do
    start()
    |> Harness.push(%Frames.Transcription{text: "Talk for a while.", turn_id: 1})
    |> Harness.push(%Frames.AssistantDraft{text: "Sure, here is a long answer."}, :upstream)
    |> Harness.push(%Frames.AssistantMessage{text: "Sure, here", interrupted?: true}, :upstream)

    assert_received {:voice_pipeline, _, {:conversation, %{role: "user"}}}

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "assistant", status: "playing", message_id: id}}}

    assert_received {:voice_pipeline, _,
                     {:conversation,
                      %{
                        role: "assistant",
                        status: "interrupted",
                        text: "Sure, here",
                        message_id: ^id
                      }}}
  end

  defp memories do
    receive do
      {:voice_pipeline, _, {:memory, memory}} -> [memory | memories()]
    after
      0 -> []
    end
  end

  test "tells its owner what to keep: finished messages only" do
    start()
    |> Harness.push(%Frames.Transcription{text: "Hi.", speaker: "Alice", turn_id: 1})
    |> Harness.push(%Frames.AssistantDraft{text: "Hello there."}, :upstream)
    |> Harness.push(%Frames.AssistantMessage{text: "Hello there."}, :upstream)

    # Once for the user's turn (its reply's place isn't kept), once for the
    # reply; the draft and the item it reserved change only the sequence.
    assert [
             %{history: [%{role: "user", content: "[Alice] Hi."}], conversation: c1},
             %{conversation: c2},
             %{
               history: [_, %{role: "assistant", content: "Hello there."}],
               conversation: c2
             }
           ] = memories()

    assert c1.id == c2.id and c2.sequence > c1.sequence
  end

  test "carries on from what was saved, with a reconnect notice by default" do
    saved = %{
      history: [
        %{role: "user", content: "[Alice] My name is Alice."},
        %{role: "assistant", content: "Nice to meet you, Alice."}
      ],
      conversation: %{id: "conv", sequence: 7}
    }

    harness =
      processor(:context, Context)
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Transcription{text: "What's my name?", turn_id: 1})

    assert last_request(harness) ==
             saved.history ++
               [
                 %{role: "user", content: Restore.default_context_notice()},
                 %{role: "user", content: "What's my name?"}
               ]

    assert_received {:voice_pipeline, _,
                     {:conversation, %{conversation_id: "conv", sequence: 8, role: "user"}}}
  end

  test "restore option controls history, tool results, and reconnect notice" do
    saved = %{
      history: [
        %{role: "user", content: "[Alice] Check Friday."},
        %{
          role: "user",
          content: ~s|[Tool result, not said by the user] check() -> {"open":true}|,
          tool_result: true
        },
        %{role: "assistant", content: "Friday is open."}
      ],
      conversation: %{id: "conv", sequence: 3}
    }

    # Omit reconnect notice and tool results.
    harness =
      processor(:context, Context, restore: [tool_results: false, notice: false])
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Transcription{text: "Book it.", turn_id: 1})

    assert last_request(harness) == [
             %{role: "user", content: "[Alice] Check Friday."},
             %{role: "assistant", content: "Friday is open."},
             %{role: "user", content: "Book it."}
           ]

    # Custom reconnect notice, keeping tool results without conversation history.
    harness =
      processor(:context, Context,
        restore: [history: false, tool_results: true, notice: "[Reconnected] Brief recap above."]
      )
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Transcription{text: "Book it.", turn_id: 1})

    assert last_request(harness) == [
             %{
               role: "user",
               content: ~s|[Tool result, not said by the user] check() -> {"open":true}|
             },
             %{role: "user", content: "[Reconnected] Brief recap above."},
             %{role: "user", content: "Book it."}
           ]

    # restore: false starts fresh.
    harness =
      processor(:context, Context, restore: false)
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Transcription{text: "Hello?", turn_id: 1})

    assert last_request(harness) == [%{role: "user", content: "Hello?"}]
  end

  test "restore: [prompt: true | string] triggers a reply on Start unless a turn arrives first" do
    saved = %{
      history: [
        %{role: "user", content: "[Alice] Check Friday."},
        %{role: "assistant", content: "Friday is open."}
      ],
      conversation: %{id: "conv", sequence: 2}
    }

    # prompt: true replies directly to the restored context (including the reconnect notice)
    # without duplicating the notice.
    harness =
      processor(:context, Context, restore: [prompt: true])
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Start{})

    assert Harness.timer_pending?(harness, :context, :restore_prompt)
    harness = Harness.fire_timer(harness, :context, :restore_prompt)

    assert last_request(harness) ==
             saved.history ++ [%{role: "user", content: Restore.default_context_notice()}]

    assert {:status, "Thinking"} in Harness.notifications(harness)

    # Custom prompt string sends an app-originated prompt message.
    harness =
      processor(:context, Context,
        restore: [notice: false, prompt: "Let Alice know you're back and continue."]
      )
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Start{})
      |> Harness.fire_timer(:context, :restore_prompt)

    assert last_request(harness) ==
             saved.history ++
               [
                 %{
                   role: "user",
                   content:
                     "[From the app, not said by anyone on the call] Let Alice know you're back and continue."
                 }
               ]

    # If the user speaks before the delay elapses, the pending restore prompt is cancelled.
    harness =
      processor(:context, Context, restore: [prompt: true])
      |> Harness.start!(ctx: %{owner: self(), saved: saved})
      |> Harness.push(%Frames.Start{})
      |> Harness.push(%Frames.Transcription{text: "Are you there?", turn_id: 1})

    refute Harness.timer_pending?(harness, :context, :restore_prompt)
  end

  test "saves blocking tool call results into history and memory before the reply completes" do
    harness =
      start()
      |> Harness.push(%Frames.Transcription{text: "Check Friday.", speaker: "Alice", turn_id: 1})
      |> Harness.push(
        %Frames.ToolResults{
          messages: [],
          results: [
            %{
              call_id: "c1",
              name: "check_availability",
              args: ~s({"date":"2026-11-27"}),
              response: ~s({"slots":["09:00","14:00"]})
            }
          ]
        },
        :upstream
      )

    # Even before the assistant reply arrives, the tool result is saved in memory.
    assert Enum.any?(memories(), fn %{history: hist} ->
             Enum.any?(
               hist,
               &(&1.role == "user" and
                   &1.content =~ ~s|check_availability({"date":"2026-11-27"})| and
                   &1.content =~ ~s|"09:00"|)
             )
           end)

    assert_received {:voice_pipeline, _,
                     {:tool_result,
                      %{
                        call_id: "c1",
                        name: "check_availability",
                        args: ~s({"date":"2026-11-27"}),
                        response: ~s({"slots":["09:00","14:00"]})
                      }}}

    harness =
      Harness.push(
        harness,
        %Frames.AssistantMessage{text: "Friday has 9 AM and 2 PM open."},
        :upstream
      )

    assert [
             %{role: "user", content: "[Alice] Check Friday."},
             %{
               role: "user",
               content: "[Tool result, not said by the user] check_availability" <> _
             },
             %{role: "assistant", content: "Friday has 9 AM and 2 PM open."}
           ] = history(harness)
  end
end
