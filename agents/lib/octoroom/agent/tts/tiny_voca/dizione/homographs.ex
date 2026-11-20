defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Homographs do
  @moduledoc false

  # Disambiguates English homographs ("read", "live", "record", "lead", ...)
  # using hand-written rules (`homograph_rules.txt`) and the trained linear
  # classifier (`phonemizer/homographs.json`).

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.Tables

  @classes [
    {"TO", ~w(to)},
    {"DET",
     ~w(the a an this that these those every each no some any another such what which whose)},
    {"POSS", ~w(my your his her its our their)},
    {"SUBJ", ~w(i you he she it we they who)},
    {"OBJ", ~w(me him us them)},
    {"MODAL",
     ~w(will would shall should can could may might must 'll 'd won't can't cannot couldn't shouldn't wouldn't let's please)},
    {"DO", ~w(do does did don't doesn't didn't)},
    {"BE",
     ~w(am is are was were be been being isn't aren't wasn't weren't i'm you're we're they're he's she's it's that's there's)},
    {"HAVE", ~w(have has had having haven't hasn't hadn't i've you've we've they've)},
    {"NEG", ~w(not never)},
    {"PREP",
     ~w(of in on at by for from with into onto over under about after before between through during without within against among around across behind beside near upon toward towards as than like)},
    {"CONJ",
     ~w(and or but nor so yet if because although though while when where unless until since whether)},
    {"ADV",
     ~w(very too quite rather more most less least also just only even still always often sometimes usually again now then here there soon already almost)}
  ]

  @tag_map for {cls, words} <- @classes, w <- words, into: %{}, do: {w, cls}
  @sentence_end MapSet.new([".", "?", "!"])
  @window 6
  @skip_for_before MapSet.new(["ADV", "NEG", "LY"])
  @skip_for_aux MapSet.union(@skip_for_before, MapSet.new(["SUBJ", "OBJ", "DET", "POSS"]))

  defstruct [:words, :pooled, :plural_bases, :rules]

  def load(json_path) do
    data = json_path |> File.read!() |> Jason.decode!()

    %__MODULE__{
      words: data["words"],
      pooled: data["pooled"],
      plural_bases: MapSet.new(Map.get(data, "plural_bases", [])),
      rules: read_rules()
    }
  end

  def covers?(%__MODULE__{words: words, plural_bases: plural_bases}, word) do
    Map.has_key?(words, word) or
      (String.ends_with?(word, "s") and
         MapSet.member?(plural_bases, String.slice(word, 0, String.length(word) - 1)))
  end

  def pronounce(%__MODULE__{words: words} = h, word, tokens, index, joined \\ false) do
    case Map.get(words, word) do
      nil ->
        base = String.slice(word, 0, String.length(word) - 1)
        entry = Map.fetch!(words, base)
        adj = Enum.find(entry["senses"], &(&1["role"] == "n"))

        if adj && adj["id"] == "adj" do
          verb = Enum.find(entry["senses"], &(&1["role"] == "v"))
          {verb["phones"], true}
        else
          {choose(h, base, tokens, index, joined)["phones"], true}
        end

      _entry ->
        {choose(h, word, tokens, index, joined)["phones"], false}
    end
  end

  def choose(%__MODULE__{words: words, rules: rules} = h, word, tokens, index, joined \\ false) do
    entry = Map.fetch!(words, word)
    {sentence, pos} = sentence_of(tokens, index)

    rule_match =
      rules
      |> Map.get(word, [])
      |> Enum.find_value(fn {sense_id, conditions} ->
        if Enum.all?(conditions, fn {name, cond_words} ->
             holds?(name, cond_words, sentence, pos, joined)
           end) do
          Enum.find(entry["senses"], &(&1["id"] == sense_id))
        end
      end)

    rule_match || best_sense(h, entry, sentence, pos)
  end

  defp best_sense(h, entry, sentence, pos) do
    scores = scores(h, entry, sentence, pos)

    entry["senses"]
    |> Enum.zip(scores)
    |> Enum.reduce(fn {sense, score}, {best_s, best_sc} ->
      if score > best_sc, do: {sense, score}, else: {best_s, best_sc}
    end)
    |> elem(0)
  end

  defp scores(%__MODULE__{pooled: pooled}, entry, sentence, pos) do
    names = features(sentence, pos)
    model = entry["model"]

    if model["kind"] == "noun-verb" do
      shared_names = Enum.filter(names, &(String.starts_with?(&1, "t") or &1 in ["first", "cap"]))
      pooled_weights = pooled["weights"]
      model_weights = model["weights"]

      verb =
        pooled["bias"] +
          Enum.reduce(shared_names, 0.0, fn n, acc -> acc + Map.get(pooled_weights, n, 0.0) end) +
          model["bias"] +
          Enum.reduce(names, 0.0, fn n, acc -> acc + Map.get(model_weights, n, 0.0) end)

      Enum.map(entry["senses"], fn sense -> if sense["role"] == "v", do: verb, else: -verb end)
    else
      Enum.zip_with(model["bias"], model["weights"], fn bias, weights ->
        bias + Enum.reduce(names, 0.0, fn n, acc -> acc + Map.get(weights, n, 0.0) end)
      end)
    end
  end

  def tag("<s>"), do: "<s>"
  def tag("</s>"), do: "</s>"

  def tag(token) when is_binary(token) do
    first = String.first(token)

    if first == nil or not alpha?(first) do
      if first != nil and digit?(first), do: "NUM", else: "PUNCT"
    else
      tag_alpha(token, first)
    end
  end

  defp tag_alpha(token, first) do
    lower = String.downcase(token)
    Map.get(@tag_map, lower) || tag_suffix(lower, first)
  end

  defp tag_suffix(lower, first) do
    len = String.length(lower)

    cond do
      String.ends_with?(lower, "'s") and len > 3 -> "POS"
      String.ends_with?(lower, "ly") and len > 3 -> "LY"
      String.ends_with?(lower, "ing") and len > 4 -> "ING"
      String.ends_with?(lower, "ed") and len > 3 -> "ED"
      plural_s?(lower, len) -> "S"
      upper?(first) -> "CAP"
      true -> "W"
    end
  end

  defp plural_s?(lower, len),
    do: String.ends_with?(lower, "s") and not String.ends_with?(lower, "ss") and len > 3

  defp features(sentence, index) do
    n = tuple_size(sentence)

    at = fn off ->
      pos = index + off

      cond do
        pos >= 0 and pos < n -> elem(sentence, pos)
        off < 0 -> "<s>"
        true -> "</s>"
      end
    end

    p2 = at.(-2)
    p1 = at.(-1)
    n1 = at.(1)
    n2 = at.(2)
    tp2 = tag(p2)
    tp1 = tag(p1)
    tn1 = tag(n1)
    tn2 = tag(n2)

    base = [
      "tp1=" <> tp1,
      "tp2=" <> tp2,
      "tn1=" <> tn1,
      "tn2=" <> tn2,
      "tp2p1=" <> tp2 <> "+" <> tp1,
      "tp1n1=" <> tp1 <> "+" <> tn1,
      "tn1n2=" <> tn1 <> "+" <> tn2
    ]

    cur = elem(sentence, index)

    pos_feat =
      cond do
        index == 0 -> ["first"]
        upper?(String.first(cur)) -> ["cap"]
        true -> []
      end

    neighbor_words = [
      "p1=" <> String.downcase(p1),
      "p2=" <> String.downcase(p2),
      "n1=" <> String.downcase(n1),
      "n2=" <> String.downcase(n2)
    ]

    target = String.downcase(cur)
    lo = max(0, index - @window)
    hi = min(n - 1, index + @window)

    nearby =
      lo..hi
      |> Enum.map(&elem(sentence, &1))
      |> Enum.filter(&alpha?(String.first(&1)))
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 == target))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&("w=" <> &1))

    base ++ pos_feat ++ neighbor_words ++ nearby
  end

  defp sentence_of(tokens, index) do
    arr = if is_tuple(tokens), do: tokens, else: List.to_tuple(tokens)
    n = tuple_size(arr)
    start = find_sentence_start(arr, index)
    finish = find_sentence_end(arr, index, n)
    slice = for i <- start..min(finish, n - 1), do: elem(arr, i)
    {List.to_tuple(slice), index - start}
  end

  defp find_sentence_start(arr, idx) when idx > 0 do
    if MapSet.member?(@sentence_end, elem(arr, idx - 1)),
      do: idx,
      else: find_sentence_start(arr, idx - 1)
  end

  defp find_sentence_start(_arr, idx), do: idx

  defp find_sentence_end(arr, idx, n) when idx < n do
    if MapSet.member?(@sentence_end, elem(arr, idx)),
      do: idx,
      else: find_sentence_end(arr, idx + 1, n)
  end

  defp find_sentence_end(_arr, idx, _n), do: idx

  defp left_token(sentence, index, skip) do
    stop = max(index - 6, -1)
    scan_left(sentence, index - 1, stop, skip)
  end

  defp scan_left(_sentence, pos, stop, _skip) when pos <= stop, do: "<s>"

  defp scan_left(sentence, pos, stop, skip) do
    tok = elem(sentence, pos)

    if MapSet.member?(skip, tag(tok)) do
      scan_left(sentence, pos - 1, stop, skip)
    else
      lower = String.downcase(tok)

      cond do
        String.ends_with?(lower, "'ll") -> "will"
        String.ends_with?(lower, "'ve") -> "have"
        true -> lower
      end
    end
  end

  defp holds?("first", _words, _sentence, index, _joined), do: index == 0

  defp holds?("joined", words, sentence, index, joined),
    do: joined and index > 0 and MapSet.member?(words, String.downcase(elem(sentence, index - 1)))

  defp holds?("aux", words, sentence, index, _joined),
    do: MapSet.member?(words, left_token(sentence, index, @skip_for_aux))

  defp holds?("before", words, sentence, index, _joined),
    do: MapSet.member?(words, left_token(sentence, index, @skip_for_before))

  defp holds?("next", words, sentence, index, _joined) do
    nxt =
      if index + 1 < tuple_size(sentence),
        do: String.downcase(elem(sentence, index + 1)),
        else: "</s>"

    MapSet.member?(words, nxt)
  end

  defp holds?("near", words, sentence, index, _joined) do
    n = tuple_size(sentence)
    lo = max(0, index - @window)
    hi = min(n - 1, index + @window)
    Enum.any?(lo..hi, fn i -> MapSet.member?(words, String.downcase(elem(sentence, i))) end)
  end

  defp read_rules do
    Enum.reduce(Tables.rows("homograph_rules.txt"), %{}, fn {_num, [word, sense, conds_str]},
                                                            acc ->
      conditions =
        conds_str
        |> String.split(";")
        |> Enum.map(fn part ->
          case String.split(String.trim(part), ":", parts: 2) do
            [name, rest] -> {String.trim(name), rest |> String.split() |> MapSet.new()}
            [name] -> {String.trim(name), MapSet.new()}
          end
        end)

      Map.update(acc, word, [{sense, conditions}], &(&1 ++ [{sense, conditions}]))
    end)
  end

  defp alpha?(nil), do: false
  defp alpha?(ch), do: Regex.match?(~r/^\p{L}$/u, ch)

  defp digit?(nil), do: false
  defp digit?(ch), do: Regex.match?(~r/^\d$/, ch)

  defp upper?(nil), do: false
  defp upper?(ch), do: Regex.match?(~r/^\p{Lu}$/u, ch)
end
