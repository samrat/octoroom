defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Sentence do
  @moduledoc false

  # Clause-level stress resolution, linking r, "the"/"to" before vowels,
  # flapping of "it"/"at", and grouping of attached units.

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.Symbols

  @split %{
    "ɑːɹ" => "ɑː",
    "ɔːɹ" => "ɔː",
    "oːɹ" => "oː",
    "ɪɹ" => "ɪ",
    "ɛɹ" => "ɛ",
    "ʊɹ" => "ʊ"
  }
  @rhotic MapSet.new(["ɚ", "ɜː", "aɪɚ"])
  @no_link_before MapSet.new(~w(and or if))
  @flap_before_vowel MapSet.new(~w(it at))

  defmodule Unit do
    @moduledoc false
    defstruct [:word, :phones, kind: "c", final: nil, attach: false, source: ""]
  end

  def unstress(phones), do: Enum.map(phones, fn {p, _} -> {p, 0} end)

  def promote(phones) do
    marks = Enum.map(phones, &elem(&1, 1))

    if 1 in marks do
      phones
    else
      target =
        case last_index_of(marks, 2) do
          nil -> Enum.find_index(phones, fn {p, _} -> Symbols.vowel?(p) end)
          idx -> idx
        end

      phones
      |> Enum.with_index()
      |> Enum.map(fn {{p, st}, i} -> {p, if(i == target, do: 1, else: st)} end)
    end
  end

  def stress_clause([]), do: []

  def stress_clause(units) do
    last_idx = length(units) - 1

    {resolved, _primary_follows} =
      units
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.reduce({[], false}, fn {unit, idx}, {acc, primary_follows} ->
        phones = resolve_unit_stress(unit, idx, last_idx, primary_follows)
        has_primary = Enum.any?(phones, fn {_, st} -> st == 1 end)
        {[%{unit | phones: phones} | acc], primary_follows or has_primary}
      end)

    ensure_clause_stress(resolved)
  end

  defp resolve_unit_stress(unit, idx, last_idx, primary_follows) do
    promoted = fn -> if unit.final != nil, do: unit.final, else: promote(unit.phones) end

    case unit.kind do
      "u" -> unstress(unit.phones)
      "uf" -> if idx == last_idx, do: promoted.(), else: unstress(unit.phones)
      "ur" -> if primary_follows, do: unstress(unit.phones), else: promoted.()
      "s" -> if primary_follows, do: unit.phones, else: promoted.()
      "si" -> resolve_si(unit, idx, primary_follows, promoted)
      "pf" -> if idx == last_idx, do: promoted.(), else: unit.phones
      _ -> unit.phones
    end
  end

  defp resolve_si(unit, idx, primary_follows, promoted) do
    cond do
      not primary_follows -> promoted.()
      idx == 0 -> unit.phones
      true -> unstress(unit.phones)
    end
  end

  defp ensure_clause_stress(units) do
    any_stress? =
      Enum.any?(units, fn u -> Enum.any?(u.phones, fn {_, st} -> st > 0 end) end)

    if any_stress? do
      units
    else
      units
      |> Enum.reverse()
      |> promote_first_vowel_unit()
      |> Enum.reverse()
    end
  end

  defp promote_first_vowel_unit([]), do: []

  defp promote_first_vowel_unit([u | rest]) do
    if Enum.any?(u.phones, fn {p, _} -> Symbols.vowel?(p) end) do
      [%{u | phones: promote(u.phones)} | rest]
    else
      [u | promote_first_vowel_unit(rest)]
    end
  end

  def join_clause([]), do: []
  def join_clause([only]), do: [only]

  def join_clause([unit, following | rest]) do
    updated = join_pair(unit, following)
    [updated | join_clause([following | rest])]
  end

  defp join_pair(%{phones: []} = unit, _following), do: unit
  defp join_pair(unit, %{phones: []}), do: unit

  defp join_pair(unit, %{phones: [{next_phone, _} | _]} = following) do
    if Symbols.vowel?(next_phone) do
      adjust_end(unit, following)
    else
      unit
    end
  end

  defp adjust_end(unit, following) do
    {init, {last, stress}} = split_last(unit.phones)
    last_w = last_word(unit.word)
    first_w = first_word(following.word)

    cond do
      last_w == "the" and last == "ə" ->
        %{unit | phones: init ++ [{"ɪ", stress}]}

      last_w == "to" and last == "ə" ->
        %{unit | phones: init ++ [{"ʊ", stress}]}

      MapSet.member?(@no_link_before, first_w) ->
        unit

      Map.has_key?(@split, last) ->
        %{unit | phones: init ++ [{@split[last], stress}, {"ɹ", 0}]}

      MapSet.member?(@rhotic, last) ->
        %{unit | phones: unit.phones ++ [{"ɹ", 0}]}

      last == "t" and MapSet.member?(@flap_before_vowel, unit.word) and init != [] and
          Symbols.vowel?(elem(List.last(init), 0)) ->
        %{unit | phones: init ++ [{"ɾ", 0}]}

      true ->
        unit
    end
  end

  def groups(units) do
    units
    |> Enum.reduce([], fn unit, acc ->
      case {unit.attach, acc} do
        {true, [prev | rest]} -> [prev ++ unit.phones | rest]
        _ -> [unit.phones | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == []))
  end

  defp last_word(word) do
    case String.split(word, " ") do
      [] -> ""
      parts -> List.last(parts)
    end
  end

  defp first_word(word) do
    case String.split(word, " ", parts: 2) do
      [first | _] -> first
      [] -> ""
    end
  end

  defp split_last(list) do
    {last, rev_init} = List.pop_at(Enum.reverse(list), 0)
    {Enum.reverse(rev_init), last}
  end

  defp last_index_of(list, value) do
    list
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {^value, idx}, _acc -> idx
      _, acc -> acc
    end)
  end
end
