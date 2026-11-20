defmodule Octoroom.Agent.TTS do
  @moduledoc """
  Text-to-speech providers.

      :ok =
        Octoroom.Agent.TTS.stream("inworld:inworld-tts-2", "Hello!", fn pcm -> ... end,
          voice: "Ashley",
          sample_rate: 24_000
        )

      {:ok, pcm} = Octoroom.Agent.TTS.synthesize(:inworld, "Hello!", model: "inworld-tts-2")

  Audio is 16-bit little-endian mono PCM at `:sample_rate`, with no
  container header.

  ## Options

  The provider is a `"provider:model"` string, a registered name, or a
  module; options can also name it with `:provider` and `:model`. Every
  provider takes:

    * `:api_key` - defaults to the provider's environment variable
    * `:model` - needed: no provider picks one for you
    * `:voice`
    * `:sample_rate` - of the audio returned

  Anything else is passed to the provider, which ignores what it doesn't use.

  ## Adding a provider

  Implement `stream/3` or `synthesize/2`, or both: `stream/3` falls back to
  one `synthesize/2` call, and `synthesize/2` collects what `stream/3`
  sends. Then register it:

      config :octoroom_agents, tts_providers: [acme: MyApp.AcmeTTS]

  A module that implements the behaviour also works as `:provider` without
  being registered.
  """

  alias Octoroom.Agent.SpeechProvider

  @doc """
  Speaks `text`, calling `on_audio` with each piece of audio as it arrives.
  Returns once all of it has been passed on.
  """
  @callback stream(text :: String.t(), on_audio :: (binary() -> any()), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Speaks `text`, returning all of the audio at once."
  @callback synthesize(text :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Options used when the caller doesn't give them, such as `:voice`."
  @callback default_options() :: keyword()

  @doc """
  Opens what the provider keeps between calls, such as a WebSocket, tied to
  the calling process. Returns the options that use it. Whoever speaks many
  times (the TTS processor) calls it once first.
  """
  @callback connect(opts :: keyword()) :: {:ok, keyword()} | {:error, term()}

  @optional_callbacks stream: 3, synthesize: 2, default_options: 0, connect: 1

  @providers %{
    assembly_ai: Octoroom.Agent.TTS.AssemblyAI,
    inworld: Octoroom.Agent.TTS.Inworld,
    openai: Octoroom.Agent.TTS.OpenAI
  }

  @doc "The registered providers, by name."
  def providers, do: SpeechProvider.registry(@providers, :tts_providers)

  @doc """
  Finds the provider for `opts`. Returns the module and its options, with
  the provider's defaults filled in.
  """
  def resolve(opts), do: SpeechProvider.resolve(opts, __MODULE__, providers())

  @doc "`connect/1` of `module`, or `opts` unchanged when it has none."
  def connect(module, opts) do
    if function_exported?(module, :connect, 1), do: module.connect(opts), else: {:ok, opts}
  end

  @doc "Speaks `text` with `provider`, streaming audio to `on_audio`."
  def stream(provider, text, on_audio, opts \\ []) do
    with {:ok, module, opts} <- resolve(SpeechProvider.with_provider(provider, opts)) do
      stream_with(module, text, on_audio, opts)
    end
  end

  @doc "Speaks `text` with `provider`, returning all of the audio."
  def synthesize(provider, text, opts \\ []) do
    with {:ok, module, opts} <- resolve(SpeechProvider.with_provider(provider, opts)) do
      synthesize_with(module, text, opts)
    end
  end

  @doc "`stream/4` with a module and options from `resolve/1`."
  def stream_with(module, text, on_audio, opts) do
    if function_exported?(module, :stream, 3) do
      module.stream(text, on_audio, opts)
    else
      with {:ok, audio} <- module.synthesize(text, opts) do
        on_audio.(audio)
        :ok
      end
    end
  end

  @doc "`synthesize/3` with a module and options from `resolve/1`."
  def synthesize_with(module, text, opts) do
    if function_exported?(module, :synthesize, 2) do
      module.synthesize(text, opts)
    else
      ref = make_ref()
      parent = self()

      # Providers call `on_audio` before `stream/3` returns, so all of the
      # audio is in the mailbox by then.
      with :ok <- module.stream(text, &send(parent, {ref, &1}), opts) do
        {:ok, collect(ref, [])}
      end
    end
  end

  defp collect(ref, acc) do
    receive do
      {^ref, audio} -> collect(ref, [acc | audio])
    after
      0 -> IO.iodata_to_binary(acc)
    end
  end

  @doc false
  # Splits `text` into parts of at most `max` units, as `count` measures
  # them, for providers that cap each message: on whitespace, and by
  # graphemes inside a "word" over the limit.
  def split_text(text, max, count) do
    text
    |> String.split(~r/(?<=\s)/u)
    |> Enum.reduce([], fn
      word, [current | rest] ->
        if count.(current) + count.(word) <= max,
          do: [current <> word | rest],
          else: [word, current | rest]

      word, [] ->
        [word]
    end)
    |> Enum.reverse()
    |> Enum.flat_map(&hard_split(&1, max, count))
  end

  defp hard_split(part, max, count) do
    if count.(part) <= max do
      [part]
    else
      part
      |> String.graphemes()
      |> Enum.chunk_while(
        "",
        fn g, acc ->
          if count.(acc) + count.(g) <= max, do: {:cont, acc <> g}, else: {:cont, acc, g}
        end,
        fn acc -> {:cont, acc, ""} end
      )
    end
  end
end
