defmodule Octoroom.Agent.ToolsTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Tool
  alias Octoroom.Agent.ToolAdapters.Gemini
  alias Octoroom.Agent.ToolAdapters.OpenAI
  alias Octoroom.Agent.ToolDispatcher
  alias Octoroom.Agent.ToolResult

  defmodule FocusHandler do
    def set_focus(%{id: id, name: name, args: args}, context) do
      focus = args["focus"]

      {%{id: id, name: name, response: %{result: "ok", focus: focus}},
       %{type: "poc_focus_set", focus: focus}, Map.put(context, :focus, focus)}
    end
  end

  test "Gemini adapter renders logical tools as function declarations" do
    assert [
             %{
               functionDeclarations: [
                 %{
                   name: "review_card",
                   parameters: %{
                     type: "OBJECT",
                     properties: %{
                       card_id: %{type: "STRING"},
                       rating: %{type: "STRING", enum: ["again", "hard", "good", "easy"]},
                       answer: %{type: "STRING"}
                     },
                     required: ["card_id", "rating", "answer"]
                   }
                 }
               ]
             }
           ] = Gemini.to_declarations([review_card_tool()])
  end

  test "OpenAI adapter renders logical tools as Responses API function tools" do
    assert [
             %{
               type: "function",
               name: "create_cards",
               parameters: %{
                 type: "object",
                 properties: %{
                   deck_id: %{type: "string"},
                   cards: %{type: "array"}
                 },
                 required: ["deck_id", "cards"]
               }
             }
           ] = OpenAI.to_responses_tools([create_cards_tool()])
  end

  test "tool dispatcher routes arbitrary app tool calls through their handlers" do
    call = %{
      id: "call-1",
      name: "set_voice_focus",
      args: %{"focus" => "Prototype review"}
    }

    assert {[
              {%{
                 id: "call-1",
                 name: "set_voice_focus",
                 response: %{result: "ok", focus: "Prototype review"}
               }, %{type: "poc_focus_set", focus: "Prototype review"}}
            ], %{focus: "Prototype review"}} =
             ToolDispatcher.handle_calls([call], [focus_tool()], %{})
  end

  test "ToolResult.summary compacts and truncates large tool payloads" do
    big = String.duplicate("a", 1_500)

    summary =
      ToolResult.summary(%{
        call_id: "c1",
        name: "search",
        args: %{"query" => big},
        response: %{"body" => big}
      })

    assert summary.call_id == "c1"
    assert summary.name == "search"
    assert String.ends_with?(summary.args, "…")
    assert String.length(summary.args) <= 301
    assert String.ends_with?(summary.response, "…")
    assert String.length(summary.response) <= 1_001
    assert ToolResult.format(summary) == "search(#{summary.args}) -> #{summary.response}"
  end

  defp review_card_tool do
    %Tool{
      name: "review_card",
      description: "Grade the current review card.",
      parameters: %{
        type: "object",
        properties: %{
          card_id: %{type: "string"},
          rating: %{type: "string", enum: ["again", "hard", "good", "easy"]},
          answer: %{type: "string"}
        },
        required: ["card_id", "rating", "answer"]
      }
    }
  end

  defp create_cards_tool do
    %Tool{
      name: "create_cards",
      description: "Create cards.",
      parameters: %{
        type: "object",
        properties: %{
          deck_id: %{type: "string"},
          cards: %{type: "array", items: %{type: "object"}}
        },
        required: ["deck_id", "cards"]
      }
    }
  end

  defp focus_tool do
    %Tool{
      name: "set_voice_focus",
      description: "Set the current focus.",
      parameters: %{
        type: "object",
        properties: %{focus: %{type: "string"}},
        required: ["focus"]
      },
      handler: {FocusHandler, :set_focus}
    }
  end
end
