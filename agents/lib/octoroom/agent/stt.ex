defmodule Octoroom.Agent.STT do
  @moduledoc """
  Streaming speech-to-text providers.

  A provider is a process, usually a WebSocket client, that one owner feeds
  with audio and that reports back with messages:

      {:ok, stt} = Octoroom.Agent.STT.start_link("soniox:stt-rt-v5", sample_rate: 16_000)
      Octoroom.Agent.STT.send_audio(stt, pcm)
      # receive {:stt, ^stt, {:final, "hello"}}

  ## Options

  `start_link/2` takes a provider and options. The provider is a
  `"provider:model"` string, a registered name, or a module; options can also
  name it with `:provider` and `:model`. Every provider takes:

    * `:owner` - the process that gets the events (default: the caller)
    * `:api_key` - defaults to the provider's environment variable
    * `:model`
    * `:sample_rate` - of the audio sent: 16-bit little-endian mono PCM
    * `:language_hints`

  Anything else is passed to the provider, which ignores what it doesn't use.

  ## Events

  The owner gets `{:stt, pid, event}`, where `event` is:

    * `:connected` - audio sent from now on is heard
    * `{:partial, text}` - an interim transcript of the current utterance
    * `{:final, text}` - the final transcript of an utterance, after the
      provider's endpointing or a `finalize/1`. After `finalize/1`, it comes
      even if `text` is `""`
    * `:finished` - the provider is done, after `close/1`
    * `{:warning, reason}` - something went wrong but the session goes on
    * `{:error, reason}` - the session failed; `reason` is a string or a
      map with `:message` when the provider gave one
    * `{:disconnected, reason, %{intentional?: boolean}}` - the connection
      closed; intentional after `close/1`

  ## Adding a provider

  Implement this behaviour, sending events with `notify/2`, and register it:

      config :octoroom_agents, stt_providers: [acme: MyApp.AcmeSTT]

  A module that implements the behaviour also works as `:provider` without
  being registered.
  """

  alias Octoroom.Agent.SpeechProvider

  @type event ::
          :connected
          | {:partial, String.t()}
          | {:final, String.t()}
          | :finished
          | {:warning, term()}
          | {:error, term()}
          | {:disconnected, term(), %{intentional?: boolean()}}

  @doc "Starts a session that sends events to `opts[:owner]`."
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @callback send_audio(pid(), audio :: binary()) :: :ok

  @doc """
  Finalizes what's been heard so far, without waiting for the provider's
  endpointing. Answered with a `{:final, text}`. Providers without it just
  wait for their endpointing.
  """
  @callback finalize(pid()) :: :ok

  @doc "Flushes the audio sent, then ends the session."
  @callback close(pid()) :: :ok

  @doc "Options used when the caller doesn't give them, such as `:model`."
  @callback default_options() :: keyword()

  @optional_callbacks finalize: 1, default_options: 0

  @providers %{
    soniox: Octoroom.Agent.STT.Soniox,
    assembly_ai: Octoroom.Agent.STT.AssemblyAI
  }

  @doc "The registered providers, by name."
  def providers, do: SpeechProvider.registry(@providers, :stt_providers)

  @doc """
  Finds the provider for `opts`. Returns the module and its options, with
  the provider's defaults filled in.
  """
  def resolve(opts), do: SpeechProvider.resolve(opts, __MODULE__, providers())

  @doc "Starts a session. See the module docs for `provider` and `opts`."
  def start_link(provider, opts \\ []) do
    with {:ok, module, opts} <- resolve(with_provider(provider, opts)) do
      module.start_link(Keyword.put_new(opts, :owner, self()))
    end
  end

  @doc "Asks `module`'s session to finalize, if the provider can."
  def finalize(module, pid) do
    if function_exported?(module, :finalize, 1), do: module.finalize(pid), else: :ok
  end

  @doc "Sends `event` from the calling provider process to `owner`."
  def notify(owner, event), do: send(owner, {:stt, self(), event})

  @doc "A message for a user to read about an `{:error, reason}` event."
  def error_message(message) when is_binary(message), do: message
  def error_message(%{message: message}) when is_binary(message), do: message
  def error_message(%{code: code}) when not is_nil(code), do: "STT error #{code}"
  def error_message(_reason), do: "STT error"

  defp with_provider(provider, opts), do: SpeechProvider.with_provider(provider, opts)
end
