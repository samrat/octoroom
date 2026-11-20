defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Morphology do
  @moduledoc false

  # Derives pronunciations for inflected, prefixed, British-spelled, or compound
  # words not directly listed in CMUdict.

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.Symbols

  @short_stem ~r/(?:^|[^aeiou])[aeiou](?:[bcdfgklmnprstvz]|th)$/
  @sibilant MapSet.new(["s", "z", "ʃ", "ʒ", "tʃ", "dʒ"])
  @voiceless MapSet.new(["p", "t", "k", "f", "θ", "ʔ"])
  @split %{
    "ɑːɹ" => "ɑː",
    "ɔːɹ" => "ɔː",
    "oːɹ" => "oː",
    "ɪɹ" => "ɪ",
    "ɛɹ" => "ɛ"
  }
  @rhotic MapSet.new(["ɚ", "ɜː", "aɪɚ", "ʊɹ"])
  @consonant_letters MapSet.new(String.graphemes("bcdfghjklmnpqrstvwxz"))
  @consonant_or_u MapSet.put(@consonant_letters, "u")

  @endings [
    {"fully", [{"f", 0}, {"əl", 0}, {"i", 0}]},
    {"lessly", [{"l", 0}, {"ə", 0}, {"s", 0}, {"l", 0}, {"i", 0}]},
    {"ness", [{"n", 0}, {"ə", 0}, {"s", 0}]},
    {"less", [{"l", 0}, {"ə", 0}, {"s", 0}]},
    {"ments", [{"m", 0}, {"ə", 0}, {"n", 0}, {"t", 0}, {"s", 0}]},
    {"ment", [{"m", 0}, {"ə", 0}, {"n", 0}, {"t", 0}]},
    {"ful", [{"f", 0}, {"əl", 0}]},
    {"ship", [{"ʃ", 0}, {"ɪ", 2}, {"p", 0}]},
    {"hood", [{"h", 0}, {"ʊ", 2}, {"d", 0}]},
    {"like", [{"l", 0}, {"aɪ", 2}, {"k", 0}]},
    {"dom", [{"d", 0}, {"ə", 0}, {"m", 0}]},
    {"ish", [{"ɪ", 0}, {"ʃ", 0}]},
    {"able", [{"ə", 0}, {"b", 0}, {"əl", 0}]},
    {"ism", [{"ɪ", 0}, {"z", 0}, {"ə", 0}, {"m", 0}]},
    {"ist", [{"ɪ", 0}, {"s", 0}, {"t", 0}]},
    {"wards", [{"w", 0}, {"ɚ", 0}, {"d", 0}, {"z", 0}]},
    {"ward", [{"w", 0}, {"ɚ", 0}, {"d", 0}]},
    {"age", [{"ɪ", 0}, {"dʒ", 0}]},
    {"ers", [{"ɚ", 0}, {"z", 0}]},
    {"er", [{"ɚ", 0}]},
    {"est", [{"ɪ", 0}, {"s", 0}, {"t", 0}]},
    {"y", [{"i", 0}]}
  ]

  @prefixes [
    {"under", [{"ʌ", 2}, {"n", 0}, {"d", 0}, {"ɚ", 0}], [{"ʌ", 2}, {"n", 0}, {"d", 0}, {"ɚ", 0}]},
    {"over", [{"oʊ", 2}, {"v", 0}, {"ɚ", 0}], [{"oʊ", 2}, {"v", 0}, {"ɚ", 0}]},
    {"anti", [{"æ", 2}, {"n", 0}, {"t", 0}, {"i", 0}], [{"æ", 2}, {"n", 0}, {"t", 0}, {"i", 0}]},
    {"semi", [{"s", 0}, {"ɛ", 2}, {"m", 0}, {"i", 0}], [{"s", 0}, {"ɛ", 2}, {"m", 0}, {"i", 0}]},
    {"non", [{"n", 0}, {"ɑː", 2}, {"n", 0}], [{"n", 0}, {"ɑː", 2}, {"n", 0}]},
    {"out", [{"aʊ", 2}, {"t", 0}], [{"aʊ", 2}, {"t", 0}]},
    {"dis", [{"d", 0}, {"ɪ", 0}, {"s", 0}], [{"d", 0}, {"ɪ", 2}, {"s", 0}]},
    {"mis", [{"m", 0}, {"ɪ", 0}, {"s", 0}], [{"m", 0}, {"ɪ", 2}, {"s", 0}]},
    {"un", [{"ʌ", 0}, {"n", 0}], [{"ʌ", 2}, {"n", 0}]},
    {"in", [{"ɪ", 0}, {"n", 0}], [{"ɪ", 2}, {"n", 0}]},
    {"re", [{"ɹ", 0}, {"ᵻ", 0}], [{"ɹ", 0}, {"iː", 2}]},
    {"pre", [{"p", 0}, {"ɹ", 0}, {"iː", 2}], [{"p", 0}, {"ɹ", 0}, {"iː", 2}]}
  ]

  @british [
    {"isation", "ization"},
    {"ising", "izing"},
    {"ised", "ized"},
    {"ises", "izes"},
    {"ise", "ize"},
    {"yse", "yze"},
    {"our", "or"},
    {"ourable", "orable"},
    {"ours", "ors"},
    {"oured", "ored"},
    {"ouring", "oring"},
    {"tre", "ter"},
    {"tres", "ters"},
    {"bre", "ber"},
    {"ence", "ense"},
    {"ogue", "og"},
    {"mme", "m"},
    {"lled", "led"},
    {"lling", "ling"},
    {"ller", "ler"},
    {"oul", "ol"},
    {"ae", "e"},
    {"enqui", "inqui"}
  ]

  def join([], ending), do: ending
  def join(stem, []), do: stem

  def join(stem, [{first, first_stress} | _] = ending) do
    {init, {last, stress}} = split_last(stem)
    adjusted = adjust_seam(init, last, stress, first, first_stress, ending)
    adjusted ++ ending
  end

  defp adjust_seam(init, last, stress, first, first_stress, ending) do
    cond do
      Symbols.vowel?(first) ->
        adjust_vowel_seam(init, last, stress, first, first_stress, ending)

      last == "i" and first in ["n", "l", "f", "m"] ->
        init ++ [{"ɪ", stress}]

      last == "n" and first in ["k", "ɡ"] ->
        init ++ [{"ŋ", 0}]

      true ->
        init ++ [{last, stress}]
    end
  end

  defp adjust_vowel_seam(init, last, stress, first, first_stress, ending) do
    cond do
      Map.has_key?(@split, last) ->
        init ++ [{@split[last], stress}, {"ɹ", 0}]

      MapSet.member?(@rhotic, last) ->
        init ++ [{last, stress}, {"ɹ", 0}]

      last == "t" and init != [] and flap_prev?(List.last(init)) and first_stress == 0 and
          not (first == "ə" and match?([_, {"n", _} | _], ending)) ->
        init ++ [{"ɾ", 0}]

      last == "i" ->
        init ++ [{if(first != "ɪ", do: "ɪ", else: "i"), stress}]

      true ->
        init ++ [{last, stress}]
    end
  end

  defp flap_prev?({p, _}), do: Symbols.vowel?(p) or p == "ɹ"

  def plural(stem) do
    {last, _} = List.last(stem)

    ending =
      cond do
        MapSet.member?(@sibilant, last) -> [{"ᵻ", 0}, {"z", 0}]
        MapSet.member?(@voiceless, last) -> [{"s", 0}]
        true -> [{"z", 0}]
      end

    join(stem, ending)
  end

  def past(stem) do
    {last, _} = List.last(stem)

    ending =
      cond do
        last in ["t", "d", "ɾ"] -> [{"ᵻ", 0}, {"d", 0}]
        MapSet.member?(@voiceless, last) or last in ["s", "ʃ", "tʃ"] -> [{"t", 0}]
        true -> [{"d", 0}]
      end

    join(stem, ending)
  end

  def adverb(stem) do
    {last, _} = List.last(stem)
    ending = if last in ["əl", "l"], do: [{"i", 0}], else: [{"l", 0}, {"i", 0}]
    join(stem, ending)
  end

  def compound(first, second) do
    demoted = Enum.map(second, fn {p, st} -> {p, if(st == 1, do: 2, else: st)} end)
    join(first, demoted)
  end

  def derive(word, lookup, part \\ nil, depth \\ 0) do
    part = part || lookup
    ctx = %{lookup: lookup, part: part, depth: depth}

    derive_possessive(word, ctx) ||
      derive_inflection(word, ctx) ||
      derive_endings(word, ctx) ||
      derive_prefixes(word, ctx) ||
      derive_british(word, ctx) ||
      derive_compound(word, ctx)
  end

  defp stem_lookup(spelling, %{lookup: lookup, part: part, depth: depth}) do
    if String.length(spelling) < 2 do
      nil
    else
      lookup.(spelling) || if(depth < 2, do: derive(spelling, lookup, part, depth + 1))
    end
  end

  defp first_match(candidates, ctx, build) do
    Enum.find_value(candidates, fn spelling ->
      case stem_lookup(spelling, ctx) do
        nil -> nil
        found -> build.(found)
      end
    end)
  end

  defp derive_possessive(word, ctx) do
    cond do
      String.ends_with?(word, "'s") ->
        first_match([drop_tail(word, 2)], ctx, &plural/1)

      String.ends_with?(word, "s'") ->
        first_match([drop_tail(word, 1)], ctx, & &1)

      true ->
        nil
    end
  end

  defp derive_inflection(word, ctx) do
    len = String.length(word)
    derive_plural(word, len, ctx) || derive_verb_adverb(word, len, ctx)
  end

  defp derive_plural(word, len, ctx) do
    cond do
      String.ends_with?(word, "ies") and len > 4 ->
        first_match([drop_tail(word, 3) <> "y"], ctx, &plural/1)

      String.ends_with?(word, "ves") and len > 4 ->
        first_match([drop_tail(word, 3) <> "f", drop_tail(word, 3) <> "fe"], ctx, &ves_plural/1)

      String.ends_with?(word, "es") and len > 3 and
          String.at(word, len - 3) in ["s", "x", "z", "h"] ->
        first_match([drop_tail(word, 2)], ctx, &plural/1)

      String.ends_with?(word, "s") and not String.ends_with?(word, ["ss", "us", "is"]) and len > 3 ->
        first_match([drop_tail(word, 1)], ctx, &plural/1)

      true ->
        nil
    end
  end

  defp ves_plural(found) do
    {init, {last, _}} = split_last(found)
    if last == "f", do: join(init ++ [{"v", 0}], [{"z", 0}])
  end

  defp derive_verb_adverb(word, len, ctx) do
    (String.ends_with?(word, "ied") and len > 4 and
       first_match([drop_tail(word, 3) <> "y"], ctx, &past/1)) ||
      (String.ends_with?(word, "ed") and len > 3 and
         first_match(stems(drop_tail(word, 2)), ctx, &past/1)) ||
      (String.ends_with?(word, "ing") and len > 4 and
         first_match(stems(drop_tail(word, 3)), ctx, &join(&1, [{"ɪ", 0}, {"ŋ", 0}]))) ||
      (String.ends_with?(word, "ily") and len > 4 and
         first_match([drop_tail(word, 3) <> "y"], ctx, &adverb/1)) ||
      (String.ends_with?(word, "ly") and len > 3 and
         first_match(ly_candidates(word), ctx, &adverb/1))
  end

  defp ly_candidates(word) do
    base = drop_tail(word, 2)

    if String.ends_with?(word, ["bly", "ply"]) do
      [base, base <> "le", drop_tail(word, 1) <> "e"]
    else
      [base]
    end
  end

  defp derive_endings(word, ctx) do
    len = String.length(word)

    Enum.find_value(@endings, fn {spelling, phones} ->
      s_len = String.length(spelling)

      if String.ends_with?(word, spelling) and len - s_len > 2 do
        body = drop_tail(word, s_len)
        ending_match(spelling, phones, body, ctx)
      end
    end)
  end

  defp ending_match("y", phones, body, ctx) do
    if MapSet.member?(@consonant_letters, String.last(body)) do
      first_match(stems(body), ctx, &join(&1, phones))
    end
  end

  defp ending_match(_spelling, phones, body, ctx) do
    vowel_first? = Symbols.vowel?(elem(hd(phones), 0))

    candidates =
      cond do
        vowel_first? -> stems(body)
        String.ends_with?(body, "i") -> [drop_tail(body, 1) <> "y", body]
        true -> [body]
      end

    first_match(candidates, ctx, &join(&1, phones))
  end

  defp derive_prefixes(word, ctx) do
    len = String.length(word)

    Enum.find_value(@prefixes, fn {spelling, plain, stressed} ->
      s_len = String.length(spelling)

      if String.starts_with?(word, spelling) and len - s_len > 2 do
        apply_prefix(String.slice(word, s_len..-1//1), plain, stressed, ctx)
      end
    end)
  end

  defp apply_prefix(rest, plain, stressed, ctx) do
    case stem_lookup(rest, ctx) do
      nil ->
        nil

      found ->
        first_vowel_stress =
          Enum.find_value(found, fn {p, st} -> if Symbols.vowel?(p), do: st end)

        head = if first_vowel_stress == 1, do: plain, else: stressed
        join(head, found)
    end
  end

  defp derive_british(word, ctx) do
    Enum.find_value(@british, fn {old, new} ->
      if String.contains?(word, old) do
        stem_lookup(String.replace(word, old, new, global: false), ctx)
      end
    end)
  end

  defp derive_compound(word, %{depth: 0, part: part}) do
    len = String.length(word)

    if len < 8 do
      nil
    else
      best =
        Enum.reduce(4..(len - 4), nil, fn cut, best ->
          left = part.(String.slice(word, 0, cut))
          right = part.(String.slice(word, cut..-1//1))

          if left && right do
            score = min(cut, len - cut)
            if best == nil or score > elem(best, 0), do: {score, left, right}, else: best
          else
            best
          end
        end)

      case best do
        {_score, left, right} -> compound(left, right)
        nil -> nil
      end
    end
  end

  defp derive_compound(_word, _ctx), do: nil

  defp stems(body) do
    len = String.length(body)
    last = String.last(body)
    out = [body]

    out =
      if len > 2 and last == String.at(body, len - 2) and MapSet.member?(@consonant_letters, last) do
        out ++ [drop_tail(body, 1)]
      else
        out
      end

    out =
      if body != "" and MapSet.member?(@consonant_or_u, last) do
        if Regex.match?(@short_stem, body), do: [body <> "e" | out], else: out ++ [body <> "e"]
      else
        out
      end

    if String.ends_with?(body, "i") and len > 2 do
      out ++ [drop_tail(body, 1) <> "y"]
    else
      out
    end
  end

  defp drop_tail(str, n), do: String.slice(str, 0, max(String.length(str) - n, 0))

  defp split_last(list) do
    {last, rev_init} = List.pop_at(Enum.reverse(list), 0)
    {Enum.reverse(rev_init), last}
  end
end
