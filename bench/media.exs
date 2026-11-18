# Measures what server-side workers cost the app's node.
#
#     elixir --sname bench -S mix run bench/media.exs -- --workers 0,1,5,10,20,40
#
# Each simulated worker is the real app-side media path: an `ex_webrtc` peer
# connection (DTLS, SRTP, ICE over UDP), an `Octoroom.Inlet` (jitter buffer,
# Opus decode, real-time hold), an `Octoroom.Worker.Server` running a worker
# that hears 16 kHz mono and speaks 24 kHz mono (an agent's formats), and an
# `Octoroom.Outlet` (pacing, Opus encode, RTP). The worker plays 20 ms of
# audio for every 20 ms it hears, so input and output are both busy all the
# time: an upper bound for an agent, which listens more than it speaks.
#
# Cloudflare's side runs in a second BEAM (a `:peer` node, so its CPU isn't
# counted): one peer connection per worker that sends a pre-encoded mono Opus
# voice stream, 50 packets a second, and times the packets the worker sends
# back. Nothing reaches the network beyond this machine.
#
# Per worker count, after a warm-up, it reports the app node's CPU (all
# threads, including NIFs, from `:erlang.statistics(:runtime)`) as cores in
# use and per worker, the kernel's share of it (Linux), the longest run queue
# seen, inlet drops, outlet underruns and
# the gaps between packets arriving from each outlet: 20 ms when all is well.
#
# Options: --workers 0,1,5,10 (counts to run), --seconds 20 (measured window),
# --warmup 5.

defmodule Bench.Voice do
  # A voice-like mono signal at 48 kHz: a gliding pitch with harmonics, shaped
  # into syllables and pauses, plus a little noise, so Opus spends realistic
  # bits on it. Returns a list of 20 ms Opus packets (10 s, looped by senders).
  def packets do
    enc = Membrane.Opus.Encoder.Native.create(48_000, 1, 2048, -1000, 3001)
    rate = 48_000
    :rand.seed(:exsss, {1, 2, 3})

    for frame <- 0..499 do
      pcm =
        for i <- 0..959, into: <<>> do
          t = (frame * 960 + i) / rate
          f0 = 140 + 30 * :math.sin(2 * :math.pi() * 0.7 * t)
          syllable = max(0.0, :math.sin(2 * :math.pi() * 3.5 * t))
          pause = if rem(trunc(t * 10), 30) > 22, do: 0.0, else: 1.0

          voiced =
            Enum.reduce(1..8, 0.0, fn h, acc ->
              acc + :math.sin(2 * :math.pi() * f0 * h * t) / h
            end)

          s = (voiced * syllable * pause * 6000 + (:rand.uniform() - 0.5) * 300) |> round()
          <<max(-32768, min(32767, s))::little-signed-16>>
        end

      {:ok, packet} = Membrane.Opus.Encoder.Native.encode_packet(enc, pcm, 960)
      packet
    end
  end
end

