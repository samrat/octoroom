defmodule Octoroom.Phoenix.ChannelTest do
  use ExUnit.Case, async: true

  alias Octoroom.Phoenix.Channel

  # The test process stands in for the room server: whatever the channel
  # forwards arrives here as a cast.
  setup do
    socket = %Phoenix.Socket{
      joined: true,
      topic: "room:r",
      ref: "1",
      join_ref: "1",
      transport_pid: self(),
      serializer: Phoenix.Socket.V2.JSONSerializer,
      assigns: %{octoroom: %{server: self(), participant_id: "p"}}
    }

    %{socket: socket}
  end

  @bad [
    {"publish", %{"sdp" => "offer", "mids" => "notamap"}},
    {"publish", %{"sdp" => "offer", "mids" => %{"mic" => 0}}},
    {"publish", %{"sdp" => 1, "mids" => %{"mic" => "0"}}},
    {"publish", %{"sdp" => "offer"}},
    {"publish", "notamap"},
    {"publish_tracks", %{"sources" => [%{}]}},
    {"publish_tracks", %{"sources" => "camera"}},
    {"push_offer", %{"sdp" => "offer", "op_id" => "op", "mids" => ["camera"]}},
    {"push_offer", %{"sdp" => "offer", "op_id" => 1, "mids" => %{"camera" => "1"}}},
    {"unpublish", %{"source" => %{}}},
    {"mute", %{"source" => "mic", "muted" => "yes"}},
    {"answer", %{"sdp" => "answer", "op_id" => nil}},
    {"close_offer", %{"sdp" => %{}, "op_id" => "op"}},
    {"worker_message", %{"worker" => 1, "payload" => %{}}},
    {"worker_message", %{"worker" => "assistant", "payload" => "hi"}},
    {"worker_message", %{"worker" => "assistant"}}
  ]

  test "a known event with a malformed body is refused before it reaches the room", ctx do
    for {event, payload} <- @bad do
      assert {:reply, {:error, %{reason: "bad_payload"}}, _} =
               Channel.__handle_in__(event, payload, ctx.socket),
             "#{event} #{inspect(payload)}"
    end

    refute_received {:"$gen_cast", _}
  end

  test "an unknown event is refused as unknown", ctx do
    assert {:reply, {:error, %{reason: "unknown_event"}}, _} =
             Channel.__handle_in__("dance", %{}, ctx.socket)
  end

  test "well-formed payloads are forwarded to the room", ctx do
    mids = %{"mic" => "0"}

    assert {:noreply, _} =
             Channel.__handle_in__("publish", %{"sdp" => "offer", "mids" => mids}, ctx.socket)

    assert_received {:"$gen_cast", {:publish, "p", "offer", ^mids, _ref}}

    assert {:noreply, _} =
             Channel.__handle_in__("publish_tracks", %{"sources" => ["camera"]}, ctx.socket)

    assert_received {:"$gen_cast", {:publish_tracks, "p", ["camera"], _ref}}

    payload = %{"sdp" => "offer", "op_id" => "op", "mids" => %{"camera" => "1"}}
    assert {:noreply, _} = Channel.__handle_in__("push_offer", payload, ctx.socket)
    assert_received {:"$gen_cast", {:push_offer, "p", "op", "offer", %{"camera" => "1"}, _ref}}

    payload = %{"source" => "mic", "muted" => true}
    assert {:reply, :ok, _} = Channel.__handle_in__("mute", payload, ctx.socket)
    assert_received {:"$gen_cast", {:mute, "p", "mic", true}}
  end

  test "a message to a worker is forwarded, unless it's too large", ctx do
    payload = %{"text" => "hi"}

    assert {:noreply, _} =
             Channel.__handle_in__(
               "worker_message",
               %{"worker" => "assistant", "payload" => payload},
               ctx.socket
             )

    assert_received {:"$gen_cast", {:worker_message, "p", "assistant", ^payload, _ref}}

    big = %{"text" => String.duplicate("a", 16_384)}

    assert {:reply, {:error, %{reason: "too_large"}}, _} =
             Channel.__handle_in__(
               "worker_message",
               %{"worker" => "assistant", "payload" => big},
               ctx.socket
             )

    refute_received {:"$gen_cast", _}
  end

  test "connected forwards the client's join timings, keeping only known numbers", ctx do
    assert {:reply, :ok, _} = Channel.__handle_in__("connected", %{}, ctx.socket)
    assert_received {:"$gen_cast", {:connected, "p", timings}}
    assert timings == %{}

    payload = %{
      "timings" => %{
        "join_ms" => 80,
        "media_ms" => 612.5,
        "ice_ms" => 2001,
        "ice_timed_out" => true,
        "publish_ms" => -1,
        "connect_ms" => "190",
        "made_up_ms" => 1
      }
    }

    assert {:reply, :ok, _} = Channel.__handle_in__("connected", payload, ctx.socket)
    assert_received {:"$gen_cast", {:connected, "p", timings}}
    assert timings == %{join_ms: 80, media_ms: 612.5, ice_ms: 2001, ice_timed_out: true}

    payload = %{"timings" => %{"ice_timed_out" => "yes"}}
    assert {:reply, :ok, _} = Channel.__handle_in__("connected", payload, ctx.socket)
    assert_received {:"$gen_cast", {:connected, "p", timings}}
    assert timings == %{}
  end
end
