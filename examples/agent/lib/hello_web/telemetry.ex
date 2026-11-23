defmodule HelloWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      {HelloWeb.MetricsStorage, metrics()},
      HelloWeb.TraceStore
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Octoroom Agent Metrics (shown alongside Octoroom room metrics under ?nav=octoroom)
      summary("octoroom_agent.turn.latency.transcript_ms",
        tags: [:agent_id],
        unit: :millisecond,
        reporter_options: [nav: :octoroom],
        description: "Speech end to turn reaching the back end"
      ),
      summary("octoroom_agent.turn.latency.llm_ms",
        tags: [:agent_id],
        unit: :millisecond,
        reporter_options: [nav: :octoroom],
        description: "Speech end to first LLM text"
      ),
      summary("octoroom_agent.turn.latency.audio_ms",
        tags: [:agent_id],
        unit: :millisecond,
        reporter_options: [nav: :octoroom],
        description: "Speech end to first audio handed to the outlet"
      ),
      summary("octoroom_agent.processor.async.stop.first_output_duration",
        tags: [:agent_id, :processor],
        unit: {:native, :millisecond},
        reporter_options: [nav: :octoroom],
        description: "Time to first output (TTFT for LLM, TTFB for TTS)"
      ),
      summary("octoroom_agent.processor.async.stop.duration",
        tags: [:agent_id, :processor, :task, :status],
        unit: {:native, :millisecond},
        reporter_options: [nav: :octoroom],
        description: "Total async stage duration"
      ),
      counter("octoroom_agent.processor.async.stop.count",
        event_name: [:octoroom_agent, :processor, :async, :stop],
        measurement: :duration,
        tags: [:agent_id, :processor, :task, :status],
        reporter_options: [nav: :octoroom],
        description: "Completed async stages by status"
      ),
      counter("octoroom_agent.processor.async.exception.count",
        event_name: [:octoroom_agent, :processor, :async, :exception],
        measurement: :duration,
        tags: [:agent_id, :processor, :task],
        reporter_options: [nav: :octoroom],
        description: "Crashed async stages"
      ),
      summary("octoroom_agent.tool.call.stop.duration",
        tags: [:agent_id, :tool, :result],
        unit: {:native, :millisecond},
        reporter_options: [nav: :octoroom],
        description: "Tool handler duration"
      ),
      summary("octoroom_agent.live.response.stop.response_latency_ms",
        tags: [:agent_id, :provider],
        unit: :millisecond,
        reporter_options: [nav: :octoroom],
        description: "Live S2S response latency (user end to first audio)"
      ),
      summary("octoroom_agent.live.response.stop.duration",
        tags: [:agent_id, :provider, :status],
        unit: {:native, :millisecond},
        reporter_options: [nav: :octoroom],
        description: "Live S2S response streaming duration"
      ),
      counter("octoroom_agent.pipeline.interruption.count",
        event_name: [:octoroom_agent, :pipeline, :interruption],
        measurement: :killed_tasks,
        tags: [:agent_id],
        reporter_options: [nav: :octoroom],
        description: "Pipeline interruptions"
      ),

      # Octoroom Room & WebRTC Metrics
      summary("octoroom.participant.connected.duration_ms",
        unit: :millisecond,
        description: "Participant join to media connected"
      ),
      summary("octoroom.participant.first_pull.since_connected_ms",
        unit: :millisecond,
        description: "Connected to first remote track pulled"
      ),
      summary("octoroom.outlet.live.duration_ms",
        tags: [:worker_id],
        unit: :millisecond,
        description: "Outlet start to first RTP packet sent"
      ),
      summary("octoroom.cloudflare.request.duration_ms",
        tags: [:method, :result],
        unit: :millisecond,
        description: "Cloudflare Realtime SFU HTTP request duration"
      ),
      summary("octoroom.peer.connect.duration_ms",
        tags: [:worker_id],
        unit: :millisecond,
        description: "Worker WebRTC peer connection time to Cloudflare"
      ),
      summary("octoroom.pull.stop.duration_ms",
        unit: :millisecond,
        description: "Batched track pull round-trip"
      ),
      counter("octoroom.failure.count",
        tags: [:name, :given_up],
        tag_values: &failure_tag_values/1,
        description: "Retried or abandoned room/worker failures"
      ),

      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp failure_tag_values(meta) do
    Map.update(meta, :name, "", &format_failure_name/1)
  end

  defp format_failure_name({:peer, id}), do: "peer:#{id}"
  defp format_failure_name({:outlet, name}), do: "outlet:#{name}"
  defp format_failure_name({:inlet, {worker_id, input}}), do: "inlet:#{worker_id}:#{input}"
  defp format_failure_name(name) when is_binary(name), do: name
  defp format_failure_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_failure_name(other), do: inspect(other)

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {HelloWeb, :count_users, []}
    ]
  end
end
