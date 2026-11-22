defmodule VisionWeb.VisionLiveTest do
  use VisionWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the vision page and toggles pipeline mode", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Talk to a vision agent"
    assert html =~ ~s(data-mode="cascaded")
    assert html =~ "Cascaded (Gemini Flash)"
    assert html =~ "Gemini Live"

    updated = view |> element("button", "Gemini Live") |> render_click()
    assert updated =~ ~s(data-mode="gemini_live")
  end

  test "Vision.Room uses join mode when room starts and allows mode assign override" do
    {:ok, meta} = Vision.Room.join(%{"mode" => "gemini_live"}, nil)
    p = %Octoroom.Participant{id: "guest", meta: meta}
    room = %Octoroom.Room{id: "r1", participants: [p], assigns: %{mode: nil}}

    assert [%{id: "assistant", args: %{agent: Vision.GeminiAssistant, name: "Gemini Live"}}] =
             Vision.Room.workers(room)

    room_override = %{room | assigns: %{mode: :cascaded}}

    assert [%{id: "assistant", args: %{agent: Vision.CascadedAssistant, name: "Cascaded"}}] =
             Vision.Room.workers(room_override)
  end
end
