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

  test "desired equals actual means no operations" do
    desired = %{"a" => [t("b/mic")], "b" => [t("a/mic")]}

    actual = %{
      subscriptions: %{"a" => %{"b/mic" => sub(:open)}, "b" => %{"a/mic" => sub(:open)}},
      tracks: %{"a/mic" => :live, "b/mic" => :live}
    }

    assert Reconciler.diff(desired, actual) == []
  end
end
