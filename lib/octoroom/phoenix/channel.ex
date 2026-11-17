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

    Client → server: `publish`, `connected`, `answer`, `close_offer`.
    Server → client: `renegotiate`, `close`, `tracks`, `gain`, `room_event`.
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

    @doc false
    def __join__(module, topic, params, socket) do
      [_prefix, room_id] = String.split(topic, ":", parts: 2)

      with {:ok, meta} <- module.join(params, socket),
           {:ok, reply, server} <- Octoroom.Room.join(module, room_id, meta) do
        Process.monitor(server)

        room = %{room_id: room_id, server: server, participant_id: reply.participant_id}
        {:ok, reply, assign(socket, :octoroom, room)}
      else
        {:error, reason} -> {:error, %{reason: format(reason)}}
      end
    end

    @doc false
    def __handle_in__("publish", %{"sdp" => sdp, "mids" => mids}, socket) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.publish(server, id, sdp, mids, socket_ref(socket))
      {:noreply, socket}
    end

    def __handle_in__("connected", _payload, socket) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.connected(server, id)
      {:reply, :ok, socket}
    end

    def __handle_in__("answer", %{"sdp" => sdp, "op_id" => op_id}, socket) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.answer(server, id, op_id, sdp, socket_ref(socket))
      {:noreply, socket}
    end

    def __handle_in__("close_offer", %{"sdp" => sdp, "op_id" => op_id}, socket) do
      %{server: server, participant_id: id} = socket.assigns.octoroom
      Server.close_offer(server, id, op_id, sdp, socket_ref(socket))
      {:noreply, socket}
    end

    def __handle_in__(_event, _payload, socket),
      do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

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
        when kind in [:renegotiate, :close, :tracks, :gain] do
      push(socket, Atom.to_string(kind), payload)
      {:noreply, socket}
    end

    def __handle_info__({:DOWN, _ref, :process, pid, _reason}, socket) do
      if match?(%{server: ^pid}, socket.assigns[:octoroom]),
        do: {:stop, {:shutdown, :room_closed}, socket},
        else: {:noreply, socket}
    end

    def __handle_info__(_message, socket), do: {:noreply, socket}

    @doc false
    def __terminate__(_reason, socket) do
      case socket.assigns[:octoroom] do
        %{server: server, participant_id: id} -> Server.leave(server, id)
        _ -> :ok
      end
    end

    defp format(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp format(reason) when is_binary(reason), do: reason
    defp format(reason), do: inspect(reason)
  end
end
