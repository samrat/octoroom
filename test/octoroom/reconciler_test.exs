defmodule Octoroom.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Octoroom.{Reconciler, Track}

  defp t(name, gain \\ 1.0), do: %Track{name: name, gain: gain}
  defp sub(status, gain \\ 1.0), do: %{status: status, gain: gain}

  test "opens live tracks and waits for pending ones" do
    desired = %{"a" => [t("b/mic"), t("c/mic")]}
    actual = %{subscriptions: %{}, tracks: %{"b/mic" => :live, "c/mic" => :pending}}

    assert Reconciler.diff(desired, actual) == [{:open_subscription, "a", "b/mic", %{gain: 1.0}}]
  end

  test "closes what is no longer desired or no longer published" do
    desired = %{"a" => [t("c/mic")]}

    actual = %{
      subscriptions: %{
        "a" => %{"b/mic" => sub(:open), "c/mic" => sub(:open)},
        "z" => %{"c/mic" => sub(:open)}
      },
      tracks: %{"b/mic" => :live}
    }

    assert Reconciler.diff(desired, actual) == [
             {:close_subscription, "a", "b/mic"},
             {:close_subscription, "a", "c/mic"},
             {:close_subscription, "z", "c/mic"}
           ]
  end

  test "leaves in-flight subscriptions alone" do
    desired = %{"a" => [t("b/mic")]}

    actual = %{
      subscriptions: %{"a" => %{"b/mic" => sub(:closing), "c/mic" => sub(:opening)}},
      tracks: %{"b/mic" => :live, "c/mic" => :live}
    }

    assert Reconciler.diff(desired, actual) == []
  end

  test "changes gain without touching Cloudflare, after closes and opens" do
    desired = %{"a" => [t("b/mic", 0.15), "c/mic"], "d" => []}

    actual = %{
      subscriptions: %{"a" => %{"b/mic" => sub(:open)}, "d" => %{"b/mic" => sub(:open)}},
      tracks: %{"b/mic" => :live, "c/mic" => :live}
    }

    assert Reconciler.diff(desired, actual) == [
             {:close_subscription, "d", "b/mic"},
             {:open_subscription, "a", "c/mic", %{gain: 1.0}},
             {:update_subscription, "a", "b/mic", %{gain: 0.15}}
           ]
  end

  test "a stale subscription is closed, not given a new gain" do
    desired = %{"a" => [t("bot/out", 0.5)]}

    actual = %{
      subscriptions: %{"a" => %{"bot/out" => Map.put(sub(:open), :stale, true)}},
      tracks: %{"bot/out" => :live}
    }

    assert Reconciler.diff(desired, actual) == [{:close_subscription, "a", "bot/out"}]
  end

  test "desired equals actual means no operations" do
    desired = %{"a" => [t("b/mic")], "b" => [t("a/mic")]}

    actual = %{
      subscriptions: %{"a" => %{"b/mic" => sub(:open)}, "b" => %{"a/mic" => sub(:open)}},
      tracks: %{"a/mic" => :live, "b/mic" => :live}
    }

    assert Reconciler.diff(desired, actual) == []
  end

  describe "diff_workers/2" do
    defp w(id, opts \\ []), do: Octoroom.Room.worker(id, Keyword.get(opts, :module, M), opts)

    test "starts workers and outlets, and inlets only for live inputs" do
      specs = [w("echo", inputs: ["a/mic", "b/mic"], outputs: ["a/echo"])]
      actual = %{tracks: %{"a/mic" => :live, "b/mic" => :pending}}

      assert Reconciler.diff_workers(specs, actual) == [
               {:start_worker, hd(specs)},
               {:start_outlet, "a/echo", "echo"},
               {:start_inlet, {"echo", "a/mic"}}
             ]
    end

    test "tears down before building up, and leaves settled workers alone" do
      keep = w("keep", inputs: ["a/mic"], outputs: ["keep"])
      new = w("new", outputs: ["new"])

      actual = %{
        workers: %{"keep" => keep, "gone" => w("gone", outputs: ["gone"])},
        outlets: %{"keep" => "keep", "gone" => "gone"},
        inlets: [{"keep", "a/mic"}, {"gone", "a/mic"}, {"keep", "x/mic"}],
        tracks: %{"a/mic" => :live, "keep" => :live, "gone" => :live}
      }

      assert Reconciler.diff_workers([keep, new], actual) == [
               {:stop_inlet, {"gone", "a/mic"}},
               {:stop_inlet, {"keep", "x/mic"}},
               {:stop_outlet, "gone"},
               {:stop_worker, "gone"},
               {:start_worker, new},
               {:start_outlet, "new", "new"}
             ]
    end

    test "a changed module or args restarts; changed inputs or outputs update in place" do
      old = w("a", inputs: ["a/mic"], args: %{n: 1})
      actual = %{workers: %{"a" => old}, inlets: [{"a", "a/mic"}], tracks: %{"a/mic" => :live}}

      restarted = %{old | args: %{n: 2}}
      assert Reconciler.diff_workers([restarted], actual) == [{:restart_worker, restarted}]

      moved = %{old | module: N}
      assert Reconciler.diff_workers([moved], actual) == [{:restart_worker, moved}]

      more = w("a", inputs: ["a/mic", "b/mic"], args: %{n: 1})
      actual = put_in(actual.tracks["b/mic"], :live)

      assert Reconciler.diff_workers([more], actual) == [
               {:update_worker, more},
               {:start_inlet, {"a", "b/mic"}}
             ]

      # Data outputs have no media, so a change is only an update.
      noted = Map.put(old, :data, ["notes"])
      assert Reconciler.diff_workers([noted], actual) == [{:update_worker, noted}]
    end

    test "the first worker to name an output has it" do
      a = w("a", outputs: ["shared"])
      b = w("b", outputs: ["shared"])
      assert {:start_outlet, "shared", "a"} in Reconciler.diff_workers([a, b], %{})
    end

    test "an output that moves to another worker gets a new outlet" do
      new = w("new", outputs: ["out"])
      actual = %{workers: %{"old" => w("old", outputs: ["out"])}, outlets: %{"out" => "old"}}

      assert Reconciler.diff_workers([new], actual) == [
               {:stop_outlet, "out"},
               {:stop_worker, "old"},
               {:start_worker, new},
               {:start_outlet, "out", "new"}
             ]
    end
  end
end
