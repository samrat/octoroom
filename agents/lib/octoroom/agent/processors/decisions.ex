defmodule Octoroom.Agent.Processors.Decisions do
  @moduledoc """
  Asks a decision model about each turn, and attaches the answers to the
  turn: who the speaker is talking to, and whether an assistant could
  usefully answer. The agent's gate uses them to decide whether to reply.

  Each turn goes to a decision model (`ReqLLM.evaluate/4`), which answers
  calibrated questions in one call. The turn (`Transcription` or
  `UserAudio`) goes on with `decision` set to

      %{addressee: "assistant" | "person" | "group" | "nobody",
        confidence: 0.81, probabilities: %{...}, answerable: 0.95,
        answers: %{...}, latency_ms: 430, audio_ms: 2100, questions_id: nil}

  where `answers` are the model's raw answers by question (custom
  questions included), and the other fields read the `"addressee"` and
  `"answerable"` questions when they're asked; `audio_ms` is only there
  when the audio was judged.

  or `nil` when the call failed or was too slow.

  `:input` picks what the model judges:

    * `:audio` - the turn's audio, which carries tone and pauses. Only
      Gemini Decisions (`google:gemini-decision-1`) takes
      audio.
    * `:transcript` - the turn's final transcript, for text-only decision
      models such as `"openrouter:cloudflare/clef-flash"` (Cloudflare's
      Clef Flash). The call can't start until the transcript is final, so
      it adds its whole latency to the turn. Half-cascaded turns have no
      transcript and go on without a decision.

  It defaults to `:audio` for `google:` models and `:transcript` for any
  other.

  With `:audio`, place it in a front end after the turn stage. Behind an
  STT turn stage it
  records each turn from `VADUserStartedSpeaking` (with `preroll_ms` before
  it) and starts the call at the VAD's stop, so it runs while the STT
  finalizes; the transcript is held for at most `max_wait_ms` for the
  answers. A pause that turns out not to be the end of the turn cancels the
  call, and the turn is evaluated again when it ends. Behind `AudioTurns`
  (half-cascaded), the turn's own `UserAudio` is evaluated when it arrives.

  Options: `:model` (needed, such as `"google:gemini-decision-1"`), `:input` (see
  above), `:api_key` (default ReqLLM's key for the model's provider, such
  as `GOOGLE_API_KEY` or `OPENROUTER_API_KEY`), `:request_options`,
  `:questions` (see `default_questions/0`), `:max_wait_ms` (1500),
  `:preroll_ms` (1000), `:max_audio_ms` (30000), `:min_audio_ms` (300), and
  `:evaluate`, a `fn wav_or_text -> {:ok, answers} | {:error, reason} end`
  that replaces the API call (for tests). Under a host, it warms the
  connection with one call when it starts (on half a second of silence, or
  a short line of text).

  ## Changing the questions

  An `Octoroom.Agent.Frames.UpdateStage` naming this stage can change
  `:questions` while it runs, so each part of a conversation asks only what
  it needs. Pass `:questions_id` with them (any term, such as the name of
  the part of the conversation they're for): every decision carries the
  `questions_id` of the questions it answered, so whoever reads it can tell
  answers to old questions, from a turn that was being judged when they
  changed. `:questions_id` is also an option here, `nil` by default.

  With no questions (`%{}`), nothing is asked: turns go on at once, with
  `decision: nil`.
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Cascaded.AudioTurn
  alias Octoroom.Agent.Frames
  alias ReqLLM.Message.ContentPart

  @sample_rate 16_000

  @default_questions %{
    "addressee" => %{
      type: :choice,
      instructions:
        "This is one turn from a group voice call that includes an AI assistant. " <>
          "Who is the speaker talking to?",
      criteria: %{
        "assistant" => "The AI assistant in the call.",
        "person" => "A specific other person in the call.",
        "group" => "Everyone in the call, or no one in particular.",
        "nobody" => "Nobody: thinking aloud, a remark, or a statement."
      }
    },
    "answerable" => %{
      type: :boolean,
      instructions:
        "Is this a question or request that an AI assistant could usefully answer right now?"
    }
  }

  # Models whose catalog entry doesn't say how to call them for decisions
  # yet, by spec. ReqLLM takes an inline model with the contract instead; its
  # id must not be one the catalog knows, or the catalog's entry wins.
  @inline_models %{
    "openrouter:cloudflare/clef-flash" => %{
      provider: :openrouter,
      id: "octoroom-clef-flash",
      provider_model_id: "cloudflare/clef-flash",
      capabilities: %{evaluate: true, chat: false},
      execution: %{
        evaluate: %{
          supported: true,
          base_url: "https://openrouter.ai",
          family: "openrouter_decisions",
          wire_protocol: "openrouter_decisions",
          path: "/api/alpha/decisions",
          provider_model_id: "cloudflare/clef-flash"
        }
      }
    }
  }

  @doc "The questions asked by default (`addressee` and `answerable`)."
  def default_questions, do: @default_questions

  @impl true
  def init(opts, ctx) do
    if is_binary(opts[:model]) or is_function(opts[:evaluate]),
      do: start(opts, ctx),
      else: {:error, {:no_model, __MODULE__}}
  end

  defp start(opts, ctx) do
    questions = Keyword.get(opts, :questions, @default_questions)
    input = Keyword.get_lazy(opts, :input, fn -> default_input(opts) end)

    # The first call opens a connection and takes seconds; make it now, so
    # the first real turn doesn't pay for it.
    if not Keyword.has_key?(opts, :evaluate) and is_pid(Map.get(ctx, :runner)) do
      evaluate = api_evaluate(input, questions, opts)
      Task.start(fn -> evaluate.(warm_up(input)) end)
    end

    {:ok,
     %{
       input: input,
       opts: opts,
       questions_id: Keyword.get(opts, :questions_id),
       # No questions: nothing to ask, and turns go on without a decision.
       ask?: questions != %{},
       evaluate: Keyword.get(opts, :evaluate) || api_evaluate(input, questions, opts),
       max_wait_ms: Keyword.get(opts, :max_wait_ms, 1_500),
       preroll_bytes: bytes(Keyword.get(opts, :preroll_ms, 1_000)),
       max_audio_bytes: bytes(Keyword.get(opts, :max_audio_ms, 30_000)),
       min_audio_bytes: bytes(Keyword.get(opts, :min_audio_ms, 300)),
       preroll: <<>>,
       # The turn being recorded: %{seq, audio, eval: nil | :running | {:done, decision}}
       rec: nil,
       # Turns handed off at `UserStoppedSpeaking`, by seq:
       # %{turn_id, eval: :running | {:done, decision}, held: nil | frame}
       turns: %{},
       seq: 0
     }}
  end

  @impl true
  def handle_frame(
        %Frames.Transcription{turn_id: turn_id, text: text} = frame,
        :downstream,
        state
      )
      when state.input == :transcript and state.ask? and not is_nil(turn_id) and
             is_binary(text) do
    case String.trim(text) do
      "" -> {[{:push, frame, :downstream}], state}
      text -> hold_and_evaluate(frame, text_task(state.seq + 1, text, state), state)
    end
  end

  # Judging transcripts: there's no audio to record, and nothing else to hold.
  def handle_frame(frame, direction, %{input: :transcript} = state),
    do: {[{:push, frame, direction}], state}

  def handle_frame(%Frames.InputAudio{audio: audio} = frame, :downstream, state),
    do: {[{:push, frame, :downstream}], record(state, audio)}

  def handle_frame(%Frames.VADUserStartedSpeaking{} = frame, :downstream, state) do
    {effects, state} = speech_started(state)
    {[{:push, frame, :downstream} | effects], state}
  end

  # A candidate end of turn: start evaluating while the turn stage decides.
  def handle_frame(%Frames.VADUserStoppedSpeaking{} = frame, :downstream, state) do
    {effects, state} = start_eval(state)
    {[{:push, frame, :downstream} | effects], state}
  end

  def handle_frame(%Frames.UserStoppedSpeaking{turn_id: turn_id} = frame, :downstream, state) do
    {effects, state} = start_eval(state)
    {[{:push, frame, :downstream} | effects], hand_off(state, turn_id)}
  end

  # Half-cascaded: the turn arrives as audio, nothing was recorded here.
  def handle_frame(%Frames.UserAudio{turn_id: turn_id} = frame, :downstream, state) do
    case find_turn(state, turn_id) do
      nil -> evaluate_frame(frame, state)
      found -> hold_or_release(frame, found, state)
    end
  end

  def handle_frame(%Frames.Transcription{turn_id: turn_id} = frame, :downstream, state)
      when not is_nil(turn_id) do
    case find_turn(state, turn_id) do
      nil -> {[{:push, frame, :downstream}], state}
      found -> hold_or_release(frame, found, state)
    end
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_update(opts, state) do
    case Keyword.split(opts, [:questions, :questions_id]) do
      {update, []} ->
        state = %{state | questions_id: Keyword.get(update, :questions_id, state.questions_id)}

        # A test's `:evaluate` has no questions to change.
        state =
          case Keyword.fetch(update, :questions) do
            {:ok, questions} ->
              state = %{state | ask?: questions != %{}}

              if Keyword.has_key?(state.opts, :evaluate),
                do: state,
                else: %{state | evaluate: api_evaluate(state.input, questions, state.opts)}

            :error ->
              state
          end

        {[], state}

      {_update, other} ->
        {[{:error, {:not_updatable, Keyword.keys(other)}, false}], state}
    end
  end

  @impl true
  def handle_async({:evaluate, seq}, {:done, {:ok, answers, timing}}, state),
    do: finish_eval(state, seq, decision(answers, timing))

  def handle_async({:evaluate, seq}, {:done, {:error, reason}}, state) do
    Logger.warning("DECISIONS evaluation failed: #{inspect(reason)}")
    finish_eval(state, seq, nil)
  end

  def handle_async({:evaluate, seq}, {:failed, reason}, state) do
    Logger.warning("DECISIONS evaluation crashed: #{inspect(reason)}")
    finish_eval(state, seq, nil)
  end

  @impl true
  def handle_timer({:wait, seq}, state) do
    case state.turns[seq] do
      %{held: held} when held != nil ->
        Logger.info("DECISIONS turn=#{held.turn_id} timed out; sent without a decision")
        {[{:push, held, :downstream}], drop_turn(state, seq)}

      _other ->
        {[], state}
    end
  end

  # -- recording

  defp record(%{rec: nil} = state, audio),
    do: %{state | preroll: keep_last(state.preroll <> audio, state.preroll_bytes)}

  defp record(%{rec: rec} = state, audio),
    do: %{state | rec: %{rec | audio: keep_last(rec.audio <> audio, state.max_audio_bytes)}}

  defp speech_started(%{rec: nil} = state) do
    seq = state.seq + 1
    {[], %{state | seq: seq, rec: %{seq: seq, audio: state.preroll, eval: nil}, preroll: <<>>}}
  end

  # Talking again after a pause: what was evaluated is no longer the turn.
  defp speech_started(%{rec: %{eval: :running} = rec} = state),
    do: {[{:cancel, {:evaluate, rec.seq}}], %{state | rec: %{rec | eval: nil}}}

  defp speech_started(%{rec: rec} = state), do: {[], %{state | rec: %{rec | eval: nil}}}

  defp start_eval(%{rec: %{eval: nil} = rec} = state)
       when state.ask? and byte_size(rec.audio) >= state.min_audio_bytes do
    {[eval_task(rec.seq, rec.audio, state)], %{state | rec: %{rec | eval: :running}}}
  end

  defp start_eval(state), do: {[], state}

  defp eval_task(seq, pcm, state) do
    wav = AudioTurn.wav(pcm, @sample_rate)
    audio_ms = AudioTurn.duration_ms(pcm, @sample_rate)
    timing = %{audio_ms: audio_ms, questions_id: state.questions_id}

    meta = %{
      model: state.opts[:model],
      modality: :audio,
      audio_ms: audio_ms,
      questions_id: state.questions_id
    }

    timed_task(seq, state.evaluate, wav, timing, meta)
  end

  defp text_task(seq, text, state) do
    meta = %{
      model: state.opts[:model],
      modality: :transcript,
      chars: String.length(text),
      questions_id: state.questions_id
    }

    timed_task(seq, state.evaluate, text, %{questions_id: state.questions_id}, meta)
  end

  defp timed_task(seq, evaluate, input, timing, meta) do
    task = fn _emit ->
      {micros, result} = :timer.tc(fn -> evaluate.(input) end)

      case result do
        {:ok, answers} -> {:ok, answers, Map.put(timing, :latency_ms, div(micros, 1_000))}
        {:error, reason} -> {:error, reason}
      end
    end

    {:async, {:evaluate, seq}, task, meta}
  end

  defp hand_off(%{rec: %{eval: eval} = rec} = state, turn_id) when eval != nil do
    turn = %{turn_id: turn_id, eval: eval, held: nil}
    %{state | rec: nil, turns: Map.put(state.turns, rec.seq, turn)}
  end

  # Too short to evaluate.
  defp hand_off(state, _turn_id), do: %{state | rec: nil}

  # A `UserAudio` turn nobody recorded: evaluate its own audio, holding it.
  defp evaluate_frame(%Frames.UserAudio{audio: audio} = frame, state)
       when state.ask? and byte_size(audio) >= state.min_audio_bytes,
       do: hold_and_evaluate(frame, eval_task(state.seq + 1, audio, state), state)

  defp evaluate_frame(frame, state), do: {[{:push, frame, :downstream}], state}

  # Hold `frame` while `task` (numbered `state.seq + 1`) judges it.
  defp hold_and_evaluate(frame, task, state) do
    seq = state.seq + 1
    turn = %{turn_id: frame.turn_id, eval: :running, held: frame}

    {[task, {:timer, {:wait, seq}, state.max_wait_ms}],
     %{state | seq: seq, turns: Map.put(state.turns, seq, turn)}}
  end

  defp find_turn(state, turn_id),
    do: Enum.find(state.turns, fn {_seq, turn} -> turn.turn_id == turn_id end)

  defp hold_or_release(frame, {seq, %{eval: {:done, decision}}}, state),
    do: {release(frame, decision), drop_turn(state, seq)}

  defp hold_or_release(frame, {seq, %{eval: :running} = turn}, state) do
    turns = Map.put(state.turns, seq, %{turn | held: frame})
    {[{:timer, {:wait, seq}, state.max_wait_ms}], %{state | turns: turns}}
  end

  defp finish_eval(state, seq, decision) do
    case state.turns[seq] do
      %{held: held} when held != nil ->
        {[{:cancel_timer, {:wait, seq}} | release(held, decision)], drop_turn(state, seq)}

      %{} = turn ->
        {[], %{state | turns: Map.put(state.turns, seq, %{turn | eval: {:done, decision}})}}

      nil ->
        rec = state.rec

        if rec && rec.seq == seq,
          do: {[], %{state | rec: %{rec | eval: {:done, decision}}}},
          else: {[], state}
    end
  end

  defp release(frame, nil), do: [{:push, frame, :downstream}]

  defp release(frame, decision) do
    Logger.info(
      "DECISIONS turn=#{frame.turn_id} #{summary(decision)} latency_ms=#{decision.latency_ms}"
    )

    [{:push, %{frame | decision: decision}, :downstream}]
  end

  # The default questions' answers, or else each answer's choice or probability.
  defp summary(%{addressee: addressee} = d) when addressee != nil,
    do: "addressee=#{addressee}(#{d.confidence}) answerable=#{d.answerable}"

  defp summary(decision) do
    answers =
      Enum.map_join(decision.answers, " ", fn {question, answer} ->
        "#{question}=#{answer["choice"] || answer["probability"]}" <>
          if(answer["confidence"], do: "(#{round2(answer["confidence"])})", else: "")
      end)

    if id = decision[:questions_id], do: "questions=#{inspect(id)} #{answers}", else: answers
  end

  defp drop_turn(state, seq), do: %{state | turns: Map.delete(state.turns, seq)}

  # -- answers

  @doc false
  def decision(answers, timing) do
    addressee = answers["addressee"] || %{}
    answerable = answers["answerable"] || %{}

    Map.merge(timing, %{
      answers: answers,
      addressee: addressee["choice"],
      confidence: round2(addressee["confidence"]),
      probabilities: Map.new(addressee["probabilities"] || %{}, fn {k, v} -> {k, round2(v)} end),
      answerable: round2(answerable["probability"])
    })
  end

  defp round2(number) when is_number(number), do: Float.round(number / 1, 2)
  defp round2(_other), do: nil

  # -- the API call

  # No model: an `:evaluate` function stands in for it, and hears audio.
  defp default_input(opts) do
    case Keyword.get(opts, :model) do
      "google:" <> _ -> :audio
      nil -> :audio
      _other -> :transcript
    end
  end

  defp warm_up(:audio), do: AudioTurn.wav(:binary.copy(<<0, 0>>, 8_000), @sample_rate)
  defp warm_up(:transcript), do: "Hello."

  defp api_evaluate(input, questions, opts) do
    model = Keyword.get(opts, :model)
    model = Map.get(@inline_models, model, model)
    req_opts = Keyword.get(opts, :request_options, [])
    req_opts = if key = opts[:api_key], do: [{:api_key, key} | req_opts], else: req_opts

    fn turn ->
      with {:ok, response} <- ReqLLM.evaluate(model, state(input, turn), questions, req_opts) do
        {:ok, response.object}
      end
    end
  end

  defp state(:transcript, text), do: text

  defp state(:audio, wav) do
    ReqLLM.Context.new([
      ReqLLM.Context.user([ContentPart.file(wav, "turn.wav", "audio/wav")])
    ])
  end

  defp keep_last(binary, max) when byte_size(binary) <= max, do: binary
  defp keep_last(binary, max), do: binary_part(binary, byte_size(binary) - max, max)

  defp bytes(ms), do: div(@sample_rate * 2 * ms, 1_000)
end
