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
      :ok = Store.put(store, :adapters, "ws1", %{room_id: "a"})
      :ok = Store.put(store, :adapters, "ws2", %{room_id: "b"})
      :ok = Store.delete(store, :adapters, "ws2")

      assert Store.get(store, :rooms, "a") == %{run: "r1"}
      assert Store.all(store, :adapters) == [{"ws1", %{room_id: "a"}}]

      ETS.flush(opts)
      stop_supervised!(opts[:name])
      start_supervised!({ETS, opts}, id: opts[:name])

      assert Store.get(store, :rooms, "a") == %{run: "r1"}
      assert Store.all(store, :adapters) == [{"ws1", %{room_id: "a"}}]
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
    setup ctx do
      {:ok, fake} = FakeCloudflare.start_link(self())
      %{store: start_store(ctx), cf: FakeCloudflare.config(fake)}
    end

    defp adapter(room, run, id, age_ms \\ 60_000),
      do: %{room_id: room, run: run, adapter_id: id, created_at: Store.now() - age_ms}

    test "closes adapters whose room or run is gone, and keeps the rest", ctx do
      Store.put(ctx.store, :adapters, "live", adapter("a", "run2", "cf-live"))
      Store.put(ctx.store, :adapters, "old-run", adapter("a", "run1", "cf-old"))
      Store.put(ctx.store, :adapters, "no-room", adapter("b", "run1", "cf-gone"))
      Store.put(ctx.store, :adapters, "orphan", adapter("b", "run1", nil))
      Store.put(ctx.store, :adapters, "pending", adapter("b", "run1", nil, 0))

      run_of = fn
        "a" -> "run2"
        _ -> nil
      end

      result = Janitor.sweep(store: ctx.store, cloudflare: ctx.cf, run_of: run_of)

      assert Enum.sort(result.closed) == ["cf-gone", "cf-old"]
      assert_received {:cloudflare, :close_adapters, [ids]}
      assert Enum.sort(ids) == ["cf-gone", "cf-old"]

      assert ctx.store |> Store.all(:adapters) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ["live", "pending"]
    end

    test "keeps records it couldn't close, for the next sweep", ctx do
      Store.put(ctx.store, :adapters, "x", adapter("gone", "r", "cf-x"))
      FakeCloudflare.fail_next(ctx.cf.fake, :close_adapters, :down)
      run_of = fn _ -> nil end

      assert %{closed: []} = Janitor.sweep(store: ctx.store, cloudflare: ctx.cf, run_of: run_of)
      assert [{"x", _}] = Store.all(ctx.store, :adapters)

      assert %{closed: ["cf-x"]} =
               Janitor.sweep(store: ctx.store, cloudflare: ctx.cf, run_of: run_of)

      assert Store.all(ctx.store, :adapters) == []
    end

    test "deletes room records past the resume window", ctx do
      Store.put(ctx.store, :rooms, "old", %{run: "r", assigns: %{}, updated_at: 0})
      Store.put(ctx.store, :rooms, "recent", %{run: "r", assigns: %{}, updated_at: Store.now()})
      Store.put(ctx.store, :rooms, "running", %{run: "r", assigns: %{}, updated_at: 0})
      run_of = fn room -> if room == "running", do: "r" end

      assert %{deleted_rooms: ["old"]} =
               Janitor.sweep(store: ctx.store, cloudflare: ctx.cf, run_of: run_of)
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
        public_ws_url: "wss://example.test/octoroom"
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

    test "records the room's run, and each adapter before Cloudflare creates it", ctx do
      c = Client.join("a", EchoRoom, ctx.room_id, %{}, ctx.opts)
      run = Octoroom.Room.Server.run(ctx.room_id)
      assert %{run: ^run, assigns: %{}} = Store.get(ctx.store, :rooms, ctx.room_id)

      assert_receive {:cloudflare, :new_adapters, [_]}

      eventually(fn ->
        match?(
          [{_, %{room_id: _, run: ^run, adapter_id: "adapter-" <> _}}],
          Store.all(ctx.store, :adapters)
        )
      end)

      # The last participant leaving stops the room: its adapters are closed
      # and both records go.
      Client.stop(c)
      assert_receive {:cloudflare, :close_adapters, [["adapter-" <> _]]}
      eventually(fn -> Store.all(ctx.store, :adapters) == [] end)
      eventually(fn -> Store.get(ctx.store, :rooms, ctx.room_id) == nil end)
    end

    test "a room that didn't stop cleanly keeps its record; the next run takes its assigns and closes its adapters",
         ctx do
      _c = Client.join("a", EchoRoom, ctx.room_id, %{}, ctx.opts)
      :ok = Octoroom.Room.assign(ctx.room_id, :topic, "standup")
      assert_receive {:cloudflare, :new_adapters, [_]}

      eventually(fn ->
        match?([{_, %{adapter_id: "adapter-" <> _}}], Store.all(ctx.store, :adapters))
      end)

      [{ws_id, %{adapter_id: old_id, run: old_run}}] = Store.all(ctx.store, :adapters)

      # Simulate a node dying: the adapter record stays (no terminate runs).
      server = Octoroom.Room.Server.whereis(ctx.room_id)
      saved = Store.all(ctx.store, :adapters)
      Process.exit(server, :kill)
      eventually(fn -> Octoroom.Room.Server.whereis(ctx.room_id) == nil end)
      for {k, v} <- saved, do: Store.put(ctx.store, :adapters, k, v)

      _c = Client.join("b", EchoRoom, ctx.room_id, %{}, ctx.opts)
      new_run = Octoroom.Room.Server.run(ctx.room_id)
      assert new_run != old_run
      assert {:ok, %{assigns: %{topic: "standup"}}} = {:ok, Octoroom.Room.state(ctx.room_id)}

      assert_receive {:cloudflare, :close_adapters, [[^old_id]]}
      eventually(fn -> Store.get(ctx.store, :adapters, ws_id) == nil end)
    end
  end
end
