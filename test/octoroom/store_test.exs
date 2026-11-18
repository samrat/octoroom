defmodule Octoroom.StoreTest do
  use ExUnit.Case, async: true

  alias Octoroom.{Janitor, Store}
  alias Octoroom.Store.ETS
  alias Octoroom.Test.{Client, FakeCloudflare}

  @moduletag :tmp_dir

  defmodule EchoRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(room) do
      for p <- room.participants,
          do: worker("echo:#{p.id}", Octoroom.StoreTest.Quiet, outputs: ["#{p.id}/echo"])
    end
  end

  defmodule Quiet do
    use Octoroom.Worker

    @impl true
    def init(_args, _ctx), do: {:ok, nil}

    @impl true
    def handle_audio(_input, _pcm, s), do: {:ok, s}
  end

  defp start_store(ctx, opts \\ []) do
    name = :"store_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, path: Path.join(ctx.tmp_dir, "store")], opts)
    start_supervised!({ETS, opts}, id: name)
    {ETS, opts}
  end

  describe "ETS store" do
    test "reads back what it wrote, and survives a restart through its snapshot", ctx do
      {_, opts} = store = start_store(ctx)
      :ok = Store.put(store, :rooms, "a", %{run: "r1"})
      :ok = Store.put(store, :things, "ws1", %{room_id: "a"})
      :ok = Store.put(store, :things, "ws2", %{room_id: "b"})
      :ok = Store.delete(store, :things, "ws2")

      assert Store.get(store, :rooms, "a") == %{run: "r1"}
      assert Store.all(store, :things) == [{"ws1", %{room_id: "a"}}]

      ETS.flush(opts)
      stop_supervised!(opts[:name])
      start_supervised!({ETS, opts}, id: opts[:name])

      assert Store.get(store, :rooms, "a") == %{run: "r1"}
      assert Store.all(store, :things) == [{"ws1", %{room_id: "a"}}]
      assert Store.get(store, :rooms, "missing") == nil
    end

    test "path: nil keeps it in memory", ctx do
      store = start_store(ctx, path: nil)
      Store.put(store, :rooms, "a", 1)
      assert Store.get(store, :rooms, "a") == 1
      assert File.ls!(ctx.tmp_dir) == []
    end
  end

  describe "janitor" do
    setup ctx, do: %{store: start_store(ctx)}

    test "deletes room records past the resume window", ctx do
      Store.put(ctx.store, :rooms, "old", %{run: "r", assigns: %{}, updated_at: 0})
      Store.put(ctx.store, :rooms, "recent", %{run: "r", assigns: %{}, updated_at: Store.now()})
      Store.put(ctx.store, :rooms, "running", %{run: "r", assigns: %{}, updated_at: 0})
      Store.put(ctx.store, :workers, {"old", "agent"}, :memory)
      Store.put(ctx.store, :workers, {"recent", "agent"}, :memory)
      run_of = fn room -> if room == "running", do: "r" end

      assert %{deleted_rooms: ["old"]} = Janitor.sweep(store: ctx.store, run_of: run_of)

      assert ctx.store |> Store.all(:rooms) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ["recent", "running"]

      # And what the old room's workers saved.
      assert Store.all(ctx.store, :workers) == [{{"recent", "agent"}, :memory}]
    end
  end

  describe "rooms and the store" do
    setup ctx do
      {:ok, fake} = FakeCloudflare.start_link(self())
      store = start_store(ctx)
      room_id = "room-#{System.unique_integer([:positive])}"

      opts = [
        cloudflare: FakeCloudflare.config(fake),
        store: store,
        peer_media: Octoroom.Test.FakePeerMedia
      ]

      %{fake: fake, store: store, room_id: room_id, opts: opts}
    end

    defp eventually(fun, tries \\ 50) do
      if fun.() do
        true
      else
        if tries == 0, do: flunk("condition never held")
        Process.sleep(10)
        eventually(fun, tries - 1)
      end
    end

    test "records the room's run and assigns, and deletes the record when the last one leaves",
         ctx do
      c = Client.join("a", EchoRoom, ctx.room_id, %{}, ctx.opts)
      run = Octoroom.Room.Server.run(ctx.room_id)
      assert %{run: ^run, assigns: %{}} = Store.get(ctx.store, :rooms, ctx.room_id)
      :ok = Octoroom.Room.assign(ctx.room_id, :topic, "standup")
      assert %{assigns: %{topic: "standup"}} = Store.get(ctx.store, :rooms, ctx.room_id)

      Client.stop(c)
      eventually(fn -> Store.get(ctx.store, :rooms, ctx.room_id) == nil end)
    end

    test "a room that didn't stop cleanly keeps its record; the next run takes its assigns",
         ctx do
      _c = Client.join("a", EchoRoom, ctx.room_id, %{}, ctx.opts)
      :ok = Octoroom.Room.assign(ctx.room_id, :topic, "standup")
      old_run = Octoroom.Room.Server.run(ctx.room_id)
      # The worker's output was pushed from its own session.
      assert_receive {:cloudflare, :push_tracks, [_, _, [_]]}

      # A node dying: no terminate runs. Workers' sessions end with their
      # peer connections, so there's nothing at Cloudflare to clean up.
      server = Octoroom.Room.Server.whereis(ctx.room_id)
      Process.exit(server, :kill)
      eventually(fn -> Octoroom.Room.Server.whereis(ctx.room_id) == nil end)

      _c = Client.join("b", EchoRoom, ctx.room_id, %{}, ctx.opts)
      assert Octoroom.Room.Server.run(ctx.room_id) != old_run
      assert %{assigns: %{topic: "standup"}} = Octoroom.Room.state(ctx.room_id)
    end
  end
end