{:module, _, remote_bin, _} =
  defmodule Bench.Remote do
    # Runs on the peer node: Cloudflare plus the human on the other end.
    alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

    def put_packets(packets), do: :persistent_term.put(:bench_packets, List.to_tuple(packets))

    # Answers the app's offer from a new process that owns the connection.
    def connect(offer_sdp) do
      caller = self()
      pid = spawn(fn -> run(offer_sdp, caller) end)

      receive do
        {:answer, ^pid, sdp} -> {pid, sdp}
      after
        10_000 -> raise "remote answer timed out"
      end
    end

    def stats(pid) do
      send(pid, {:stats, self()})

      receive do
        {:stats, ^pid, stats} -> stats
      after
        5_000 -> nil
      end
    end

    def stop(pid), do: send(pid, :stop)

    defp run(offer_sdp, caller) do
      {:ok, pc} = PeerConnection.start_link(ice_servers: [])

      :ok =
        PeerConnection.set_remote_description(pc, %SessionDescription{
          type: :offer,
          sdp: offer_sdp
        })

      track = MediaStreamTrack.new(:audio)
      {:ok, _sender} = PeerConnection.add_track(pc, track)
      {:ok, answer} = PeerConnection.create_answer(pc)
      :ok = PeerConnection.set_local_description(pc, answer)
      send(caller, {:answer, self(), complete_sdp(pc)})

      loop(%{
        pc: pc,
        track: track,
        i: 0,
        seq: 0,
        ts: 0,
        next: nil,
        last: nil,
        gaps: [],
        received: 0
      })
    end

    defp loop(s) do
      receive do
        {:ex_webrtc, _pc, {:connection_state_change, :connected}} ->
          next = System.monotonic_time(:millisecond) + 20
          :erlang.start_timer(next, self(), :send, abs: true)
          loop(%{s | next: next})

        {:timeout, _, :send} ->
          packets = :persistent_term.get(:bench_packets)
          payload = elem(packets, rem(s.i, tuple_size(packets)))

          packet =
            ExRTP.Packet.new(payload,
              sequence_number: rem(s.seq, 65_536),
              timestamp: rem(s.ts, 4_294_967_296)
            )

          PeerConnection.send_rtp(s.pc, s.track.id, packet)
          next = s.next + 20
          :erlang.start_timer(next, self(), :send, abs: true)
          loop(%{s | i: s.i + 1, seq: s.seq + 1, ts: s.ts + 960, next: next})

        {:ex_webrtc, _pc, {:rtp, _track_id, _rid, _packet}} ->
          now = System.monotonic_time(:microsecond)
          gaps = if s.last, do: [now - s.last | s.gaps], else: s.gaps
          loop(%{s | last: now, gaps: gaps, received: s.received + 1})

        {:stats, from} ->
          send(from, {:stats, self(), %{gaps: s.gaps, received: s.received}})
          loop(%{s | gaps: [], received: 0})

        :stop ->
          PeerConnection.close(s.pc)

        _ ->
          loop(s)
      end
    end

    def complete_sdp(pc) do
      if PeerConnection.get_ice_gathering_state(pc) != :complete do
        receive do
          {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
        after
          5_000 -> :ok
        end
      end

      PeerConnection.get_local_description(pc).sdp
    end
  end

# Kept so the module can be loaded on the peer node: it has no beam on disk.
:persistent_term.put({:bench_bin, Bench.Remote}, remote_bin)

defmodule Bench.Agent do
  # Hears 16 kHz mono, speaks 24 kHz mono: 20 ms of "TTS" for every 20 ms heard.
  use Octoroom.Worker, audio: [rate: 16_000, channels: 1, output: [rate: 24_000]]

  @tts (for i <- 0..479, into: <<>> do
          <<round(4000 * :math.sin(2 * :math.pi() * 220 * i / 24_000))::little-signed-16>>
        end)

  @impl true
  def init(_args, _ctx), do: {:ok, 0}

  @impl true
  def handle_audio(_input, pcm, bytes) do
    # 640 bytes of 16 kHz mono is 20 ms.
    bytes = bytes + byte_size(pcm)

    if bytes >= 640,
      do: {:ok, bytes - 640, play: {:default, @tts}},
      else: {:ok, bytes}
  end
end

defmodule Bench.AppPeer do
  # Stands in for `Octoroom.Peer`: owns the app's peer connection, hands RTP
  # to the inlet and the sink to the outlet once connected.
  use GenServer

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(%{remote: node, inlet: inlet, outlet: outlet}) do
    {:ok, pc} = PeerConnection.start_link(ice_servers: [], ice_aggressive_nomination: true)
    out = MediaStreamTrack.new(:audio)
    {:ok, _} = PeerConnection.add_transceiver(pc, out, direction: :sendonly)
    {:ok, _} = PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    sdp = Bench.Remote.complete_sdp(pc)
    {remote, answer} = :erpc.call(node, Bench.Remote, :connect, [sdp])

    :ok =
      PeerConnection.set_remote_description(pc, %SessionDescription{type: :answer, sdp: answer})

    {:ok, %{pc: pc, out: out, inlet: inlet, outlet: outlet, remote: remote, connected: false}}
  end

  @impl true
  def handle_call(:connected?, _from, s), do: {:reply, s.connected, s}
  def handle_call(:remote, _from, s), do: {:reply, s.remote, s}

  @impl true
  def handle_info({:ex_webrtc, pc, {:rtp, _track, _rid, packet}}, %{pc: pc} = s) do
    send(s.inlet, {:octoroom_rtp, packet})
    {:noreply, s}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = s) do
    send(s.outlet, {:octoroom_sink, {:rtp, pc, s.out.id}})
    {:noreply, %{s | connected: true}}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, state}}, %{pc: pc} = s)
      when state in [:failed, :closed] do
    IO.puts(:stderr, "connection #{state}")
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: PeerConnection.close(s.pc)
end

