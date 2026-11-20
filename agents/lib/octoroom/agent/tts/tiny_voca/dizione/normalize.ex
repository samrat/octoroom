defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Normalize do
  @moduledoc false

  # English text normalization front end matching `dizione/normalize.py`:
  # expands numbers, ordinals, currency, dates, times, phone numbers, versions,
  # codes, units, fractions, ranges, addresses, symbols, abbreviations, chat
  # forms, initialisms, and inline `{...}` pronunciations into `Word` and `Punct`
  # tokens.

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.{Convert, Numbers, Symbols, Tables}

  defmodule Word do
    @moduledoc false
    defstruct [:text, attach: false, raw: "", spell: false, phones: nil]
  end

  defmodule Punct do
    @moduledoc false
    defstruct [:mark]
  end

  # Private-use sentinel codepoints carried through rewriting passes.
  @spell <<0xE000::utf8>>
  @spell_end <<0xE001::utf8>>
  @inline <<0xE003::utf8>>
  @inline_base 0xE100
  @formula_sign <<0xE004::utf8>>
  # 1-byte ASCII control mark used ONLY inside `without_angles/1` so byte offsets
  # in `plain` remain identical to `text` (replacing 1-byte `<` and `>`).
  @angle_mark <<1>>
  @is_mark <<0xE006::utf8>>

  @months ~w(January February March April May June July August September October November December)
  @months_tuple List.to_tuple(@months)
  @month_number @months
                |> Enum.with_index(1)
                |> Map.new(fn {name, idx} ->
                  {name |> String.downcase() |> String.slice(0, 3), idx}
                end)
  @month_pattern Enum.join(@months, "|") <> "|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
  @day_names %{
    "mon" => "Monday",
    "tue" => "Tuesday",
    "wed" => "Wednesday",
    "thu" => "Thursday",
    "fri" => "Friday",
    "sat" => "Saturday",
    "sun" => "Sunday"
  }
  @day_pattern "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Thurs|Thur|Tues|Mon|Tue|Wed|Thu|Fri|Sat|Sun"

  @currency %{
    "$" => {"dollar", "dollars", "cent", "cents"},
    "£" => {"pound", "pounds", "penny", "pence"},
    "€" => {"euro", "euros", "cent", "cents"},
    "¥" => {"yen", "yen", "", ""},
    "₹" => {"rupee", "rupees", "paisa", "paise"},
    "USD" => {"dollar", "dollars", "cent", "cents"},
    "EUR" => {"euro", "euros", "cent", "cents"},
    "GBP" => {"pound", "pounds", "penny", "pence"},
    "JPY" => {"yen", "yen", "", ""},
    "INR" => {"rupee", "rupees", "paisa", "paise"},
    "CHF" => {"Swiss franc", "Swiss francs", "centime", "centimes"},
    "CAD" => {"Canadian dollar", "Canadian dollars", "cent", "cents"},
    "AUD" => {"Australian dollar", "Australian dollars", "cent", "cents"},
    "CNY" => {"yuan", "yuan", "", ""}
  }
  @currency_codes "USD|EUR|GBP|JPY|INR|CHF|CAD|AUD|CNY"
  @scale_letter %{
    "k" => "thousand",
    "m" => "million",
    "b" => "billion",
    "bn" => "billion",
    "t" => "trillion"
  }

  @symbol_words %{
    "&" => "and",
    "@" => "at",
    "+" => "plus",
    "=" => "equals",
    "%" => "percent",
    "×" => "times",
    "÷" => "divided by",
    "±" => "plus or minus",
    "©" => "copyright",
    "§" => "section",
    "°" => "degrees",
    "≥" => "greater than or equal to",
    "≤" => "less than or equal to",
    "≠" => "not equal to",
    "≈" => "approximately",
    "∞" => "infinity",
    "√" => "square root of",
    "π" => "pi"
  }
  @comparisons %{
    ">=" => "greater than or equal to",
    "<=" => "less than or equal to",
    "!=" => "not equal to"
  }

  @initialisms MapSet.new(~w(US IT AI ID UN EU UK LA AD BC AM PM OS PE PA MA LED SAT RIP ER))
  @sounds MapSet.new(~w(sh shh ss zz hm hmm mm tsk psst pfft hmph psh pssh))
  @clause_openers MapSet.new(
                    ~w(if elif while when whenever where whether that because since as and or but so then think thinks thought know knows say says said suppose assume means implies hence thus therefore although though unless until once else also clearly obviously indeed here now again first next finally similarly otherwise however moreover)
                  )
  @sentence_starters MapSet.new(
                       ~w(the he she it i we they this that there but and in on at a an if when what why how who my our you then so now after before however)
                     )
  @year_context MapSet.new(
                  ~w(in since by from until till before after during around circa of year early late mid summer winter spring fall autumn class)
                )
  @cardinal_after MapSet.new(
                    ~w(war chapter part book volume act scene section phase type class level stage title article appendix world)
                  )
  @labelled MapSet.new(
              ~w(plan vitamin grade type option class section part team group exhibit appendix point model series hepatitis level)
            )
  @roman %{
    "II" => 2,
    "III" => 3,
    "IV" => 4,
    "VI" => 6,
    "VII" => 7,
    "VIII" => 8,
    "IX" => 9,
    "XI" => 11,
    "XII" => 12,
    "XIII" => 13,
    "XIV" => 14,
    "XV" => 15,
    "XVI" => 16,
    "XVIII" => 18,
    "XX" => 20
  }
  @leading_apostrophe MapSet.new([
                        "'em",
                        "'tis",
                        "'twas",
                        "'til",
                        "'cause",
                        "'bout",
                        "'round",
                        "'n"
                      ])
  @phone_words MapSet.new(
                 ~w(call dial ring phone telephone tel mobile cell fax hotline text sms whatsapp)
               )
  @phone_links MapSet.new(~w(to on at or us me him her them back))
  @pin_words MapSet.new(~w(code pin extension ext passcode password zip postcode cvv cvc otp))
  @strong_words MapSet.new(
                  ~w(number id reference ref serial account tracking booking confirmation)
                )
  @weak_words MapSet.new(
                ~w(order ticket invoice case claim policy receipt transaction parcel shipment container payment reservation membership customer batch lot item job issue bug request)
              )
  @link_words MapSet.new(~w(is was are were ends ending in with starts starting begins beginning))
  @not_counted MapSet.new(
                 ~w(is was has does goes ships arrives departs leaves shows needs blocks remains includes contains says reads starts ends closes opens runs takes comes this his its us as yes plus minus less)
               )
  @numbered MapSet.new(
              ~w(ref reference serial account order invoice tracking part model phone tel fax id room flight case ticket policy licence license booking customer vat tax reg registration)
            )
  @date_before MapSet.new(
                 ~w(on dated due until till by since from before after for shipped delivered arriving arrives arrive arrived expires expired ends ending starts starting begins beginning monday tuesday wednesday thursday friday saturday sunday mon tue tues wed thu thur thurs fri sat sun)
               )
  @classic_fractions MapSet.new([2, 3, 4, 5, 6, 8, 10, 16, 32, 64, 100])
  @ratio_words MapSet.new(~w(ratio ratios scale odds aspect mix split proportion))
  @duration_words MapSet.new(
                    ~w(lasted took duration runtime recording video clip track lap pace length long)
                  )
  @clock_words MapSet.new(
                 ~w(window slot open opens opening hours shift session served service available booked appointment delivery arrive arrives arriving)
               )
  @capital_words MapSet.new(
                   ~w(IN ON AT TO OF BY OR IS AS IF NO SO WE HE MY ME DO GO UP AN AM PM BE IT US THE AND FOR BUT NOT ALL)
                 )
  @short_words MapSet.new(
                 ~w(my to in on of go up no do me we us it is at by be so or an as if he hi ok)
               )
  @zones "ET|CT|MT|PT|EST|EDT|CST|CDT|MST|MDT|PST|PDT|GMT|UTC|BST|CET|CEST|IST|AEST|AEDT|JST"
  @sizes "XXXL|XXL|XXS|XL|XS|S|M|L"
  @lengths "mm|cm|km|m|ft|in|inch|inches|feet|foot|metres?|meters?|yards?|yd|px|pixels?"
  @versioned "version|ver|release|firmware|patch|kernel|build|python|node|nodejs|ios|ipados|macos|watchos|tvos|android|chrome|firefox|safari|java|php|ruby|rust|swift|kotlin|golang|django|rails|react|angular|vue|docker|kubernetes|ubuntu|debian|fedora|windows|linux|postgres|postgresql|mysql|redis|numpy|pytorch|tensorflow|cuda|xcode|gcc|clang|unity|minecraft|typescript|bluetooth|usb|hdmi|opengl|vulkan|directx|upgrade[ds]?|update[ds]?|downgrade[ds]?"
  @separators %{
    "." => "dot",
    "/" => "slash",
    "@" => "at",
    "-" => "dash",
    "_" => "underscore",
    ":" => "colon",
    "=" => "equals",
    "&" => "and",
    "+" => "plus"
  }
  @accent_decides %{
    "résumé" => "R EH1 Z AH0 M EY2",
    "resumé" => "R EH1 Z AH0 M EY2",
    "exposé" => "EH2 K S P OW0 Z EY1",
    "rosé" => "R OW0 Z EY1",
    "pâté" => "P AA0 T EY1",
    "maté" => "M AA1 T EY2",
    "saké" => "S AA1 K EY2",
    "lamé" => "L AA0 M EY1"
  }

  @quote_replacements [
    {"‘", "'"},
    {"’", "'"},
    {"‚", "'"},
    {"‛", "'"},
    {"`", "'"},
    {"´", "'"},
    {"“", "\""},
    {"”", "\""},
    {"„", "\""},
    {"‟", "\""},
    {"«", "\""},
    {"»", "\""},
    {"–", "—"},
    {"―", "—"},
    {"[", "("},
    {"]", ")"}
  ]

  # Precompiled static regexes
  @half_day ~S"(?:\s?([AaPp])\.[Mm]\.?|\s?([AaPp])[Mm]\b)"
  @amount ~S"(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?"
  @sign_after "[$£€¥₹](?![\\w$£€¥₹])|(?:" <> @currency_codes <> ")(?![A-Za-z])"

  @compared_re Regex.compile!("([ \\t]?)(>=|<=|!=|[<>≥≤≠])\\1", "u")
  @value_before_re Regex.compile!(
                     "(?:(?<![\\w.,])\\d[\\d.,]*%?|(?<![\\w'’.-])[A-Za-z]|[)\\]])$",
                     "u"
                   )
  @value_after_re Regex.compile!(
                    "^(?:[-+]?[$£€¥₹]?\\d[\\d.,]*%?(?!\\w)|\\.\\d|[A-Za-z](?![\\w'’])|[(\\[])",
                    "u"
                  )

  @sign_pat "[<>+*/^≤≥≠≈×÷±]"
  @spaced_sign_pat " [<>+*≤≥≠≈×÷±] "
  @no_phrase "(?![\\w'’-]|\\s+(?!(?:and|or|then|if|when|where|while|for|is|are|was|but|so|in|to)\\b)[A-Za-z])"
  @letter_places [
    Regex.compile!("(?<![\\w'’.-])([Aakur])(?=" <> @is_mark <> "?\\s?[<>!=]?=)", "u"),
    Regex.compile!("[<>!=]?=\\s?([Aakur])" <> @no_phrase, "u"),
    Regex.compile!(
      "(?<![\\w'’.-])([Aakur])(?=" <> @is_mark <> "?" <> @sign_pat <> "(?:[\\w($]|\\.\\d))",
      "u"
    ),
    Regex.compile!(
      "(?<=[\\w)" <> @is_mark <> "]" <> @sign_pat <> ")(?<![Ww]/)([Aakur])(?![\\w'’-])",
      "u"
    ),
    Regex.compile!(
      "(?<![\\w'’.-])([Aakur])(?=" <>
        @is_mark <> "?" <> @spaced_sign_pat <> "(?:[A-Za-z]|\\d[\\d.,]*)(?![\\w'’]))",
      "u"
    ),
    Regex.compile!(
      "(?<![\\w'’.])(?:[A-Za-z]|\\d[\\d.,]*)" <>
        @is_mark <> "?" <> @spaced_sign_pat <> "([Aakur])" <> @no_phrase,
      "u"
    ),
    Regex.compile!("(?<=\\()([Aakur])(?=\\)|, )", "u"),
    Regex.compile!("(?<=, )([Aakur])(?=\\))", "u"),
    Regex.compile!("(?:(?<=\\s)|^)([akur])(?=\\)\\s)", "u")
  ]

  @angles_re Regex.compile!(
               "(?<![\\w)" <>
                 @spell_end <>
                 @is_mark <>
                 "])<[A-Za-z0-9/!?][^<>(){}+*;|\\n]*>" <>
                 "|(?<=[\\w" <>
                 @spell_end <>
                 @is_mark <>
                 "])<[^<>(){}+*;|\\n]{1,80}>(?![\\w$])" <>
                 "|</?[A-Za-z][\\w-]+/?>",
               "u"
             )

  @joined_comparison_re Regex.compile!(
                          "(?<=[\\w)" <>
                            @spell_end <>
                            @is_mark <>
                            "])[<>](?=[\\w(" <>
                            @spell <>
                            "]|\\.\\d| minus \\d)",
                          "u"
                        )
  @figure_before_re ~r/(?<![\w.,])\d[\d.,]*%?$/u
  @figure_after_re ~r/^(?:\d[\d.,]*%?(?!\w)|\.\d| minus \d)/u
  @letter_before_re Regex.compile!("(?:(?<![\\w'’.])[A-Za-z]|[)" <> @spell_end <> "])$", "u")
  @letter_after_re Regex.compile!("^(?:[A-Za-z](?![\\w'’])|[(" <> @spell <> "])", "u")

  @emoji_re ~r/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{1F1E6}-\x{1F1FF}\x{2190}-\x{21FF}\x{2B00}-\x{2BFF}\x{FE0F}\x{200D}\x{20E3}]+/u
  @emoticon_re ~r/(?<![A-Za-z0-9])(?:[:;=]['^-]?[DPpOo3|\/\\*\]\[}{><]+|[)(\]\[][-^']?[:;=]|<3+|<\/3|\^_?\^|-_-|[oO]_[oO]|>_<|T_T|\\o\/|:'[()])(?![A-Za-z0-9])|[:;]['^-]?[)(]+|(?<![A-Za-z0-9)])=['^-]?[)(]+|=['^-]?[)(]+(?![A-Za-z0-9(.$-])|(?<=[A-Za-z]{2})<3+(?![.,]?\d)/u

  @money_re Regex.compile!(
              "(?:(?<![\\w.])(-)\\s?)?([$£€¥₹]|(?<![A-Za-z])(?:" <>
                @currency_codes <>
                ")(?![A-Za-z]))\\s?(-)?" <>
                @amount <>
                "(?:\\s?(thousand|million|billion|trillion|bn|[kKmMbB])(?![A-Za-z]))?",
              "u"
            )
  @money_after_re Regex.compile!(
                    "(?:(?<![\\w.])(-)\\s?)?(?<![\\w.,^])(\\d{1,3}(?:,\\d{3})+|[1-9]\\d{0,2}(?: \\d{3})+|\\d+)(?:\\.(\\d+))?\\s?(" <>
                      @sign_after <> ")",
                    "u"
                  )
  @range_before_sign_re Regex.compile!(
                          "(?<![\\w.,-])(\\d[\\d,]*(?:\\.\\d+)?)-(?=\\d[\\d,]*(?:\\.\\d+)?\\s?(?:" <>
                            @sign_after <> "))",
                          "u"
                        )
  @continental_re ~r/(?<![\w.,])([1-9]\d{0,2}(?:\.\d{3})+),(\d{1,2})(?!\d|[.,]\d)/u
  @comma_after_sign_re Regex.compile!(
                         "((?:[$£€¥₹]|(?<![A-Za-z])(?:" <>
                           @currency_codes <> "))\\s?-?\\d+),(\\d{1,2})(?!\\d|[.,]\\d)",
                         "u"
                       )
  @comma_before_sign_re Regex.compile!(
                          "(?<![\\w.,])(\\d+),(\\d{1,2})(?=\\s?(?:%|" <> @sign_after <> "))",
                          "u"
                        )
  @formula_end_re ~r/(?<![\w$])(?<!\d\s)\$(?:(?=[^\s\d$.,;:!?)])[^$\n]{0,80}|(?=\d)[^$\n]{0,80}[=^_\\{}+*\/<>][^$\n]{0,80}|(?=\s)[^$\n]{0,80}[=^_\\{}+*<>][^$\n]{0,80})\d\s?\$(?![\w$])/u
  @vulgar_re ~r/(?<![\d.,\/])(?:(\d+)\s?)?([½⅓⅔¼¾⅕⅖⅗⅘⅙⅚⅐⅛⅜⅝⅞⅑⅒])/u
  @address_re ~r/(?<url>(?:https?:\/\/|www\.)[^\s<>"']+)|(?<mail>[\w.+-]+@[\w-]+(?:\.[\w-]+)+)|(?<file>(?<![\w@.\/-])(?<folder>\/?(?:[\w~-]+\/)+)?(?<stem>[\w-]+(?:\.[\w-]+)*)\.(?<ending>[A-Za-z][A-Za-z0-9]{0,9})(?![\w-])(?<path>\/[^\s<>"']*)?)/u
  @day_range_re Regex.compile!(
                  "\\b(" <>
                    @day_pattern <>
                    "|" <>
                    @month_pattern <>
                    ")\\b(\\.?)\\s?[-–]\\s?(" <>
                    @day_pattern <> "|" <> @month_pattern <> ")\\b(\\.?)",
                  "u"
                )
  @ratio_re ~r/(?<![\d:.,])(\d{1,3}):(\d{1,3}(?:,\d{3})+|\d+)(?![\d:]|[.,]\d)/u
  @code_re ~r/(?<![\w.,\/-])(#)?([A-Za-z0-9]+(?:-[A-Za-z0-9]+)+)(?![\w-]|[.,]\d)/u
  @slashed_re ~r/(?<![\w.,\/-])(\d+(?:\/\d+){2,})(?![\w\/]|[.,]\d)/u
  @grouped_re ~r/(?<![\w.,:\/#+-])(?<plus>\+)?(?:(?<lead>[A-Z]{2}) )?(?<core>[A-Z0-9]*\d[A-Z0-9]*(?: [A-Z0-9]*\d[A-Z0-9]*)+)(?(lead)(?: (?<trail>[A-Z]{2})(?![\w]))?)(?![\w]|[.,:\/-]\d|\s?[%°])/u
  @glued_re ~r/(?<![\w'.])(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]+(?![\w']|\.\d)/u
  @accented_re Regex.compile!(
                 "\\b(" <> Enum.join(Map.keys(@accent_decides), "|") <> ")(s?)\\b",
                 "iu"
               )

  @clock_pat ~S"\d{1,2}:[0-5]\d(?:\s?[AaPp]\.?[Mm]\.?)?|\b\d{1,2}\s?[AaPp]\.?[Mm]\.?"
  @clock_zone_re Regex.compile!("(" <> @clock_pat <> ")\\s(" <> @zones <> ")\\b", "u")
  @clock_range_re Regex.compile!(
                    "(" <>
                      @clock_pat <> ")\\s?[-—]\\s?(?=\\d{1,2}(?::[0-5]\\d|\\s?[AaPp]\\.?[Mm]\\b))",
                    "u"
                  )
  @time_re Regex.compile!(
             "(?<![\\d:])(\\d{1,2}):([0-5]\\d)(?::([0-5]\\d))?" <> @half_day <> "?(?![\\d:])",
             "u"
           )
  @hour_ampm_re Regex.compile!("(?<![\\d.:,])(\\d{1,2})" <> @half_day <> "(?![A-Za-z])", "u")
  @month_days_re Regex.compile!(
                   "\\b(" <>
                     @month_pattern <>
                     ")\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\s?[-—]\\s?(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?(?![\\d:])",
                   "u"
                 )
  @days_month_re Regex.compile!(
                   "(?<![\\d.,/:-])(\\d{1,2})(?:st|nd|rd|th)?\\s?[-—]\\s?(\\d{1,2})(?:st|nd|rd|th)?\\s+(" <>
                     @month_pattern <> ")\\b(?:,?\\s+(\\d{4}))?",
                   "u"
                 )
  @month_day_re Regex.compile!(
                  "\\b(" <>
                    @month_pattern <>
                    ")\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?(?![\\d:])",
                  "u"
                )
  @day_month_re Regex.compile!(
                  "(?<![\\d.,/:-])(\\d{1,2})(?:st|nd|rd|th)?\\s+(" <>
                    @month_pattern <> ")\\b(\\.(?=\\s+[a-z\\d]))?(?:,?\\s+(\\d{4}))?",
                  "u"
                )
  @versioned_re Regex.compile!(
                  "\\b(" <>
                    @versioned <>
                    ")(\\.?\\s(?:(?:from|to)\\s)?)(\\d+)\\.(\\d{2,3})(?:(\\s(?:to|or|and)\\s)(\\d+)\\.(\\d{2,3}))?(?!\\d|\\.\\d|\\s?%|\\s(?:percent|million|billion)\\b)",
                  "iu"
                )
  @dim_by_re Regex.compile!(
               "(?:(?<=\\d)\\s?[xX×]|×)\\s?(?=\\d[\\d.,]*\\s?(?:" <> @lengths <> ")\\b)",
               "u"
             )
  @size_range_re Regex.compile!("(?<![\\w-])(" <> @sizes <> ")-(" <> @sizes <> ")(?![\\w-])", "u")
  @comp_ops_re Regex.compile!(
                 "(?<=[\\w\\s" <>
                   @spell_end <> @is_mark <> "])(>=|<=|!=)(?=[\\w\\s" <> @spell <> "])",
                 "u"
               )
  @lt_gt_re Regex.compile!(
              "(?<=\\d)" <> @is_mark <> "?\\s?[<>]\\s?(?=\\d)|(?<=\\s)[<>](?=\\s)",
              "u"
            )
  @symbol_re Regex.compile!("[" <> Regex.escape(Enum.join(Map.keys(@symbol_words))) <> "]", "u")
  @token_re Regex.compile!(
              @spell <>
                "([A-Za-z ]+)" <>
                @spell_end <>
                "|" <>
                @inline <>
                "(.)" <>
                @inline <>
                "|('?[A-Za-z]+(?:'[A-Za-z]+)*)|(\\d+)|(-)|(\\S)",
              "u"
            )

  defstruct [
    :is_word,
    :abbreviations,
    :units,
    :exact_units,
    :chat,
    :replies,
    :endings,
    :unit_names,
    :unit_re,
    :area_re,
    :area_plain_re
  ]

  def new(is_word \\ fn _ -> true end) do
    abbreviations =
      Map.new(Tables.rows("abbreviations.txt"), fn {_, [k, when_kind, words]} ->
        {k, {when_kind, words}}
      end)

    {units, exact_units} =
      Enum.reduce(Tables.rows("units.txt"), {%{}, %{}}, fn {_, cols}, {u, ex} ->
        case cols do
          [k, one, many, "exact"] -> {u, Map.put(ex, k, {one, many})}
          [k, one, many | _] -> {Map.put(u, String.downcase(k), {one, many}), ex}
        end
      end)

    {chat, replies} =
      Enum.reduce(Tables.rows("chat.txt"), {%{}, MapSet.new()}, fn {_, cols}, {ch, rep} ->
        case cols do
          [k] -> {Map.put(ch, k, "-"), rep}
          [k, v] -> {Map.put(ch, k, v), rep}
          [k, v, "alone"] -> {Map.put(ch, k, v), MapSet.put(rep, k)}
        end
      end)

    endings = Tables.mapping("endings.txt")

    unit_names =
      (Map.keys(units) ++ Map.keys(exact_units))
      |> Enum.map(&Regex.escape/1)
      |> Enum.uniq()
      |> Enum.sort_by(fn s -> {-String.length(s), s} end)
      |> Enum.join("|")

    unit_re =
      Regex.compile!(
        "(?<![\\w.])(\\d[\\d,]*(?:\\.\\d+)?)(?:[-–](\\d[\\d,]*(?:\\.\\d+)?))?\\s?(" <>
          unit_names <> ")(?![A-Za-z])(\\.(?=\\s+(?-i:[a-z])))?",
        "iu"
      )

    area_re = ~r/(?<![\w.])(\d[\d,]*(?:\.\d+)?)\s?(km|cm|mm|m|ft|mi|yd|in)([²³])/u
    area_plain_re = ~r/(?<![\w.])(\d[\d,]*(?:\.\d+)?)\s?(km|cm|mm|m|ft)([23])(?![\w])/u

    %__MODULE__{
      is_word: is_word,
      abbreviations: abbreviations,
      units: units,
      exact_units: exact_units,
      chat: chat,
      replies: replies,
      endings: endings,
      unit_names: unit_names,
      unit_re: unit_re,
      area_re: area_re,
      area_plain_re: area_plain_re
    }
  end

  def tokens(%__MODULE__{} = norm, text) when is_binary(text) do
    {rewritten, inline_list} = rewrite(norm, text)
    inline_tuple = List.to_tuple(inline_list)

    runs = Regex.scan(~r/[A-Za-z]{2,}/, rewritten) |> List.flatten()
    upper_count = Enum.count(runs, &(&1 == String.upcase(&1)))
    all_caps = length(runs) >= 3 and upper_count >= 0.6 * length(runs)

    state = %{
      out: [],
      attach: false,
      previous: "",
      fresh: true,
      short: [],
      replies: []
    }

    matches = Regex.scan(@token_re, rewritten, return: :index)

    state =
      Enum.reduce(matches, state, fn spans, st ->
        process_token_match(norm, rewritten, spans, inline_tuple, all_caps, st)
      end)

    out = state.out |> Enum.reverse() |> List.to_tuple()
    out = resolve_short_sounds(out, Enum.reverse(state.short))
    resolve_replies(norm, Tuple.to_list(out), state.replies)
  end

  def rewrite(%__MODULE__{} = norm, text) when is_binary(text) do
    text =
      text
      |> sub_with_pos(@vulgar_re, &vulgar/1)
      |> sub_with_pos(norm.area_re, &square(norm, &1))
      |> String.replace("²", " squared ")
      |> String.replace("³", " cubed ")
      |> :unicode.characters_to_nfkc_binary()
      |> String.replace("⁄", "/")
      |> String.replace("−", " minus ")

    text =
      if Numbers.ascii?(text) do
        text
      else
        text
        |> sub_with_pos(@accented_re, fn m ->
          base = Map.fetch!(@accent_decides, String.downcase(group(m, 1)))
          "{" <> base <> if(group(m, 2) != "", do: " Z", else: "") <> "}"
        end)
        |> String.graphemes()
        |> Enum.map_join(&Numbers.plain_letter/1)
      end

    text =
      text
      |> String.replace(~r/(?<=\d)–(?=\d)/u, "-")
      |> sub_with_pos(@day_range_re, &day_range(norm, &1))
      |> replace_many(@quote_replacements)

    {text, inline_list} = extract_inline(text)

    text =
      text
      |> String.replace("{", "(")
      |> String.replace("}", ")")
      |> sub_with_pos(@address_re, &address(norm, &1))
      |> String.replace("→", " to ")
      |> String.replace(@emoji_re, " ")
      |> String.replace(@emoticon_re, " ")
      |> String.replace(~r/\.{3,}/u, "…")
      |> String.replace(~r/(?<=\d)\s-\s(?=\d[\d.,]*\s?=)/u, " minus ")
      |> String.replace(~r/(?<![\d.,\/-])(\d[\d.,]*)-(?=\d[\d.,]*=)/u, "\\1 minus ")
      |> String.replace(~r/-{2,}|\s-\s/u, "—")
      |> String.replace(~r/\bw\/o\b/iu, " without ")
      |> String.replace(~r/\bw\/(?=\s|$)/iu, " with ")
      |> String.replace(~r/\bn\/a\b/iu, " not applicable ")
      |> String.replace("'n'", " 'n ")

    text = if Regex.match?(~r/[<>≥≤≠]|!=/u, text), do: mark_comparisons(text), else: text
    text = if Regex.match?(~r/\d/, text), do: rewrite_figures(norm, text), else: text
    {rewrite_signs(norm, text), inline_list}
  end

  # -- Figures pass

  defp rewrite_figures(norm, text) do
    text =
      text
      |> sub_with_pos(@formula_end_re, fn m ->
        full = group(m, 0)
        binary_part(full, 0, byte_size(full) - 1) <> @formula_sign
      end)
      |> sub_with_pos(@continental_re, &continental/1)
      |> String.replace(@comma_after_sign_re, "\\1.\\2")
      |> String.replace(@comma_before_sign_re, "\\1.\\2")
      |> sub_with_pos(@money_re, &money_prefix/1)
      |> String.replace(@range_before_sign_re, "\\1 to ")
      |> sub_with_pos(@money_after_re, &money_suffix/1)
      |> sub_with_pos(~r/(?<![\w.])(\d[\d,]*(?:\.\d+)?)\s?¢/u, fn m ->
        v = group(m, 1)
        " #{Numbers.number_words(v)} #{if v == "1", do: "cent", else: "cents"} "
      end)

    # Times, durations, ratios
    text =
      text
      |> sub_with_pos(@clock_zone_re, fn m -> "#{group(m, 1)} #{spelled(group(m, 2))}" end)
      |> String.replace(~r/(?<![\d.,:])(\d{1,2})\.([0-5]\d)(?=\s?[AaPp]\.?[Mm]\b)/u, "\\1:\\2")
      |> sub_with_pos(
        ~r/(?<![\d.,:])(\d{1,2})\.(00|15|30|45)(\s?(?:to|until|till|and|[-—])\s?)(\d{1,2})\.(00|15|30|45)(?!\d|\.\d)/u,
        &dot_times(norm, &1)
      )
      |> String.replace(@clock_range_re, "\\1 to ")
      |> sub_with_pos(@ratio_re, &ratio/1)
      |> sub_with_pos(@time_re, &time_match/1)
      |> sub_with_pos(@hour_ampm_re, fn m ->
        " #{Numbers.cardinal(String.to_integer(group(m, 1)))} " <>
          half_day(m, group(m, 2), group(m, 3))
      end)

    # Dates
    seen =
      Regex.scan(~r/(?<![\d\/.])(\d{1,2})\/(\d{1,2})(?:\/(?:\d{4}|\d{2}))?(?![\d\/])/u, text)
      |> Enum.map(fn [_, a, b] -> {String.to_integer(a), String.to_integer(b)} end)
      |> Enum.reject(&(&1 == {24, 7}))

    day_first =
      Enum.any?(seen, fn {a, b} -> a > 12 and b <= 12 end) and
        not Enum.any?(seen, fn {a, b} -> b > 12 and a <= 12 end)

    dated = Regex.match?(~r/(?<![\d\/])\d{1,2}\/\d{1,2}\/(?:\d{4}|\d{2})(?![\d\/])/u, text)
    date_ctx = %{day_first: day_first, dated: dated}

    text =
      text
      |> sub_with_pos(~r/(?<![\d-])(\d{4})-(\d{1,2})-(\d{1,2})(?![\d-])/u, fn m ->
        format_date(String.to_integer(group(m, 2)), String.to_integer(group(m, 3)), group(m, 1)) ||
          group(m, 0)
      end)
      |> sub_with_pos(~r/(?<![\d\/])(\d{4})\/(\d{1,2})\/(\d{1,2})(?![\d\/])/u, fn m ->
        format_date(String.to_integer(group(m, 2)), String.to_integer(group(m, 3)), group(m, 1)) ||
          group(m, 0)
      end)
      |> sub_with_pos(~r/(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4})(?!\d|\.\d)/u, &dot_date/1)
      |> sub_with_pos(
        ~r/(?<![\d\/])(\d{1,2})\/(\d{1,2})\/(\d{4}|\d{2})(?![\d\/])/u,
        &slash_date(&1, date_ctx)
      )
      |> sub_with_pos(@month_days_re, &days_of_month/1)
      |> sub_with_pos(@days_month_re, &days_of_month/1)
      |> sub_with_pos(@month_day_re, fn m ->
        month_key = group(m, 1) |> String.downcase() |> String.slice(0, 3)
        yr = non_empty(group(m, 3))
        format_date(@month_number[month_key], String.to_integer(group(m, 2)), yr) || group(m, 0)
      end)
      |> sub_with_pos(@day_month_re, &day_month/1)

    # Phone numbers, versions, codes
    text =
      text
      |> sub_with_pos(
        ~r/(?<![\d-])(?:\+?(1)[-.\s])?\(?(\d{3})\)?[-.\s](\d{3})[-.\s](\d{4})(?![\d-])/u,
        &phone/1
      )
      |> sub_with_pos(~r/(?<![\w.,-])(\d{3})-(\d{4})(?![\w-])/u, &phone/1)
      |> sub_with_pos(
        ~r/(?<![\w.])([vV])?(\d+(?:\.\d+){2,})(?:-(\d+)(?![\w-]|\.\d))?(?![\w])/u,
        fn m ->
          v = non_empty(group(m, 1))

          nums =
            group(m, 2) |> String.split(".") |> Enum.map_join(" point ", &Numbers.version_part/1)

          dash = non_empty(group(m, 3))

          " " <>
            if(v, do: spelled(v) <> " ", else: "") <>
            nums <>
            if(dash, do: " dash " <> Numbers.number_words(dash), else: "") <> " "
        end
      )
      |> sub_with_pos(~r/(?<![\w.])([vV])(\d+)\.(\d{2,3})(?!\d|\.\d|\w)/u, fn m ->
        " #{spelled(group(m, 1))} #{Numbers.cardinal(String.to_integer(group(m, 2)))} point #{Numbers.minor(group(m, 3))} "
      end)
      |> sub_with_pos(@versioned_re, fn m ->
        first =
          "#{group(m, 1)}#{group(m, 2)}#{Numbers.cardinal(String.to_integer(group(m, 3)))} point #{Numbers.minor(group(m, 4))}"

        second =
          case non_empty(group(m, 5)) do
            nil ->
              ""

            sep ->
              "#{sep}#{Numbers.cardinal(String.to_integer(group(m, 6)))} point #{Numbers.minor(group(m, 7))}"
          end

        first <> second <> " "
      end)
      |> sub_with_pos(@code_re, &code_match(norm, &1))
      |> sub_with_pos(@slashed_re, fn m ->
        " " <> digit_groups(String.split(group(m, 1), "/")) <> " "
      end)
      |> sub_with_pos(@grouped_re, &grouped(norm, &1))

    # Remaining numeric patterns
    text
    |> String.replace(~r/(?<![\w.])-(?=\d)/u, " minus ")
    |> String.replace(@dim_by_re, " by ")
    |> String.replace(~r/(?<=\d)\s[xX×]\s(?=\d)/u, " times ")
    |> sub_with_pos(
      ~r/(?<![\w\/'])[A-Za-z0-9\/]*[0-9\/][A-Za-z0-9\/]*(?![\w\/'])/u,
      &chat_form(norm, &1)
    )
    |> sub_with_pos(~r/(?<![\w.])'?(\d{2}|\d{4})'?s\b/u, fn m ->
      g = group(m, 1)
      n = String.to_integer(g)
      words = if String.length(g) == 4, do: Numbers.year(n), else: Numbers.cardinal(n)
      " " <> Numbers.plural_of(words) <> " "
    end)
    |> sub_with_pos(~r/(?<![\w.])(\d+)(?:st|nd|rd|th)\b/u, fn m ->
      " #{Numbers.ordinal(String.to_integer(group(m, 1)))} "
    end)
    |> sub_with_pos(
      ~r/(?<![\w.])(144|240|360|480|540|576|720|900|1080|1440|2160|4320)([pi])\b/u,
      fn m ->
        " #{Numbers.pairs(String.to_integer(group(m, 1)))} #{spelled(group(m, 2))} "
      end
    )
    |> sub_with_pos(~r/(\d[\d,]*(?:\.\d+)?)\s?%/u, fn m ->
      " #{Numbers.number_words(group(m, 1))} percent "
    end)
    |> sub_with_pos(norm.area_plain_re, &square(norm, &1))
    |> sub_with_pos(norm.unit_re, &measure(norm, &1))
    |> sub_with_pos(
      ~r/(?<![\d\/.,-])(\d+) (\d)\/(2|3|4|5|6|8|10|16)(?![\d\/]|\.\d)/u,
      &mixed_fraction/1
    )
    |> sub_with_pos(~r/(?<![\d\/.])(\d+)\/(\d+)(?![\d\/]|\.\d)/u, &fraction(&1, date_ctx))
    |> sub_with_pos(~r/(?<![\w.,-])(\d{4})[-–](\d{4})(?![\w.,-])/u, fn m ->
      " #{Numbers.year(String.to_integer(group(m, 1)))} to #{Numbers.year(String.to_integer(group(m, 2)))} "
    end)
    |> sub_with_pos(~r/(?<![\w.,-])(\d+)[-–](\d+)(?![\w-]|[.,]\d)/u, fn m ->
      " #{Numbers.number_words(group(m, 1))} to #{Numbers.number_words(group(m, 2))} "
    end)
    |> sub_with_pos(~r/(?<![\w.])(\d+)x\b/u, fn m ->
      " #{Numbers.number_words(group(m, 1))} times "
    end)
    |> String.replace(~r/(?<=\d)\^(?=\d)/u, " to the power of ")
  end

  # -- Signs pass

  defp rewrite_signs(norm, text) do
    text = named_letters(text)
    text = if String.contains?(text, ["<", ">"]), do: joined_comparisons(text), else: text

    text =
      text
      |> sub_with_pos(@size_range_re, fn m ->
        " #{spelled(group(m, 1))} to #{spelled(group(m, 2))} "
      end)
      |> String.replace(~r/#(?=\d)/u, " number ")
      |> String.replace(~r/#(?=[A-Z]{1,4}-?\d)/u, " number ")
      |> String.replace(~r/#(?=[A-Za-z])/u, " hashtag ")
      |> String.replace(~r/~(?=\s?\d)/u, " about ")
      |> sub_with_pos(@comp_ops_re, fn m -> compared(m, @comparisons[group(m, 1)]) end)
      |> String.replace(~r/(?<=\d) Ti\b/u, " #{spelled("TI")}")
      |> String.replace(~r/\b([Rr])ef\.\s?[Nn]o\.(?=\s)/u, "\\1eference number")

    text =
      if String.contains?(text, "."),
        do: sub_with_pos(text, ~r/\b((?:[A-Za-z]\.){2,})/u, &dotted/1),
        else: text

    text =
      sub_with_pos(text, ~r/\b([A-Za-z]{1,6})\b(\.?)(?![A-Za-z'’])/u, &abbreviation(norm, &1))

    text =
      if Regex.match?(~r/\d/, text) do
        text
        |> sub_with_pos(@glued_re, &glued(norm, &1))
        |> sub_with_pos(
          ~r/(?<![\w.])\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|(?<![\w.])\.\d+/u,
          &number_match(norm, &1)
        )
      else
        text
      end

    text
    |> String.replace(~r/(?<=[A-Za-z])\/(?=[A-Za-z])/u, " ")
    |> sub_with_pos(@lt_gt_re, fn m ->
      compared(m, if(String.contains?(group(m, 0), "<"), do: "less than", else: "greater than"))
    end)
    |> sub_with_pos(@symbol_re, fn m ->
      sym = group(m, 0)

      if sym in ["≥", "≤", "≠"],
        do: compared(m, @symbol_words[sym]),
        else: " #{@symbol_words[sym]} "
    end)
    |> String.replace(@is_mark, "")
  end

  # -- Individual rewriter helpers

  defp extract_inline(text) do
    matches = Regex.scan(~r/([A-Za-z']+)?\{([^{}]*)\}/u, text, return: :index)

    {iodata, cursor, inline_rev} =
      Enum.reduce(matches, {[], 0, []}, fn [{s, len} | _] = spans, {acc, cur, inl} ->
        prefix = binary_part(text, cur, s - cur)
        w = slice_span(text, Enum.at(spans, 1))
        body = slice_span(text, Enum.at(spans, 2))
        syms = String.split(body)

        parsed =
          if syms == [] or Enum.all?(syms, &(String.length(&1) == 1 and Numbers.ascii?(&1))) do
            :skip
          else
            parse_inline_phones(syms)
          end

        case parsed do
          {:ok, phones} ->
            idx = length(inl)
            marker = " " <> @inline <> <<@inline_base + idx::utf8>> <> @inline <> " "
            {[marker, prefix | acc], s + len, [{w, phones} | inl]}

          :skip ->
            {[binary_part(text, s, len), prefix | acc], s + len, inl}
        end
      end)

    tail = binary_part(text, cursor, byte_size(text) - cursor)
    {IO.iodata_to_binary(Enum.reverse([tail | iodata])), Enum.reverse(inline_rev)}
  end

  defp parse_inline_phones(syms) do
    if Convert.is_arpabet?(syms) do
      {:ok, Convert.convert("", syms)}
    else
      case Convert.from_text_safe(Enum.join(syms, " ")) do
        {:ok, phones} -> {:ok, phones}
        :error -> :skip
      end
    end
  end

  defp without_angles(text) do
    if String.contains?(text, "<") and String.contains?(text, ">") do
      marked =
        Regex.replace(@angles_re, text, fn full ->
          @angle_mark <> binary_part(full, 1, byte_size(full) - 2) <> @angle_mark
        end)

      if marked == text, do: text, else: without_angles(marked)
    else
      text
    end
  end

  defp mark_comparisons(text) do
    plain = without_angles(text)

    sub_with_pos(text, @compared_re, fn m ->
      before = binary_part(plain, 0, m.start)
      after_s = binary_part(plain, m.stop, byte_size(plain) - m.stop)
      {sign_start, _} = Enum.at(m.spans, 2)
      sign = group(m, 2)
      val_match = Regex.run(@value_before_re, before, return: :index)

      if binary_part(plain, sign_start, 1) != binary_part(sign, 0, 1) or
           val_match == nil or not Regex.match?(@value_after_re, after_s) do
        group(m, 0)
      else
        [{v_start, v_len} | _] = val_match
        v_str = binary_part(before, v_start, v_len)
        start = adjust_bracket_start(before, v_start, v_str)
        left = before |> binary_part(0, max(start, 0)) |> String.trim_trailing()

        case Regex.run(~r/[A-Za-z']+$/, left) do
          [w] ->
            if MapSet.member?(@clause_openers, String.downcase(w)),
              do: @is_mark <> group(m, 0),
              else: group(m, 0)

          nil ->
            @is_mark <> group(m, 0)
        end
      end
    end)
  end

  defp adjust_bracket_start(before, start, v_str) when v_str in [")", "]"] do
    pos = unwind_brackets(before, start, 0)
    unwind_ident(before, pos)
  end

  defp adjust_bracket_start(_before, start, _v_str), do: start

  defp unwind_brackets(_before, pos, _depth) when pos < 0, do: pos

  defp unwind_brackets(before, pos, depth) do
    b = :binary.at(before, pos)
    delta = if(b in [?), ?]], do: 1, else: 0) - if(b in [?(, ?[], do: 1, else: 0)
    new_depth = depth + delta
    if new_depth == 0, do: pos, else: unwind_brackets(before, pos - 1, new_depth)
  end

  defp unwind_ident(before, pos) when pos > 0 do
    b = :binary.at(before, pos - 1)

    if b in ?a..?z or b in ?A..?Z or b in ?0..?9 or b in [?_, ?.] do
      unwind_ident(before, pos - 1)
    else
      pos
    end
  end

  defp unwind_ident(_before, pos), do: pos

  defp compared(m, words) do
    full = group(m, 0)
    before = binary_part(m.text, 0, m.start) |> String.trim_trailing(" ")
    marked = String.starts_with?(full, @is_mark) or String.ends_with?(before, @is_mark)
    " #{if marked, do: "is ", else: ""}#{words} "
  end

  defp named_letters(text) do
    if String.contains?(text, [
         "=",
         "<",
         ">",
         "+",
         "*",
         "/",
         "^",
         "(",
         ")",
         "≤",
         "≥",
         "≠",
         "≈",
         "×",
         "÷",
         "±"
       ]) do
      plain = without_angles(text)

      places =
        for pattern <- @letter_places,
            [_, {pos, 1} | _] <- Regex.scan(pattern, plain, return: :index),
            into: MapSet.new() do
          pos
        end

      if MapSet.size(places) == 0 do
        text
      else
        places
        |> Enum.sort()
        |> splice_named_letters(text, 0, [])
      end
    else
      text
    end
  end

  defp splice_named_letters([], text, cur, acc) do
    tail = binary_part(text, cur, byte_size(text) - cur)
    IO.iodata_to_binary(Enum.reverse([tail | acc]))
  end

  defp splice_named_letters([pos | rest], text, cur, acc) do
    prefix = binary_part(text, cur, pos - cur)
    ch = binary_part(text, pos, 1) |> String.upcase()
    splice_named_letters(rest, text, pos + 1, [spelled(ch), prefix | acc])
  end

  defp joined_comparisons(text) do
    plain = without_angles(text)

    sub_with_pos(text, @joined_comparison_re, fn m ->
      sym = group(m, 0)
      before = binary_part(m.text, 0, m.start) |> String.trim_trailing(@is_mark)
      after_s = binary_part(m.text, m.stop, byte_size(m.text) - m.stop)

      cond do
        binary_part(plain, m.start, 1) != sym ->
          sym

        Regex.match?(@figure_before_re, before) or Regex.match?(@figure_after_re, after_s) or
            (Regex.match?(@letter_before_re, before) and Regex.match?(@letter_after_re, after_s)) ->
          compared(m, if(sym == "<", do: "less than", else: "greater than"))

        true ->
          sym
      end
    end)
  end

  defp vulgar(m) do
    whole = non_empty(group(m, 1))
    [top_s, bot_s] = m |> group(2) |> :unicode.characters_to_nfkc_binary() |> String.split("⁄")
    top = String.to_integer(top_s)
    bot = String.to_integer(bot_s)

    if whole == nil do
      " #{top}/#{bot} "
    else
      " #{Numbers.cardinal(String.to_integer(whole))} and #{Numbers.fraction_words(top, bot, true)} "
    end
  end

  defp continental(m) do
    groups = String.split(group(m, 1), ".")

    if length(groups) == 4 and Enum.all?(groups, &(String.to_integer(&1) <= 255)) do
      group(m, 0)
    else
      Enum.join(groups, ",") <> "." <> group(m, 2)
    end
  end

  defp money_prefix(m) do
    minus = non_empty(group(m, 1)) || non_empty(group(m, 3))
    symbol = group(m, 2)
    whole = group(m, 4) |> String.replace(",", "") |> String.replace(" ", "")
    frac = non_empty(group(m, 5))
    scale = non_empty(group(m, 6))
    words = format_amount(symbol, whole, frac, scale)
    if(minus, do: " minus ", else: " ") <> words <> " "
  end

  defp money_suffix(m) do
    minus = non_empty(group(m, 1))
    whole = group(m, 2) |> String.replace(",", "") |> String.replace(" ", "")
    frac = non_empty(group(m, 3))
    symbol = group(m, 4)
    words = format_amount(symbol, whole, frac, nil)
    if(minus, do: " minus ", else: " ") <> words <> " "
  end

  defp format_amount(symbol, whole, frac, scale) do
    {one, many, cent, cents} = Map.fetch!(@currency, symbol)

    cond do
      scale != nil ->
        sc = Map.get(@scale_letter, String.downcase(scale), String.downcase(scale))
        num_str = whole <> if(frac, do: "." <> frac, else: "")
        "#{Numbers.number_words(num_str)} #{sc} #{many}"

      frac != nil and (String.length(frac) > 2 or cent == "") ->
        "#{Numbers.number_words(whole <> "." <> frac)} #{many}"

      true ->
        amount = String.to_integer(whole)
        change = (frac || "0") |> String.pad_trailing(2, "0") |> String.to_integer()

        parts =
          if amount > 0 or change == 0,
            do: ["#{Numbers.cardinal(amount)} #{if amount == 1, do: one, else: many}"],
            else: []

        parts =
          if change > 0 and cent != "",
            do: parts ++ ["#{Numbers.cardinal(change)} #{if change == 1, do: cent, else: cents}"],
            else: parts

        Enum.join(parts, " and ")
    end
  end

  defp half_day(m, dotted, plain) do
    dotted = non_empty(dotted)
    plain = non_empty(plain)

    if dotted == nil and plain == nil do
      ""
    else
      following = binary_part(m.text, m.stop, byte_size(m.text) - m.stop) |> String.trim_leading()

      first =
        case Regex.run(~r/^[A-Za-z']+/, following) do
          [w] -> w
          nil -> nil
        end

      closes =
        dotted != nil and String.ends_with?(group(m, 0), ".") and
          (following == "" or
             (first != nil and starts_upper?(following) and
                MapSet.member?(@sentence_starters, String.downcase(first))))

      spelled(String.upcase(dotted || plain) <> "M") <> if(closes, do: " .", else: "") <> " "
    end
  end

  defp time_match(m) do
    hour = String.to_integer(group(m, 1))
    minute = String.to_integer(group(m, 2))
    second = non_empty(group(m, 3))
    dotted = non_empty(group(m, 4))
    plain = non_empty(group(m, 5))
    half = dotted || plain
    before = words_before(m.text, m.start, 3)

    cond do
      second != nil and half == nil and List.last(before) != "at" ->
        " #{Numbers.duration(hour, minute, String.to_integer(second))} "

      hour > 24 and second == nil and half == nil ->
        format_long_minutes(m, hour, minute, before)

      hour > 24 ->
        group(m, 0)

      true ->
        format_clock_time(m, hour, minute, second, dotted, plain, half)
    end
  end

  defp format_long_minutes(m, hour, minute, before) do
    after_w = next_alpha_word(m.text, m.stop)

    if Enum.any?(before, &MapSet.member?(@duration_words, &1)) or
         (after_w != nil and MapSet.member?(@duration_words, after_w)) do
      " #{Numbers.duration(0, hour, minute)} "
    else
      " #{Numbers.cardinal(hour)} #{if minute < 10, do: "oh ", else: ""}#{Numbers.cardinal(minute)} "
    end
  end

  defp format_clock_time(m, hour, minute, second, dotted, plain, half) do
    words =
      cond do
        minute == 0 and half != nil -> Numbers.cardinal(hour)
        minute == 0 and hour == 0 -> "midnight"
        minute == 0 and hour > 12 -> "#{Numbers.cardinal(hour)} hundred"
        minute == 0 -> "#{Numbers.cardinal(hour)} o'clock"
        minute < 10 -> "#{Numbers.cardinal(hour)} oh #{Numbers.cardinal(minute)}"
        true -> "#{Numbers.cardinal(hour)} #{Numbers.cardinal(minute)}"
      end

    words = append_seconds(words, second)
    " #{words} " <> half_day(m, dotted, plain)
  end

  defp append_seconds(words, nil), do: words

  defp append_seconds(words, second) do
    case String.to_integer(second) do
      0 -> words
      1 -> words <> " and one second"
      s -> words <> " and #{Numbers.cardinal(s)} seconds"
    end
  end

  defp dot_times(norm, m) do
    h1 = String.to_integer(group(m, 1))
    h2 = String.to_integer(group(m, 4))
    following = binary_part(m.text, m.stop, byte_size(m.text) - m.stop)
    before = words_before(m.text, m.start, 4)

    unit_after =
      Regex.compile!(
        "^\\s?(?:%|percent|million|billion|" <> norm.unit_names <> ")(?![A-Za-z])",
        "iu"
      )

    if h1 > 23 or h2 > 23 or not Enum.any?(before, &MapSet.member?(@clock_words, &1)) or
         Regex.match?(unit_after, following) do
      group(m, 0)
    else
      "#{group(m, 1)}:#{group(m, 2)}#{group(m, 3)}#{group(m, 4)}:#{group(m, 5)}"
    end
  end

  defp ratio(m) do
    first = group(m, 1)
    second = group(m, 2)

    if String.length(first) <= 2 and String.length(second) == 2 and
         String.first(second) in ["0", "1", "2", "3", "4", "5"] do
      before = words_before(m.text, m.start, 3)
      after_w = next_alpha_word(m.text, m.stop)

      if Enum.any?(before, &MapSet.member?(@ratio_words, &1)) or
           (after_w != nil and MapSet.member?(@ratio_words, after_w)) do
        " #{Numbers.number_words(first)} to #{Numbers.number_words(second)} "
      else
        group(m, 0)
      end
    else
      " #{Numbers.number_words(first)} to #{Numbers.number_words(second)} "
    end
  end

  defp format_date(month, day, year_text \\ nil, the? \\ false) do
    if month in 1..12 and day in 1..31 do
      m_name = elem(@months_tuple, month - 1)

      words =
        if the?,
          do: "the #{Numbers.ordinal(day)} of #{m_name}",
          else: "#{m_name} #{Numbers.ordinal(day)}"

      words =
        if year_text != nil and year_text != "" do
          yr = String.to_integer(year_text)

          yr_words =
            if String.length(year_text) == 4,
              do: Numbers.year(yr),
              else: if(yr < 10, do: "oh ", else: "") <> Numbers.cardinal(yr)

          words <> " " <> yr_words
        else
          words
        end

      " #{words} "
    else
      nil
    end
  end

  defp slash_date(m, %{day_first: day_first}) do
    a = String.to_integer(group(m, 1))
    b = String.to_integer(group(m, 2))
    {month, day} = if (a > 12 and b <= 12) or (day_first and b <= 12), do: {b, a}, else: {a, b}
    format_date(month, day, group(m, 3)) || group(m, 0)
  end

  defp dot_date(m) do
    d = String.to_integer(group(m, 1))
    mo = String.to_integer(group(m, 2))
    {day, month} = if mo > 12 and d <= 12, do: {mo, d}, else: {d, mo}
    format_date(month, day, group(m, 3)) || group(m, 0)
  end

  defp day_month(m) do
    month = group(m, 2)
    key = month |> String.downcase() |> String.slice(0, 3)

    case format_date(
           @month_number[key],
           String.to_integer(group(m, 1)),
           non_empty(group(m, 4)),
           true
         ) do
      nil ->
        group(m, 0)

      spoken ->
        spoken <> if(non_empty(group(m, 3)) != nil and month in @months, do: ". ", else: "")
    end
  end

  defp days_of_month(m) do
    g1 = group(m, 1)
    month_first? = Numbers.ascii_alpha?(String.first(g1))

    {month, s1, s2} =
      if month_first?, do: {g1, group(m, 2), group(m, 3)}, else: {group(m, 3), g1, group(m, 2)}

    d1 = String.to_integer(s1)
    d2 = String.to_integer(s2)

    if d1 in 1..31 and d2 in 1..31 do
      name =
        elem(@months_tuple, @month_number[month |> String.downcase() |> String.slice(0, 3)] - 1)

      words =
        if month_first?,
          do: "#{name} #{Numbers.ordinal(d1)} to #{Numbers.ordinal(d2)}",
          else: "the #{Numbers.ordinal(d1)} to the #{Numbers.ordinal(d2)} of #{name}"

      yr = non_empty(group(m, 4))
      " #{words}#{if yr, do: " " <> Numbers.year(String.to_integer(yr)), else: ""} "
    else
      group(m, 0)
    end
  end

  defp day_range(norm, m) do
    names =
      for name <- [group(m, 1), group(m, 3)] do
        key = String.downcase(name)

        case Map.get(norm.abbreviations, key) do
          {_, words} -> words
          nil -> Map.get(@day_names, key, name)
        end
      end

    following = binary_part(m.text, m.stop, byte_size(m.text) - m.stop) |> String.trim_leading()

    first =
      case Regex.run(~r/^[A-Za-z']+/, following) do
        [w] -> w
        nil -> nil
      end

    ends =
      non_empty(group(m, 4)) != nil and
        (following == "" or
           (first != nil and starts_upper?(following) and
              MapSet.member?(@sentence_starters, String.downcase(first))))

    "#{Enum.at(names, 0)} to #{Enum.at(names, 1)}#{if ends, do: " .", else: ""}"
  end

  defp short_date(m, %{day_first: day_first, dated: dated}) do
    s1 = group(m, 1)
    s2 = group(m, 2)

    if String.length(s1) <= 2 and String.length(s2) <= 2 do
      parse_short_date(m, s1, s2, day_first, dated)
    end
  end

  defp parse_short_date(m, s1, s2, day_first, dated) do
    a = String.to_integer(s1)
    b = String.to_integer(s2)
    before = words_before(m.text, m.start, 4)

    if a in 1..12 and b in 20..49 and "card" in before do
      " #{elem(@months_tuple, a - 1)} #{Numbers.year(2000 + b)} "
    else
      if short_date_match?(s1, s2, a, b, before, dated) do
        {mo, d} = if a > 12 or (day_first and b <= 12), do: {b, a}, else: {a, b}
        format_date(mo, d)
      end
    end
  end

  defp short_date_match?(s1, s2, a, b, before, dated) do
    last = List.last(before) || ""
    classic = a < b and MapSet.member?(@classic_fractions, b)
    zero = leading_zero_two?(s1) or leading_zero_two?(s2)

    zero or
      (a > 12 and a <= 31 and b <= 12 and {a, b} != {24, 7}) or
      (MapSet.member?(@date_before, last) and (not classic or last == "on")) or
      (dated and not classic and a != b)
  end

  defp leading_zero_two?(s), do: String.length(s) == 2 and String.starts_with?(s, "0")

  defp fraction(m, date_ctx) do
    case short_date(m, date_ctx) do
      nil ->
        top = String.to_integer(group(m, 1))
        bot = String.to_integer(group(m, 2))

        cond do
          {top, bot} == {24, 7} or top == bot ->
            " #{Numbers.cardinal(top)} #{Numbers.cardinal(bot)} "

          top <= 0 or top >= 100 or bot <= 1 or bot > 100 ->
            " #{Numbers.cardinal(top)} over #{Numbers.cardinal(bot)} "

          true ->
            " #{Numbers.fraction_words(top, bot)} "
        end

      spoken ->
        spoken
    end
  end

  defp mixed_fraction(m) do
    top = String.to_integer(group(m, 2))
    bot = String.to_integer(group(m, 3))

    if top > 0 and top < bot do
      " #{Numbers.number_words(group(m, 1))} and #{Numbers.fraction_words(top, bot, true)} "
    else
      group(m, 0)
    end
  end

  defp phone(m) do
    groups =
      1..(length(m.spans) - 1)
      |> Enum.map(&non_empty(group(m, &1)))
      |> Enum.reject(&is_nil/1)

    spoken =
      Enum.map_join(groups, ", ", fn
        "800" -> "eight hundred"
        g -> Numbers.digits(g, "oh")
      end)

    " " <> spoken <> " "
  end

  defp measure(norm, m) do
    unit = group(m, 3)
    names = Map.get(norm.exact_units, unit) || Map.get(norm.units, String.downcase(unit))
    {u_start, u_len} = Enum.at(m.spans, 3)
    u_end = u_start + u_len
    next_ch = if u_end < byte_size(m.text), do: binary_part(m.text, u_end, 1), else: ""

    if names == nil or (String.length(unit) == 1 and next_ch in ["-", "'", "/"]) do
      group(m, 0)
    else
      {one, many} = names
      val = Numbers.decimal_comma(group(m, 1))

      upper =
        case non_empty(group(m, 2)) do
          nil -> nil
          u -> Numbers.decimal_comma(u)
        end

      if upper do
        " #{Numbers.number_words(val)} to #{Numbers.number_words(upper)} #{many} "
      else
        " #{Numbers.number_words(val)} #{if val in ["1", "1.0"], do: one, else: many} "
      end
    end
  end

  defp square(norm, m) do
    unit = group(m, 2)

    {one, many} =
      case unit do
        "in" -> {"inch", "inches"}
        _ -> Map.get(norm.exact_units, unit) || Map.fetch!(norm.units, unit)
      end

    kind = if group(m, 3) in ["²", "2"], do: "square", else: "cubic"
    val = Numbers.decimal_comma(group(m, 1))
    " #{Numbers.number_words(val)} #{kind} #{if val in ["1", "1.0"], do: one, else: many} "
  end

  defp counted?(norm, text, pos) do
    case next_alpha_word(text, pos) do
      nil ->
        false

      w when w in ~w(people men women children feet miles) ->
        true

      w ->
        String.length(w) > 3 and String.ends_with?(w, "s") and not String.ends_with?(w, "ss") and
          not MapSet.member?(@not_counted, w) and
          norm.is_word.(String.slice(w, 0, String.length(w) - 1))
    end
  end

  defp number_match(norm, m) do
    value = group(m, 0)
    plain = String.replace(value, ",", "")

    no_punct =
      not String.contains?(plain, ".") and not String.contains?(value, ",") and
        not String.starts_with?(plain, "0")

    cond do
      no_punct and String.length(plain) > 2 and ref_digits?(norm, m, plain) ->
        kind = identifier(m.text, m.start)
        " #{Numbers.digits(plain, if(kind == :phone, do: "oh", else: "zero"))} "

      no_punct and String.length(plain) == 4 ->
        four_digit_number(m, value, String.to_integer(plain))

      true ->
        " #{Numbers.number_words(value)} "
    end
  end

  defp ref_digits?(norm, m, plain) do
    kind = identifier(m.text, m.start)

    limit =
      case kind do
        :phone -> 3
        :pin -> 3
        :strong -> 4
        :enter -> 4
        :weak -> 5
        nil -> 7
      end

    String.length(plain) >= limit and
      not (kind == nil and String.ends_with?(plain, "000")) and
      not (kind == :enter and String.length(plain) == 4 and String.to_integer(plain) in 1900..2099) and
      not (kind in [nil, :phone, :weak] and counted?(norm, m.text, m.stop))
  end

  defp four_digit_number(m, value, n) do
    pre_start = max(0, m.start - 24)
    pre_slice = binary_part(m.text, pre_start, m.start - pre_start)
    before = Regex.scan(~r/[A-Za-z]+/, pre_slice) |> List.flatten()
    after_w = next_alpha_word(m.text, m.stop)

    counted =
      after_w != nil and
        Regex.match?(~r/(?:[^s]s|people|men|women|children|feet|miles)$/, after_w)

    dated =
      before != [] and
        (MapSet.member?(@year_context, String.downcase(List.last(before))) or
           Map.has_key?(
             @month_number,
             before |> List.last() |> String.downcase() |> String.slice(0, 3)
           ))

    model_match = Regex.run(~r/(?<![A-Za-z])([A-Z]{2,5}) $/, binary_part(m.text, 0, m.start))

    cond do
      model_match != nil and not MapSet.member?(@capital_words, Enum.at(model_match, 1)) and
          not counted ->
        " #{Numbers.pairs(n)} "

      n in 1100..1999 or (n in 2000..2099 and (dated or not counted)) ->
        " #{Numbers.year(n)} "

      true ->
        " #{Numbers.number_words(value)} "
    end
  end

  defp reads_as_word?(norm, letters) do
    lower = String.downcase(letters)
    len = String.length(lower)

    if len < 3 or not norm.is_word.(lower) do
      false
    else
      len > 3 or Enum.any?(~w(s es ed ing), &norm.is_word.(lower <> &1))
    end
  end

  defp alnum(group, zero \\ "zero") do
    Regex.scan(~r/[A-Za-z]+|\d+/, group)
    |> List.flatten()
    |> Enum.map_join(" ", fn run ->
      if digits_only?(run), do: Numbers.digits(run, zero), else: spelled(run)
    end)
  end

  defp digit_groups(groups, zero \\ "zero") do
    if Enum.all?(groups, &(Numbers.short_number?(&1) and String.length(&1) <= 2)) do
      Enum.map_join(groups, " , ", &Numbers.cardinal(String.to_integer(&1)))
    else
      Enum.map_join(groups, " , ", &Numbers.digits(&1, zero))
    end
  end

  defp code_match(norm, m) do
    groups = String.split(group(m, 2), "-")

    case code_words(norm, groups, m) do
      nil -> group(m, 0)
      words -> if(non_empty(group(m, 1)), do: " number ", else: " ") <> words <> " "
    end
  end

  defp code_words(norm, groups, m) do
    token = Enum.join(groups, "-")

    if Regex.match?(~r/\d/, token) do
      kinds = Enum.map(groups, &group_kind/1)
      code_words_by_kind(norm, groups, kinds, token, m)
    else
      nil
    end
  end

  defp group_kind(g) do
    cond do
      digits_only?(g) -> :d
      Regex.match?(~r/\d/, g) -> :m
      g == String.upcase(g) -> :u
      true -> :l
    end
  end

  defp code_words_by_kind(norm, groups, kinds, token, m) do
    cond do
      Enum.all?(kinds, &(&1 == :d)) ->
        code_all_digits(groups, m)

      match?([k, :d] when k in [:u, :l], kinds) ->
        code_prefix_digits(norm, groups, hd(kinds))

      reject_code?(groups, kinds, token) ->
        nil

      true ->
        format_code_parts(norm, kinds, groups)
    end
  end

  defp code_prefix_digits(norm, [letters, number], kind) do
    cond do
      (kind == :l and String.length(letters) > 1) or reads_as_word?(norm, letters) ->
        nil

      Numbers.short_number?(number) ->
        "#{spelled(letters)} #{Numbers.cardinal(String.to_integer(number))}"

      true ->
        "#{spelled(letters)} , #{Numbers.digits(number)}"
    end
  end

  defp reject_code?(groups, kinds, token) do
    digit_then_word? =
      length(groups) == 2 and hd(kinds) == :d and
        (Enum.at(kinds, 1) == :l or String.length(Enum.at(groups, 1)) == 1 or
           Regex.match?(~r/^\d+[A-Za-z]+$/, Enum.at(groups, 1)))

    bad_part? =
      Enum.zip(kinds, groups)
      |> Enum.any?(fn {k, g} ->
        (k == :l and String.length(g) > 2) or
          (k == :m and Regex.match?(~r/^\d+(?:s|st|nd|rd|th)$/, g))
      end)

    lower_only? = not Regex.match?(~r/[A-Z]/, token) and (:l in kinds or :m in kinds)
    digit_then_word? or bad_part? or lower_only?
  end

  defp format_code_parts(norm, kinds, groups) do
    Enum.zip(kinds, groups)
    |> Enum.map_join(" , ", fn
      {:d, g} -> Numbers.digits(g)
      {:m, g} -> alnum(g)
      {_, g} -> format_code_word(norm, g)
    end)
  end

  defp format_code_word(norm, g) do
    if String.length(g) > 3 and norm.is_word.(String.downcase(g)) do
      g
    else
      if String.length(g) <= 5, do: spelled(g), else: g
    end
  end

  defp code_all_digits([g1, g2] = groups, m) do
    years? = Enum.all?(groups, &(String.length(&1) == 4 and String.to_integer(&1) in 1000..2100))

    keep =
      non_empty(group(m, 1)) != nil or
        Enum.any?(groups, &(String.length(&1) > 1 and String.starts_with?(&1, "0"))) or
        (min(String.length(g1), String.length(g2)) >= 4 and not years?) or
        identifier(m.text, m.start) in [:strong, :pin]

    if keep, do: digit_groups(groups), else: nil
  end

  defp code_all_digits(groups, _m), do: digit_groups(groups)

  defp grouped(norm, m) do
    plus = non_empty(group(m, 1))
    lead = non_empty(group(m, 2))
    core = String.split(group(m, 3), " ")
    trail = non_empty(group(m, 4))
    {head, tail, lead, trail} = strip_capital_lead(lead, trail)
    kind = identifier(m.text, m.start)
    pure = Enum.all?(core, &digits_only?/1)

    cond do
      pure and plus == nil and lead == nil ->
        grouped_pure(norm, m, head, tail, trail, core, kind)

      not pure and lead == nil and plus == nil and kind == nil ->
        group(m, 0)

      true ->
        format_grouped(head, tail, plus, lead, trail, core, pure, kind)
    end
  end

  defp strip_capital_lead(lead, trail) do
    if lead != nil and MapSet.member?(@capital_words, lead) do
      {lead <> " ", if(trail, do: " " <> trail, else: ""), nil, nil}
    else
      {"", "", lead, trail}
    end
  end

  defp grouped_pure(norm, m, head, tail, trail, core, kind) do
    following = binary_part(m.text, m.stop, byte_size(m.text) - m.stop)
    unit_after = Regex.compile!("^\\s?(?:" <> norm.unit_names <> ")(?![A-Za-z])", "iu")
    amount = counted?(norm, m.text, m.stop) or Regex.match?(unit_after, following)

    cond do
      thousands_grouped?(core, kind, amount) ->
        head <> Enum.join(core, ",") <> tail

      digit_group_code?(core, kind) ->
        format_grouped(head, tail, nil, nil, trail, core, true, kind)

      true ->
        group(m, 0)
    end
  end

  defp thousands_grouped?([first | rest] = core, nil, amount) do
    not String.starts_with?(first, "0") and String.length(first) <= 3 and
      Enum.all?(rest, &(String.length(&1) == 3)) and
      (List.last(core) == "000" or (amount and length(core) > 2))
  end

  defp thousands_grouped?(_core, _kind, _amount), do: false

  defp digit_group_code?([first | _] = core, kind) do
    kind != nil or
      (String.length(first) > 1 and String.starts_with?(first, "0")) or
      (length(core) > 2 and Enum.any?(core, &(String.length(&1) > 2)))
  end

  defp format_grouped(head, tail, plus, lead, trail, core, pure, kind) do
    total_digits = Enum.reduce(core, 0, &(String.length(&1) + &2))

    zero =
      if plus != nil or kind == :phone or
           (pure and String.starts_with?(hd(core), "0") and total_digits >= 10),
         do: "oh",
         else: "zero"

    spoken =
      if pure do
        digit_groups(core, zero)
      else
        Enum.map_join(core, " , ", fn p ->
          if digits_only?(p), do: Numbers.digits(p, zero), else: alnum(p, zero)
        end)
      end

    spoken = if lead, do: "#{spelled(lead)} , #{spoken}", else: spoken
    spoken = if trail, do: "#{spoken} , #{spelled(trail)}", else: spoken
    head <> if(plus, do: " plus ", else: " ") <> spoken <> " " <> tail
  end

  defp glued(norm, m) do
    parts =
      Regex.scan(~r/[A-Za-z]+|\d+/, group(m, 0))
      |> List.flatten()
      |> Enum.map(fn run ->
        cond do
          digits_only?(run) ->
            if Numbers.short_number?(run),
              do: Numbers.cardinal(String.to_integer(run)),
              else: Numbers.digits(run)

          String.length(run) == 1 or
              ((run == String.upcase(run) or String.length(run) <= 3) and
                 not reads_as_word?(norm, run)) ->
            spelled(run)

          true ->
            run
        end
      end)

    " " <> Enum.join(parts, " ") <> " "
  end

  defp address(norm, m) do
    whole = group(m, 0)
    text = String.replace(whole, ~r/[.,;:!?)]+$/, "")
    tail = binary_part(whole, byte_size(text), byte_size(whole) - byte_size(text))

    # Named groups in @address_re: 1=url, 2=mail, 3=file, 4=folder, 5=stem, 6=ending, 7=path
    is_file = non_empty(group(m, 3)) != nil

    skip_file =
      if is_file do
        ending = group(m, 6)
        lower_end = String.downcase(ending)
        known = Map.has_key?(norm.endings, lower_end)

        marked =
          non_empty(group(m, 4)) != nil or non_empty(group(m, 7)) != nil or
            String.contains?(group(m, 5), "_")

        not (known or
               (marked and String.length(ending) <= 5 and
                  (ending == String.downcase(ending) or ending == String.upcase(ending)) and
                  not norm.is_word.(lower_end)))
      else
        false
      end

    if skip_file do
      whole
    else
      core =
        text |> String.replace(~r/^(?:https?:\/\/)?(?:www\.)?/, "") |> String.trim_trailing("/")

      " #{spoken_address(norm, core)} #{tail}"
    end
  end

  defp spoken_address(norm, core) do
    pieces = Regex.scan(~r/[A-Za-z]+|\d+|./u, core) |> List.flatten() |> List.to_tuple()
    n = tuple_size(pieces)
    mail = String.contains?(core, "@")

    {rev_out, _host} =
      Enum.reduce(0..(n - 1)//1, {[], false}, fn idx, {acc, host} ->
        piece = elem(pieces, idx)
        prev = if idx > 0, do: elem(pieces, idx - 1), else: ""
        nxt = if idx + 1 < n, do: elem(pieces, idx + 1), else: ""
        host = host or piece == "@"
        items = address_piece_items(norm, piece, idx, prev, nxt, host, mail)
        {Enum.reverse(items) ++ acc, host}
      end)

    rev_out |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
  end

  defp address_piece_items(norm, piece, idx, prev, nxt, host, mail) do
    cond do
      digits_only?(piece) ->
        [Numbers.address_digits(piece)]

      not Numbers.ascii_alpha?(piece) ->
        [Map.get(@separators, piece, "")]

      address_ending?(norm, piece, idx, prev, nxt, host, mail) ->
        lp = String.downcase(piece)
        [if(Map.get(norm.endings, lp) == "word", do: lp, else: spelled(piece))]

      true ->
        address_word_parts(norm, piece)
    end
  end

  defp address_ending?(norm, piece, idx, prev, nxt, host, mail) do
    idx > 0 and prev == "." and (host or not mail) and
      (nxt in ["", "/", ":", "?", "#"] or
         (String.length(piece) <= 3 and
            (Map.has_key?(norm.endings, String.downcase(piece)) or
               not norm.is_word.(String.downcase(piece)))))
  end

  defp address_word_parts(norm, piece) do
    parts = Regex.scan(~r/[A-Z]?[a-z]+|[A-Z]+(?![a-z])/, piece) |> List.flatten()

    {rev, letters} =
      Enum.reduce(parts, {[], ""}, fn part, {acc, letters} ->
        spoken = address_part(norm, part)

        if String.starts_with?(spoken, @spell) do
          {acc, letters <> part}
        else
          acc = if letters != "", do: [spelled(letters) | acc], else: acc
          {[spoken | acc], ""}
        end
      end)

    rev = if letters != "", do: [spelled(letters) | rev], else: rev
    Enum.reverse(rev)
  end

  defp address_part(norm, part) do
    lower = String.downcase(part)

    cond do
      String.length(part) > 1 and norm.is_word.(lower) and
          (String.length(part) > 2 or MapSet.member?(@short_words, lower)) ->
        part

      String.length(part) <= 3 ->
        spelled(part)

      true ->
        part
    end
  end

  defp chat_form(norm, m) do
    case Map.get(norm.chat, String.downcase(group(m, 0))) do
      nil ->
        group(m, 0)

      "-" ->
        " "

      said ->
        words =
          said
          |> String.split()
          |> Enum.map_join(" ", fn
            "*" <> rest -> spelled(rest)
            w -> w
          end)

        " " <> words <> " "
    end
  end

  defp dotted(m) do
    full = group(m, 0)
    letters = String.replace(full, ".", "")
    key = String.downcase(letters)
    following = binary_part(m.text, m.stop, byte_size(m.text) - m.stop) |> String.trim_leading()

    words =
      case key do
        "eg" -> "for example"
        "ie" -> "that is"
        _ -> spelled(String.upcase(letters))
      end

    first =
      case Regex.run(~r/^[A-Za-z']+/, following) do
        [w] -> w
        nil -> nil
      end

    ends =
      following == "" or
        (first != nil and starts_upper?(following) and
           MapSet.member?(@sentence_starters, String.downcase(first)))

    " #{words}#{if ends and String.ends_with?(full, "."), do: " .", else: ""} "
  end

  defp abbreviation(norm, m) do
    token = group(m, 1)
    stop = non_empty(group(m, 2))
    key = String.downcase(token)
    following = binary_part(m.text, m.stop, byte_size(m.text) - m.stop)
    next_tok = match_first_capture(~r/^\s*([A-Za-z]+|\d)/, following)
    capital_next = next_tok != nil and starts_upper?(next_tok)

    cond do
      key in ["st", "dr"] and starts_upper?(token) ->
        expand_st_dr(m, key, stop, following, capital_next)

      Map.has_key?(norm.abbreviations, key) ->
        expand_abbreviation(norm, m, token, stop, key, following, next_tok, capital_next)

      true ->
        group(m, 0)
    end
  end

  defp expand_st_dr(m, key, stop, following, capital_next) do
    capital_before = Regex.match?(~r/[A-Z][a-z]+\s+$/, binary_part(m.text, 0, m.start))

    cond do
      capital_next and (stop != nil or key == "dr") ->
        if key == "st", do: " saint ", else: " doctor "

      capital_before and stop != nil ->
        base = if key == "st", do: " street", else: " drive"
        base <> if(String.trim(following) == "", do: " .", else: " ")

      true ->
        group(m, 0)
    end
  end

  defp expand_abbreviation(norm, m, token, stop, key, following, next_tok, capital_next) do
    {when_kind, words} = norm.abbreviations[key]
    number_next = next_tok != nil and digits_only?(next_tok)
    previous = match_first_capture(~r/([A-Za-z]+)\.?\s+$/, binary_part(m.text, 0, m.start))
    previous = if previous, do: String.downcase(previous)

    if skip_abbreviation?(
         when_kind,
         token,
         stop,
         key,
         next_tok,
         capital_next,
         number_next,
         previous
       ) do
      group(m, 0)
    else
      words = if key == "est" and not number_next, do: "estimated", else: words

      ends =
        when_kind != "title" and
          (String.trim(following) == "" or
             (capital_next and MapSet.member?(@sentence_starters, String.downcase(next_tok))))

      " #{words}#{if ends, do: " .", else: ""} "
    end
  end

  defp skip_abbreviation?("title", token, stop, _key, _next_tok, capital_next, _num, _prev) do
    not (starts_upper?(token) and (capital_next or stop != nil))
  end

  defp skip_abbreviation?("number", _token, stop, key, _next_tok, _cap, number_next, previous) do
    not (stop != nil and
           (number_next or
              (key == "no" and previous != nil and MapSet.member?(@numbered, previous))))
  end

  defp skip_abbreviation?(when_kind, token, stop, key, next_tok, _cap, number_next, _prev) do
    cond do
      stop == nil or (when_kind == "small" and token == String.upcase(token)) ->
        true

      key in ~w(mar sun sat jan dec max min est no) and not starts_upper?(token) and
          not number_next ->
        not (key in ~w(max min est) and next_tok != nil and starts_lower?(next_tok))

      true ->
        false
    end
  end

  defp match_first_capture(regex, str) do
    case Regex.run(regex, str) do
      [_, cap] -> cap
      nil -> nil
    end
  end

  # -- Tokenization & word-level rules

  defp process_token_match(norm, text, [{s, len} | _] = spans, inline_tuple, all_caps, st) do
    before_ch = if s > 0, do: prev_grapheme(text, s), else: " "
    stop = s + len

    case classify_token_match(text, spans) do
      {:hyphen, _} -> process_hyphen(text, before_ch, stop, st)
      {:spelled, val} -> append_tokens(st, [spelled_word(val)])
      {:inline, val} -> append_tokens(st, [inline_word(val, inline_tuple)])
      {:word, val} -> process_word_token(norm, text, val, before_ch, stop, all_caps, st)
      {:number, val} -> append_tokens(st, number_word_tokens(val))
      {:other, val} -> process_other_token(text, val, before_ch, stop, st)
      :none -> %{st | attach: false}
    end
  end

  defp classify_token_match(text, spans) do
    [
      {5, :hyphen},
      {1, :spelled},
      {2, :inline},
      {3, :word},
      {4, :number},
      {6, :other}
    ]
    |> Enum.find_value(:none, fn {idx, kind} ->
      case span_or_nil(text, Enum.at(spans, idx)) do
        nil -> nil
        val -> {kind, val}
      end
    end)
  end

  defp process_hyphen(text, before_ch, stop, st) do
    next_ch = if stop < byte_size(text), do: next_grapheme(text, stop), else: ""

    attach =
      match?([%Word{} | _], st.out) and not whitespace?(before_ch) and
        next_ch != "" and alnum_char?(next_ch)

    %{st | attach: attach}
  end

  defp spelled_word(val) do
    %Word{text: val |> String.replace(" ", "") |> String.downcase(), raw: val, spell: true}
  end

  defp inline_word(val, inline_tuple) do
    <<cp::utf8>> = val
    {written, phones} = elem(inline_tuple, cp - @inline_base)
    %Word{text: String.downcase(written), raw: written, phones: phones}
  end

  defp number_word_tokens(val) do
    for part <- String.split(Numbers.number_words(val)), do: %Word{text: part, raw: val}
  end

  defp process_other_token(text, other_s, before_ch, stop, st) do
    if Symbols.punctuation?(other_s) do
      next_ch = if stop < byte_size(text), do: next_grapheme(text, stop), else: ""

      skip_apos =
        other_s == "'" and alnum_char?(before_ch) and next_ch != "" and alnum_char?(next_ch)

      out = if skip_apos, do: st.out, else: [%Punct{mark: other_s} | st.out]
      fresh = if other_s in [".", "!", "?", ";", "…"], do: true, else: st.fresh
      %{st | out: out, fresh: fresh, attach: false}
    else
      %{st | attach: false}
    end
  end

  defp process_word_token(norm, text, word, before_ch, stop, all_caps, st) do
    {word, st} = strip_leading_apostrophe(norm, word, st)
    after_str = binary_part(text, stop, byte_size(text) - stop)
    following? = Regex.match?(~r/^\s*[A-Za-z]/, after_str)
    new = word_tokens(norm, word, all_caps, st.previous, following?, st.fresh)
    out_len = length(st.out)

    short =
      if short_sound_candidate?(word, new, before_ch, after_str),
        do: [out_len | st.short],
        else: st.short

    replies =
      if reply_candidate?(norm, word, new, before_ch, after_str),
        do: [out_len | st.replies],
        else: st.replies

    st = %{st | previous: word, short: short, replies: replies}
    append_tokens(st, new)
  end

  defp strip_leading_apostrophe(norm, "'" <> rest = word, st) do
    lower = String.downcase(word)

    cond do
      not MapSet.member?(@leading_apostrophe, lower) ->
        {rest, %{st | out: [%Punct{mark: "'"} | st.out]}}

      not norm.is_word.(lower) ->
        {rest, st}

      true ->
        {word, st}
    end
  end

  defp strip_leading_apostrophe(_norm, word, st), do: {word, st}

  defp short_sound_candidate?(word, new, before_ch, after_str) do
    word in ["Ss", "ss", "Zz", "zz"] and length(new) == 1 and
      (whitespace?(before_ch) or before_ch in ["\"", "'", "("]) and
      Regex.match?(~r/^[.!?…,;:—"')\]?]*(?:\s|$)/u, after_str)
  end

  defp reply_candidate?(norm, word, new, before_ch, after_str) do
    lower = String.downcase(word)

    MapSet.member?(norm.replies, lower) and (String.length(word) > 1 or word == lower) and
      length(new) == 1 and (whitespace?(before_ch) or before_ch in ["\"", "'"]) and
      Regex.match?(~r/^(?:[.?…,;—]*["']?(?:\s|$)|!+["']?\s*$)/u, after_str)
  end

  defp append_tokens(st, []), do: %{st | attach: false}

  defp append_tokens(st, [first | rest]) do
    first = if st.attach, do: %{first | attach: true}, else: first
    new = [first | rest]
    %{st | out: Enum.reverse(new) ++ st.out, attach: false, fresh: false}
  end

  defp word_tokens(norm, raw, all_caps, previous, following?, fresh?) do
    lower = String.downcase(raw)
    chat = Map.get(norm.chat, lower)

    cond do
      chat != nil and (String.length(raw) > 1 or raw == lower) and
          not MapSet.member?(norm.replies, lower) ->
        chat_words(chat, raw)

      Map.has_key?(@roman, raw) and previous != "" and starts_upper?(previous) ->
        n = @roman[raw]

        words =
          if MapSet.member?(@cardinal_after, String.downcase(previous)),
            do: Numbers.cardinal(n),
            else: "the " <> Numbers.ordinal(n)

        for w <- String.split(words), do: %Word{text: w, raw: raw}

      true ->
        word_tokens_core(norm, raw, lower, all_caps, previous, following?, fresh?)
    end
  end

  defp word_tokens_core(norm, raw, lower, all_caps, previous, following?, fresh?) do
    letters = String.replace(raw, "'", "")
    possessive = String.ends_with?(lower, "'s")
    stem = if possessive, do: String.slice(raw, 0, String.length(raw) - 2), else: raw
    stem_len = String.length(stem)

    cond do
      stem_len == 1 and Numbers.ascii_alpha?(stem) ->
        single_letter_token(raw, lower, stem, possessive, previous, following?, fresh?)

      hiss_or_snore?(stem, stem_len, lower, all_caps) ->
        [%Word{text: lower, raw: raw, phones: [{String.first(lower), 0}]}]

      initialism_stem?(norm, stem, stem_len, all_caps) ->
        [%Word{text: lower, raw: raw, spell: true}]

      not Numbers.ascii_alpha?(letters) ->
        []

      true ->
        word_tokens_split(norm, raw, lower)
    end
  end

  defp single_letter_token(raw, lower, stem, possessive, previous, following?, fresh?) do
    label =
      stem == "A" and previous != "" and
        (not following? or (not fresh? and MapSet.member?(@labelled, String.downcase(previous))))

    if stem in ["a", "A", "I", "i"] and not possessive and not label do
      [%Word{text: String.downcase(stem), raw: raw}]
    else
      [%Word{text: lower, raw: raw, spell: true}]
    end
  end

  defp hiss_or_snore?(stem, stem_len, lower, all_caps) do
    stem_len > 2 and String.first(stem) in ["S", "s", "Z", "z"] and
      lower |> String.graphemes() |> Enum.uniq() |> length() == 1 and
      (all_caps or stem != String.upcase(stem))
  end

  defp initialism_stem?(norm, stem, stem_len, all_caps) do
    stem == String.upcase(stem) and Numbers.ascii_alpha?(stem) and stem_len in 2..5 and
      (not all_caps or not norm.is_word.(String.downcase(stem))) and
      (MapSet.member?(@initialisms, stem) or not norm.is_word.(String.downcase(stem)))
  end

  defp word_tokens_split(norm, raw, lower) do
    capitals = Regex.match?(~r/^[a-z]+(?:[A-Z][a-z]+)*[A-Z]{2,}(?:'s)?$/, raw)

    if capitals or not norm.is_word.(lower) do
      unstretched_match =
        if not capitals do
          Enum.find(unstretched(lower), norm.is_word)
        end

      if unstretched_match do
        [%Word{text: unstretched_match, raw: raw}]
      else
        parts = Regex.scan(~r/[A-Z]?[a-z']+|[A-Z]+(?![a-z])/, raw) |> List.flatten()

        if length(parts) > 1 and Enum.join(parts) == raw do
          split_camel_parts(norm, parts, capitals)
        else
          [%Word{text: lower, raw: raw}]
        end
      end
    else
      [%Word{text: lower, raw: raw}]
    end
  end

  defp split_camel_parts(norm, parts, capitals) do
    parts
    |> Enum.reduce([], fn part, acc ->
      upper? = part == String.upcase(part)
      named = if capitals and upper?, do: MapSet.member?(@initialisms, part), else: false

      spelled? =
        String.length(part) == 1 or named or (upper? and not norm.is_word.(String.downcase(part)))

      case acc do
        [%Word{spell: true} = prev | rest] when capitals and (spelled? or part == "'s") ->
          [%{prev | text: prev.text <> String.downcase(part), raw: prev.raw <> part} | rest]

        _ ->
          [
            %Word{text: String.downcase(part), attach: acc != [], raw: part, spell: spelled?}
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  defp unstretched(word) do
    if Regex.match?(~r/(.)\1\1/u, word) do
      liked =
        Regex.match?(~r/([lfsz])\1\1+$/, word) or
          word |> String.graphemes() |> Enum.uniq() == ["m"] or
          Regex.replace(~r/(.)\1{2,}$/, word, "\\1") == "to"

      [
        cut_stretched(word, true, liked),
        cut_stretched(word, true, not liked),
        cut_stretched(word, false, liked),
        cut_stretched(word, false, not liked)
      ]
      |> Enum.uniq()
    else
      []
    end
  end

  defp cut_stretched(word, double_inside, double_final) do
    sub_with_pos(word, ~r/(.)\1{2,}/u, fn m ->
      doubled? = if m.stop == byte_size(word), do: double_final, else: double_inside
      String.duplicate(group(m, 1), if(doubled?, do: 2, else: 1))
    end)
  end

  defp chat_words("-", _raw), do: []

  defp chat_words(chat, raw) do
    chat
    |> String.split()
    |> Enum.map(fn
      "*" <> rest -> %Word{text: String.downcase(rest), raw: raw, spell: true}
      w -> %Word{text: String.downcase(w), raw: w}
    end)
  end

  defp resolve_short_sounds(out, []), do: out

  defp resolve_short_sounds(out, places) do
    n = tuple_size(out)

    Enum.reduce(places, out, fn place, acc ->
      first = scan_clause_edge(acc, place, -1, n)
      last = scan_clause_edge(acc, place + 1, 1, n)

      all_sounds? =
        Enum.all?(first..(last - 1)//1, fn i ->
          case elem(acc, i) do
            %Word{text: t, phones: ph} ->
              MapSet.member?(@sounds, t) or
                (ph != nil and t |> String.graphemes() |> Enum.uniq() |> length() == 1)

            _ ->
              true
          end
        end)

      if all_sounds? do
        tok = elem(acc, place)
        put_elem(acc, place, %{tok | phones: [{String.first(tok.text), 0}]})
      else
        acc
      end
    end)
  end

  defp scan_clause_edge(arr, idx, -1, n) when idx > 0 do
    case elem(arr, idx - 1) do
      %Word{} -> scan_clause_edge(arr, idx - 1, -1, n)
      %Punct{mark: m} when m in ["\"", "'", "(", ")"] -> scan_clause_edge(arr, idx - 1, -1, n)
      _ -> idx
    end
  end

  defp scan_clause_edge(arr, idx, 1, n) when idx < n do
    case elem(arr, idx) do
      %Word{} -> scan_clause_edge(arr, idx + 1, 1, n)
      %Punct{mark: m} when m in ["\"", "'", "(", ")"] -> scan_clause_edge(arr, idx + 1, 1, n)
      _ -> idx
    end
  end

  defp scan_clause_edge(_arr, idx, _step, _n), do: idx

  defp resolve_replies(_norm, out, []), do: out

  defp resolve_replies(norm, out, places_desc) do
    Enum.reduce(places_desc, out, fn place, acc ->
      if reply?(acc, place) do
        tok = Enum.at(acc, place)
        replacement = chat_words(norm.chat[String.downcase(tok.raw)], tok.raw)
        Enum.slice(acc, 0, place) ++ replacement ++ Enum.drop(acc, place + 1)
      else
        acc
      end
    end)
  end

  defp reply?(out, place) do
    arr = List.to_tuple(out)
    n = tuple_size(arr)

    results =
      for step <- [-1, 1] do
        idx = skip_quote_brackets(arr, place + step, step, n)

        cond do
          idx < 0 or idx >= n ->
            {:ok, ""}

          match?(%Word{}, elem(arr, idx)) ->
            :word

          true ->
            mark = elem(arr, idx).mark
            beyond = if idx + step >= 0 and idx + step < n, do: elem(arr, idx + step), else: nil

            if mark == "," and match?(%Word{}, beyond) and String.length(beyond.text) == 1 and
                 beyond.text != "i" do
              :list
            else
              {:ok, mark}
            end
        end
      end

    case results do
      [{:ok, ","}, {:ok, ","}] -> false
      [{:ok, _}, {:ok, _}] -> true
      _ -> false
    end
  end

  defp skip_quote_brackets(arr, idx, step, n) when idx >= 0 and idx < n do
    case elem(arr, idx) do
      %Punct{mark: m} when m in ["\"", "'", "(", ")"] ->
        skip_quote_brackets(arr, idx + step, step, n)

      _ ->
        idx
    end
  end

  defp skip_quote_brackets(_arr, idx, _step, _n), do: idx

  # -- Context & regex helpers

  defp words_before(text, pos, count) do
    start = max(0, pos - 80)
    slice = binary_part(text, start, pos - start)
    clause = slice |> String.split(~r/[.!?;…]\s|[()"]/u) |> List.last()

    Regex.scan(~r/[A-Za-z]+/, clause)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.take(-count)
  end

  defp identifier(text, pos) do
    words = words_before(text, pos, 4)

    if words == [] do
      nil
    else
      last = List.last(words)
      prev_two = words |> Enum.drop(-1) |> Enum.take(-2)

      if MapSet.member?(@phone_words, last) or
           (MapSet.member?(@phone_links, last) and
              Enum.any?(prev_two, &MapSet.member?(@phone_words, &1))) do
        :phone
      else
        classify_identifier(words, last)
      end
    end
  end

  defp classify_identifier(words, last) do
    base_word =
      words
      |> Enum.reverse()
      |> Enum.drop_while(&MapSet.member?(@link_words, &1))
      |> List.first()
      |> Kernel.||(hd(words))

    cond do
      MapSet.member?(@phone_words, base_word) -> :phone
      MapSet.member?(@pin_words, base_word) -> :pin
      MapSet.member?(@strong_words, base_word) -> :strong
      MapSet.member?(@weak_words, base_word) -> :weak
      last == "enter" -> :enter
      true -> nil
    end
  end

  defp next_alpha_word(text, pos) do
    after_s = binary_part(text, pos, byte_size(text) - pos)

    case Regex.run(~r/^\s*([A-Za-z]+)/, after_s) do
      [_, w] -> String.downcase(w)
      nil -> nil
    end
  end

  defp sub_with_pos(text, regex, fun) do
    case Regex.scan(regex, text, return: :index) do
      [] ->
        text

      matches ->
        {rev_io, cursor} =
          Enum.reduce(matches, {[], 0}, fn [{s, len} | _] = spans, {acc, cur} ->
            prefix = binary_part(text, cur, s - cur)
            rep = fun.(%{text: text, start: s, stop: s + len, spans: spans})
            {[rep, prefix | acc], s + len}
          end)

        tail = binary_part(text, cursor, byte_size(text) - cursor)
        IO.iodata_to_binary(Enum.reverse([tail | rev_io]))
    end
  end

  defp group(%{text: text, spans: spans}, idx) do
    slice_span(text, Enum.at(spans, idx))
  end

  defp slice_span(_text, nil), do: ""
  defp slice_span(_text, {-1, _}), do: ""
  defp slice_span(text, {s, len}), do: binary_part(text, s, len)

  defp span_or_nil(_text, nil), do: nil
  defp span_or_nil(_text, {-1, _}), do: nil
  defp span_or_nil(text, {s, len}), do: binary_part(text, s, len)

  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  defp spelled(letters), do: @spell <> letters <> @spell_end

  defp digits_only?(str), do: str != "" and Regex.match?(~r/^\d+$/, str)
  defp starts_upper?(str), do: Regex.match?(~r/^[A-Z]/, str)
  defp starts_lower?(str), do: Regex.match?(~r/^[a-z]/, str)
  defp whitespace?(str), do: Regex.match?(~r/^\s$/u, str)
  defp alnum_char?(str), do: Regex.match?(~r/^[\p{L}\p{N}]$/u, str)

  defp prev_grapheme(text, byte_pos) do
    start = utf8_char_start(text, byte_pos - 1)
    binary_part(text, start, byte_pos - start)
  end

  defp utf8_char_start(text, pos) when pos > 0 do
    if Bitwise.band(:binary.at(text, pos), 0xC0) == 0x80,
      do: utf8_char_start(text, pos - 1),
      else: pos
  end

  defp utf8_char_start(_text, _pos), do: 0

  defp next_grapheme(text, byte_pos) do
    len = min(4, byte_size(text) - byte_pos)
    binary_part(text, byte_pos, len) |> String.first()
  end

  defp replace_many(text, pairs) do
    Enum.reduce(pairs, text, fn {old, new}, acc -> String.replace(acc, old, new) end)
  end
end
