# Octoroom Talking Points ("Unscripted Teleprompter")

A silent, real-time talking-points tracker powered by **Octoroom** (`voice: false`) and **Cloudflare Clef Flash** (`cloudflare/clef-flash` on OpenRouter)—with **no LLM and no TTS**.

Instead of reading a rigid script word-for-word, put your 5 bullet points on screen and talk naturally in any order. As each sentence finishes, Clef Flash evaluates **only the remaining unchecked points** in parallel and checks them off live with calibrated probabilities and the exact quote you said.

## How it works

```text
front (per mic): vad -> stt (AssemblyAI) -> turns
back:            rolling_window -> decisions (Clef Flash) -> tracker
```

- [lib/teleprompter/rolling_window.ex](lib/teleprompter/rolling_window.ex) — keeps a 3-utterance rolling context window so a point spread across multiple sentences still registers cleanly, while preserving the exact latest utterance for display.
- [lib/teleprompter/tracker.ex](lib/teleprompter/tracker.ex) — evaluates Clef Flash boolean probabilities against the threshold (default `72%`), checks off covered points, sends `Frames.UpdateStage` upstream to prune covered questions (dropping to zero API calls once every point is checked), and handles live add/remove/toggle/reset/preset edits without restarting the worker.
- [lib/teleprompter/agent.ex](lib/teleprompter/agent.ex) — `Octoroom.Agent` definition and built-in presets (*Octoroom Deploy Demo*, *Product Pitch*, *Sales Discovery BANT*).
- [lib/teleprompter.ex](lib/teleprompter.ex) — Phoenix LiveView checklist UI with live progress bar, partial-confidence meters, inline point editing, sensitivity slider, and live hearing log.

## Run it

Put your keys in `.env` here (or in your shell environment):

```sh
OPENROUTER_API_KEY=...        # Clef Flash boolean decisions
ASSEMBLY_AI_API_KEY=...       # Real-time speech-to-text
# Optional: use Cloudflare Realtime SFU instead of Octoroom.Cloudflare.Local
OCTOROOM_CLOUDFLARE_APP_ID=...
OCTOROOM_CLOUDFLARE_APP_SECRET=...
```

```sh
cd examples/teleprompter
OCTOROOM_LOCAL=1 mix deps.get
OCTOROOM_LOCAL=1 mix run --no-halt
```

Open <http://localhost:4360> and press **Start listening →**.

## Offline tests

```sh
cd examples/teleprompter
OCTOROOM_LOCAL=1 mix test
```
