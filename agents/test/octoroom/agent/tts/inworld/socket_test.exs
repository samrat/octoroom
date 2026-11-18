defmodule Octoroom.Agent.TTS.Inworld.SocketTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TTS.Inworld.Socket

  defp state(contexts \\ %{}),
    do: %{owner: self(), owner_ref: nil, contexts: contexts, next_id: 0}

  defp context(caller \\ self()),
    do: %{caller: caller, ref: make_ref(), monitor: Process.monitor(caller)}

  defp result(body), do: {:text, Jason.encode!(%{"result" => body})}

  # Sends what one `{:reply, ...}` and the `:send_frames` messages after it
  # would put on the wire.
  defp drain({:reply, {:text, json}, state}, frames) do
    receive do
      {:send_frames, rest} ->
        drain(Socket.handle_info({:send_frames, rest}, state), [json | frames])
    after
      0 -> {Enum.reverse([json | frames]) |> Enum.map(&Jason.decode!/1), state}
    end
  end

  test "a speak opens a context, sends its text, flushes and closes it" do
    config = %{
      voiceId: "Ashley",
      modelId: "inworld-tts-2",
      audioConfig: %{audioEncoding: "LINEAR16"}
    }

    ref = make_ref()

    {frames, state} =
      drain(Socket.handle_cast({:speak, self(), ref, "Hello there", config}, state()), [])

    assert frames == [
             %{
               "contextId" => "octoroom-0",
               "create" => %{
                 "voiceId" => "Ashley",
                 "modelId" => "inworld-tts-2",
                 "audioConfig" => %{"audioEncoding" => "LINEAR16"}
               }
             },
             %{"contextId" => "octoroom-0", "sendText" => %{"text" => "Hello there"}},
             %{"contextId" => "octoroom-0", "flushContext" => %{}},
             %{"contextId" => "octoroom-0", "closeContext" => %{}}
           ]

    assert %{next_id: 1, contexts: %{"octoroom-0" => %{ref: ^ref}}} = state
  end

  test "audio goes to the caller, wav headers stripped, until the context closes" do
    %{ref: ref} = context = context()
    state = state(%{"c1" => context})

    wav =
      "RIFF" <>
        <<0::32-little>> <> "WAVEfmt " <> <<0::size(128)>> <> "data" <> <<2::32-little, 7, 8>>

    audio =
      result(%{"contextId" => "c1", "audioChunk" => %{"audioContent" => Base.encode64(wav)}})

    {:ok, state} = Socket.handle_frame(audio, state)
    assert_receive {^ref, {:audio, <<7, 8>>}}

    {:ok, state} =
      Socket.handle_frame(result(%{"contextId" => "c1", "flushCompleted" => %{}}), state)

    refute_receive {^ref, :done}

    {:ok, state} =
      Socket.handle_frame(result(%{"contextId" => "c1", "contextClosed" => %{}}), state)

    assert_receive {^ref, :done}
    assert state.contexts == %{}
  end

  test "a status error fails its context" do
    %{ref: ref} = context = context()

    frame =
      result(%{"contextId" => "c1", "status" => %{"code" => 3, "message" => "bad voice"}})

    {:ok, state} = Socket.handle_frame(frame, state(%{"c1" => context}))

    assert_receive {^ref,
                    {:error, {:inworld_speech_failed, %{"code" => 3, "message" => "bad voice"}}}}

    assert state.contexts == %{}
  end

  test "a caller that exits gets its context cancelled" do
    caller = spawn(fn -> :ok end)
    context = context(caller)
    assert_receive {:DOWN, monitor, :process, ^caller, _reason} when monitor == context.monitor

    assert {:reply, {:text, json}, state} =
             Socket.handle_info(
               {:DOWN, context.monitor, :process, caller, :normal},
               state(%{"c1" => context})
             )

    assert Jason.decode!(json) == %{"contextId" => "c1", "cancelContext" => %{}}
    assert state.contexts == %{}
  end

  test "a disconnect fails every context, then reconnects a few times" do
    %{ref: ref} = context = context()
    state = state(%{"c1" => context})

    assert {:reconnect, %{contexts: contexts}} =
             Socket.handle_disconnect(%{reason: {:remote, :closed}, attempt_number: 1}, state)

    assert contexts == %{}
    assert_receive {^ref, {:error, {:inworld_socket_disconnected, {:remote, :closed}}}}

    assert {:ok, _state} =
             Socket.handle_disconnect(%{reason: {:remote, :closed}, attempt_number: 3}, state())

    assert {:ok, _state} =
             Socket.handle_disconnect(%{reason: {:local, :normal}, attempt_number: 1}, state())
  end

  test "speak/5 passes audio on until done" do
    socket =
      fake_socket(fn caller, ref ->
        send(caller, {ref, {:audio, <<1, 2>>}})
        send(caller, {ref, {:audio, <<3>>}})
        send(caller, {ref, :done})
      end)

    parent = self()
    assert :ok = Socket.speak(socket, "Hi", %{}, &send(parent, {:audio, &1}), 1_000)
    assert_receive {:audio, <<1, 2>>}
    assert_receive {:audio, <<3>>}
  end

  test "speak/5 fails when the socket goes down or stays quiet" do
    down = fake_socket(fn _caller, _ref -> exit(:boom) end)

    assert {:error, {:inworld_socket_down, :boom}} =
             Socket.speak(down, "Hi", %{}, fn _ -> :ok end, 1_000)

    quiet = fake_socket(fn _caller, _ref -> Process.sleep(:infinity) end)
    assert {:error, :inworld_socket_timeout} = Socket.speak(quiet, "Hi", %{}, fn _ -> :ok end, 50)
  end

  test "text over Inworld's limit is split, on whitespace when it can be" do
    words = String.duplicate("word ", 900)
    parts = Socket.text_parts(words)
    assert length(parts) == 3
    assert Enum.join(parts) == words
    assert Enum.all?(parts, &(String.length(&1) <= 2_000))

    unbroken = String.duplicate("é", 4_500)
    assert Enum.map(Socket.text_parts(unbroken), &String.length/1) == [2_000, 2_000, 500]
    assert Socket.text_parts("short") == ["short"]
  end

  defp fake_socket(respond) do
    spawn(fn ->
      receive do
        {:"$websockex_cast", {:speak, caller, ref, _text, _config}} -> respond.(caller, ref)
      end

      Process.sleep(:infinity)
    end)
  end
end
