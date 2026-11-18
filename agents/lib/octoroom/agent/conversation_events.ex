defmodule Octoroom.Agent.ConversationEvents do
  @moduledoc """
  Accumulates observed text and emits finalized conversation items to the owner.

  An assistant reply that's spoken is emitted twice with the same
  `message_id`: `:playing` when its text is done and its audio is playing,
  then `:completed` once it played to the end, or `:interrupted` with only
  the words that were heard. Without TTS, `:completed` means the text is
  done. Interrupted/failed items contain only text observed before that
  boundary.
  This event ledger is separate from the model's history and does not persist it.
  """

  def new do
    %{id: id(), sequence: 0, pending: %{}}
  end

  def append(state, role, text) when role in [:user, :assistant] and is_binary(text) do
    events = Map.get(state, :conversation_events) || new()
    pending = Map.update(events.pending, role, text, &(&1 <> text))
    Map.put(state, :conversation_events, %{events | pending: pending})
  end

  def replace(state, role, text) do
    events = Map.get(state, :conversation_events) || new()
    Map.put(state, :conversation_events, %{events | pending: Map.put(events.pending, role, text)})
  end

  def commit(state, role, status \\ :completed, extra \\ %{})
      when status in [:completed, :interrupted, :failed] do
    events = Map.get(state, :conversation_events) || new()
    {text, pending} = Map.pop(events.pending, role, "")
    events = %{events | pending: pending}

    if String.trim(text) == "" do
      Map.put(state, :conversation_events, events)
    else
      sequence = events.sequence + 1

      item = %{
        type: "conversation_item_added",
        conversation_id: events.id,
        message_id: id(),
        sequence: sequence,
        role: Atom.to_string(role),
        text: text,
        status: Atom.to_string(status),
        interrupted: status == :interrupted
      }

      item = Map.merge(item, extra)

      if is_pid(Map.get(state, :owner)) do
        send(state.owner, {:voice_pipeline, self(), {:conversation, item}})
      end

      Map.put(state, :conversation_events, %{events | sequence: sequence})
    end
  end

  @doc """
  Reserves the next sequence number for an item whose text arrives later, such
  as a user turn heard as audio and transcribed in the background. Returns
  `{state, reservation}`; pass the reservation to `commit_reserved/4`.
  """
  def reserve(state) do
    events = Map.get(state, :conversation_events) || new()
    sequence = events.sequence + 1
    reservation = %{conversation_id: events.id, message_id: id(), sequence: sequence}
    {Map.put(state, :conversation_events, %{events | sequence: sequence}), reservation}
  end

  @doc "Emits a reserved item. Its sequence may be lower than items already emitted."
  def commit_reserved(state, role, reservation, text, extra \\ %{}, status \\ :completed)
      when role in [:user, :assistant] and status in [:completed, :interrupted, :failed] do
    if String.trim(text) != "" and is_pid(Map.get(state, :owner)) do
      item =
        Map.merge(reservation, %{
          type: "conversation_item_added",
          role: Atom.to_string(role),
          text: text,
          status: Atom.to_string(status),
          interrupted: status == :interrupted
        })
        |> Map.merge(extra)

      send(state.owner, {:voice_pipeline, self(), {:conversation, item}})
    end

    state
  end

  @doc """
  Emits a reserved item, or a new version of one already emitted (same
  `message_id` and `sequence`), even with empty text: an assistant reply
  shown as `:playing` and then cut off before any of it was heard.
  """
  def update_reserved(state, role, reservation, text, status)
      when role in [:user, :assistant] and status in [:playing, :completed, :interrupted, :failed] do
    if is_pid(Map.get(state, :owner)) do
      item =
        Map.merge(reservation, %{
          type: "conversation_item_added",
          role: Atom.to_string(role),
          text: text,
          status: Atom.to_string(status),
          interrupted: status == :interrupted
        })

      send(state.owner, {:voice_pipeline, self(), {:conversation, item}})
    end

    state
  end

  defp id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
