defmodule Octoroom.Agent.TTS.TinyVoca.Dizione do
  @moduledoc false

  # Pure-Elixir port of `n4ze3m/dizione` (English text -> tiny-voca phoneme IDs & stress).
  #
  # Word resolution order matches `dizione/engine.py`:
  #   1. inline pronunciation `{...}`
  #   2. caller `:overrides`
  #   3. built-in exceptions (`exceptions.txt`) & multi-word names
  #   4. phrases (`phrases.txt`)
  #   5. homographs (`homograph_rules.txt` + `homographs.json`)
  #   6. function words (`function_words.txt`)
  #   7. CMUdict lexicon (`lexicon.tsv`)
  #   8. regular morphology (endings, prefixes, British spellings, compounds)
  #   9. `-leigh` and `-virus` compounds
  #  10. neural G2P (`g2p.npz` via OnnxRuntime)
  #  11. letter-by-letter fallback (`letters.txt`)

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.{
    Align,
    Convert,
    Homographs,
    Morphology,
    Normalize,
    Sentence,
    Symbols,
    Tables
  }

  alias Octoroom.Agent.TTS.TinyVoca.G2P

  @leigh_re ~r/(?<=[a-z]{2})leigh(?=s?$)/
  @virus_tails ["viruses", "virus"]

  defstruct [
    :lexicon,
    :aligner,
    :g2p,
    :homographs,
    :functions,
    :phrases,
    :phrase_length,
    :exceptions,
    :names,
    :name_starts,
    :name_length,
    :letter_names,
    :normalizer,
    overrides: %{},
    user_names: MapSet.new()
  ]

  @doc """
  Loads the phonemizer from `phonemizer_dir` (containing `lexicon.tsv`,
  `align.json`, and optionally `homographs.json` and `g2p.json`/`g2p.npz`).
  """
  def load(phonemizer_dir, opts \\ []) do
    lexicon_path = Path.join(phonemizer_dir, "lexicon.tsv")
    align_path = Path.join(phonemizer_dir, "align.json")
    homographs_path = Path.join(phonemizer_dir, "homographs.json")
    g2p_npz_path = Path.join(phonemizer_dir, "g2p.npz")

    lexicon = load_lexicon!(lexicon_path)
    aligner = align_path |> File.read!() |> Jason.decode!() |> Align.new()
    homographs = if File.regular?(homographs_path), do: Homographs.load(homographs_path)
    g2p = if File.regular?(g2p_npz_path), do: G2P.load(phonemizer_dir)

    functions = Tables.function_words()
    phrases = if Keyword.get(opts, :join_phrases, true), do: Tables.phrases(), else: %{}
    phrase_length = phrases |> Map.keys() |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)

    exceptions = Tables.pronunciations("exceptions.txt")
    names = Tables.names("exceptions.txt")
    name_starts = names |> Map.keys() |> Enum.map(&hd/1) |> MapSet.new()
    name_length = names |> Map.keys() |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)

    letter_names =
      Tables.mapping("letters.txt")
      |> Map.new(fn {k, v} -> {k, Convert.from_text(v)} end)

    base = %__MODULE__{
      lexicon: lexicon,
      aligner: aligner,
      g2p: g2p,
      homographs: homographs,
      functions: functions,
      phrases: phrases,
      phrase_length: phrase_length,
      exceptions: exceptions,
      names: names,
      name_starts: name_starts,
      name_length: name_length,
      letter_names: letter_names
    }

    base = %{base | normalizer: Normalize.new(&word?(base, &1))}

    case Keyword.get(opts, :overrides) do
      nil -> base
      overrides -> with_overrides(base, overrides)
    end
  end

  def with_overrides(%__MODULE__{} = d, overrides) when map_size(overrides) == 0, do: d

  def with_overrides(%__MODULE__{} = d, overrides) do
    new_overrides = Map.merge(d.overrides, Tables.pronunciations(overrides))
    taught = Tables.names(overrides)
    new_names = Map.merge(d.names, taught)
    new_user_names = MapSet.union(d.user_names, MapSet.new(Map.keys(taught)))
    name_starts = new_names |> Map.keys() |> Enum.map(&hd/1) |> MapSet.new()
    name_length = new_names |> Map.keys() |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)

    updated = %{
      d
      | overrides: new_overrides,
        names: new_names,
        user_names: new_user_names,
        name_starts: name_starts,
        name_length: name_length
    }

    %{updated | normalizer: %{updated.normalizer | is_word: &word?(updated, &1)}}
  end

  @doc """
  Converts `text` into `{:ok, %{symbols, ids, stress, unknown}}` or
  `{:error, :nothing_to_pronounce}`.
  """
  def phonemize(%__MODULE__{} = d, text) when is_binary(text) do
    if String.trim(text) == "" do
      {:error, :nothing_to_pronounce}
    else
      d |> pieces(text) |> Symbols.tokenize()
    end
  end

  def pieces(%__MODULE__{} = d, text) when is_binary(text) do
    d
    |> analyse(text)
    |> Enum.map(fn
      {:punct, mark} -> {:punct, mark}
      {:clause, units} -> {:words, Sentence.groups(units)}
    end)
  end

  def analyse(%__MODULE__{} = d, text) when is_binary(text) do
    stream = Normalize.tokens(d.normalizer, text)

    written =
      stream
      |> Enum.map(fn
        %Normalize.Punct{mark: mark} -> mark
        %Normalize.Word{raw: raw, text: t} -> non_empty(raw) || non_empty(t) || "x"
      end)
      |> List.to_tuple()

    {out_rev, words_rev, places_rev} =
      stream
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn
        {%Normalize.Punct{mark: mark}, _place}, {out, words, places} ->
          out = flush_clause(d, words, places, written, out)
          {[{:punct, mark} | out], [], []}

        {%Normalize.Word{} = tok, place}, {out, words, places} ->
          {out, [tok | words], [place | places]}
      end)

    flush_clause(d, words_rev, places_rev, written, out_rev) |> Enum.reverse()
  end

  defp flush_clause(_d, [], _places, _written, out), do: out

  defp flush_clause(d, words_rev, places_rev, written, out) do
    words = Enum.reverse(words_rev)
    places = Enum.reverse(places_rev)

    units =
      d
      |> build_units(List.to_tuple(words), List.to_tuple(places), written, 0, [])
      |> Sentence.stress_clause()
      |> Sentence.join_clause()

    [{:clause, units} | out]
  end

  defp build_units(_d, words, _places, _written, idx, acc) when idx >= tuple_size(words),
    do: Enum.reverse(acc)

  defp build_units(d, words, places, written, idx, acc) do
    tok = elem(words, idx)

    cond do
      tok.phones != nil ->
        unit = %Sentence.Unit{
          word: tok.text,
          phones: tok.phones,
          kind: "p",
          attach: tok.attach,
          source: "inline"
        }

        build_units(d, words, places, written, idx + 1, [unit | acc])

      tok.spell ->
        unit = %Sentence.Unit{
          word: tok.text,
          phones: spell(d, tok.text),
          kind: "p",
          attach: tok.attach,
          source: "letters"
        }

        build_units(d, words, places, written, idx + 1, [unit | acc])

      true ->
        build_units_lexical(d, words, places, written, idx, tok, acc)
    end
  end

  defp build_units_lexical(d, words, places, written, idx, tok, acc) do
    name_size = if MapSet.member?(d.name_starts, tok.text), do: match_name(d, words, idx), else: 0

    if name_size > 0 do
      key = for j <- idx..(idx + name_size - 1), do: elem(words, j).text

      new_units =
        key
        |> Enum.zip(Map.fetch!(d.names, key))
        |> Enum.with_index()
        |> Enum.map(fn {{text, entry}, pos} ->
          %Sentence.Unit{
            word: text,
            phones: resolve_entry(d, text, entry),
            kind: "p",
            attach: tok.attach and pos == 0,
            source: "name"
          }
        end)

      build_units(d, words, places, written, idx + name_size, Enum.reverse(new_units) ++ acc)
    else
      phrase_size = match_phrase(d, words, idx)

      if phrase_size > 0 do
        key = for j <- idx..(idx + phrase_size - 1), do: elem(words, j).text
        {kind, forms, final} = Map.fetch!(d.phrases, key)

        new_units =
          case forms do
            [single] ->
              [
                %Sentence.Unit{
                  word: Enum.join(key, " "),
                  phones: single,
                  kind: kind,
                  final: final,
                  attach: tok.attach,
                  source: "phrase"
                }
              ]

            many ->
              key
              |> Enum.zip(many)
              |> Enum.with_index()
              |> Enum.map(fn {{text, form}, pos} ->
                %Sentence.Unit{
                  word: text,
                  phones: form,
                  kind: kind,
                  attach: tok.attach and pos == 0,
                  source: "phrase"
                }
              end)
          end

        build_units(d, words, places, written, idx + phrase_size, Enum.reverse(new_units) ++ acc)
      else
        unit = resolve_single_unit(d, tok, elem(places, idx), written)
        build_units(d, words, places, written, idx + 1, [unit | acc])
      end
    end
  end

  defp resolve_single_unit(d, tok, place, written) do
    cond do
      Map.has_key?(d.overrides, tok.text) ->
        %Sentence.Unit{
          word: tok.text,
          phones: known(d, tok.text),
          kind: "c",
          attach: tok.attach,
          source: "override"
        }

      d.homographs != nil and tuple_size(written) > 0 and
        Homographs.covers?(d.homographs, tok.text) and not Map.has_key?(d.exceptions, tok.text) ->
        {phones_str, ending?} =
          Homographs.pronounce(d.homographs, tok.text, written, place, tok.attach)

        phones = Convert.from_text(phones_str)
        phones = if ending?, do: Morphology.plural(phones), else: phones

        %Sentence.Unit{
          word: tok.text,
          phones: phones,
          kind: "c",
          attach: tok.attach,
          source: "homograph"
        }

      Map.has_key?(d.functions, tok.text) ->
        {kind, form, final} = d.functions[tok.text]

        %Sentence.Unit{
          word: tok.text,
          phones: form,
          kind: kind,
          final: final,
          attach: tok.attach,
          source: "function"
        }

      true ->
        {phones, source} = word(d, tok.text)

        %Sentence.Unit{
          word: tok.text,
          phones: phones,
          kind: "c",
          attach: tok.attach,
          source: source
        }
    end
  end

  defp match_name(d, words, idx) do
    max_size = min(d.name_length, tuple_size(words) - idx)

    if max_size < 2 do
      0
    else
      Enum.find_value(max_size..2//-1, 0, fn size ->
        span = for j <- idx..(idx + size - 1), do: elem(words, j)
        key = Enum.map(span, & &1.text)

        if Map.has_key?(d.names, key) and
             Enum.all?(span, &(&1.phones == nil and not &1.spell)) and
             not Enum.any?(tl(span), & &1.attach) and
             (MapSet.member?(d.user_names, key) or
                not Enum.any?(span, &Map.has_key?(d.overrides, &1.text))) do
          size
        end
      end)
    end
  end

  defp match_phrase(d, words, idx) do
    max_size = min(d.phrase_length, tuple_size(words) - idx)

    if max_size < 2 do
      0
    else
      Enum.find_value(max_size..2//-1, 0, fn size ->
        span = for j <- idx..(idx + size - 1), do: elem(words, j)
        key = Enum.map(span, & &1.text)

        if Map.has_key?(d.phrases, key) and
             hd(span).phones == nil and not hd(span).spell and
             Enum.all?(tl(span), &(&1.phones == nil and not &1.spell and not &1.attach)) and
             not Enum.any?(span, &Map.has_key?(d.overrides, &1.text)) do
          size
        end
      end)
    end
  end

  # -- Single-word lookup & fallback chain

  def word?(%__MODULE__{} = d, w) do
    Map.has_key?(d.lexicon, w) or Map.has_key?(d.functions, w) or
      Map.has_key?(d.exceptions, w) or Map.has_key?(d.overrides, w)
  end

  def known(%__MODULE__{} = d, w) do
    cond do
      Map.has_key?(d.overrides, w) -> resolve_entry(d, w, d.overrides[w])
      Map.has_key?(d.exceptions, w) -> resolve_entry(d, w, d.exceptions[w])
      Map.has_key?(d.lexicon, w) -> Convert.from_text(d.lexicon[w])
      true -> nil
    end
  end

  defp ordinary(d, w) do
    if String.length(w) >= 3 and Enum.any?(~w(s es ed ing), &Map.has_key?(d.lexicon, w <> &1)) do
      known(d, w)
    end
  end

  defp resolve_entry(_d, _w, {:phones, phones}), do: phones

  defp resolve_entry(d, w, {:arpabet, syms}) do
    Convert.convert(w, syms, Align.align(d.aligner, w, syms))
  end

  def word(%__MODULE__{} = d, w) do
    case known(d, w) do
      nil ->
        case Morphology.derive(w, &known(d, &1), &ordinary(d, &1)) do
          nil -> word_fallback(d, w)
          phones -> {Convert.settle_stress(phones), "ending"}
        end

      phones ->
        {phones, "dictionary"}
    end
  end

  defp word_fallback(d, w) do
    case from_parts(d, w) do
      nil ->
        if String.ends_with?(w, "'s") and String.length(w) > 3 do
          stem = String.slice(w, 0, String.length(w) - 2)
          {Morphology.plural(guess(d, stem)), "model"}
        else
          {guess(d, w), "model"}
        end

      found ->
        found
    end
  end

  defp from_parts(d, w) do
    cond do
      String.ends_with?(w, "'s") and String.length(w) > 3 ->
        case from_parts(d, String.slice(w, 0, String.length(w) - 2)) do
          {phones, src} -> {Morphology.plural(phones), src}
          nil -> nil
        end

      Regex.match?(@leigh_re, w) ->
        word(d, Regex.replace(@leigh_re, w, "ley"))

      true ->
        Enum.find_value(@virus_tails, fn tail ->
          t_len = String.length(tail)

          if String.ends_with?(w, tail) and String.length(w) - t_len > 2 do
            case known(d, tail) do
              nil ->
                nil

              second ->
                {first, src} = word(d, String.slice(w, 0, String.length(w) - t_len))

                phones =
                  first
                  |> Morphology.compound(second)
                  |> Convert.settle_stress()
                  |> Sentence.promote()

                {phones, if(src == "model", do: "model", else: "ending")}
            end
          end
        end)
    end
  end

  def guess(%__MODULE__{g2p: nil} = d, w), do: spell(d, w)

  def guess(%__MODULE__{g2p: g2p} = d, w) do
    spelling = G2P.spellable(g2p, w)
    symbols = G2P.predict(g2p, spelling) |> fix_syllabic_r()

    if Enum.any?(symbols, &stressed_arpa?/1) do
      spelling
      |> Convert.convert(symbols, Align.align(d.aligner, spelling, symbols))
      |> Sentence.promote()
    else
      spell(d, w)
    end
  end

  defp fix_syllabic_r(symbols) do
    arr = List.to_tuple(symbols)
    n = tuple_size(arr)

    for k <- 0..(n - 1)//1 do
      sym = elem(arr, k)

      if sym == "R" and
           not ((k > 0 and stressed_arpa?(elem(arr, k - 1))) or
                  (k + 1 < n and stressed_arpa?(elem(arr, k + 1)))) do
        "ER0"
      else
        sym
      end
    end
  end

  defp stressed_arpa?(sym) do
    byte_size(sym) > 0 and :binary.at(sym, byte_size(sym) - 1) in [?0, ?1, ?2]
  end

  def spell(%__MODULE__{letter_names: letter_names}, letters) do
    lower = String.downcase(letters)
    possessive = String.ends_with?(lower, "'s")
    body = if possessive, do: String.slice(lower, 0, String.length(lower) - 2), else: lower

    names =
      body
      |> String.graphemes()
      |> Enum.flat_map(fn ch ->
        case Map.get(letter_names, ch) do
          nil -> []
          ph -> [ph]
        end
      end)

    last_idx = length(names) - 1

    out =
      names
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, idx} ->
        Enum.map(name, fn {p, st} ->
          {p, if(st > 0 and idx < last_idx, do: 2, else: st)}
        end)
      end)

    if possessive and out != [], do: Morphology.plural(out), else: out
  end

  defp load_lexicon!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [word, phones] = String.split(line, "\t", parts: 2)
      {word, phones}
    end)
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s
end
