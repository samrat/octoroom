defmodule Octoroom.Agent.Frames do
  @moduledoc """
  The frames built into agents. See `Octoroom.Agent.Frame` for the categories.

  `source` on audio, speaking and transcription frames names the input track
  they came from (the room's track name, such as `"<participant>/mic"`). It
  is `nil` for frames made outside a room, as in tests.
  """

  import Octoroom.Agent.Frame, only: [defframe: 2, defframe: 3]

  # system: handled before queued frames, never dropped by an interruption
  defframe(Start, :system, fields: [:session_id])
  defframe(Cancel, :system)
  defframe(Interruption, :system)
  defframe(Error, :system, fields: [:reason, :processor, fatal?: false])
  defframe(InputAudio, :system, fields: [:audio, :source, sample_rate: 16_000])

  defframe(InputImage, :system,
    fields: [
      :image,
      :source,
      mime_type: "image/jpeg",
      width: nil,
      height: nil,
      speaker: nil,
      track_source: nil
    ]
  )

  defframe(VideoInactive, :system, fields: [:source])
  defframe(VADUserStartedSpeaking, :system, fields: [:source])
  defframe(VADUserStoppedSpeaking, :system, fields: [:source])
  defframe(UserStartedSpeaking, :system, fields: [:source])
  defframe(UserStoppedSpeaking, :system, fields: [:turn_id, :source])
  defframe(BotStartedSpeaking, :system)
  defframe(BotStoppedSpeaking, :system)
  # The runner flushed the agent's output after an interruption:
  # `dropped_ms` of the audio it had queued never played (nil: unknown).
  # Tells `Octoroom.Agent.Processors.AssistantCollector` how much was heard.
  defframe(AudioFlushed, :system, fields: [:dropped_ms])

  # data: delivered in order; dropped by an interruption unless uninterruptible
  defframe(InterimTranscription, :data, fields: [:text, :source])
  # Speculative turn emitted at VAD silence using the latest interim transcript
  # so the LLM can start in parallel with STT finalization.
  defframe(PreemptiveTranscription, :data, fields: [:text, :source, speaker: nil])
  # `annotation`: text for the LLM only, put before the user's words (how
  # they sounded, for example); conversation events get just `text`.
  # `speaker`: who said it, shown to the LLM as `[speaker] text`.
  # `respond: false`: goes into the history without starting a reply.
  # `decision`: what a decision model made of the turn (see
  # `Octoroom.Agent.Processors.Decisions`). `UserAudio` takes the same three.
  defframe(Transcription, :data,
    fields: [
      :text,
      :turn_id,
      :source,
      speaker: nil,
      respond: true,
      decision: nil,
      annotation: nil
    ],
    uninterruptible: true
  )

  defframe(UserAudio, :data,
    fields: [
      :turn_id,
      :audio,
      :source,
      speaker: nil,
      respond: true,
      decision: nil,
      sample_rate: 16_000
    ],
    uninterruptible: true
  )

  defframe(LLMText, :data, fields: [:text])
  # A turn the app starts with `Octoroom.Agent.prompt/3`: not said by anyone
  # on the call.
  defframe(Prompt, :data, fields: [:text], uninterruptible: true)
  # Text to speak.
  defframe(Text, :data, fields: [:text])
  # Text actually sent to TTS.
  defframe(TTSText, :data, fields: [:text])
  defframe(OutputAudio, :data, fields: [:audio, sample_rate: 24_000])
  # `spoke?`: the LLM said something before the calls (so no progress
  # message is needed).
  defframe(ToolCalls, :data, fields: [:calls, :continuation, :provider, spoke?: false])
  defframe(ToolResults, :data, fields: [:messages, results: []], uninterruptible: true)
  defframe(AsyncToolResult, :data, fields: [:result], uninterruptible: true)
  defframe(LLMContext, :data, fields: [:messages, :tools])
  defframe(PreemptiveLLMContext, :data, fields: [:text, :messages, :tools])

  # A finished reply whose audio is still playing: the LLM sees it in
  # replies that start meanwhile. `AssistantMessage` replaces it once it's
  # known how much was heard.
  defframe(AssistantDraft, :data, fields: [:text], uninterruptible: true)

  defframe(AssistantMessage, :data,
    fields: [:text, interrupted?: false],
    uninterruptible: true
  )

  # control
  defframe(End, :control, uninterruptible: true)
  defframe(LLMResponseStart, :control)
  defframe(LLMResponseEnd, :control)
  defframe(TTSStarted, :control)
  defframe(TTSStopped, :control)
  # Sent upstream to ask the STT processor to finalize the transcript now.
  defframe(FinalizeTranscript, :control)
  # Makes the `switch` stage named `stage` use branch `branch`.
  defframe(SwitchBranch, :control, fields: [:stage, :branch])
  # Changes options of the stage named `stage`: the runner hands `opts` to
  # its `handle_update/2` instead of `handle_frame/3`, and the frame stops
  # there. Stages with other names pass it on. In an agent, one that leaves
  # the back end goes to every front end (see `Octoroom.Agent.Worker`).
  defframe(UpdateStage, :control, fields: [:stage, opts: []], uninterruptible: true)
end
