defmodule Octoroom.Test.FakePeerMedia do
  @moduledoc false

  # `Octoroom.Peer.Media` with no peer connection: SDP is placeholder text,
  # and media moves as PCM through `Octoroom.Test.FakeCloudflare`. An
  # outlet's sink pushes its frames into the fake (`ingest/4`), and frames
  # the fake sends this session arrive as `{:fake_media, session, mid,
  # frame}`, under the pulled track's mid. The connection is up once the
  # first negotiation completes.

  @behaviour Octoroom.Peer.Media

  alias Octoroom.Test.FakeCloudflare

  @impl true
  def init(%{cloudflare: %{fake: fake}}),
    do: {:ok, %{fake: fake, session: nil, n: 0, connected: false}}

  @impl true
  def session_created(state, session) do
    FakeCloudflare.register_media(state.fake, session, self())
    %{state | session: session}
  end

  @impl true
  def offer_sendonly(state, n) do
    {fake, session} = {state.fake, state.session}

    slots =
      for i <- 1..n do
        mid = "out#{state.n + i}"
        %{mid: mid, sink: {:pcm, &FakeCloudflare.ingest(fake, session, mid, &1)}}
      end

    {:ok, "offer", slots, %{state | n: state.n + n}}
  end

  @impl true
  def apply_answer(state, _sdp), do: {:ok, connect(state)}

  @impl true
  def answer_offer(state, _sdp), do: {:ok, "answer", %{}, state}

  @impl true
  def renegotiated(state), do: connect(state)

  @impl true
  def stop_and_offer(state, _mids), do: {:ok, "close offer", state}

  @impl true
  def handle_info({:fake_media, _session, mid, frame}, _state), do: {:input, mid, {:pcm, frame}}
  def handle_info(:fake_connected, state), do: {:connected, state}
  def handle_info(_message, state), do: {:ignore, state}

  @impl true
  def close(_state), do: :ok

  defp connect(%{connected: true} = state), do: state

  defp connect(state) do
    send(self(), :fake_connected)
    %{state | connected: true}
  end
end
