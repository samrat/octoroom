defmodule Octoroom.AgentTest do
  use ExUnit.Case, async: true

  @thresholds %{reply_above: 0.7, wait_above: 0.35, answer_above: 0.7, wait_ms: 2_500}

  defp ctx(id, roster \\ nil),
    do: %{agent_id: id, name: String.capitalize(id), roster: roster, thresholds: @thresholds}

  @roster [
    %{id: "assistant", name: "Assistant", description: nil},
    %{id: "atlas", name: "Atlas", description: "Answers questions about capital cities."}
  ]

  describe "default_questions/1" do
    test "one agent: who it's for, and whether it can answer" do
      questions = Octoroom.Agent.default_questions(ctx("assistant"))
      assert Map.keys(questions) |> Enum.sort() == ["addressee", "answerable"]

      assert Map.keys(questions["addressee"].criteria) |> Enum.sort() ==
               ~w(assistant group nobody person)
    end

    test "several agents: each by name and description, each with its own answerable" do
      questions = Octoroom.Agent.default_questions(ctx("assistant", @roster))
      assert questions["addressee"].instructions =~ "AI assistants: Assistant, Atlas"

      assert questions["addressee"].criteria["atlas"] =~
               "Atlas, an AI assistant in the call. Answers questions about capital cities."

      assert questions["answerable_atlas"].instructions =~ "capital cities"
      assert Map.has_key?(questions, "answerable_assistant")
      refute Map.has_key?(questions, "answerable")
    end
  end

  describe "decide/2" do
    test "one agent reads the old \"assistant\" choice" do
      d = %{addressee: "assistant", probabilities: %{"assistant" => 0.8}, answerable: 0.9}
      assert {:reply, :addressed} = Octoroom.Agent.decide(%{decision: d}, ctx("helper"))
    end

    test "its name is a reply" do
      d = %{addressee: "group", probabilities: %{"atlas" => 0.1}}

      assert {:reply, :name} =
               Octoroom.Agent.decide(%{decision: d, named: true}, ctx("atlas", @roster))
    end

    test "agent ids become question names the API takes" do
      assert Octoroom.Agent.question_key("room:1/bot") == "room_1_bot"
    end

    test "maybe addressed waits only if no other agent is likelier" do
      d = %{addressee: "atlas", probabilities: %{"assistant" => 0.4, "atlas" => 0.5}}
      assert {:listen, _} = Octoroom.Agent.decide(%{decision: d}, ctx("assistant", @roster))

      assert {:wait, :maybe_addressed} =
               Octoroom.Agent.decide(%{decision: d}, ctx("atlas", @roster))
    end
  end

  test "agents/2 gives each agent the roster, with its own options over the shared ones" do
    [assistant, atlas] =
      Octoroom.Agent.agents(
        [
          {"assistant", Octoroom.AgentTest.Bare, name: "Assistant"},
          {"atlas", Octoroom.AgentTest.Bare, name: "Atlas", description: "Capitals.", gate: :name}
        ],
        hears: [],
        gate: :decision
      )

    assert assistant.args.gate == :decision
    assert atlas.args.gate == :name

    assert [%{id: "assistant", name: "Assistant"}, %{id: "atlas", description: "Capitals."}] =
             atlas.args.roster

    assert assistant.args.roster == atlas.args.roster
  end

  defmodule Bare do
    use Octoroom.Agent
  end
end
