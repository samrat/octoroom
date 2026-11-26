defmodule Octoroom.Agent.Cascaded.TextChunker do
  @moduledoc false

  # Each chunk is synthesized as a separate TTS request, so every boundary
  # resets the voice's prosody. Only the first chunk is cut early (at a clause
  # or word limit) to keep time-to-first-audio low; after that, chunks end on
  # sentence boundaries so speech flows naturally. Long run-on sentences still
  # get split, preferring a clause boundary.

  defstruct buffer: "", emitted?: false

  @min_sentence_words 3
  @first_min_clause_words 8
  @first_max_words 24
  @later_min_clause_words 20
  @later_max_words 60

  @sentence_end ~r/[.!?]["')\]]*(?:\s+|$)/u
  @clause_end ~r/[,;:]["')\]]*(?:\s+|$)/u

  def new, do: %__MODULE__{}

  def push(%__MODULE__{} = state, text) when is_binary(text) do
    state
    |> Map.update!(:buffer, &(&1 <> text))
    |> drain([])
  end

  def flush(%__MODULE__{buffer: buffer} = state) do
    text = clean(buffer)

    chunks =
      if text == "" do
        []
      else
        [text]
      end

    {chunks, %{state | buffer: "", emitted?: state.emitted? or chunks != []}}
  end

  def reset(%__MODULE__{} = state), do: %{state | buffer: ""}

  defp drain(%__MODULE__{} = state, chunks) do
    case next_chunk(state.buffer, state.emitted?) do
      {:ok, chunk, rest} ->
        state = %{state | buffer: rest, emitted?: true}
        drain(state, [chunk | chunks])

      :wait ->
        {Enum.reverse(chunks), state}
    end
  end

  defp next_chunk(buffer, emitted?) do
    text = clean(buffer)

    cond do
      text == "" ->
        :wait

      sentence = boundary_chunk(text, @sentence_end, @min_sentence_words) ->
        split_at(buffer, sentence)

      not emitted? ->
        split_long(buffer, text, @first_min_clause_words, @first_max_words)

      word_count(text) >= @later_max_words ->
        split_long(buffer, text, @later_min_clause_words, @later_max_words)

      true ->
        :wait
    end
  end

  defp split_long(buffer, text, min_clause_words, max_words) do
    cond do
      clause = boundary_chunk(text, @clause_end, min_clause_words) ->
        split_at(buffer, clause)

      word_count(text) >= max_words ->
        split_at(buffer, words_chunk(text, max_words))

      true ->
        :wait
    end
  end

  defp boundary_chunk(text, regex, min_words) do
    regex
    |> Regex.scan(text, return: :index)
    |> Enum.find_value(fn [{index, length} | _] ->
      candidate = binary_part(text, 0, index + length) |> clean()

      if word_count(candidate) >= min_words do
        candidate
      end
    end)
  end

  defp words_chunk(text, max_words) do
    words =
      text
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.take(max_words)

    Enum.join(words, " ")
  end

  defp split_at(buffer, chunk) do
    buffer = String.trim_leading(buffer)

    rest =
      buffer
      |> String.replace_prefix(chunk, "")
      |> String.trim_leading()

    {:ok, chunk, rest || ""}
  end

  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()

  defp clean(text), do: String.trim(text || "")
end
