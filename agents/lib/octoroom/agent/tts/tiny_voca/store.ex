defmodule Octoroom.Agent.TTS.TinyVoca.Store do
  @moduledoc false

  # Downloads and caches `n4ze3m/tiny-voca` ONNX model + phonemizer files on
  # demand, and shares loaded ONNX sessions and phonemizer data across processes
  # via `:persistent_term`.

  require Logger

  alias Octoroom.Agent.TTS.TinyVoca.Dizione

  @default_base_url "https://huggingface.co/n4ze3m/tiny-voca/resolve/main"

  @files [
    "onnx/model.onnx",
    "phonemizer/lexicon.tsv",
    "phonemizer/align.json",
    "phonemizer/homographs.json",
    "phonemizer/g2p.json",
    "phonemizer/g2p.npz"
  ]

  def files, do: @files

  @doc """
  Directory where tiny-voca weights and phonemizer files are cached.

  Checks `:model_dir` in `opts`, then `TINY_VOCA_DIR`, then
  `:octoroom_agents`'s `:tiny_voca_dir` config, then the OS user cache
  directory (`octoroom_agents/tiny_voca`).
  """
  def model_dir(opts \\ []) do
    Keyword.get(opts, :model_dir) ||
      non_empty(System.get_env("TINY_VOCA_DIR")) ||
      Application.get_env(:octoroom_agents, :tiny_voca_dir) ||
      Path.join(:filename.basedir(:user_cache, "octoroom_agents"), "tiny_voca")
  end

  @doc """
  Loads (downloading on demand unless `download: false`) and caches the
  `%{model: OnnxRuntime.Model.t(), phonemizer: Dizione.t()}` bundle for `dir`.
  """
  def load(opts \\ []) do
    dir = Path.expand(model_dir(opts))
    key = {__MODULE__, dir}

    case :persistent_term.get(key, nil) do
      %{} = loaded ->
        {:ok, loaded}

      nil ->
        with :ok <- ensure_files(dir, opts),
             {:ok, loaded} <- load_from_disk(dir) do
          :persistent_term.put(key, loaded)
          {:ok, loaded}
        end
    end
  end

  @doc false
  def ensure_files(dir, opts \\ []) do
    download? = Keyword.get(opts, :download, true)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    request_fun = Keyword.get(opts, :request_fun, &Req.get/2)

    Enum.reduce_while(@files, :ok, fn relpath, :ok ->
      dest = Path.join(dir, relpath)

      cond do
        File.regular?(dest) ->
          {:cont, :ok}

        not download? ->
          {:halt, {:error, {:tiny_voca_model_missing, dest}}}

        true ->
          case download_file(base_url, relpath, dest, request_fun) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp download_file(base_url, relpath, dest, request_fun) do
    url = String.trim_trailing(base_url, "/") <> "/" <> relpath
    File.mkdir_p!(Path.dirname(dest))
    tmp = "#{dest}.tmp.#{System.unique_integer([:positive])}"
    Logger.info("Downloading tiny-voca asset #{relpath} from #{url}")

    try do
      case request_fun.(url, into: File.stream!(tmp), receive_timeout: 120_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          File.rename!(tmp, dest)
          :ok

        {:ok, %{status: status}} ->
          File.rm(tmp)
          {:error, {:tiny_voca_download_failed, relpath, status}}

        {:error, reason} ->
          File.rm(tmp)
          {:error, {:tiny_voca_download_failed, relpath, reason}}
      end
    rescue
      error ->
        File.rm(tmp)
        {:error, {:tiny_voca_download_failed, relpath, Exception.message(error)}}
    end
  end

  defp load_from_disk(dir) do
    onnx_path = Path.join(dir, "onnx/model.onnx")
    phonemizer_dir = Path.join(dir, "phonemizer")

    try do
      model = OnnxRuntime.load(onnx_path)
      phonemizer = Dizione.load(phonemizer_dir)
      {:ok, %{model: model, phonemizer: phonemizer}}
    rescue
      error -> {:error, {:tiny_voca_load_failed, Exception.message(error)}}
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(val), do: val
end
