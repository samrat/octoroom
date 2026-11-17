defmodule Octoroom.Agent.ConversationEventsTest do
  use ExUnit.Case, async: true
  alias Octoroom.Agent.ConversationEvents, as: Events

  test "items have stable conversation identity, unique message IDs and commit ordering" do
    state = %{owner: self(), conversation_events: Events.new()}
    state = state |> Events.append(:user, "Hi") |> Events.commit(:user)
    assert_receive {:voice_pipeline, _, {:conversation, first}}

    state =
      state
      |> Events.append(:assistant, "Hel")
      |> Events.append(:assistant, "lo")
      |> Events.commit(:assistant)

    assert_receive {:voice_pipeline, _, {:conversation, second}}
    assert first.conversation_id == second.conversation_id
    assert first.message_id != second.message_id
    assert {first.sequence, second.sequence, second.text} == {1, 2, "Hello"}
    state |> Events.commit(:assistant) |> Events.append(:user, " ") |> Events.commit(:user)
    refute_receive {:voice_pipeline, _, {:conversation, _}}, 10
  end

  test "a reserved item keeps its place in the sequence when committed later" do
    state = %{owner: self(), conversation_events: Events.new()}
    {state, reservation} = Events.reserve(state)
    state = state |> Events.append(:assistant, "Sure.") |> Events.commit(:assistant)
    assert_receive {:voice_pipeline, _, {:conversation, %{role: "assistant", sequence: 2}}}

    Events.commit_reserved(state, :user, reservation, "Can you help?")

    assert_receive {:voice_pipeline, _,
                    {:conversation, %{role: "user", text: "Can you help?", sequence: 1} = item}}

    assert item.conversation_id == state.conversation_events.id
    Events.commit_reserved(state, :user, reservation, " ")
    refute_receive {:voice_pipeline, _, {:conversation, _}}, 10
  end
end
