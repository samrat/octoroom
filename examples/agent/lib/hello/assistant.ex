defmodule Hello.Assistant do
  @moduledoc """
  The clinic receptionist agent: a date-seeded system prompt, a greeting, clinic
  scheduling tools (`Hello.Clinic`), and switchable voice pipelines (OpenAI Live,
  Gemini Live, and cascaded STT → LLM → TTS presets).
  """
  use Octoroom.Agent

  alias Hello.Clinic
  alias Octoroom.Agent.Pipeline.Spec
  alias Octoroom.Agent.Tool

  @tool_names ~w(check_availability book_appointment list_appointments cancel_appointment)

  @default_pipeline "openai_live"

  @pipelines [
    %{
      id: "nuance_sam",
      name: "Nuance Live · Sam (Video)",
      label: "Video avatar · Nuance Live (Sam)",
      agent: __MODULE__,
      video: true
    },
    %{
      id: "nuance_sonia",
      name: "Nuance Live · Sonia (Video)",
      label: "Video avatar · Nuance Live (Sonia)",
      agent: __MODULE__,
      video: true
    },
    %{
      id: "nuance_mira",
      name: "Nuance Live · Mira (Video)",
      label: "Video avatar · Nuance Live (Mira)",
      agent: __MODULE__,
      video: true
    },
    %{
      id: "openai_live",
      name: "OpenAI Live · gpt-live-1.1",
      label: "Speech-to-speech · OpenAI gpt-live-1.1",
      agent: __MODULE__
    },
    %{
      id: "gemini_live",
      name: "Gemini Live · gemini-3.8-live",
      label: "Speech-to-speech · Gemini 3.8 Live",
      agent: __MODULE__
    },
    %{
      id: "cascaded_openai",
      name: "Cascaded · GPT-5.4 Mini + AssemblyAI EU",
      label: "AssemblyAI EU → GPT-5.4 Mini → AssemblyAI EU",
      agent: __MODULE__
    },
    %{
      id: "cascaded_nemotron",
      name: "Cascaded · Nemotron + AssemblyAI EU",
      label: "AssemblyAI EU → Nemotron 3.5 Lightning → AssemblyAI EU",
      agent: __MODULE__
    },
    %{
      id: "cascaded_gemini",
      name: "Cascaded · Gemini 3.5 Flash Lite + AssemblyAI EU",
      label: "AssemblyAI EU → Gemini 3.5 Flash Lite → AssemblyAI EU",
      agent: __MODULE__
    },
    %{
      id: "cascaded_local_tts",
      name: "Cascaded · Nemotron + TinyVoca",
      label: "Reson8 → Nemotron 3.5 Lightning → TinyVoca (local)",
      agent: __MODULE__
    },
    %{
      id: "booking",
      name: "Script · Clef Flash Booking",
      label: "AssemblyAI EU → Clef Flash Script → AssemblyAI EU",
      agent: Hello.Booking
    }
  ]

  def tool_names, do: @tool_names

  def pipelines, do: @pipelines

  def default_pipeline do
    if Application.get_env(:hello, :agent, __MODULE__) == Hello.Booking,
      do: "booking",
      else: @default_pipeline
  end

  def pipeline_info(id) do
    Enum.find(@pipelines, &(&1.id == id)) ||
      Enum.find(@pipelines, &(&1.id == @default_pipeline))
  end

  def valid_pipeline?(id), do: Enum.any?(@pipelines, &(&1.id == id))

  @impl true
  def instructions(ctx) do
    name_line =
      case Map.get(ctx.args || %{}, :pipeline) do
        "nuance_" <> persona ->
          "Your name is #{String.capitalize(persona)}. When the patient asks to check availability, book, list, or cancel an appointment, hand the request off to your backend and let them know you're checking.\n"

        _ ->
          ""
      end

    """
    #{name_line}You are the front-desk receptionist at Elixir Clinic, open Monday through Friday from 8 AM to 5 PM.
    You are on a direct one-on-one phone call with a patient, so always respond to the caller.
    #{Clinic.date_context()}
    Use your tools to check real availability, list existing appointments, book new appointments, or cancel appointments — never invent open slots or confirmation codes without calling a tool first.
    Before calling a tool, say a brief natural filler in 3 to 5 words (like "Let me check that." or "One moment, booking that.") so the caller never hears dead silence.
    Be warm, calm, and helpful. Ask one short question at a time and never give medical advice or diagnoses.
    Keep your spoken replies concise, natural, and to one or two short sentences.
    Always speak times naturally in 12-hour format (like "9 AM", "10:30 AM", "2 PM", or "3:30 PM"), while still passing 24-hour HH:MM times to your tools.
    """
  end

  @impl true
  def initial_text(_ctx),
    do: "Answer the phone warmly in one short sentence as the receptionist at Elixir Clinic."

  @impl true
  def pipeline(ctx) do
    build_pipeline(Map.get(ctx.args || %{}, :pipeline, @default_pipeline))
  end

  def build_pipeline("nuance_" <> persona) when persona in ~w(sam sonia mira) do
    Spec.nuance_live(
      persona: persona,
      camera: true,
      delegation: [
        model: "default",
        instructions:
          "Use the Elixir Clinic tools to check availability, book, list, or cancel appointments, then answer in one short sentence."
      ]
    )
  end

  def build_pipeline("gemini_live") do
    Spec.gemini_live(
      model: "gemini-3.8-live",
      voice: "Zephyr"
    )
  end

  @eu_stt [
    provider: :assembly_ai,
    model: "assemblyai-stt-3-7-realtime-agent",
    region: :eu,
    min_end_of_turn_silence_when_confident: 160
  ]

  @eu_tts [provider: :assembly_ai, model: "assemblyai-tts-1", region: :eu]

  def build_pipeline("cascaded_openai") do
    Spec.default(
      vad: [min_silence_ms: 200],
      stt: @eu_stt,
      llm: [
        provider: :openai,
        model: "gpt-5.4-mini",
        reasoning_effort: :none
      ],
      tts: @eu_tts
    )
  end

  def build_pipeline("cascaded_nemotron") do
    Spec.default(
      vad: [min_silence_ms: 200],
      stt: @eu_stt,
      llm: [
        provider: :openrouter,
        model: "nvidia/nemotron-3.5-lightning",
        reasoning_effort: :none,
        provider_options: [openrouter_provider: %{sort: "latency"}]
      ],
      tts: @eu_tts
    )
  end

  def build_pipeline("cascaded_gemini") do
    Spec.default(
      vad: [min_silence_ms: 200],
      stt: @eu_stt,
      llm: [
        provider: :google,
        model: "gemini-3.5-flash-lite",
        reasoning_effort: :minimal,
        provider_options: [google_include_thoughts: false]
      ],
      tts: @eu_tts
    )
  end

  def build_pipeline("cascaded_local_tts") do
    Spec.default(
      vad: [min_silence_ms: 200],
      stt: [provider: :reson8, model: "rumble-2", language_hints: ["en"]],
      llm: [
        provider: :openrouter,
        model: "nvidia/nemotron-3.5-lightning",
        reasoning_effort: :none,
        provider_options: [openrouter_provider: %{sort: "latency"}]
      ],
      tts: [provider: :tiny_voca, model: "tiny-voca", voice: "F2"]
    )
  end

  def build_pipeline(_openai_live) do
    Spec.openai_live(
      model: "gpt-live-1.1",
      voice: "marin",
      delegation: [model: "gpt-5.4-mini"],
      idle_timeout_s: 15,
      wake_policy: :speech
    )
  end

  @impl true
  def tools(_ctx) do
    [
      %Tool{
        name: "check_availability",
        description: "Check open appointment slots at Elixir Clinic for a given date.",
        parameters: %{
          type: "object",
          properties: %{
            date: %{
              type: "string",
              description: "Date in YYYY-MM-DD format (use the seeded upcoming clinic dates)."
            },
            doctor: %{
              type: "string",
              description: "Optional doctor name filter, e.g. Dr. Valim or Dr. Armstrong."
            }
          },
          required: ["date"]
        },
        handler: {__MODULE__, :check_availability}
      },
      %Tool{
        name: "book_appointment",
        description: "Book an available clinic appointment slot for the caller.",
        parameters: %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "Date in YYYY-MM-DD format."},
            time: %{
              type: "string",
              description: "Slot time such as 09:00, 10:30, 14:00, or 15:30."
            },
            patient_name: %{type: "string", description: "Caller's name."},
            reason: %{type: "string", description: "Short reason for the visit."},
            doctor: %{type: "string", description: "Optional preferred doctor."}
          },
          required: ["date", "time", "patient_name"]
        },
        handler: {__MODULE__, :book_appointment}
      },
      %Tool{
        name: "list_appointments",
        description: "List existing booked appointments at Elixir Clinic.",
        parameters: %{
          type: "object",
          properties: %{
            patient_name: %{type: "string", description: "Optional caller name filter."}
          }
        },
        handler: {__MODULE__, :list_appointments}
      },
      %Tool{
        name: "cancel_appointment",
        description: "Cancel an existing appointment by confirmation code or date.",
        parameters: %{
          type: "object",
          properties: %{
            confirmation_code: %{
              type: "string",
              description: "Confirmation code like EX-1042."
            },
            date: %{
              type: "string",
              description: "Appointment date in YYYY-MM-DD format if no code was given."
            }
          }
        },
        handler: {__MODULE__, :cancel_appointment}
      }
    ]
  end

  def check_availability(call, ctx) do
    run_tool(call, ctx, fn args ->
      case Clinic.check_availability(ctx.room_id, args["date"], args["doctor"]) do
        {:ok, data} -> {:ok, data}
        {:error, err} -> {:error, err}
      end
    end)
  end

  def book_appointment(call, ctx) do
    run_tool(call, ctx, fn args ->
      case Clinic.book_appointment(ctx.room_id, args) do
        {:ok, appt} -> {:ok, %{result: "booked", appointment: appt}}
        {:error, err} -> {:error, err}
      end
    end)
  end

  def list_appointments(call, ctx) do
    run_tool(call, ctx, fn args ->
      appts = Clinic.list_appointments(ctx.room_id, args["patient_name"])
      {:ok, %{appointments: appts}}
    end)
  end

  def cancel_appointment(call, ctx) do
    run_tool(call, ctx, fn args ->
      case Clinic.cancel_appointment(ctx.room_id, args) do
        {:ok, data} -> {:ok, Map.put(data, :result, "cancelled")}
        {:error, err} -> {:error, err}
      end
    end)
  end

  defp run_tool(call, ctx, fun) do
    args = Map.get(call, :args) || %{}
    room_id = Map.get(ctx, :room_id)
    started = System.monotonic_time(:millisecond)

    broadcast(
      room_id,
      {:tool_event, %{id: call.id, name: call.name, args: args, status: "running"}}
    )

    {status, response} =
      case fun.(args) do
        {:ok, resp} -> {"ok", resp}
        {:error, resp} -> {"error", resp}
      end

    duration_ms = max(System.monotonic_time(:millisecond) - started, 1)

    broadcast(
      room_id,
      {:tool_event,
       %{
         id: call.id,
         name: call.name,
         args: args,
         response: response,
         duration_ms: duration_ms,
         status: status
       }}
    )

    if room_id do
      broadcast(room_id, {:appointments_updated, Clinic.list_appointments(room_id)})
    end

    %{id: call.id, name: call.name, response: response}
  end

  defp broadcast(nil, _msg), do: :ok

  defp broadcast(room_id, msg) do
    Phoenix.PubSub.broadcast(Hello.PubSub, "clinic:#{room_id}", msg)
  end
end
