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
  defframe(VADUserStartedSpeaking, :system, fields: [:source])
  defframe(VADUserStoppedSpeaking, :system, fields: [:source])
  defframe(UserStartedSpeaking, :system, fields: [:source])
  defframe(UserStoppedSpeaking, :system, fields: [:turn_id, :source])
  defframe(BotStartedSpeaking, :system)
  defframe(BotStoppedSpeaking, :system)

  # data: delivered in order; dropped by an interruption unless uninterruptible
  defframe(InterimTranscription, :data, fields: [:text, :source])
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
  # Text to speak.
  defframe(Text, :data, fields: [:text])
  # Text actually sent to TTS.
  defframe(TTSText, :data, fields: [:text])
  defframe(OutputAudio, :data, fields: [:audio, sample_rate: 24_000])
  # `spoke?`: the LLM said something before the calls (so no progress
  # message is needed).
  defframe(ToolCalls, :data, fields: [:calls, :continuation, :provider, spoke?: false])
  defframe(ToolResults, :data, fields: [:messages], uninterruptible: true)
  defframe(AsyncToolResult, :data, fields: [:result], uninterruptible: true)
  defframe(LLMContext, :data, fields: [:messages, :tools])

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
end
