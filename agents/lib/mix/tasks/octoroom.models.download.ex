defmodule Mix.Tasks.Octoroom.Models.Download do
  @shortdoc "Downloads optional ONNX models for octoroom_agents"

  @moduledoc """
  Downloads and verifies optional ONNX models (currently Smart Turn v3.2) into
  the local cache directory, or into `--dir`.

      mix octoroom.models.download
      mix octoroom.models.download --dir /app/priv/models

  Useful in Dockerfiles and release builds when `auto_download_models: false`
  is set in production.
  """

  use Mix.Task

  alias Octoroom.Agent.Models

  @impl Mix.Task
  def run(args) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: [dir: :string])

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    {:ok, _} = Application.ensure_all_started(:req)

    opts = if dir = parsed[:dir], do: [models_dir: dir], else: []

    case Models.download_all(opts) do
      {:ok, paths} ->
        Enum.each(paths, fn {name, path} ->
          Mix.shell().info("#{name}: #{path}")
        end)

      {:error, reason} ->
        Mix.raise("Failed to download models: #{inspect(reason)}")
    end
  end
end
