defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Align do
  @moduledoc false

  # Viterbi alignment of a word's spelling to an ARPAbet pronunciation using
  # `phonemizer/align.json` log-probabilities.

  @max_run 4
  @unseen -14.0
  @low -1.0e18

  defstruct [:table]

  def new(table) when is_map(table), do: %__MODULE__{table: table}

  @doc "ARPAbet symbol without its trailing stress digit."
  def base(symbol) when is_binary(symbol) do
    case byte_size(symbol) do
      0 ->
        ""

      n ->
        last = :binary.at(symbol, n - 1)
        if last in [?0, ?1, ?2], do: binary_part(symbol, 0, n - 1), else: symbol
    end
  end

  def score(%__MODULE__{table: table}, phone, run) do
    case table do
      %{^phone => %{^run => value}} -> value * 1.0
      _ -> @unseen - 2.0 * abs(String.length(run) - 1)
    end
  end

  @doc """
  Splits `word` into one letter run per phoneme in `phones`, or returns `nil`
  when `word` cannot be aligned (e.g. too long for the pronunciation).
  """
  def align(%__MODULE__{} = aligner, word, phones) when is_binary(word) and is_list(phones) do
    bases = Enum.map(phones, &base/1)
    chars = word |> String.graphemes() |> List.to_tuple()
    letters = tuple_size(chars)
    count = length(bases)

    if count == 0 or letters > @max_run * count do
      nil
    else
      viterbi(aligner, chars, letters, bases)
    end
  end

  defp viterbi(aligner, chars, letters, bases) do
    init_row =
      0..letters
      |> Enum.map(&if(&1 == 0, do: 0.0, else: @low))
      |> List.to_tuple()

    {final_row, trace_rows} =
      Enum.reduce(bases, {init_row, []}, fn phone, {prev_row, traces} ->
        {best_list, step_list} =
          Enum.reduce(0..letters, {[], []}, fn i, {b_acc, s_acc} ->
            {best_val, best_k} = best_step(aligner, chars, phone, prev_row, i)
            {[best_val | b_acc], [best_k | s_acc]}
          end)

        {best_list |> Enum.reverse() |> List.to_tuple(),
         [step_list |> Enum.reverse() |> List.to_tuple() | traces]}
      end)

    if elem(final_row, letters) <= @low do
      nil
    else
      backtrack(chars, letters, trace_rows, [])
    end
  end

  defp best_step(aligner, chars, phone, prev_row, i) do
    max_k = min(@max_run, i)

    Enum.reduce(0..max_k, {@low, 0}, fn k, {best_val, best_k} ->
      prev = elem(prev_row, i - k)

      if prev > @low do
        run = slice_chars(chars, i - k, k)
        val = prev + score(aligner, phone, run)
        if val > best_val, do: {val, k}, else: {best_val, best_k}
      else
        {best_val, best_k}
      end
    end)
  end

  defp backtrack(_chars, _i, [], acc), do: acc

  defp backtrack(chars, i, [trace | rest], acc) do
    k = elem(trace, i)
    run = slice_chars(chars, i - k, k)
    backtrack(chars, i - k, rest, [run | acc])
  end

  defp slice_chars(_chars, _start, 0), do: ""

  defp slice_chars(chars, start, len) do
    Enum.map_join(start..(start + len - 1), &elem(chars, &1))
  end
end
