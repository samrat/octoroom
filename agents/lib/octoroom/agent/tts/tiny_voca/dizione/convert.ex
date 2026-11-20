defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Convert do
  @moduledoc false

  # Converts broad CMUdict ARPAbet (with optional spelling alignment) into
  # tiny-voca's 59-phone narrow American English inventory.

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.{Align, Symbols}

  @arpa_vowels MapSet.new(~w(AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW))
  @consonants %{
    "B" => "b",
    "CH" => "tʃ",
    "D" => "d",
    "DH" => "ð",
    "F" => "f",
    "G" => "ɡ",
    "HH" => "h",
    "JH" => "dʒ",
    "K" => "k",
    "L" => "l",
    "M" => "m",
    "N" => "n",
    "NG" => "ŋ",
    "P" => "p",
    "R" => "ɹ",
    "S" => "s",
    "SH" => "ʃ",
    "T" => "t",
    "TH" => "θ",
    "V" => "v",
    "W" => "w",
    "Y" => "j",
    "Z" => "z",
    "ZH" => "ʒ"
  }
  @full_vowels %{
    "AA" => "ɑː",
    "AE" => "æ",
    "AH" => "ʌ",
    "AO" => "ɔː",
    "AW" => "aʊ",
    "AY" => "aɪ",
    "EH" => "ɛ",
    "ER" => "ɜː",
    "EY" => "eɪ",
    "IH" => "ɪ",
    "IY" => "iː",
    "OW" => "oʊ",
    "OY" => "ɔɪ",
    "UH" => "ʊ",
    "UW" => "uː"
  }
  @arpabet MapSet.union(
             MapSet.new(Map.keys(@consonants)),
             MapSet.new(for v <- @arpa_vowels, d <- ["0", "1", "2"], do: v <> d)
           )
  @sibilants MapSet.new(~w(S Z SH ZH CH JH))
  @vowel_letters MapSet.new(~w(a e i o u y))
  @force_spellings ~w(forc ford sword worn torn sworn borne shorn pork divorc)
  @prefixes MapSet.new(~w(dis mis un in re non over pre))
  @weak_prefixes ~w(be de re pre)
  @ire_endings MapSet.new(~w(ing ings ingly able y er ers est))

  def is_arpabet?(symbols) when is_list(symbols) do
    symbols != [] and Enum.all?(symbols, &MapSet.member?(@arpabet, &1))
  end

  def to_text(phones) do
    Enum.map_join(phones, " ", fn
      {phone, 1} -> "ˈ" <> phone
      {phone, 2} -> "ˌ" <> phone
      {phone, _} -> phone
    end)
  end

  def from_text(text) when is_binary(text) do
    text
    |> String.split()
    |> Enum.map(&parse_phone!/1)
  end

  def from_text_safe(text) when is_binary(text) do
    {:ok, from_text(text)}
  rescue
    ArgumentError -> :error
  end

  defp parse_phone!(unit) do
    {stress, phone} =
      case unit do
        "ˈ" <> rest -> {1, rest}
        "ˌ" <> rest -> {2, rest}
        _ -> {0, unit}
      end

    unless Symbols.phone?(phone) do
      raise ArgumentError, "#{inspect(phone)} is not a phone of the inventory"
    end

    if stress > 0 and not Symbols.vowel?(phone) do
      raise ArgumentError, "stress mark on consonant #{inspect(phone)}"
    end

    {phone, stress}
  end

  def convert(word, arpabet, runs \\ nil) when is_binary(word) and is_list(arpabet) do
    w = build_word(word, arpabet, runs)

    w
    |> walk(0, [])
    |> Enum.reverse()
    |> flap()
    |> velar_n()
    |> settle_stress()
  end

  def settle_stress(phones) when is_list(phones) do
    arr = List.to_tuple(phones)
    vowel_indices = for {p, idx} <- Enum.with_index(phones), Symbols.vowel?(elem(p, 0)), do: idx
    primaries = Enum.filter(vowel_indices, fn idx -> elem(elem(arr, idx), 1) == 1 end)

    arr =
      primaries
      |> Enum.drop(-1)
      |> Enum.reduce(arr, fn idx, acc ->
        {p, _} = elem(acc, idx)
        put_elem(acc, idx, {p, 2})
      end)

    v_tuple = List.to_tuple(vowel_indices)
    v_count = tuple_size(v_tuple)

    arr =
      Enum.reduce(0..(v_count - 1)//1, arr, fn pos, acc ->
        idx = elem(v_tuple, pos)
        {p, st} = elem(acc, idx)

        if st == 2 and adjacent_primary?(acc, v_tuple, v_count, pos) do
          put_elem(acc, idx, {p, 0})
        else
          acc
        end
      end)

    Tuple.to_list(arr)
  end

  defp adjacent_primary?(arr, v_tuple, v_count, pos) do
    left = pos > 0 and elem(elem(arr, elem(v_tuple, pos - 1)), 1) == 1
    right = pos + 1 < v_count and elem(elem(arr, elem(v_tuple, pos + 1)), 1) == 1
    left or right
  end

  # -- Word representation

  defp build_word(word, arpabet, runs) do
    bases = Enum.map(arpabet, &Align.base/1)
    stresses = Enum.map(arpabet, &parse_arpa_stress/1)

    Enum.zip(arpabet, bases)
    |> Enum.each(fn {sym, b} ->
      unless Map.has_key?(@consonants, b) or MapSet.member?(@arpa_vowels, b) do
        raise ArgumentError, "#{inspect(sym)} is not an ARPAbet symbol"
      end
    end)

    aligned? = runs != nil
    run_list = if aligned?, do: runs, else: List.duplicate("", length(arpabet))

    {rev_starts, _} =
      Enum.reduce(run_list, {[], 0}, fn r, {acc, pos} ->
        {[pos | acc], pos + String.length(r)}
      end)

    %{
      word: word,
      bases: List.to_tuple(bases),
      stresses: List.to_tuple(stresses),
      aligned?: aligned?,
      runs: List.to_tuple(run_list),
      starts: rev_starts |> Enum.reverse() |> List.to_tuple(),
      count: length(bases)
    }
  end

  defp parse_arpa_stress(sym) do
    case :binary.at(sym, byte_size(sym) - 1) do
      ?0 -> 0
      ?1 -> 1
      ?2 -> 2
      _ -> nil
    end
  end

  defp base_at(w, i) when i >= 0 and i < w.count, do: elem(w.bases, i)
  defp base_at(_w, _i), do: nil

  defp stress_at(w, i) when i >= 0 and i < w.count, do: elem(w.stresses, i)
  defp stress_at(_w, _i), do: nil

  defp vowel?(w, i), do: i >= 0 and i < w.count and MapSet.member?(@arpa_vowels, elem(w.bases, i))

  defp unstressed?(w, i), do: vowel?(w, i) and stress_at(w, i) in [0, nil]

  defp run_at(w, i) when i >= 0 and i < w.count, do: elem(w.runs, i)
  defp run_at(_w, _i), do: ""

  defp vowel_letters(str) do
    str
    |> String.graphemes()
    |> Enum.filter(&MapSet.member?(@vowel_letters, &1))
    |> Enum.join()
  end

  defp letters_at(w, i), do: vowel_letters(run_at(w, i))

  defp before_at(%{aligned?: false}, _i), do: ""
  defp before_at(w, i), do: String.slice(w.word, 0, elem(w.starts, i))

  defp after_at(%{aligned?: false}, _i), do: ""

  defp after_at(w, i) do
    start = elem(w.starts, i) + String.length(elem(w.runs, i))
    String.slice(w.word, start..-1//1)
  end

  defp ends_with?(w, i, syms) do
    rem_count = w.count - (i + 1)
    rem_count == length(syms) and tail_matches?(w, i + 1, syms)
  end

  defp tail_matches?(_w, _i, []), do: true

  defp tail_matches?(w, i, [s | rest]),
    do: base_at(w, i) == s and tail_matches?(w, i + 1, rest)

  defp first_vowel?(w, i) do
    not Enum.any?(0..(i - 1)//1, &vowel?(w, &1))
  end

  defp next_vowel_stress(w, i) do
    Enum.find_value((i + 1)..(w.count - 1)//1, fn j ->
      if vowel?(w, j), do: stress_at(w, j)
    end)
  end

  defp weak_prefix?(w, i) do
    w.aligned? and first_vowel?(w, i) and letters_at(w, i) == "e" and
      String.starts_with?(w.word, @weak_prefixes) and
      before_at(w, i) in ["b", "d", "r", "pr"]
  end

  # -- Main conversion loop

  defp walk(%{count: count}, i, acc) when i >= count, do: acc

  defp walk(w, i, acc) do
    name = base_at(w, i)
    stress = stress_at(w, i) || 0

    if MapSet.member?(@arpa_vowels, name) do
      {next_i, acc} = convert_vowel(w, i, name, stress, acc)
      walk(w, next_i, acc)
    else
      {next_i, acc} = convert_consonant(w, i, name, acc)
      walk(w, next_i, acc)
    end
  end

  defp convert_consonant(w, i, "Y", acc) do
    if base_at(w, i + 1) == "AH" and unstressed?(w, i + 1) and
         base_at(w, i - 1) in ["N", "L"] and base_at(w, i + 2) != "L" and
         (not w.aligned? or String.contains?(run_at(w, i) <> run_at(w, i + 1), "i")) do
      {i + 2, [{"iə", 0} | acc]}
    else
      {i + 1, [{@consonants["Y"], 0} | acc]}
    end
  end

  defp convert_consonant(_w, i, name, acc) do
    {i + 1, [{@consonants[name], 0} | acc]}
  end

  defp convert_vowel(w, i, "ER", stress, acc) do
    acc = [{if(stress > 0, do: "ɜː", else: "ɚ"), stress} | acc]
    i = if base_at(w, i + 1) == "R", do: i + 1, else: i
    acc = if vowel?(w, i + 1), do: [{"ɹ", 0} | acc], else: acc
    {i + 1, acc}
  end

  defp convert_vowel(w, i, name, stress, acc) do
    nxt = base_at(w, i + 1)

    convert_r_or_diphthong(w, i, name, stress, nxt, acc) ||
      convert_unstressed_special(w, i, name, stress, nxt, acc) ||
      convert_vowel_fallback(w, i, name, stress, nxt, acc)
  end

  defp convert_r_or_diphthong(w, i, "AW", stress, "R", acc) do
    acc = [{"ɚ", 0}, {"aʊ", stress} | acc]
    acc = if vowel?(w, i + 2), do: [{"ɹ", 0} | acc], else: acc
    {i + 2, acc}
  end

  defp convert_r_or_diphthong(w, i, name, stress, "R", acc)
       when name in ["AA", "AO", "IH", "IY", "EH", "UH", "UW", "AY"] do
    before_vowel = vowel?(w, i + 2)
    {quality, single} = r_colored(w, i, name, stress, before_vowel)

    acc =
      if before_vowel,
        do: [{"ɹ", 0}, {quality, stress} | acc],
        else: [{single, stress} | acc]

    {i + 2, acc}
  end

  defp convert_r_or_diphthong(w, i, "AY", stress, "ER", acc) do
    if unstressed?(w, i + 1) do
      if run_at(w, i + 1) == "er" and run_at(w, i) != "i" do
        {i + 1, [{"aɪ", stress} | acc]}
      else
        acc = [{"aɪɚ", stress} | acc]
        i = i + 1
        acc = if vowel?(w, i + 1), do: [{"ɹ", 0} | acc], else: acc
        {i + 1, acc}
      end
    end
  end

  defp convert_r_or_diphthong(w, i, "AY", stress, "AH", acc) do
    if unstressed?(w, i + 1), do: {i + 2, [{"aɪə", stress} | acc]}
  end

  defp convert_r_or_diphthong(w, i, "IY", stress, "AH", acc) do
    if unstressed?(w, i + 1) and not weak_prefix?(w, i) do
      after_b = base_at(w, i + 2)

      if stress != 1 and
           (after_b in ["L", "D", "T"] or (after_b == "N" and base_at(w, i + 3) == "S")) do
        {i + 1, [{"ɪ", 0} | acc]}
      else
        {i + 2, [{"iə", stress} | acc]}
      end
    end
  end

  defp convert_r_or_diphthong(_w, _i, _name, _stress, _nxt, _acc), do: nil

  defp convert_unstressed_special(w, i, "AH", 0, "N", acc) do
    if base_at(w, i - 1) == "T" and base_at(w, i + 2) != "T" and glottal_t_ready?(acc) do
      [{"t", _} | rest] = acc
      {i + 2, [{"n̩", 0}, {"ʔ", 0} | rest]}
    end
  end

  defp convert_unstressed_special(w, i, "AH", 0, "W", acc) do
    if base_at(w, i + 2) == "AH" and unstressed?(w, i + 2) and
         String.contains?(run_at(w, i) <> run_at(w, i + 1), "u") do
      {i + 2, [{"uː", 0} | acc]}
    end
  end

  defp convert_unstressed_special(w, i, "AH", 0, "L", acc) do
    if i > 0 and not (vowel?(w, i + 2) and (stress_at(w, i + 2) || 0) > 0) do
      convert_syllabic_l(w, i, acc)
    end
  end

  defp convert_unstressed_special(_w, _i, _name, _stress, _nxt, _acc), do: nil

  defp convert_vowel_fallback(w, i, name, 0, _nxt, acc) when name in ["AH", "IH"] do
    {i + 1, [{reduced(w, i), 0} | acc]}
  end

  defp convert_vowel_fallback(w, i, "IY", stress, nxt, acc)
       when stress == 0 or (stress == 2 and nxt == nil) do
    {i + 1, [unstressed_iy(w, i) | acc]}
  end

  defp convert_vowel_fallback(w, 0, "AE", 0, nxt, acc) when nxt in ["D", "K"] do
    if String.starts_with?(w.word, ["ad", "acc"]),
      do: {1, [{"ɐ", 0} | acc]},
      else: {1, [{@full_vowels["AE"], 0} | acc]}
  end

  defp convert_vowel_fallback(w, i, name, stress, nxt, acc) when name in ["AA", "AO"] do
    cond do
      letters_at(w, i) == "a" and String.ends_with?(before_at(w, i), ["w", "qu"]) and nxt == "N" ->
        {i + 1, [{"ɔ", stress} | acc]}

      name == "AO" and letters_at(w, i) == "o" ->
        {i + 1, [{"ɔ", stress} | acc]}

      true ->
        {i + 1, [{@full_vowels[name], stress} | acc]}
    end
  end

  defp convert_vowel_fallback(_w, i, name, stress, _nxt, acc) do
    {i + 1, [{@full_vowels[name], stress} | acc]}
  end

  defp glottal_t_ready?([{"t", _}, {prev_phone, prev_stress} | _]) do
    Symbols.vowel?(prev_phone) and prev_stress > 0
  end

  defp glottal_t_ready?(_), do: false

  defp convert_syllabic_l(w, i, acc) do
    cond do
      letters_at(w, i) == "i" and vowel?(w, i + 2) ->
        {i + 1, [{"ɪ", 0} | acc]}

      base_at(w, i - 1) == "Y" and String.contains?(run_at(w, i - 1) <> run_at(w, i), "u") ->
        {i + 1, [{"ʊ", 0} | acc]}

      true ->
        {i + 2, [{"əl", 0} | acc]}
    end
  end

  defp r_colored(_w, _i, "AA", _stress, _bv), do: {"ɑː", "ɑːɹ"}

  defp r_colored(w, i, "AO", _stress, before_vowel) do
    q = north_or_force(w, i, before_vowel)
    {q, q <> "ɹ"}
  end

  defp r_colored(w, i, name, stress, _bv) when name in ["IH", "IY"] do
    q = if stress > 0 and letters_at(w, i) in ["e", "eo"], do: "iə", else: "ɪ"
    {q, "ɪɹ"}
  end

  defp r_colored(w, i, "EH", _stress, _bv) do
    doubled =
      String.starts_with?(run_at(w, i + 1) <> after_at(w, i + 1), "rr") or
        (String.ends_with?(run_at(w, i), "r") and String.starts_with?(run_at(w, i + 1), "r"))

    q = if letters_at(w, i) == "a" and doubled, do: "æ", else: "ɛ"
    {q, "ɛɹ"}
  end

  defp r_colored(_w, _i, name, _stress, _bv) when name in ["UH", "UW"], do: {"ʊɹ", "ʊɹ"}

  defp r_colored(w, i, "AY", _stress, _bv) do
    q =
      if not w.aligned? or MapSet.member?(@ire_endings, after_at(w, i + 1)),
        do: "aɪɚ",
        else: "aɪ"

    {q, "aɪɚ"}
  end

  defp north_or_force(%{aligned?: false}, _i, _before_vowel), do: "ɔː"

  defp north_or_force(w, i, before_vowel) do
    spelled = letters_at(w, i)

    cond do
      spelled in ["oa", "oo", "ou"] -> "oː"
      spelled != "o" -> "ɔː"
      true -> north_or_force_o(w, i, before_vowel)
    end
  end

  defp north_or_force_o(w, i, before_vowel) do
    run = run_at(w, i)

    tail =
      case :binary.match(run, "o") do
        {pos, 1} -> binary_part(run, pos + 1, byte_size(run) - pos - 1) <> after_at(w, i)
        :nomatch -> after_at(w, i)
      end

    rest = String.slice(tail, 1..-1//1)

    if before_vowel do
      cond do
        String.starts_with?(rest, "r") -> "ɔː"
        rest in ~w(y ies ied a as ah er ers) -> "oː"
        String.starts_with?(rest, ~w(ia io iu ing age)) -> "oː"
        true -> "ɔː"
      end
    else
      cond do
        String.starts_with?(rest, "e") -> "oː"
        String.ends_with?(before_at(w, i), "p") and String.starts_with?(rest, "t") -> "oː"
        Enum.any?(@force_spellings, &String.contains?(w.word, &1)) -> "oː"
        true -> "ɔː"
      end
    end
  end

  defp weak_i(w, i) do
    nxt = base_at(w, i + 1)
    nxt2 = base_at(w, i + 2)

    cond do
      nxt == "F" and nxt2 == "AH" and base_at(w, i + 3) == "L" ->
        "i"

      (nxt == "T" and nxt2 == "IY") or (nxt == "B" and nxt2 in ["AH", "L"]) ->
        "ᵻ"

      nxt == "F" and nxt2 == "AY" ->
        "ᵻ"

      nxt == "T" and ends_with?(w, i, ["T"]) and base_at(w, i - 1) in ["R", "ER"] and
          String.ends_with?(w.word, "ite") ->
        "ᵻ"

      true ->
        "ɪ"
    end
  end

  defp weak_e(w, i) do
    nxt = base_at(w, i + 1)
    prev = base_at(w, i - 1)

    cond do
      nxt == "T" and (ends_with?(w, i, ["T"]) or ends_with?(w, i, ["T", "S"])) ->
        if prev == "L", do: "ə", else: if(prev == "R", do: "ᵻ", else: "ɪ")

      nxt == "S" and
          (ends_with?(w, i, ["S", "T"]) or ends_with?(w, i, ["S", "T", "L", "IY"])) ->
        "ɪ"

      nxt == "JH" ->
        "ɪ"

      nxt == "K" and base_at(w, i + 2) == "T" ->
        "ɛ"

      nxt == "D" and ends_with?(w, i, ["D"]) ->
        "ɪ"

      true ->
        "ə"
    end
  end

  defp inflection?(w, i) do
    if i + 1 >= w.count or
         (w.aligned? and not String.contains?(run_at(w, i) <> run_at(w, i + 1), "e")) do
      false
    else
      nxt = base_at(w, i + 1)
      prev = base_at(w, i - 1)

      cond do
        nxt == "D" and prev in ["T", "D"] and
            (ends_with?(w, i, ["D"]) or ends_with?(w, i, ["D", "L", "IY"])) ->
          true

        nxt == "Z" and MapSet.member?(@sibilants, prev) and ends_with?(w, i, ["Z"]) ->
          true

        true ->
          false
      end
    end
  end

  defp first_syllable(w, i) do
    next_st = next_vowel_stress(w, i)

    if not w.aligned? or not first_vowel?(w, i) or next_st in [0, nil] do
      nil
    else
      first_syllable_match(w, i)
    end
  end

  defp first_syllable_match(w, i) do
    word = w.word

    cond do
      i == 0 and String.starts_with?(word, "e") -> first_syllable_e(word)
      weak_prefix?(w, i) -> first_syllable_weak_prefix(word)
      di_prefix?(w, i, word) -> "ᵻ"
      true -> nil
    end
  end

  defp first_syllable_e(word) do
    c1 = String.at(word, 1)
    c2 = String.at(word, 2)

    cond do
      String.starts_with?(word, "ex") ->
        "ɛ"

      c1 in ["n", "m", "s"] and c2 != nil and not MapSet.member?(@vowel_letters, c2) and c2 != c1 ->
        "ɛ"

      true ->
        "ɪ"
    end
  end

  defp first_syllable_weak_prefix(word) do
    if String.starts_with?(word, "pre") or
         (String.starts_with?(word, "be") and String.at(word, 2) in ["c", "g"]),
       do: "ɪ",
       else: "ᵻ"
  end

  defp di_prefix?(w, i, word) do
    letters_at(w, i) == "i" and String.starts_with?(word, "di") and String.length(word) > 3 and
      not MapSet.member?(@vowel_letters, String.at(word, 2)) and String.at(word, 2) != "s" and
      MapSet.member?(@vowel_letters, String.at(word, 3))
  end

  defp reduced(w, i) do
    name = base_at(w, i)
    spelled = letters_at(w, i)
    nxt = base_at(w, i + 1)
    prev = base_at(w, i - 1)

    cond do
      name == "IH" and nxt == "NG" -> "ɪ"
      inflection?(w, i) -> "ᵻ"
      ah_reduced = reduced_ah(w, i, name, spelled, nxt, prev) -> ah_reduced
      prefix = first_syllable(w, i) -> prefix
      true -> reduced_by_spelling(w, i, name, spelled, nxt)
    end
  end

  defp reduced_ah(w, i, "AH", spelled, nxt, prev) do
    cond do
      prev == "Y" and String.contains?(run_at(w, i - 1) <> run_at(w, i), "u") ->
        "ʊ"

      i == 0 and String.starts_with?(w.word, "a") ->
        "ɐ"

      i == 0 and nxt == "N" and String.starts_with?(w.word, "un") ->
        "ʌ"

      spelled == "a" and MapSet.member?(@prefixes, before_at(w, i)) and
          String.starts_with?(run_at(w, i), "a") ->
        "ɐ"

      true ->
        nil
    end
  end

  defp reduced_ah(_w, _i, _name, _spelled, _nxt, _prev), do: nil

  defp reduced_by_spelling(w, i, name, spelled, nxt) do
    cond do
      spelled == "e" and nxt in ["K", "G"] and String.starts_with?(run_at(w, i + 1), "x") and
          next_vowel_stress(w, i) not in [0, nil] ->
        "ɛ"

      spelled in ["i", "ai", "ui", "y"] ->
        weak_i(w, i)

      spelled == "e" ->
        weak_e(w, i)

      spelled == "a" ->
        reduced_a(w, i, name, nxt)

      name == "AH" and nxt == "M" and ends_with?(w, i, ["M"]) and String.ends_with?(w.word, "ome") ->
        "ʌ"

      name == "IH" and spelled not in ["o", "u", "ou"] ->
        "ɪ"

      true ->
        "ə"
    end
  end

  defp reduced_a(w, i, name, nxt) do
    cond do
      nxt == "JH" or (nxt == "N" and base_at(w, i + 2) == "JH") -> "ɪ"
      nxt == "S" and ends_with?(w, i, ["S"]) and String.ends_with?(w.word, "ace") -> "ɪ"
      name == "IH" and not (nxt == "T" and ends_with?(w, i, ["T"])) -> "ɪ"
      true -> "ə"
    end
  end

  defp unstressed_iy(w, i) do
    nxt = base_at(w, i + 1)

    cond do
      nxt == nil or ends_with?(w, i, ["Z"]) or ends_with?(w, i, ["D"]) ->
        {"i", 0}

      vowel?(w, i + 1) ->
        {if(nxt == "IH" and base_at(w, i + 2) == "NG", do: "i", else: "ɪ"), 0}

      weak_prefix?(w, i) ->
        if next_vowel_stress(w, i) == 1, do: {"ᵻ", 0}, else: {"iː", 2}

      true ->
        {"ɪ", 0}
    end
  end

  defp flap(phones) when length(phones) < 3, do: phones

  defp flap(phones) do
    arr = List.to_tuple(phones)
    n = tuple_size(arr)

    Enum.reduce(1..(n - 2), arr, fn k, acc ->
      {cur, _} = elem(acc, k)

      if cur == "t" and should_flap?(acc, k, n) do
        put_elem(acc, k, {"ɾ", 0})
      else
        acc
      end
    end)
    |> Tuple.to_list()
  end

  defp should_flap?(arr, k, n) do
    {before, _} = elem(arr, k - 1)
    {after_p, stress} = elem(arr, k + 1)

    valid_left = (Symbols.vowel?(before) or before == "ɹ") and before not in ["n̩", "əl"]
    valid_right = Symbols.vowel?(after_p) and after_p != "n̩"

    final_o =
      after_p == "oʊ" and
        (k + 2 == n or (k + 3 == n and elem(elem(arr, k + 2), 0) == "z"))

    before_en =
      after_p in ["ə", "ɚ"] and k + 2 < n and elem(elem(arr, k + 2), 0) == "n"

    valid_left and valid_right and (stress == 0 or final_o) and not before_en
  end

  defp velar_n([]), do: []

  defp velar_n([{"n", st}, {nxt, _} = second | rest]) when nxt in ["k", "ɡ"],
    do: [{"ŋ", st} | velar_n([second | rest])]

  defp velar_n([head | rest]), do: [head | velar_n(rest)]
end
