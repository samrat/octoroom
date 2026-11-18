defmodule Octoroom.Agent.Processors.ContextTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors.Context

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

  test "carries on from what was saved" do
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

    assert last_request(harness) == saved.history ++ [%{role: "user", content: "What's my name?"}]

    assert_received {:voice_pipeline, _,
                     {:conversation, %{conversation_id: "conv", sequence: 8, role: "user"}}}
  end
end
