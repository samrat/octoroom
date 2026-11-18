if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Octoroom.Phoenix.Channel do
    @moduledoc """
    A Phoenix channel that connects one browser to a room.

        # user_socket.ex
        channel "room:*", MyAppWeb.RoomChannel

        defmodule MyAppWeb.RoomChannel do
          use Octoroom.Phoenix.Channel, room: MyApp.TeamRoom
        end

    The room id is the topic after its first `:`, so `"room:support:1234"` is
    room `"support:1234"`. The channel never calls Cloudflare: it relays SDP
    between the browser and the room server, which owns every session.

    Client → server: `publish`, `publish_tracks`, `push_offer`, `unpublish`,
    `mute`, `connected`, `answer`, `close_offer`.
    Server → client: `renegotiate`, `close`, `push`, `tracks`, `gain`,
    `room_event`, `resume_token`, `republish`.

    A known event whose body has the wrong shape is refused with
    `{reason: "bad_payload"}`, an unknown event with `unknown_event`.

    ## Resuming

    The join reply carries a `resume_token`, refreshed with a
    `resume_token` push whenever what it holds changes (the participant's
    Cloudflare session, its metadata). The JS client rejoins with it after
    its connection drops, including when the node restarted, and comes back
    as the same participant with the same session: the room adopts it, so
    nobody renegotiates. The token is encrypted with the endpoint's
    `secret_key_base` and accepted for `config :octoroom, resume_max_age:`
    seconds (default 600), which is the longest outage a room survives.

    When the room server crashes while the channel stays up, the channel
    resumes on its own.
    """

    import Phoenix.Channel, only: [push: 3, reply: 2, socket_ref: 1]
    import Phoenix.Socket, only: [assign: 3]

    alias Octoroom.Room.Server

    defmacro __using__(opts) do
      room = Keyword.fetch!(opts, :room)

      quote do
        use Phoenix.Channel

        @impl true
        def join(topic, params, socket),
          do: Octoroom.Phoenix.Channel.__join__(unquote(room), topic, params, socket)

        @impl true
        def handle_in(event, payload, socket),
          do: Octoroom.Phoenix.Channel.__handle_in__(event, payload, socket)

        @impl true
        def handle_info(message, socket),
          do: Octoroom.Phoenix.Channel.__handle_info__(message, socket)

        @impl true
        def terminate(reason, socket), do: Octoroom.Phoenix.Channel.__terminate__(reason, socket)
      end
    end

    @salt "octoroom resume"
    @events ~w(publish publish_tracks push_offer unpublish mute connected answer close_offer)

    @doc false
    def __join__(module, topic, params, socket) do
      [_prefix, room_id] = String.split(topic, ":", parts: 2)
      {token, params} = Map.pop(params, "resume_token")

      result =
        case verify(socket, token, room_id) do
          {:ok, data} ->
            Octoroom.Room.resume(module, room_id, data)

          :error ->
            with {:ok, meta} <- module.join(params, socket),
                 do: Octoroom.Room.join(module, room_id, meta)
        end

      case result do
        {:ok, reply, server} ->
          room = %{
            module: module,
            room_id: room_id,
            server: server,
            monitor: Process.monitor(server),
            participant_id: reply.participant_id,
            resume: reply.resume
          }

          {resume, reply} = Map.pop(reply, :resume)
          reply = Map.put(reply, :resume_token, sign(socket, room_id, resume))
          {:ok, reply, assign(socket, :octoroom, room)}

        {:error, reason} ->
          {:error, %{reason: format(reason)}}
      end
    end

    defp sign(socket, room_id, data),
      do: Phoenix.Token.encrypt(socket, @salt, Map.put(data, :room_id, room_id))

    defp verify(_socket, nil, _room_id), do: :error

    defp verify(socket, token, room_id) when is_binary(token) do
      max_age = Application.get_env(:octoroom, :resume_max_age, 600)

      case Phoenix.Token.decrypt(socket, @salt, token, max_age: max_age) do
        {:ok, %{room_id: ^room_id} = data} -> {:ok, Map.delete(data, :room_id)}
        _ -> :error
      end
    end

    defp verify(_socket, _token, _room_id), do: :error

    # The channel is where untrusted payloads come in, so each event's body
    # is checked against the protocol's shapes here: a known event with a
    # bad body gets `bad_payload`. The room server checks again, for
    # callers that don't come through a channel.
    @doc false
    def __handle_in__("publish", %{"sdp" => sdp, "mids" => mids}, socket)
        when is_binary(sdp) and is_map(mids) do
      if mids?(mids) do
        %{server: server, participant_id: id} = socket.assigns.octoroom
        Server.publish(server, id, sdp, mids, socket_ref(socket))
        {:noreply, socket}
      else
        bad_payload(socket)
      end
    end

    def __handle_in__("publish_tracks", %{"sources" => sources}, socket) when is_list(sources) do
      if Enum.all?(sources, &is_binary/1) do
        %{server: server, participant_id: id} = socket.assigns.octoroom
        Server.publish_tracks(server, id, sources, socket_ref(socket))
        {:noreply, socket}
      else
        bad_payload(socket)
      end
    end

    def __handle_in__("push_offer", %{"sdp" => sdp, "op_id" => op_id, "mids" => mids}, socket)
        when is_binary(sdp) and is_binary(op_id) and is_map(mids) do
      if mids?(mids) do
        %{server: server, participant_id: id} = socket.assigns.octoroom
        Server.push_offer(server, id, op_id, sdp, mids, socket_ref(socket))
        {:noreply, socket}
      else
        bad_payload(socket)
      end
    end

    def __handle_in__("unpublish", %{"source" => source}, socket) when is_binary(source) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.unpublish(server, id, source, socket_ref(socket))
      {:noreply, socket}
    end

    def __handle_in__("mute", %{"source" => source, "muted" => muted}, socket)
        when is_binary(source) and is_boolean(muted) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.mute(server, id, source, muted)
      {:reply, :ok, socket}
    end

    def __handle_in__("connected", payload, socket) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.connected(server, id, timings(payload))
      {:reply, :ok, socket}
    end

    def __handle_in__("answer", %{"sdp" => sdp, "op_id" => op_id}, socket)
        when is_binary(sdp) and is_binary(op_id) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.answer(server, id, op_id, sdp, socket_ref(socket))
      {:noreply, socket}
    end

    def __handle_in__("close_offer", %{"sdp" => sdp, "op_id" => op_id}, socket)
        when is_binary(sdp) and is_binary(op_id) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.close_offer(server, id, op_id, sdp, socket_ref(socket))
      {:noreply, socket}
    end

    def __handle_in__(event, _payload, socket) when event in @events, do: bad_payload(socket)

    def __handle_in__(_event, _payload, socket),
      do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

    # The client's measurements of its join, for telemetry: known keys
    # only, durations as non-negative numbers. Anything else is dropped
    # rather than refused, as the join itself went fine.
    @timings %{
      "join_ms" => :join_ms,
      "media_ms" => :media_ms,
      "ice_ms" => :ice_ms,
      "publish_ms" => :publish_ms,
      "connect_ms" => :connect_ms
    }
    defp timings(%{"timings" => timings}) when is_map(timings) do
      durations =
        for {k, v} <- timings, key = @timings[k], is_number(v), v >= 0, into: %{}, do: {key, v}

      case timings do
        %{"ice_timed_out" => flag} when is_boolean(flag) ->
          Map.put(durations, :ice_timed_out, flag)

        _ ->
          durations
      end
    end

    defp timings(_payload), do: %{}

    # Source => mid, both strings.
    defp mids?(mids),
      do: Enum.all?(mids, fn {source, mid} -> is_binary(source) and is_binary(mid) end)

    defp bad_payload(socket), do: {:reply, {:error, %{reason: "bad_payload"}}, socket}

    @doc false
    def __handle_info__({:octoroom_signal, :reply, ref, result}, socket) do
      case result do
        {:ok, payload} -> reply(ref, {:ok, payload})
        {:error, reason} -> reply(ref, {:error, %{reason: format(reason)}})
      end

      {:noreply, socket}
    end

    def __handle_info__({:octoroom_signal, :kick, reason}, socket),
      do: {:stop, {:shutdown, {:octoroom, reason}}, socket}

    def __handle_info__(
          {:octoroom_signal, :room_event, {type, %Octoroom.Participant{} = p}},
          socket
        ) do
      push(socket, "room_event", %{type: type, participant: p})
      {:noreply, socket}
    end

    def __handle_info__({:octoroom_signal, kind, payload}, socket)
        when kind in [:renegotiate, :close, :push, :tracks, :gain, :republish] do
      push(socket, Atom.to_string(kind), payload)
      {:noreply, socket}
    end

    def __handle_info__({:octoroom_signal, :resume, data}, socket) do
      room = socket.assigns.octoroom
      push(socket, "resume_token", %{token: sign(socket, room.room_id, data)})
      {:noreply, assign(socket, :octoroom, %{room | resume: data})}
    end

    def __handle_info__({:DOWN, ref, :process, _pid, reason}, socket) do
      case socket.assigns[:octoroom] do
        %{monitor: ^ref} = room -> room_down(room, reason, socket)
        _ -> {:noreply, socket}
      end
    end

    def __handle_info__(_message, socket), do: {:noreply, socket}

    # The room stopped on purpose (it was shut down): so does the channel.
    # It crashed: the channel brings this participant back into a new run.
    defp room_down(_room, reason, socket)
         when reason in [:normal, :shutdown] or
                (is_tuple(reason) and elem(reason, 0) == :shutdown),
         do: {:stop, {:shutdown, :room_closed}, assign(socket, :octoroom, nil)}

    defp room_down(room, _crash, socket) do
      case Octoroom.Room.resume(room.module, room.room_id, room.resume) do
        {:ok, reply, server} ->
          room = %{room | server: server, monitor: Process.monitor(server), resume: reply.resume}
          push(socket, "resume_token", %{token: sign(socket, room.room_id, reply.resume)})
          if not reply.resumed, do: push(socket, "republish", %{reason: :room_restarted})
          {:noreply, assign(socket, :octoroom, room)}

        {:error, _reason} ->
          {:stop, {:shutdown, :room_closed}, socket}
      end
    end

    @doc false
    # Only the client leaving is a leave. A dropped connection
    # ({:shutdown, :closed}) or the node shutting down (:shutdown) isn't:
    # the room keeps the participant for a grace period, in case it resumes.
    # Anything else (a crash) the room sees through its monitor.
    def __terminate__({:shutdown, :left}, socket) do
      case socket.assigns[:octoroom] do
        %{server: server, participant_id: id} -> Server.leave(server, id)
        _ -> :ok
      end
    end

    def __terminate__(_reason, _socket), do: :ok

    defp format(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp format(reason) when is_binary(reason), do: reason
    defp format(reason), do: inspect(reason)
  end
end
