defmodule Octoroom.Agent.SpeechProvider do
  @moduledoc false

  # What `Octoroom.Agent.STT` and `Octoroom.Agent.TTS` share: finding a
  # provider module from a name, a module or a `"provider:model"` string, and
  # reading API keys.

  @doc """
  Finds the provider in `opts` (a keyword list or map).

  `:provider` is a registered name (`:soniox`, `"soniox"`) or a module that
  implements `behaviour`. Without one, a `:model` like `"soniox:stt-rt-v6"`
  names both. The provider's `default_options/0` fill in what `opts` leaves
  out. Returns the module and the merged options, without `:provider`.

  Nothing is picked for the caller: no provider is `{:no_provider, behaviour}`
  and no `:model` is `{:no_model, module}`. The built-in providers have no
  default model.
  """
  def resolve(opts, behaviour, registry) do
    opts = opts |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    opts = split_model(opts, registry)

    with {:ok, module} <- module(Map.get(opts, :provider), behaviour, registry) do
      defaults =
        if function_exported?(module, :default_options, 0), do: module.default_options(), else: []

      opts = Keyword.merge(defaults, opts |> Map.delete(:provider) |> Map.to_list())

      case Keyword.get(opts, :model) do
        model when is_binary(model) and model != "" -> {:ok, module, opts}
        _none -> {:error, {:no_model, module}}
      end
    end
  end

  @doc """
  Moves the provider out of a `"provider:model"` model, when the prefix is a
  registered provider: `%{model: "soniox:stt-rt-v6"}` becomes
  `%{provider: :soniox, model: "stt-rt-v6"}`. Other configs are unchanged.
  """
  def split_model(%{model: model} = config, registry) when is_binary(model) do
    with [prefix, id] <- String.split(model, ":", parts: 2),
         {name, _module} <-
           Enum.find(registry, fn {name, _} -> Atom.to_string(name) == prefix end) do
      %{config | model: id} |> Map.put(:provider, name)
    else
      _no_provider -> config
    end
  end

  def split_model(config, _registry), do: config

  @doc """
  Puts a `provider` argument into `opts`: `"soniox:stt-rt-v6"` as the model,
  `"soniox"`, `:soniox` or a module as the provider.
  """
  def with_provider(provider, opts) when is_binary(provider) do
    if String.contains?(provider, ":"),
      do: Keyword.put(opts, :model, provider),
      else: Keyword.put(opts, :provider, provider)
  end

  def with_provider(provider, opts), do: Keyword.put(opts, :provider, provider)

  @doc "The registered name for `provider`, or `provider` unchanged."
  def name(provider, registry) when is_binary(provider) do
    case Enum.find(registry, fn {name, _} -> Atom.to_string(name) == provider end) do
      {name, _module} -> name
      nil -> provider
    end
  end

  def name(provider, _registry), do: provider

  @doc """
  The built-in providers merged with those configured under `key`:

      config :octoroom_agents, tts_providers: [acme: MyApp.AcmeTTS]
  """
  def registry(builtin, key),
    do: Map.merge(builtin, Map.new(Application.get_env(:octoroom_agents, key, [])))

  @doc "`opts[:api_key]`, or the environment variable `env`."
  def api_key(opts, env) do
    case Keyword.get(opts, :api_key) || System.get_env(env) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _missing -> {:error, {:missing_env, env}}
    end
  end

  defp module(nil, behaviour, _registry), do: {:error, {:no_provider, behaviour}}

  defp module(provider, behaviour, registry) do
    case Map.fetch(registry, name(provider, registry)) do
      {:ok, module} ->
        # Loaded so `function_exported?/3` sees its optional callbacks.
        Code.ensure_loaded(module)
        {:ok, module}

      :error ->
        if is_atom(provider) and implements?(provider, behaviour),
          do: {:ok, provider},
          else: {:error, {:unknown_provider, behaviour, provider}}
    end
  end

  defp implements?(module, behaviour) do
    behaviours =
      if Code.ensure_loaded?(module),
        do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
        else: []

    behaviour in behaviours
  end
end
