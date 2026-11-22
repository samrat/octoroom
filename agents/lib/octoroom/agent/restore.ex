defmodule Octoroom.Agent.Restore do
  @moduledoc false

  alias Octoroom.Agent.ToolResult

  @transcript_items 50
  @transcript_chars 8_000

  @default_context_notice "[Reconnected] You were restarted in the middle of this call. Continue naturally from the conversation above."
  @default_context_notice_empty "[Reconnected] You were restarted in the middle of this call."
  @default_live_notice "You were restarted in the middle of this call. What was said before, oldest first:"
  @default_live_notice_empty "You were restarted in the middle of this call. Continue naturally."

  @defaults %{
    enabled?: true,
    history: true,
    tool_results: true,
    session: true,
    notice: true,
    prompt: false
  }

  def default_context_notice, do: @default_context_notice

  @doc """
  Normalizes the `:restore` option.

  Accepts `true` (default), `false`, or a keyword list / map with any of:
    * `:history` - restore prior conversation messages / transcript (default `true`)
    * `:tool_results` - restore completed tool call summaries (default `true`)
    * `:session` - reuse a saved live session handle, e.g. Gemini Live (default `true`)
    * `:notice` - insert a reconnect notice into the restored context: `true`
      (default wording), `false` / `nil` (omit), or a custom string
    * `:prompt` - cascaded only: automatically trigger a reply after restoring:
      `false` / `nil` (default, wait for the next turn), `true` (reply to the
      restored context/notice), or a custom prompt string
  """
  def normalize(nil), do: @defaults
  def normalize(true), do: @defaults

  def normalize(false),
    do: %{
      enabled?: false,
      history: false,
      tool_results: false,
      session: false,
      notice: false,
      prompt: false
    }

  def normalize(%{enabled?: enabled?} = cfg) when is_boolean(enabled?), do: cfg

  def normalize(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, [:history, :tool_results, :session, :notice, :prompt])
    opts |> Map.new() |> normalize()
  end

  def normalize(opts) when is_map(opts) do
    allowed = [:history, :tool_results, :session, :notice, :prompt]

    case Map.keys(opts) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown restore options: #{inspect(unknown)}"
    end

    cfg = Map.merge(@defaults, opts)
    validate!(cfg)
    cfg
  end

  def normalize(other) do
    raise ArgumentError,
          "restore expects a boolean or keyword list of [:history, :tool_results, :session, :notice, :prompt], got: #{inspect(other)}"
  end

  @doc """
  Filters a cascaded agent's saved `history` and optionally appends a reconnect
  notice according to `opts`.
  """
  def restore_history(saved_history, opts, restored? \\ nil)

  def restore_history(saved_history, opts, restored?) when is_list(saved_history) do
    cfg = normalize(opts)
    had_saved? = if is_boolean(restored?), do: restored?, else: saved_history != []

    if not cfg.enabled? or not had_saved? do
      []
    else
      filtered =
        Enum.filter(saved_history, fn msg ->
          tool? = Map.get(msg, :tool_result, false)
          if tool?, do: cfg.tool_results, else: cfg.history
        end)

      maybe_append_notice(filtered, cfg.notice)
    end
  end

  def restore_history(_none, _opts, _restored?), do: []

  @doc """
  Appends the saved conversation transcript, completed tool call summaries, and
  reconnect notice to `instructions` when a speech-to-speech session restarts
  without resuming server-side state.
  """
  def with_transcript(instructions, items, tool_results \\ [], opts \\ true, restarted? \\ false) do
    cfg = normalize(opts)

    if not cfg.enabled? do
      instructions
    else
      raw_items = if is_list(items), do: items, else: []
      raw_tools = if is_list(tool_results), do: tool_results, else: []
      had_saved? = restarted? or raw_items != [] or raw_tools != []

      kept_items = if cfg.history, do: raw_items, else: []
      kept_tools = if cfg.tool_results, do: raw_tools, else: []

      entries = merge_chronologically(kept_items, kept_tools)

      prefix =
        if is_binary(instructions) and instructions != "", do: instructions <> "\n\n", else: ""

      cond do
        entries != [] ->
          lines =
            entries
            |> Enum.map_join("\n", &format_entry/1)
            |> String.slice(-@transcript_chars, @transcript_chars)

          header =
            case cfg.notice do
              true -> @default_live_notice <> "\n"
              text when is_binary(text) and text != "" -> text <> "\n"
              _none -> ""
            end

          prefix <> header <> lines

        had_saved? ->
          case cfg.notice do
            true -> prefix <> @default_live_notice_empty
            text when is_binary(text) and text != "" -> prefix <> text
            _none -> instructions
          end

        true ->
          instructions
      end
    end
  end

  defp maybe_append_notice(history, false), do: history
  defp maybe_append_notice(history, nil), do: history
  defp maybe_append_notice(history, ""), do: history

  defp maybe_append_notice(history, notice) do
    text =
      case {notice, history} do
        {true, []} -> @default_context_notice_empty
        {true, _} -> @default_context_notice
        {custom, _} -> custom
      end

    case List.last(history) do
      %{content: ^text} -> history
      _ -> history ++ [%{role: "user", content: text}]
    end
  end

  defp merge_chronologically(items, tool_results) do
    (Enum.with_index(items, fn item, idx -> {:item, idx, item} end) ++
       Enum.with_index(tool_results, fn res, idx -> {:tool, idx, res} end))
    |> Enum.sort_by(&sort_key/1)
    |> Enum.take(-@transcript_items)
  end

  defp sort_key({:item, idx, %{at: at, role: "assistant"}}) when is_integer(at),
    do: {0, at, 2, idx}

  defp sort_key({:item, idx, %{at: at}}) when is_integer(at), do: {0, at, 0, idx}
  defp sort_key({:tool, idx, %{at: at}}) when is_integer(at), do: {0, at, 1, idx}
  defp sort_key({:item, idx, _item}), do: {1, 0, 0, idx}
  defp sort_key({:tool, idx, _res}), do: {1, 1, 0, idx}

  defp format_entry({:item, _idx, %{role: "assistant", text: text}}), do: "You: " <> text

  defp format_entry({:item, _idx, %{speaker: speaker, text: text}}) when is_binary(speaker),
    do: "[#{speaker}] " <> text

  defp format_entry({:item, _idx, %{text: text}}), do: "[someone] " <> text
  defp format_entry({:tool, _idx, res}), do: "[Tool] " <> ToolResult.format(res)

  defp validate!(cfg) do
    for key <- [:history, :tool_results, :session] do
      unless is_boolean(Map.fetch!(cfg, key)) do
        raise ArgumentError, "restore :#{key} must be a boolean, got: #{inspect(cfg[key])}"
      end
    end

    unless is_boolean(cfg.notice) or is_nil(cfg.notice) or is_binary(cfg.notice) do
      raise ArgumentError,
            "restore :notice must be a boolean, string, or nil, got: #{inspect(cfg.notice)}"
    end

    unless is_boolean(cfg.prompt) or is_nil(cfg.prompt) or is_binary(cfg.prompt) do
      raise ArgumentError,
            "restore :prompt must be a boolean, string, or nil, got: #{inspect(cfg.prompt)}"
    end
  end
end
