defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Numbers do
  @moduledoc false

  # Pure text-to-words helpers for numbers, ordinals, years, durations,
  # fractions, version parts, and accented Latin letters.

  @ones {
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen"
  }
  @tens {"twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"}
  @scales {"thousand", "million", "billion", "trillion", "quadrillion", "quintillion"}
  @ordinal_irregular %{
    "one" => "first",
    "two" => "second",
    "three" => "third",
    "five" => "fifth",
    "eight" => "eighth",
    "nine" => "ninth",
    "twelve" => "twelfth"
  }
  @fraction_irregular %{
    2 => {"half", "halves"},
    4 => {"quarter", "quarters"}
  }
  @letter_forms %{
    "ß" => "ss",
    "æ" => "ae",
    "Æ" => "Ae",
    "œ" => "oe",
    "Œ" => "Oe",
    "ø" => "o",
    "Ø" => "O",
    "đ" => "d",
    "ł" => "l",
    "Ł" => "L"
  }

  def one(n), do: elem(@ones, n)

  def cardinal(n) when n < 0, do: "minus " <> cardinal(-n)
  def cardinal(n) when n < 20, do: elem(@ones, n)

  def cardinal(n) when n < 100 do
    t = div(n, 10)
    o = rem(n, 10)
    elem(@tens, t - 2) <> if(o > 0, do: " " <> elem(@ones, o), else: "")
  end

  def cardinal(n) when n < 1000 do
    h = div(n, 100)
    r = rem(n, 100)
    elem(@ones, h) <> " hundred" <> if(r > 0, do: " " <> cardinal(r), else: "")
  end

  def cardinal(n) do
    max_val = Integer.pow(1000, tuple_size(@scales) + 1)

    if n >= max_val do
      digits(Integer.to_string(n))
    else
      {parts, rem_n} =
        Enum.reduce(tuple_size(@scales)..1//-1, {[], n}, fn power, {acc, curr} ->
          unit = Integer.pow(1000, power)
          count = div(curr, unit)
          rest = rem(curr, unit)

          if count > 0,
            do: {[cardinal(count) <> " " <> elem(@scales, power - 1) | acc], rest},
            else: {acc, rest}
        end)

      parts = if rem_n > 0, do: [cardinal(rem_n) | parts], else: parts
      parts |> Enum.reverse() |> Enum.join(" ")
    end
  end

  def ordinal(n) do
    words = String.split(cardinal(n))
    {last, init} = List.pop_at(Enum.reverse(words), 0)

    ord_last =
      case Map.get(@ordinal_irregular, last) do
        nil ->
          if String.ends_with?(last, "y"),
            do: String.slice(last, 0, String.length(last) - 1) <> "ieth",
            else: last <> "th"

        irreg ->
          irreg
      end

    Enum.reverse([ord_last | init]) |> Enum.join(" ")
  end

  def digits(text, zero \\ "zero") when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.filter(&(&1 in ?0..?9))
    |> Enum.map_join(" ", fn
      ?0 -> zero
      c -> elem(@ones, c - ?0)
    end)
  end

  def year(n) when n < 1000 or n > 2999, do: cardinal(n)

  def year(n) do
    high = div(n, 100)
    low = rem(n, 100)

    cond do
      low == 0 ->
        if rem(high, 10) == 0, do: cardinal(n), else: cardinal(high) <> " hundred"

      high == 20 and low < 10 ->
        "two thousand " <> elem(@ones, low)

      low < 10 ->
        cardinal(high) <> " oh " <> elem(@ones, low)

      true ->
        cardinal(high) <> " " <> cardinal(low)
    end
  end

  def pairs(n) do
    high = div(n, 100)
    low = rem(n, 100)

    cond do
      n < 100 or n > 9999 or (low == 0 and (high < 10 or rem(high, 10) == 0)) ->
        cardinal(n)

      low == 0 ->
        cardinal(high) <> " hundred"

      low < 10 ->
        cardinal(high) <> " oh " <> elem(@ones, low)

      true ->
        cardinal(high) <> " " <> cardinal(low)
    end
  end

  def number_words(text) when is_binary(text) do
    cleaned = String.replace(text, ",", "")

    case String.split(cleaned, ".", parts: 2) do
      [whole, frac] when frac != "" ->
        prefix = if whole != "", do: cardinal(String.to_integer(whole)), else: ""
        prefix <> " point " <> digits(frac)

      [whole | _] ->
        if (String.length(whole) > 1 and String.starts_with?(whole, "0")) or
             String.length(whole) > 18 do
          digits(whole)
        else
          cardinal(String.to_integer(whole))
        end
    end
  end

  def duration(hours, minutes, seconds) do
    parts =
      [{hours, "hour"}, {minutes, "minute"}, {seconds, "second"}]
      |> Enum.filter(fn {c, _} -> c > 0 end)
      |> Enum.map(fn {c, name} ->
        cardinal(c) <> " " <> if(c == 1, do: name, else: name <> "s")
      end)

    case parts do
      [] -> "zero seconds"
      [only] -> only
      many -> Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)
    end
  end

  def plural_of(words) do
    parts = String.split(words, " ")
    {last, rev_init} = List.pop_at(Enum.reverse(parts), 0)

    plural_last =
      if String.ends_with?(last, "y"),
        do: String.slice(last, 0, String.length(last) - 1) <> "ies",
        else: last <> "s"

    case rev_init do
      [] -> plural_last
      _ -> (rev_init |> Enum.reverse() |> Enum.join(" ")) <> " " <> plural_last
    end
  end

  def fraction_words(top, bottom, article \\ false) do
    {one, many} = Map.get(@fraction_irregular, bottom, {ordinal(bottom), ordinal(bottom) <> "s"})

    if top != 1 do
      "#{cardinal(top)} #{many}"
    else
      prefix =
        if article do
          if String.first(one) in ["a", "e", "i", "o", "u"], do: "an ", else: "a "
        else
          "one "
        end

      prefix <> one
    end
  end

  def version_part(part) do
    if String.length(part) > 2, do: digits(part), else: number_words(part)
  end

  def minor(part) do
    if String.starts_with?(part, "0"),
      do: digits(part, "oh"),
      else: cardinal(String.to_integer(part))
  end

  def short_number?(text) do
    if String.starts_with?(text, "0") do
      false
    else
      String.length(text) <= 2 or
        text |> String.slice(1..-1//1) |> String.graphemes() |> Enum.all?(&(&1 == "0"))
    end
  end

  def decimal_comma(text) do
    if Regex.match?(~r/^\d+,\d{1,2}$/, text), do: String.replace(text, ",", "."), else: text
  end

  def address_digits(text) do
    len = String.length(text)

    cond do
      len <= 2 and not (len == 2 and String.starts_with?(text, "0")) ->
        cardinal(String.to_integer(text))

      len == 4 ->
        n = String.to_integer(text)
        if n in 1900..2099, do: year(n), else: digits(text)

      true ->
        digits(text)
    end
  end

  def plain_letter(char) do
    cond do
      ascii?(char) or not alpha?(char) ->
        char

      Map.has_key?(@letter_forms, char) ->
        @letter_forms[char]

      true ->
        base =
          char
          |> :unicode.characters_to_nfkd_binary()
          |> String.replace(~r/\p{Mn}/u, "")

        if base != "" and ascii_alpha?(base), do: base, else: char
    end
  end

  def ascii?(str), do: Regex.match?(~r/^[\x00-\x7F]*$/, str)
  def alpha?(str), do: Regex.match?(~r/^\p{L}+$/u, str)
  def ascii_alpha?(str), do: Regex.match?(~r/^[A-Za-z]+$/, str)
end
