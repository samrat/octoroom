defmodule Teleprompter.Tracker do
  @moduledoc """
  Silent talking-points tracker powered by Clef Flash boolean decisions.

  Evaluates every finalized utterance against **only the still-uncovered**
  talking points. As soon as a point crosses `:threshold` (default `0.72`),
  it is checked off with its probability and triggering quote, and an upstream
  `Frames.UpdateStage` removes that question from `:decisions` so Clef Flash
  does less work on every turn (and zero calls once all points are covered).

  Supports live control messages via `Octoroom.Worker.send/3`:

    * `{:teleprompter, {:add, text}}`
    * `{:teleprompter, {:remove, id}}`
    * `{:teleprompter, {:toggle, id}}`
    * `{:teleprompter, :reset}`
    * `{:teleprompter, {:set_points, texts}}`
    * `{:teleprompter, {:set_threshold, float}}`
  """
  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Frames

  @default_threshold 0.72
  @max_history 25

  @impl true
  def init(opts, ctx) do
    saved = get_in(ctx, [:memory, :tracker]) || %{}

    points =
      case Map.fetch(saved, :points) do
        {:ok, list} when is_list(list) -> list
        _ -> build_points(Keyword.get(opts, :points, []))
      end

    state = %{
      points: points,
      threshold: Map.get(saved, :threshold, Keyword.get(opts, :threshold, @default_threshold)),
      history: Map.get(saved, :history, []),
      rev: Map.get(saved, :rev, 1),
      next_id: Map.get(saved, :next_id, length(points) + 1)
    }

    {:ok, state}
  end

  @doc "Builds the Clef Flash boolean question map for all uncovered points."
  def questions_for(points) when is_list(points) do
    for p <- points, not p.covered?, into: %{} do
      {p.id,
       %{
         type: :boolean,
         instructions:
           "Has the speaker meaningfully covered, explained, or mentioned this talking point in what they said? " <>
             "Talking point: \"#{p.text}\""
       }}
    end
  end

  @doc "Parses multiline text (including bulleted or numbered lists) into talking point strings."
  def parse_lines(raw) when is_binary(raw) do
    raw
    |> String.split(~r/\r?\n/)
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.replace(~r/^(?:[-*•–—]+\s*(?:\[[ xX]?\]\s*)?|\d+[.)]\s*)/u, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_lines(_), do: []

  @doc "Builds initial point structs from a list of strings."
  def build_points(texts) when is_list(texts) do
    texts
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index(1)
    |> Enum.map(fn {text, i} -> new_point("p#{i}", text) end)
  end

  @impl true
  def handle_frame(%Frames.Start{} = frame, :downstream, state) do
    {[{:push, frame, :downstream} | sync_effects(state)], state}
  end

  def handle_frame(%Frames.Transcription{} = turn, :downstream, state) do
    utterance = turn.annotation || turn.text || ""
    answers = extract_answers(turn.decision)
    latency_ms = get_in(turn.decision || %{}, [:latency_ms])

    {points, newly_covered, scores} =
      apply_answers(state.points, answers, state.threshold, utterance)

    entry = %{
      id: System.unique_integer([:positive]),
      text: utterance,
      newly_covered: newly_covered,
      scores: scores,
      latency_ms: latency_ms,
      at: System.system_time(:millisecond)
    }

    history = Enum.take(state.history ++ [entry], -@max_history)
    rev = if newly_covered != [], do: state.rev + 1, else: state.rev
    state = %{state | points: points, history: history, rev: rev}

    effects =
      if newly_covered != [],
        do: sync_effects(state),
        else: notify_effects(state)

    {[{:push, %{turn | respond: false}, :downstream} | effects], state}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_info({:teleprompter, {:add, text}}, state) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {[], state}

      trimmed ->
        id = "p#{state.next_id}"

        state = %{
          state
          | points: state.points ++ [new_point(id, trimmed)],
            next_id: state.next_id + 1,
            rev: state.rev + 1
        }

        {sync_effects(state), state}
    end
  end

  def handle_info({:teleprompter, {:remove, id}}, state) when is_binary(id) do
    points = Enum.reject(state.points, &(&1.id == id))
    state = %{state | points: points, rev: state.rev + 1}
    {sync_effects(state), state}
  end

  def handle_info({:teleprompter, {:toggle, id}}, state) when is_binary(id) do
    now = System.system_time(:millisecond)

    points =
      Enum.map(state.points, fn
        %{id: ^id, covered?: true} = p ->
          %{p | covered?: false, probability: nil, quote: nil, covered_at: nil, manual?: false}

        %{id: ^id, covered?: false} = p ->
          %{
            p
            | covered?: true,
              probability: 1.0,
              quote: "Marked manually",
              covered_at: now,
              manual?: true
          }

        p ->
          p
      end)

    state = %{state | points: points, rev: state.rev + 1}
    {sync_effects(state), state}
  end

  def handle_info({:teleprompter, :reset}, state) do
    points =
      Enum.map(state.points, fn p ->
        %{
          p
          | covered?: false,
            probability: nil,
            best_probability: 0.0,
            quote: nil,
            covered_at: nil,
            manual?: false
        }
      end)

    state = %{state | points: points, history: [], rev: state.rev + 1}
    {sync_effects(state), state}
  end

  def handle_info({:teleprompter, {:set_points, texts}}, state) when is_list(texts) do
    points = build_points(texts)

    state = %{
      state
      | points: points,
        history: [],
        next_id: length(points) + 1,
        rev: state.rev + 1
    }

    {sync_effects(state), state}
  end

  def handle_info({:teleprompter, {:set_threshold, val}}, state)
      when is_number(val) and val >= 0.3 and val <= 0.98 do
    state = %{state | threshold: val / 1}
    {notify_effects(state), state}
  end

  def handle_info(_msg, state), do: {[], state}

  # -- helpers

  defp new_point(id, text) do
    %{
      id: id,
      text: text,
      covered?: false,
      probability: nil,
      best_probability: 0.0,
      quote: nil,
      covered_at: nil,
      manual?: false
    }
  end

  defp extract_answers(%{answers: answers}) when is_map(answers), do: answers
  defp extract_answers(_), do: %{}

  defp apply_answers(points, answers, threshold, utterance) do
    now = System.system_time(:millisecond)

    {rev_points, newly, scores} =
      Enum.reduce(points, {[], [], %{}}, fn point, {acc, newly, scores} ->
        case {point.covered?, Map.get(answers, point.id)} do
          {false, %{"probability" => p}} when is_number(p) ->
            best = max(point.best_probability || 0.0, p)
            scores = Map.put(scores, point.id, p)

            if p >= threshold do
              updated = %{
                point
                | covered?: true,
                  probability: p,
                  best_probability: best,
                  quote: utterance,
                  covered_at: now,
                  manual?: false
              }

              {[updated | acc], [point.id | newly], scores}
            else
              {[%{point | best_probability: best} | acc], newly, scores}
            end

          _ ->
            {[point | acc], newly, scores}
        end
      end)

    {Enum.reverse(rev_points), Enum.reverse(newly), scores}
  end

  defp sync_effects(state) do
    update = %Frames.UpdateStage{
      stage: :decisions,
      opts: [questions: questions_for(state.points), questions_id: state.rev]
    }

    [{:push, update, :upstream} | notify_effects(state)]
  end

  defp notify_effects(state) do
    snapshot = %{
      points: state.points,
      threshold: state.threshold,
      history: state.history,
      rev: state.rev,
      next_id: state.next_id
    }

    [{:notify, {:tracker_state, snapshot}}, {:notify, {:memory, %{tracker: snapshot}}}]
  end
end
