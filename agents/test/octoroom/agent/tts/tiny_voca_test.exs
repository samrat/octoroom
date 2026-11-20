defmodule Octoroom.Agent.TTS.TinyVocaTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TTS
  alias Octoroom.Agent.TTS.TinyVoca
  alias Octoroom.Agent.TTS.TinyVoca.{Dizione, G2P, Store}

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.{
    Align,
    Convert,
    Morphology,
    Normalize,
    Sentence,
    Symbols
  }

  describe "provider registration and options" do
    test "is registered with its defaults" do
      assert {:ok, TinyVoca, opts} = TTS.resolve(model: "tiny_voca:tiny-voca")
      assert opts[:model] == "tiny-voca"
      assert opts[:voice] == "F2"
      assert opts[:sample_rate] == 24_000
      assert opts[:speed] == 1.0
      assert opts[:pitch_shift] == 0.0
      assert opts[:pitch_range] == 1.0
    end

    test "validates model, voice, sample_rate, and speed" do
      assert {:error, {:unknown_model, "other", _}} =
               TTS.synthesize("tiny_voca:other", "Hello.", download: false)

      assert {:error, {:unsupported_voice, "X9", _}} =
               TTS.synthesize("tiny_voca:tiny-voca", "Hello.", voice: "X9", download: false)

      assert {:error, {:unsupported_sample_rate, 0}} =
               TTS.synthesize("tiny_voca:tiny-voca", "Hello.", sample_rate: 0, download: false)

      assert {:error, {:invalid_option, :speed, -1}} =
               TTS.synthesize("tiny_voca:tiny-voca", "Hello.", speed: -1, download: false)
    end

    test "reports missing weights when download is disabled" do
      dir =
        Path.join(System.tmp_dir!(), "tiny_voca_missing_#{System.unique_integer([:positive])}")

      assert {:error, {:tiny_voca_model_missing, path}} =
               TTS.synthesize("tiny_voca:tiny-voca", "Hello.", model_dir: dir, download: false)

      assert path == Path.join(dir, "onnx/model.onnx")
    end
  end

  describe "Store.ensure_files/2" do
    @tag :tmp_dir
    test "downloads missing assets via request_fun and skips cached ones", %{tmp_dir: dir} do
      parent = self()

      request_fun = fn url, opts ->
        send(parent, {:fetched, url})
        into = Keyword.fetch!(opts, :into)
        Enum.into(["content-for-#{Path.basename(url)}"], into)
        {:ok, %{status: 200}}
      end

      assert :ok =
               Store.ensure_files(dir,
                 base_url: "https://example.test/tiny-voca",
                 request_fun: request_fun
               )

      for rel <- Store.files() do
        assert_received {:fetched, "https://example.test/tiny-voca/" <> ^rel}
        assert File.regular?(Path.join(dir, rel))
      end

      # Second call hits cache and makes no requests.
      assert :ok =
               Store.ensure_files(dir,
                 base_url: "https://example.test/tiny-voca",
                 request_fun: fn url, _ -> flunk("unexpected fetch: #{url}") end
               )
    end

    @tag :tmp_dir
    test "returns an error and cleans up temp files on failed download", %{tmp_dir: dir} do
      request_fun = fn _url, _opts -> {:ok, %{status: 503}} end

      assert {:error, {:tiny_voca_download_failed, "onnx/model.onnx", 503}} =
               Store.ensure_files(dir, request_fun: request_fun)

      refute File.exists?(Path.join(dir, "onnx/model.onnx"))
      assert Path.wildcard(Path.join(dir, "onnx/*.tmp.*")) == []
    end
  end

  describe "text splitting and audio conversion" do
    test "finished/1 adds a trailing period only when needed" do
      assert TinyVoca.finished("Hello world") == "Hello world."
      assert TinyVoca.finished("Hello world!") == "Hello world!"
      assert TinyVoca.finished(~s(She said "go!")) == ~s(She said "go!")
      assert TinyVoca.finished("see you :)") == "see you :)."
    end

    test "sentences/1 splits sentences without breaking on titles, p.m., or initials" do
      text = "Dr. Smith arrived at 3 p.m. on Tuesday. He met J. R. R. Tolkien! Did they talk?"

      assert TinyVoca.sentences(text) == [
               "Dr. Smith arrived at 3 p.m. on Tuesday.",
               "He met J. R. R. Tolkien!",
               "Did they talk?"
             ]
    end

    test "shorter/1 splits on clauses first, then halfway between words" do
      assert TinyVoca.shorter("one, two; three") == ["one,", "two;", "three"]
      assert TinyVoca.shorter("one two three four") == ["one two", "three four"]
      assert TinyVoca.shorter("superlongword") == []
    end

    test "f32_to_pcm16/1 scales down waveforms peaking above 0.99 without clipping" do
      raw = <<0.0::float-32-native, 2.0::float-32-native, -1.0::float-32-native>>

      <<s0::little-signed-16, s1::little-signed-16, s2::little-signed-16>> =
        TinyVoca.f32_to_pcm16(raw)

      assert s0 == 0
      # Peak 2.0 scaled down to 0.99 -> ~32_439
      assert_in_delta s1, round(0.99 * 32_767), 1
      assert_in_delta s2, -round(0.495 * 32_767), 1
    end
  end

  describe "Dizione components" do
    test "Convert handles flapping, glottal t, velar n, and stress settling" do
      # water -> w ˈɔː ɾ ɚ (with alignment)
      water = Convert.convert("water", ~w(W AO1 T ER0), ["w", "a", "t", "er"])
      assert Enum.any?(water, &(elem(&1, 0) == "ɾ"))

      # button -> b ˈʌ ʔ n̩
      button = Convert.convert("button", ~w(B AH1 T AH0 N), ["b", "u", "tt", "o", "n"])
      assert button == [{"b", 0}, {"ʌ", 1}, {"ʔ", 0}, {"n̩", 0}]

      # income -> velar n before k
      income = Convert.convert("income", ~w(IH1 N K AH2 M), ["i", "n", "c", "o", "me"])
      assert Enum.at(income, 1) == {"ŋ", 0}

      # Only last primary stress stays primary; adjacent secondary drops to 0.
      settled = Convert.settle_stress([{"ɑː", 1}, {"t", 0}, {"ɛ", 1}])
      assert settled == [{"ɑː", 0}, {"t", 0}, {"ɛ", 1}]
    end

    test "Morphology derives regular inflections and compounds" do
      lex = %{
        "cat" => [{"k", 0}, {"æ", 1}, {"t", 0}],
        "dog" => [{"d", 0}, {"ɔ", 1}, {"ɡ", 0}],
        "box" => [{"b", 0}, {"ɑː", 1}, {"k", 0}, {"s", 0}],
        "wait" => [{"w", 0}, {"eɪ", 1}, {"t", 0}],
        "sand" => [{"s", 0}, {"æ", 1}, {"n", 0}, {"d", 0}],
        "piper" => [{"p", 0}, {"aɪ", 1}, {"p", 0}, {"ɚ", 0}]
      }

      lookup = &Map.get(lex, &1)
      assert Morphology.derive("cats", lookup) == [{"k", 0}, {"æ", 1}, {"t", 0}, {"s", 0}]
      assert Morphology.derive("dogs", lookup) == [{"d", 0}, {"ɔ", 1}, {"ɡ", 0}, {"z", 0}]

      assert Morphology.derive("boxes", lookup) == [
               {"b", 0},
               {"ɑː", 1},
               {"k", 0},
               {"s", 0},
               {"ᵻ", 0},
               {"z", 0}
             ]

      assert Morphology.derive("waited", lookup) == [
               {"w", 0},
               {"eɪ", 1},
               {"ɾ", 0},
               {"ᵻ", 0},
               {"d", 0}
             ]

      assert Morphology.derive("sandpiper", lookup) == [
               {"s", 0},
               {"æ", 1},
               {"n", 0},
               {"d", 0},
               {"p", 0},
               {"aɪ", 2},
               {"p", 0},
               {"ɚ", 0}
             ]
    end

    test "Sentence resolves clause stress and vowel linking" do
      units = [
        %Sentence.Unit{word: "the", phones: [{"ð", 0}, {"ə", 0}], kind: "u"},
        %Sentence.Unit{word: "apple", phones: [{"æ", 1}, {"p", 0}, {"əl", 0}], kind: "c"}
      ]

      [the, _apple] = units |> Sentence.stress_clause() |> Sentence.join_clause()
      assert the.phones == [{"ð", 0}, {"ɪ", 0}]
    end

    test "Normalize expands currency, dates, times, ordinals, and inline pronunciations" do
      norm = Normalize.new(fn w -> w in ~w(hello world meeting moved march left) end)

      tokens = Normalize.tokens(norm, "The meeting moved to 3:30 pm on March 14th, $12.99.")
      words = for %Normalize.Word{text: t} <- tokens, do: t

      assert "three" in words
      assert "thirty" in words
      assert "pm" in words
      assert "march" in words
      assert "fourteenth" in words
      assert "twelve" in words
      assert "dollars" in words
      assert "ninety" in words
      assert "cents" in words

      inline_tokens = Normalize.tokens(norm, "hello {HH AH0 L OW1}")
      assert Enum.any?(inline_tokens, &(&1.phones != nil))
    end

    @tag :tmp_dir
    test "Dizione.phonemize/2 runs end-to-end with a minimal phonemizer directory", %{
      tmp_dir: dir
    } do
      File.write!(
        Path.join(dir, "lexicon.tsv"),
        Enum.join(
          [
            "hello\th ə l ˈoʊ",
            "world\tw ˈɜː l d",
            "two\tt ˈuː"
          ],
          "\n"
        )
      )

      File.write!(Path.join(dir, "align.json"), "{}")

      d = Dizione.load(dir, overrides: %{"octoroom" => "AA1 K T ER0 UW2 M"})

      assert {:ok, res} = Dizione.phonemize(d, "Hello, octoroom!")
      assert hd(res.symbols) == "<bos>"
      assert List.last(res.symbols) == "<eos>"
      assert length(res.ids) == length(res.stress)
      assert Enum.all?(res.ids, &(&1 in 0..75))

      assert {:error, :nothing_to_pronounce} = Dizione.phonemize(d, "😀 ... !!!")
    end

    test "Symbols.tokenize/1 rejects punctuation-only pieces" do
      assert {:error, :nothing_to_pronounce} = Symbols.tokenize([{:punct, "!"}])
    end

    test "Align.align/3 aligns letters to phonemes" do
      aligner = Align.new(%{"K" => %{"c" => -0.5}, "AE" => %{"a" => -0.1}, "T" => %{"t" => -0.1}})
      assert Align.align(aligner, "cat", ~w(K AE1 T)) == ["c", "a", "t"]
      assert Align.align(aligner, "toolongword", ~w(K)) == nil
    end
  end

  describe "G2P ONNX graph builder" do
    @tag :tmp_dir
    test "builds a valid ONNX BiGRU from .npz weights and runs via OnnxRuntime", %{tmp_dir: dir} do
      # Tiny 1-layer BiGRU (width=2, hidden=2, slots=2, 3 symbols -> 4 classes)
      settings = %{
        "letters" => "ab",
        "symbols" => ["AE1", "B", "T"],
        "width" => 2,
        "hidden" => 2,
        "convs" => 0,
        "layers" => 1,
        "slots" => 2
      }

      File.write!(Path.join(dir, "g2p.json"), Jason.encode!(settings))

      zeros = fn count -> :binary.copy(<<0.0::float-32-little>>, count) end
      # Make out__bias prefer class 1 ("AE1") on every frame -> CTC collapses to ["AE1"].
      out_bias =
        <<0.0::float-32-little, 5.0::float-32-little, 0.0::float-32-little, 0.0::float-32-little>>

      entries = [
        {~c"embed__weight.npy", npy_f32([3, 2], zeros.(6))},
        {~c"slot.npy", npy_f32([2, 2], zeros.(4))},
        {~c"gru__weight_ih_l0.npy", npy_f32([6, 2], zeros.(12))},
        {~c"gru__weight_hh_l0.npy", npy_f32([6, 2], zeros.(12))},
        {~c"gru__bias_ih_l0.npy", npy_f32([6], zeros.(6))},
        {~c"gru__bias_hh_l0.npy", npy_f32([6], zeros.(6))},
        {~c"gru__weight_ih_l0_reverse.npy", npy_f32([6, 2], zeros.(12))},
        {~c"gru__weight_hh_l0_reverse.npy", npy_f32([6, 2], zeros.(12))},
        {~c"gru__bias_ih_l0_reverse.npy", npy_f32([6], zeros.(6))},
        {~c"gru__bias_hh_l0_reverse.npy", npy_f32([6], zeros.(6))},
        {~c"out__weight.npy", npy_f32([4, 4], zeros.(16))},
        {~c"out__bias.npy", npy_f32([4], out_bias)}
      ]

      {:ok, {_, zip_bin}} = :zip.create(~c"g2p.npz", entries, [:memory])
      File.write!(Path.join(dir, "g2p.npz"), zip_bin)

      g2p = G2P.load(dir)
      assert File.regular?(Path.join(dir, "g2p.onnx"))
      assert G2P.predict(g2p, "ab") == ["AE1"]
      assert G2P.predict(g2p, "123") == []
    end
  end

  defp npy_f32(shape, raw) do
    shape_str =
      case shape do
        [n] -> "(#{n},)"
        many -> "(" <> Enum.map_join(many, ", ", &Integer.to_string/1) <> ")"
      end

    header = "{'descr': '<f4', 'fortran_order': False, 'shape': #{shape_str}, }"
    pad = rem(64 - rem(10 + byte_size(header) + 1, 64), 64)
    full_header = header <> String.duplicate(" ", pad) <> "\n"

    <<0x93, "NUMPY", 1, 0, byte_size(full_header)::little-unsigned-16, full_header::binary,
      raw::binary>>
  end
end