defmodule Bench do
  def main(argv) do
    {opts, _, _} =
      OptionParser.parse(Enum.drop_while(argv, &(&1 == "--")),
        strict: [workers: :string, seconds: :integer, warmup: :integer]
      )

    counts =
      (opts[:workers] || "0,1,5,10,20") |> String.split(",") |> Enum.map(&String.to_integer/1)

    seconds = opts[:seconds] || 20
    warmup = opts[:warmup] || 5

    Logger.configure(level: :info)

    unless Node.alive?(), do: raise("run with `elixir --sname bench -S mix run bench/media.exs`")

    remote = start_remote()
    print_header(counts, seconds)

    for n <- counts do
      run(n, remote, seconds, warmup)
    end
  end

  defp start_remote do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, _peer, node} = :peer.start_link(%{name: :bench_remote, args: paths})

    for mod <- [Bench.Remote] do
      {^mod, bin, file} = :code.get_object_code(mod) |> ensure_object(mod)
      {:module, ^mod} = :erpc.call(node, :code, :load_binary, [mod, file, bin])
    end

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ex_webrtc])
    :ok = :erpc.call(node, Bench.Remote, :put_packets, [Bench.Voice.packets()])
    node
  end

  # Modules from an .exs file have no beam on disk; we kept their binaries.
  defp ensure_object(:error, mod), do: {mod, :persistent_term.get({:bench_bin, mod}), ~c"nofile"}
  defp ensure_object(found, _mod), do: found

  defp print_header(counts, seconds) do
    {os, _} = :os.type()

    IO.puts("""
    octoroom media benchmark
      host:       #{host()} (#{os}), #{System.schedulers_online()} schedulers
      otp:        #{System.otp_release()}, elixir #{System.version()}
      workers:    #{Enum.join(counts, ", ")}, #{seconds} s measured each
      per worker: 1 Opus voice stream in (16 kHz mono to the worker), 1 out (24 kHz mono), both continuous
    """)

    IO.puts(
      String.pad_trailing("workers", 9) <>
        String.pad_leading("cores", 7) <>
        String.pad_leading("ms/s/wkr", 10) <>
        String.pad_leading("kern%", 7) <>
        String.pad_leading("runq", 6) <>
        String.pad_leading("in drop", 9) <>
        String.pad_leading("underrun", 10) <>
        String.pad_leading("gap p50", 9) <>
        String.pad_leading("p99", 7) <>
        String.pad_leading("max", 7) <>
        String.pad_leading("MB", 7) <>
        String.pad_leading("setup s", 9)
    )
  end

  defp host do
    case :os.type() do
      {:unix, :darwin} ->
        String.trim(elem(System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"]), 0))

      _ ->
        case File.read("/proc/cpuinfo") do
          {:ok, info} ->
            case Regex.run(~r/model name\s*:\s*(.+)/, info) do
              [_, name] -> name
              _ -> "unknown cpu"
            end

          _ ->
            "unknown cpu"
        end
    end
  end

  defp run(n, remote, seconds, warmup) do
    t0 = System.monotonic_time(:millisecond)
    workers = for i <- 1..n//1, do: start_worker(i, remote)
    wait_connected(workers)
    setup_s = (System.monotonic_time(:millisecond) - t0) / 1000

    Process.sleep(warmup * 1000)

    # Zero the counters at the start of the window.
    for w <- workers, do: :erpc.call(remote, Bench.Remote, :stats, [w.remote])
    before = Enum.map(workers, &counters/1)

    runq = spawn_runq_sampler()
    {rt0, _} = :erlang.statistics(:runtime)
    cpu0 = proc_cpu()
    w0 = System.monotonic_time(:millisecond)
    Process.sleep(seconds * 1000)
    {rt1, _} = :erlang.statistics(:runtime)
    cpu1 = proc_cpu()
    w1 = System.monotonic_time(:millisecond)
    max_runq = stop_runq_sampler(runq)

    afterwards = Enum.map(workers, &counters/1)

    gaps =
      workers
      |> Enum.flat_map(
        &(:erpc.call(remote, Bench.Remote, :stats, [&1.remote]) || %{gaps: []}).gaps
      )

    cores = (rt1 - rt0) / (w1 - w0)
    per_worker = if n > 0, do: cores * 1000 / n, else: 0.0
    sys_share = sys_share(cpu0, cpu1)

    drops = sum(afterwards, before, :dropped)
    forwarded = sum(afterwards, before, :forwarded)
    underruns = sum(afterwards, before, :underruns)
    [p50, p99, max] = percentiles(gaps)

    IO.puts(
      String.pad_trailing("#{n}", 9) <>
        String.pad_leading(fmt(cores, 2), 7) <>
        String.pad_leading(if(n > 0, do: fmt(per_worker, 1), else: "-"), 10) <>
        String.pad_leading(if(sys_share, do: fmt(sys_share * 100, 0), else: "-"), 7) <>
        String.pad_leading("#{max_runq}", 6) <>
        String.pad_leading(drop_pct(drops, drops + forwarded), 9) <>
        String.pad_leading("#{underruns}", 10) <>
        String.pad_leading(ms(p50), 9) <>
        String.pad_leading(ms(p99), 7) <>
        String.pad_leading(ms(max), 7) <>
        String.pad_leading("#{div(:erlang.memory(:total), 1_048_576)}", 7) <>
        String.pad_leading(fmt(setup_s, 1), 9)
    )

    for w <- workers, do: stop_worker(w, remote)
    Process.sleep(1000)
  end

  defp start_worker(i, remote) do
    room = "bench-#{i}"
    sink = spawn(fn -> drain() end)

    {:ok, worker} =
      Octoroom.Worker.Server.start_link(%{
        room_id: room,
        spec: %{id: "agent", module: Bench.Agent, args: nil, inputs: ["in"], outputs: ["out"]},
        participants: []
      })

    {:ok, inlet} =
      Octoroom.Inlet.start_link(%{
        room_id: room,
        worker_id: "agent",
        input: "in",
        format: Bench.Agent.__octoroom_audio__()
      })

    {:ok, outlet} = Octoroom.Outlet.start_link(%{room_id: room, name: "out", server: sink})
    {:ok, peer} = Bench.AppPeer.start(%{remote: remote, inlet: inlet, outlet: outlet})

    %{
      room: room,
      worker: worker,
      inlet: inlet,
      outlet: outlet,
      peer: peer,
      sink: sink,
      remote: GenServer.call(peer, :remote)
    }
  end

  defp stop_worker(w, remote) do
    :erpc.call(remote, Bench.Remote, :stop, [w.remote])
    GenServer.stop(w.peer)
    GenServer.stop(w.worker)

    for pid <- [w.outlet, w.inlet, w.sink] do
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end
  end

  defp drain do
    receive do
      _ -> drain()
    end
  end

  defp wait_connected(workers, tries \\ 300)
  defp wait_connected(_workers, 0), do: raise("connections didn't come up")

  defp wait_connected(workers, tries) do
    if Enum.all?(workers, &GenServer.call(&1.peer, :connected?)) do
      :ok
    else
      Process.sleep(100)
      wait_connected(workers, tries - 1)
    end
  end

  defp counters(w) do
    inlet = Octoroom.Inlet.stats(w.inlet)
    outlet = Octoroom.Outlet.stats(w.room, "out")
    Map.merge(inlet, %{underruns: outlet.underruns})
  end

  defp sum(a, b, key),
    do: Enum.zip(a, b) |> Enum.map(fn {x, y} -> x[key] - y[key] end) |> Enum.sum()

  defp spawn_runq_sampler do
    spawn(fn -> runq_loop(0) end)
  end

  defp runq_loop(max) do
    receive do
      {:stop, from} -> send(from, {:runq, max})
    after
      50 -> runq_loop(max(max, :erlang.statistics(:total_run_queue_lengths_all)))
    end
  end

  defp stop_runq_sampler(pid) do
    send(pid, {:stop, self()})

    receive do
      {:runq, max} -> max
    end
  end

  # {user, system} CPU ticks of this OS process, on Linux.
  defp proc_cpu do
    case File.read("/proc/self/stat") do
      {:ok, stat} ->
        [_, after_comm] = String.split(stat, ") ", parts: 2)
        fields = String.split(after_comm)
        {String.to_integer(Enum.at(fields, 11)), String.to_integer(Enum.at(fields, 12))}

      _ ->
        nil
    end
  end

  defp sys_share({u0, s0}, {u1, s1}) when u1 + s1 > u0 + s0, do: (s1 - s0) / (u1 + s1 - u0 - s0)
  defp sys_share(_, _), do: nil

  defp percentiles([]), do: [nil, nil, nil]

  defp percentiles(gaps) do
    sorted = Enum.sort(gaps)
    len = length(sorted)

    [
      Enum.at(sorted, div(len, 2)),
      Enum.at(sorted, min(len - 1, trunc(len * 0.99))),
      List.last(sorted)
    ]
  end

  defp fmt(x, d), do: :erlang.float_to_binary(x * 1.0, decimals: d)
  defp ms(nil), do: "-"
  defp ms(us), do: fmt(us / 1000, 1)
  defp drop_pct(_, 0), do: "-"
  defp drop_pct(d, total), do: fmt(d * 100 / total, 2) <> "%"
end

Bench.main(System.argv())
