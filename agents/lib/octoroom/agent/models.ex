defmodule Octoroom.Agent.Models do
  @moduledoc """
  Downloads and caches optional ONNX models that are too large to bundle in
  the Hex package.

  Models are resolved in order:

    1. An explicit `:models_dir` option.
    2. `OCTOROOM_MODELS_DIR` or `config :octoroom_agents, :models_dir`.
    3. `priv/models/<filename>` if present locally.
    4. The OS user cache directory (`octoroom_agents/models`).

  On a cache miss, `ensure/2` downloads the file over HTTPS with `Req`,
  verifies its SHA-256 checksum, and atomically moves it into place. Set
  `config :octoroom_agents, auto_download_models: false` (or pass
  `download: false`) to disable runtime downloads and prefetch models ahead
  of time with `mix octoroom.models.download`.
  """

  require Logger

  @type name :: :smart_turn

  @manifest %{
    smart_turn: %{
      filename: "smart-turn-v3.2-cpu.onnx",
      url:
        "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/" <>
          "f766f81d3cfdf7737ac64aad813d91bbfd56bf93/smart-turn-v3.2-cpu.onnx",
      sha256: "2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f"
    }
  }

  @doc "Names of all models managed by this module."
  @spec names() :: [name()]
  def names, do: Map.keys(@manifest)

  @doc "Metadata (`filename`, `url`, `sha256`) for a managed model."
  @spec fetch!(name()) :: %{filename: String.t(), url: String.t(), sha256: String.t()}
  def fetch!(name), do: Map.fetch!(@manifest, name)

  @doc """
  Directory where downloaded models are cached.

  Checks `:models_dir` in `opts`, then `OCTOROOM_MODELS_DIR`, then
  `:octoroom_agents`'s `:models_dir` config, then the OS user cache directory
  (`octoroom_agents/models`).
  """
  @spec models_dir(keyword()) :: String.t()
  def models_dir(opts \\ []) do
    configured_dir(opts) ||
      Path.join(:filename.basedir(:user_cache, "octoroom_agents"), "models")
  end

  @doc """
  Path where `name` lives or will be cached.

  When no custom directory is configured, returns `priv/models/<filename>` if
  the file is present locally, otherwise `Path.join(models_dir(), filename)`.
  """
  @spec path(name(), keyword()) :: String.t()
  def path(name, opts \\ []) do
    %{filename: filename} = fetch!(name)

    case configured_dir(opts) do
      nil ->
        local = Application.app_dir(:octoroom_agents, Path.join("priv/models", filename))
        if File.regular?(local), do: local, else: Path.join(models_dir(), filename)

      dir ->
        Path.join(dir, filename)
    end
  end

  @doc """
  Returns `{:ok, path}` for `name`, downloading and verifying it if missing.

  Options:

    * `:models_dir` - override the cache directory
    * `:download` - override `:auto_download_models` (default `true`)
    * `:url`, `:sha256`, `:request_fun` - overrides for tests
  """
  @spec ensure(name(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(name, opts \\ []) do
    spec = fetch!(name)
    dest = path(name, opts)

    cond do
      File.regular?(dest) ->
        {:ok, dest}

      not download_enabled?(opts) ->
        {:error, {:model_missing, name, dest}}

      true ->
        download(name, spec, dest, opts)
    end
  end

  @doc "Ensures every managed model is present on disk."
  @spec download_all(keyword()) :: {:ok, %{name() => String.t()}} | {:error, term()}
  def download_all(opts \\ []) do
    Enum.reduce_while(names(), {:ok, %{}}, fn name, {:ok, acc} ->
      case ensure(name, opts) do
        {:ok, dest} -> {:cont, {:ok, Map.put(acc, name, dest)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp download(name, spec, dest, opts) do
    url = Keyword.get(opts, :url, spec.url)
    expected_sha = Keyword.get(opts, :sha256, spec.sha256)
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    File.mkdir_p!(Path.dirname(dest))
    tmp = "#{dest}.tmp.#{System.unique_integer([:positive])}"
    Logger.info("Downloading #{spec.filename} from #{url}")

    try do
      case request_fun.(url, into: File.stream!(tmp), receive_timeout: 120_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          verify_and_install(name, tmp, dest, expected_sha)

        {:ok, %{status: status}} ->
          File.rm(tmp)
          {:error, {:model_download_failed, name, status}}

        {:error, reason} ->
          File.rm(tmp)
          {:error, {:model_download_failed, name, reason}}
      end
    rescue
      error ->
        File.rm(tmp)
        {:error, {:model_download_failed, name, Exception.message(error)}}
    end
  end

  defp verify_and_install(name, tmp, dest, expected_sha) do
    actual_sha = sha256_file(tmp)

    if actual_sha == expected_sha do
      File.rename!(tmp, dest)
      {:ok, dest}
    else
      File.rm(tmp)
      {:error, {:model_checksum_mismatch, name, expected_sha, actual_sha}}
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp configured_dir(opts) do
    non_empty(Keyword.get(opts, :models_dir)) ||
      non_empty(System.get_env("OCTOROOM_MODELS_DIR")) ||
      non_empty(Application.get_env(:octoroom_agents, :models_dir))
  end

  defp download_enabled?(opts) do
    Keyword.get(
      opts,
      :download,
      Application.get_env(:octoroom_agents, :auto_download_models, true)
    )
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(val), do: val
end
