defmodule HelloWeb.AgentLiveTest do
  use HelloWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp agent(view, event),
    do: send(view.pid, {:octoroom, "test", {:worker_event, "assistant", {:agent, event}}})

  defp said(view, text), do: agent(view, {:conversation, %{role: "user", text: text}})

  defp replied(view, id, text),
    do: agent(view, {:conversation, %{role: "assistant", message_id: id, text: text}})

  @latency %{transcript: 600, llm: 900, audio: 1_200}

  test "renders the page with the join button and recorded questions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#agent[phx-hook=Agent]")
    assert has_element?(view, "#join", "Join")
    assert has_element?(view, ~s(button.ask[data-src="/questions/0.wav"]))
  end

  test "the greeting isn't a reply", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    replied(view, "a0", "Hi there!")
    refute render(view) =~ "Hi there!"
  end

  test "times arriving before the reply go on it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    said(view, "What is the capital of France?")
    agent(view, {:latency, @latency})
    render_hook(view, "heard", %{"ms" => 1_480.4})
    replied(view, "a1", "Paris.")

    assert has_element?(view, "#reply-a1", "What is the capital of France?")
    assert has_element?(view, "#reply-a1", "1200 ms")
    assert has_element?(view, "#reply-a1", "1480 ms")
    assert has_element?(view, "#median", "1480 ms")
  end

  test "times arriving after the reply go on it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    said(view, "Name a primary colour.")
    replied(view, "a1", "Red.")
    agent(view, {:latency, @latency})
    render_hook(view, "heard", %{"ms" => 1_500})

    assert has_element?(view, "#reply-a1", "900 ms")
    assert has_element?(view, "#reply-a1", "1500 ms")
  end

  test "a typed turn has the agent's times but nothing heard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent(view, {:decision, %{why: :typed}})
    said(view, "hello")
    replied(view, "a1", "Hi!")
    agent(view, {:latency, @latency})
    render_hook(view, "heard", %{"ms" => 999})

    assert has_element?(view, "#reply-a1", "typed")
    assert has_element?(view, "#reply-a1", "1200 ms")
    refute has_element?(view, "#reply-a1", "999 ms")
  end
end
