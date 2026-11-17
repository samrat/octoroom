defmodule Octoroom.Agent.Frame do
  @moduledoc """
  Frames are the structs that processors pass to each other.

  Every frame has a category:

    * `:system` - handled before queued frames and never dropped by an
      interruption (for example `Interruption`, VAD events, input audio)
    * `:data` - delivered in order; dropped by an interruption unless the
      frame is marked `uninterruptible`
    * `:control` - like `:data`, for markers such as `LLMResponseStart`

  Every frame also has an `:id`, which the runner sets the first time the
  frame is pushed.

  Define a frame of your own with `use Octoroom.Agent.Frame`:

      defmodule MyApp.Frames.Sentiment do
        use Octoroom.Agent.Frame, category: :data, fields: [:label, score: 0.0]
      end

  Structs that don't `use Octoroom.Agent.Frame` can still be pushed; they count as
  interruptible `:data` frames.
  """

  @categories [:system, :data, :control]

  defmacro __using__(opts) do
    category = Keyword.get(opts, :category, :data)
    fields = Keyword.get(opts, :fields, [])
    uninterruptible = Keyword.get(opts, :uninterruptible, false)

    unless category in @categories do
      raise ArgumentError,
            "frame category must be one of #{inspect(@categories)}, got: #{inspect(category)}"
    end

    quote do
      defstruct [:id | unquote(fields)]

      @doc false
      def __frame__(:category), do: unquote(category)
      def __frame__(:uninterruptible), do: unquote(uninterruptible)
    end
  end

  @doc """
  Defines a frame module nested in the calling module.

      defframe Transcription, :data, fields: [:text], uninterruptible: true
  """
  defmacro defframe(name, category, opts \\ []) do
    opts = [category: category] ++ opts

    quote do
      defmodule unquote(name) do
        use Octoroom.Agent.Frame, unquote(opts)
      end
    end
  end

  @doc "The frame's category: `:system`, `:data` or `:control`."
  def category(%module{}) do
    if frame_module?(module), do: module.__frame__(:category), else: :data
  end

  @doc "True for system frames."
  def system?(frame), do: category(frame) == :system

  @doc """
  True if the frame is marked `uninterruptible`. An interruption keeps these
  frames queued, and doesn't kill tasks started while handling them. (System
  frames are never dropped either, but tasks started for them are killed.)
  """
  def uninterruptible?(%module{}) do
    frame_module?(module) and module.__frame__(:uninterruptible)
  end

  defp frame_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__frame__, 1)
  end
end
