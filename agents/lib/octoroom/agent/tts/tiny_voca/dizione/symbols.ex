defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Symbols do
  @moduledoc false

  # 59 American English phones, 12 punctuation marks, and 5 special tokens.
  # The order matches `n4ze3m/tiny-voca`'s `config.json` vocabulary (IDs 0..75).

  @pad "<pad>"
  @bos "<bos>"
  @eos "<eos>"
  @sp "<sp>"
  @unk "<unk>"

  @specials [@pad, @bos, @eos, @sp, @unk]
  @punctuation [",", ".", "?", "!", ";", ":", "\"", "'", "(", ")", "—", "…"]
  @consonants [
    "p",
    "b",
    "t",
    "d",
    "k",
    "ɡ",
    "f",
    "v",
    "θ",
    "ð",
    "s",
    "z",
    "ʃ",
    "ʒ",
    "h",
    "m",
    "n",
    "ŋ",
    "l",
    "ɹ",
    "j",
    "w",
    "tʃ",
    "dʒ",
    "ɾ",
    "ʔ"
  ]
  @vowels [
    "ə",
    "ɐ",
    "ɚ",
    "ᵻ",
    "ɪ",
    "i",
    "iː",
    "ɛ",
    "æ",
    "ʌ",
    "ɑː",
    "ɔ",
    "ɔː",
    "ʊ",
    "uː",
    "ɜː",
    "eɪ",
    "aɪ",
    "ɔɪ",
    "oʊ",
    "aʊ",
    "iə",
    "oː",
    "ɑːɹ",
    "ɔːɹ",
    "oːɹ",
    "ɪɹ",
    "ɛɹ",
    "ʊɹ",
    "aɪɚ",
    "aɪə",
    "əl",
    "n̩"
  ]
  @phones @consonants ++ @vowels
  @symbols @specials ++ @punctuation ++ @phones

  @symbol_to_id @symbols |> Enum.with_index() |> Map.new()
  @phone_set MapSet.new(@phones)
  @vowel_set MapSet.new(@vowels)
  @punctuation_set MapSet.new(@punctuation)

  def bos, do: @bos
  def eos, do: @eos
  def sp, do: @sp
  def unk, do: @unk
  def symbols, do: @symbols
  def symbol_to_id, do: @symbol_to_id
  def phone?(s), do: MapSet.member?(@phone_set, s)
  def vowel?(s), do: MapSet.member?(@vowel_set, s)
  def punctuation?(s), do: MapSet.member?(@punctuation_set, s)

  @doc """
  Builds `{:ok, %{symbols: list, ids: list, stress: list, unknown: list}}`
  from `[{:punct, mark} | {:words, [[{phone, stress}, ...], ...]}]` pieces,
  or `{:error, :nothing_to_pronounce}` when no phone is emitted.
  """
  def tokenize(pieces) do
    {rev_syms, rev_stress, rev_unk} =
      Enum.reduce(pieces, {[@bos], [0], []}, fn
        {:punct, mark}, {[last | _] = syms, stress, unk} ->
          if last == mark, do: {syms, stress, unk}, else: {[mark | syms], [0 | stress], unk}

        {:words, words}, acc ->
          Enum.reduce(words, acc, &append_word/2)
      end)

    symbols = Enum.reverse([@eos | rev_syms])
    stress = Enum.reverse([0 | rev_stress])
    unknown = Enum.reverse(rev_unk)

    if Enum.any?(symbols, &(phone?(&1) or &1 == @unk)) do
      ids = Enum.map(symbols, &Map.fetch!(@symbol_to_id, &1))
      {:ok, %{symbols: symbols, ids: ids, stress: stress, unknown: unknown}}
    else
      {:error, :nothing_to_pronounce}
    end
  end

  defp append_word(word, {[last | _] = syms, stress, unk}) do
    {syms, stress} =
      if phone?(last) or last == @unk,
        do: {[@sp | syms], [0 | stress]},
        else: {syms, stress}

    Enum.reduce(word, {syms, stress, unk}, fn {phone, level}, {s, st, u} ->
      if phone?(phone) do
        {[phone | s], [level | st], u}
      else
        {[@unk | s], [0 | st], [phone | u]}
      end
    end)
  end
end
