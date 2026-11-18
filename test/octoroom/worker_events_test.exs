defmodule Octoroom.WorkerEventsTest do
  use ExUnit.Case, async: true

  alias Octoroom.Test.{Client, FakeCloudflare}

  # Does what the test tells it to, and tells the test who subscribes.
  defmodule Notifier do
    use Octoroom.Worker

    @impl true
    def init(test, ctx) do
      send(test, {:started, ctx.id, self()})
      {:ok, %{test: test, id: ctx.id}}
    end

    @impl true
    def handle_audio(_input, _pcm, s), do: {:ok, s}

    @impl true
    def handle_info({:do, actions}, s), do: {:ok, s, actions}

    def handle_info({:octoroom, kind, pid, output}, s)
        when kind in [:subscribed, :unsubscribed] do
      send(s.test, {:worker, s.id, kind, pid, output})
      {:ok, s}
    end

    def handle_info(_msg, s), do: {:ok, s}
  end

  # A private coach and an interpreter with a data output per language.
  # Each listener gets the data outputs in its `data` metadata.
  defmodule CoachRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def mount(_room_id), do: {:ok, %{}}

    @impl true
    def workers(%{assigns: %{test: test}}) do
      [
        worker("coach", Octoroom.WorkerEventsTest.Notifier, data: ["coach"], args: test),
        worker("interp", Octoroom.WorkerEventsTest.Notifier,
          data: ["interp/es", "interp/fr"],
          args: test
        )
      ]
    end

    def workers(_room), do: []

    @impl true
    def subscriptions(listener, room),
      do: for(p <- others(room, listener), do: mic(p)) ++ Map.get(listener.meta, :data, [])
  end

  setup do
    {:ok, fake} = FakeCloudflare.start_link(self())
    room_id = "room-#{System.unique_integer([:positive])}"
    opts = [cloudflare: FakeCloudflare.config(fake), signal_timeout: 500]
    ctx = %{fake: fake, room_id: room_id, opts: opts}

    # The first join starts the room; the workers start once it has the
    # test's pid.
    host = join(ctx, "host", [])
    :ok = Octoroom.Room.assign(room_id, :test, self())
    assert_receive {:started, "coach", _}
    assert_receive {:started, "interp", _}
    Map.put(ctx, :host, host)
  end

  defp join(ctx, name, data),
    do: Client.join(name, CoachRoom, ctx.room_id, %{name: name, data: data}, ctx.opts)

  defp tell(ctx, worker, actions),
    do: :ok = Octoroom.Worker.send(ctx.room_id, worker, {:do, actions})

  defp refute_worker_signals(name) do
    refute_receive {:client, ^name, {:octoroom_signal, :worker, _}}, 100
    refute_received {:client, ^name, {:octoroom_signal, :worker_event, _}}
  end

  test "a private worker's presence and events reach only those subscribed to it", ctx do
    customer = join(ctx, "customer", [])
    agent = join(ctx, "agent", ["coach"])
    agent_id = agent.id
    Octoroom.subscribe(ctx.room_id, scope: {:participant, agent_id})

    assert_receive {:client, "agent",
                    {:octoroom_signal, :worker,
                     %{op: :added, worker: %{id: "coach", data: ["coach"], state: nil}}}}

    assert_receive {:worker, "coach", :subscribed, ^agent_id, "coach"}

    tell(ctx, "coach", presence: %{state: "listening", attributes: %{name: "Coach"}})

    assert_receive {:client, "agent",
                    {:octoroom_signal, :worker,
                     %{
                       op: :updated,
                       worker: %{id: "coach", state: "listening", attributes: %{name: "Coach"}}
                     }}}

    assert_receive {:octoroom, _, {:worker, :updated, %{id: "coach", state: "listening"}}}

    tell(ctx, "coach", notify: {:default, "tip", %{text: "slow down"}})

    assert_receive {:client, "agent",
                    {:octoroom_signal, :worker_event,
                     %{worker: "coach", output: "coach", type: "tip", data: %{text: "slow down"}}}}

    assert_receive {:octoroom, _, {:worker_notify, "coach", "coach", "tip", %{text: "slow down"}}}

    refute_worker_signals(customer.name)
    refute_worker_signals(ctx.host.name)

    # Presence is in the room's state, and a resuming client gets it in its
    # reply.
    assert %{state: "listening"} =
             Enum.find(Octoroom.Room.state(ctx.room_id).workers, &(&1.id == "coach"))

    Client.drop(agent)
    back = Client.resume("agent", CoachRoom, ctx.room_id, agent.reply.resume, ctx.opts)
    assert [%{id: "coach", state: "listening"}] = back.reply.workers

    # The policy drops the coach: the agent no longer sees it.
    :ok = Octoroom.Room.update_meta(ctx.room_id, agent_id, &Map.put(&1, :data, []))

    assert_receive {:client, "agent",
                    {:octoroom_signal, :worker, %{op: :removed, worker: %{id: "coach"}}}}

    assert_receive {:octoroom, _, {:worker, :removed, %{id: "coach"}}}
    assert_receive {:worker, "coach", :unsubscribed, ^agent_id, "coach"}
  end

  test "events go to their output's subscribers, presence to any output's", ctx do
    spanish = join(ctx, "spanish", ["interp/es"])
    french = join(ctx, "french", ["interp/fr"])
    spanish_id = spanish.id

    for name <- ["spanish", "french"] do
      assert_receive {:client, ^name,
                      {:octoroom_signal, :worker, %{op: :added, worker: %{id: "interp"}}}}
    end

    tell(ctx, "interp", notify: {"interp/es", "caption", %{text: "hola"}})

    assert_receive {:client, "spanish",
                    {:octoroom_signal, :worker_event,
                     %{output: "interp/es", data: %{text: "hola"}}}}

    refute_receive {:client, "french", {:octoroom_signal, :worker_event, _}}, 100

    # One participant only, and only on an output it's subscribed to.
    tell(ctx, "interp", notify: {"interp/fr", "snapshot", %{}, spanish_id})
    tell(ctx, "interp", notify: {"interp/es", "snapshot", %{n: 1}, spanish_id})

    assert_receive {:client, "spanish",
                    {:octoroom_signal, :worker_event, %{type: "snapshot", data: %{n: 1}}}}

    refute_receive {:client, _, {:octoroom_signal, :worker_event, %{type: "snapshot"}}}, 100

    tell(ctx, "interp", presence: %{state: "speaking"})

    for p <- [spanish, french] do
      name = p.name

      assert_receive {:client, ^name,
                      {:octoroom_signal, :worker, %{op: :updated, worker: %{state: "speaking"}}}}
    end
  end

  test "a restarted worker is told who's subscribed, and its state starts over", ctx do
    agent = join(ctx, "agent", ["coach"])
    agent_id = agent.id
    assert_receive {:worker, "coach", :subscribed, ^agent_id, "coach"}
    tell(ctx, "coach", presence: %{state: "listening", attributes: %{name: "Coach"}})

    assert_receive {:client, "agent",
                    {:octoroom_signal, :worker, %{op: :updated, worker: %{state: "listening"}}}}

    pid = Octoroom.Worker.whereis(ctx.room_id, "coach")
    Process.exit(pid, :kill)
    assert_receive {:started, "coach", new_pid}, 2_000
    assert new_pid != pid
    assert_receive {:worker, "coach", :subscribed, ^agent_id, "coach"}

    assert_receive {:client, "agent",
                    {:octoroom_signal, :worker,
                     %{op: :updated, worker: %{state: nil, attributes: %{name: "Coach"}}}}}

    refute_receive {:client, "agent", {:octoroom_signal, :worker, %{op: :removed}}}, 100
  end

  test "a notify or presence clients couldn't decode crashes the worker", ctx do
    bad = [
      notify: {"nope", "t", %{}},
      notify: {:default, :tip, %{}},
      notify: {:default, "t", [1]},
      notify: {:default, "t", %{pid: self()}},
      presence: %{state: :busy},
      presence: %{attributes: %{ref: make_ref()}}
    ]

    spec = Octoroom.Room.worker("solo", Notifier, data: ["solo"], args: self())

    # Run outside the room, so the room's restart backoff doesn't apply.
    for action <- bad do
      {:ok, pid} =
        GenServer.start(Octoroom.Worker.Server, %{
          room_id: ctx.room_id,
          spec: spec,
          participants: []
        })

      ref = Process.monitor(pid)
      send(pid, {:do, [action]})
      assert_receive {:DOWN, ^ref, :process, ^pid, {%ArgumentError{}, _}}, 500
    end
  end
end
