defmodule Octoroom.PrimitivesTest do
  use ExUnit.Case, async: true

  alias Octoroom.Audio
  alias Octoroom.Cloudflare.HTTP

  describe "audio" do
    defp stereo(values),
      do: for(v <- values, into: <<>>, do: <<v::little-signed-16, v::little-signed-16>>)

    defp samples(pcm), do: for(<<s::little-signed-16 <- pcm>>, do: s)

    test "averages three stereo frames into one 16 kHz mono sample and carries the rest" do
      assert {<<600::little-signed-16>>, <<1, 2>>} =
               Audio.from_room(stereo([300, 600, 900]) <> <<1, 2>>, 16_000, 1)
    end

    test "keeps stereo when asked" do
      pcm =
        <<100::little-signed-16, 200::little-signed-16, 300::little-signed-16,
          400::little-signed-16>>

      assert {out, <<>>} = Audio.from_room(pcm, 24_000, 2)
      assert samples(out) == [200, 300]
      assert Audio.from_room(pcm, 48_000, 2) == {pcm, <<>>}
    end

    test "interpolates 24 kHz mono to 48 kHz stereo" do
      {out, last} = Audio.to_room(<<100::little-signed-16, 300::little-signed-16>>, 24_000, 1)
      assert last == {300, 300}
      assert samples(out) == [50, 50, 100, 100, 200, 200, 300, 300]
    end

    test "interpolates 16 kHz across calls" do
      {_, last} = Audio.to_room(<<300::little-signed-16>>, 16_000, 1)
      {out, _} = Audio.to_room(<<600::little-signed-16>>, 16_000, 1, last)
      assert samples(out) == [400, 400, 500, 500, 600, 600]
    end

    test "rejects rates that don't divide 48 kHz" do
      assert_raise ArgumentError, fn -> Audio.from_room(<<>>, 44_100, 1) end
    end
  end

  describe "HTTP client" do
    defp config(fun), do: %{app_id: "app", app_secret: "secret", request_fun: fun}

    test "sends no body to /sessions/new" do
      test = self()

      config =
        config(fn opts ->
          send(test, {:req, opts})
          {:ok, %{status: 201, body: %{"sessionId" => "s"}}}
        end)

      assert {:ok, "s"} = HTTP.new_session(config)
      assert_received {:req, opts}
      refute Keyword.has_key?(opts, :json)
      assert opts[:url] == "https://rtc.live.cloudflare.com/v1/apps/app/sessions/new"
      assert opts[:auth] == {:bearer, "secret"}
    end

    test "reports top-level and HTTP errors" do
      top = fn _ ->
        {:ok, %{status: 200, body: %{"errorCode" => "x", "errorDescription" => "y"}}}
      end

      assert {:error, {:cloudflare, "/sessions/new", "x", "y"}} = HTTP.new_session(config(top))

      bad = fn _ -> {:ok, %{status: 400, body: "bad"}} end
      assert {:error, {:cloudflare, "/sessions/new", 400, "bad"}} = HTTP.new_session(config(bad))
    end

    test "retries what Cloudflare didn't carry out" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      fun = fn responses ->
        fn opts ->
          n = Agent.get_and_update(calls, &{length(&1), [opts[:method] | &1]})
          Enum.at(responses, n, List.last(responses))
        end
      end

      config = fn f -> %{config(f) | request_fun: f} |> Map.put(:backoff_ms, 1) end

      ok = {:ok, %{status: 200, body: %{"sessionId" => "s1"}}}
      busy = {:ok, %{status: 503, body: "busy"}}
      assert {:ok, "s1"} = HTTP.new_session(config.(fun.([busy, busy, ok])))
      assert Agent.get(calls, &length/1) == 3

      # Gives up after three attempts.
      Agent.update(calls, fn _ -> [] end)
      assert {:error, {:cloudflare, _, 503, _}} = HTTP.new_session(config.(fun.([busy])))
      assert Agent.get(calls, &length/1) == 3

      # A transport error isn't retried for a POST that may have arrived...
      Agent.update(calls, fn _ -> [] end)
      down = {:error, %Req.TransportError{reason: :closed}}
      assert {:error, _} = HTTP.new_session(config.(fun.([down, ok])))
      assert Agent.get(calls, &length/1) == 1

      # ...but is for a read.
      Agent.update(calls, fn _ -> [] end)
      state = {:ok, %{status: 200, body: %{"tracks" => []}}}
      assert {:ok, %{tracks: []}} = HTTP.session_state(config.(fun.([down, state])), "s")
      assert Agent.get(calls, &length/1) == 2
    end

    test "session state comes back normalized, and a dead session as :disconnected" do
      body = %{
        "tracks" => [
          %{"location" => "local", "trackName" => "a/mic", "mid" => "0", "status" => "active"},
          %{
            "location" => "remote",
            "sessionId" => "s2",
            "trackName" => "b/mic",
            "mid" => "1",
            "status" => "inactive"
          }
        ]
      }

      assert {:ok, %{tracks: [local, remote]}} =
               HTTP.session_state(config(fn _ -> {:ok, %{status: 200, body: body}} end), "s1")

      assert local == %{
               location: :local,
               track_name: "a/mic",
               mid: "0",
               session_id: nil,
               status: :active
             }

      assert remote == %{
               location: :remote,
               track_name: "b/mic",
               mid: "1",
               session_id: "s2",
               status: :inactive
             }

      gone = fn _ ->
        {:ok,
         %{
           status: 410,
           body: %{
             "errorCode" => "session_error",
             "errorDescription" => "Session appears to be disconnected."
           }
         }}
      end

      assert {:error, :disconnected} = HTTP.session_state(config(gone), "s1")
    end

    test "push fails on a per-track error" do
      resp = fn _ -> {:ok, %{status: 200, body: %{"tracks" => [%{"errorCode" => "bad_mid"}]}}} end

      assert {:error, {:cloudflare, :track_errors, [_]}} =
               HTTP.push_tracks(config(resp), "s", "offer", [%{mid: "0", track_name: "mic"}])
    end

    test "pull keeps going past per-track errors" do
      test = self()

      resp = fn opts ->
        send(test, {:req, opts})

        {:ok,
         %{
           status: 200,
           body: %{
             "requiresImmediateRenegotiation" => true,
             "sessionDescription" => %{"type" => "offer", "sdp" => "offer"},
             "tracks" => [
               %{"mid" => "1", "trackName" => "mic", "sessionId" => "a"},
               %{"errorCode" => "empty_track_error", "trackName" => "mic", "sessionId" => "b"}
             ]
           }
         }}
      end

      sources = [%{session_id: "a", track_name: "mic"}, %{session_id: "b", track_name: "mic"}]
      assert {:ok, result} = HTTP.pull_tracks(config(resp), "me", sources)
      assert result.sdp == "offer"
      assert result.renegotiate

      assert result.tracks == [
               %{session_id: "a", track_name: "mic", mid: "1"},
               %{session_id: "b", track_name: "mic", error: "empty_track_error"}
             ]

      assert_received {:req, opts}
      assert opts[:url] =~ "/sessions/me/tracks/new"

      assert opts[:json].tracks == [
               %{location: "remote", sessionId: "a", trackName: "mic"},
               %{location: "remote", sessionId: "b", trackName: "mic"}
             ]
    end

    test "close sends the client's offer, or forces without one" do
      test = self()

      resp = fn opts ->
        send(test, {:req, opts})
        {:ok, %{status: 200, body: %{"sessionDescription" => %{"sdp" => "answer"}}}}
      end

      assert {:ok, %{sdp: "answer"}} = HTTP.close_tracks(config(resp), "s", ["1"], "offer")
      assert_received {:req, opts}
      assert opts[:method] == :put

      assert opts[:json] == %{
               tracks: [%{mid: "1"}],
               force: false,
               sessionDescription: %{type: "offer", sdp: "offer"}
             }

      HTTP.close_tracks(config(resp), "s", ["1"], nil)
      assert_received {:req, opts}
      assert opts[:json] == %{tracks: [%{mid: "1"}], force: true}
    end
  end
end
