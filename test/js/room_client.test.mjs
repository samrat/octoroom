// Tests for the browser client's half of the signaling protocol, run under
// Node with a fake Phoenix channel and a fake RTCPeerConnection (see
// fakes.mjs). The test plays the server: it answers the client's pushes
// and sends the server's messages.
//
//   node --test "test/js/*.test.mjs"      (or: mix test.js)

import assert from "node:assert/strict"
import {beforeEach, describe, test} from "node:test"

import {RoomClient} from "../../priv/static/octoroom.mjs"
import {
  FakePeerConnection,
  FakeSocket,
  FakeStream,
  FakeTrack,
  installBrowser,
  remoteOffer,
  settle,
} from "./fakes.mjs"

const ALICE = {id: "p1", meta: {name: "alice"}, tracks: {}}
const BOB = {id: "p2", meta: {name: "bob"}, tracks: {}}
const ICE_SERVERS = [{urls: "stun:stun.example"}]

const BOB_MIC = {mid: "1", track: "p2/mic", kind: "audio", source: "mic", participant_id: "p2", gain: 0.5}
const BOB_CAMERA = {mid: "2", track: "p2/camera", kind: "video", source: "camera", participant_id: "p2", gain: 1}

let browser

beforeEach(() => {
  browser = installBrowser()
})

function joinReply(extra = {}) {
  return {
    participant_id: "p1",
    participants: [ALICE],
    ice_servers: ICE_SERVERS,
    resume_token: "token-1",
    ...extra,
  }
}

// A client, with everything it emits recorded in `events`.
function client(options = {}) {
  const socket = new FakeSocket()
  const room = new RoomClient({socket, topic: "room:1", params: {name: "alice"}, ...options})
  const events = []
  const names = ["state", "participants", "tracks", "local", "error", "left", "connection"]
  for (const name of [...names, "reconnecting", "reconnected", "room_event"]) {
    room.on(name, (payload) => events.push([name, payload]))
  }
  const emitted = (name) => events.filter(([n]) => n === name).map(([, payload]) => payload)
  return {socket, room, events, emitted}
}

// A client that has joined: the server accepted the join and the publish.
async function join(options = {}) {
  const ctx = client(options)
  const joining = ctx.room.join()
  const channel = ctx.socket.channels[0]
  channel.joinPush.reply("ok", joinReply())
  ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
  ;(await channel.next("connected")).reply("ok", {})
  await joining
  return {...ctx, channel, pc: FakePeerConnection.last}
}

// The server pulls tracks into the client's session: Cloudflare's offer,
// the client's answer, then which mid is which track.
async function pull({channel}, tracks, opId = "pull") {
  const sdp = remoteOffer(Object.fromEntries(tracks.map((t) => [t.mid, t.kind])))
  channel.emit("renegotiate", {op_id: opId, sdp})
  ;(await channel.next("answer")).reply("ok", {})
  channel.emit("tracks", {added: tracks, removed: []})
  await settle()
}

// The client publishes more, and the server takes it through its queue.
async function publishMore({room, channel}, tracks, options) {
  const publishing = room.publish(tracks, options)
  const request = await channel.next("publish_tracks")
  channel.emit("push", {op_id: "push", sources: request.payload.sources})
  ;(await channel.next("push_offer")).reply("ok", {sdp: "cf-answer-push"})
  ;(await channel.next("connected")).reply("ok", {})
  request.reply("ok", {})
  await publishing
}

describe("joining", () => {
  test("joins the channel, publishes the mic and says when it's connected", async () => {
    const {room, channel, pc, emitted} = await join()

    assert.equal(channel.topic, "room:1")
    assert.deepEqual(channel.joinPush.payload, {name: "alice"})
    assert.deepEqual(browser.devices.userMediaCalls, [{audio: true, video: false}])

    assert.deepEqual(pc.config, {iceServers: ICE_SERVERS, bundlePolicy: "max-bundle"})
    const [mic] = browser.devices.streams[0].getAudioTracks()
    assert.equal(pc.mid("0").sender.track, mic)
    assert.equal(pc.mid("0").direction, "sendonly")

    assert.deepEqual(pc.calls, ["createOffer", "setLocalDescription:offer", "setRemoteDescription:answer"])
    assert.deepEqual(pc.remoteDescription, {type: "answer", sdp: "cf-answer"})
    assert.deepEqual(
      channel.pushes.map((p) => p.event),
      ["publish", "connected"],
    )
    assert.deepEqual(channel.pushed("publish"), [{sdp: "offer-1", mids: {mic: "0"}}])

    assert.equal(room.participantId, "p1")
    assert.deepEqual(emitted("state"), ["joining", "joined"])
    assert.deepEqual(emitted("participants"), [[ALICE]])
    assert.deepEqual(emitted("connection"), ["connected"])
    assert.deepEqual(room.localTracks(), {mic: {track: mic, muted: false}})
  })

  test("with video, asks for mic and camera at once and publishes both", async () => {
    const {channel} = await join({video: true})

    assert.deepEqual(browser.devices.userMediaCalls, [{audio: true, video: true}])
    assert.deepEqual(channel.pushed("publish"), [{sdp: "offer-1", mids: {mic: "0", camera: "1"}}])
  })

  test("publishes a stream it's given, without asking for the mic", async () => {
    const audio = new FakeTrack("audio")
    const {pc} = await join({stream: new FakeStream([audio])})

    assert.deepEqual(browser.devices.userMediaCalls, [])
    assert.equal(pc.mid("0").sender.track, audio)
  })

  test("says connected only once the peer connection is up", async () => {
    FakePeerConnection.autoConnect = false
    const {room, socket} = client()
    const joining = room.join()
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    await settle()
    assert.deepEqual(channel.pushed("connected"), [])

    FakePeerConnection.last.setConnectionState("connecting")
    FakePeerConnection.last.setConnectionState("connected")
    ;(await channel.next("connected")).reply("ok", {})
    await joining
    assert.equal(room.state, "joined")
  })

  test("can't join twice", async () => {
    const {room} = await join()
    await assert.rejects(room.join(), /can't join while joined/)
  })

  test("a refused join fails with the server's reason and leaves the channel", async () => {
    const {room, socket, emitted} = client()
    const failed = assert.rejects(room.join(), /room_full/)
    const channel = socket.channels[0]
    channel.joinPush.reply("error", {reason: "room_full"})
    await failed

    assert.equal(channel.left, true)
    assert.equal(room.state, "idle")
    assert.deepEqual(emitted("left"), ["failed"])
    assert.deepEqual(browser.devices.userMediaCalls, [])
  })

  test("a join that times out fails", async () => {
    const {room, socket} = client()
    const failed = assert.rejects(room.join(), /join timed out/)
    socket.channels[0].joinPush.reply("timeout")
    await failed
    assert.equal(room.state, "idle")
  })

  test("a denied mic fails the join and leaves the channel", async () => {
    browser.devices.denied = true
    const {room, socket} = client()
    const failed = assert.rejects(room.join(), /Permission denied/)
    socket.channels[0].joinPush.reply("ok", joinReply())
    await failed

    assert.equal(socket.channels[0].left, true)
    assert.equal(FakePeerConnection.instances.length, 0)
  })

  test("a stream with no tracks fails the join", async () => {
    const {room, socket} = client({stream: new FakeStream([])})
    const failed = assert.rejects(room.join(), /nothing to publish/)
    socket.channels[0].joinPush.reply("ok", joinReply())
    await failed
  })

  test("a refused publish fails the join, closes the connection and frees the mic", async () => {
    const {room, socket} = client()
    const failed = assert.rejects(room.join(), /not_allowed/)
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    ;(await channel.next("publish")).reply("error", {reason: "not_allowed"})
    await failed

    assert.equal(FakePeerConnection.last.closed, true)
    assert.equal(browser.devices.streams[0].getAudioTracks()[0].readyState, "ended")
    assert.equal(channel.left, true)
    assert.equal(room.state, "idle")
  })

  test("a peer connection that fails to connect fails the join", async () => {
    FakePeerConnection.autoConnect = false
    const {room, socket} = client()
    const failed = assert.rejects(room.join(), /connection to Cloudflare failed/)
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    await settle()
    FakePeerConnection.last.setConnectionState("failed")
    await failed

    assert.deepEqual(channel.pushed("connected"), [])
  })

  test("a peer connection that never connects fails the join after 15 s", async (t) => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    FakePeerConnection.autoConnect = false
    const {room, socket} = client()
    const failed = assert.rejects(room.join(), /connection to Cloudflare timed out/)
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    await settle()

    t.mock.timers.tick(14_999)
    await settle()
    assert.equal(room.state, "joining")
    t.mock.timers.tick(1)
    await failed
  })

  test("sends the offer at its first ICE candidate, without waiting for gathering to finish", async () => {
    FakePeerConnection.iceGatheringState = "gathering"
    const {room, socket} = client()
    const joining = room.join()
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    await settle()
    const pc = FakePeerConnection.last
    assert.deepEqual(pc.calls, ["createOffer", "setLocalDescription:offer"])
    assert.deepEqual(channel.pushed("publish"), [])

    pc.addCandidate()
    const publish = await channel.next("publish")
    assert.match(publish.payload.sdp, /^offer-1\r\na=candidate:1 /)
    assert.equal(pc.iceGatheringState, "gathering")
    publish.reply("ok", {sdp: "cf-answer"})
    const connected = await channel.next("connected")
    assert.equal(connected.payload.timings.ice_timed_out, false)
    connected.reply("ok", {})
    await joining
  })

  test("sends the offer once gathering finishes, even with no candidate", async () => {
    FakePeerConnection.iceGatheringState = "gathering"
    const {room, socket} = client()
    const joining = room.join()
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    await settle()

    FakePeerConnection.last.setIceGatheringState("complete")
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    ;(await channel.next("connected")).reply("ok", {})
    await joining
  })

  test("tells the server and the app how long each step of the join took", async () => {
    const {room, socket} = client()
    const timings = []
    room.on("timings", (t) => timings.push(t))
    const joining = room.join()
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    const connected = await channel.next("connected")
    connected.reply("ok", {})
    await joining

    const sent = connected.payload.timings
    assert.deepEqual(Object.keys(sent).sort(), [
      "connect_ms",
      "ice_ms",
      "ice_timed_out",
      "join_ms",
      "media_ms",
      "publish_ms",
    ])
    for (const [key, value] of Object.entries(sent)) {
      if (key !== "ice_timed_out") assert.ok(Number.isInteger(value) && value >= 0, `${key}: ${value}`)
    }
    assert.equal(sent.ice_timed_out, false)
    assert.deepEqual(timings, [sent])
  })

  test("sends the offer after 100 ms if no ICE candidate has come", async (t) => {
    t.mock.timers.enable({apis: ["setTimeout"]})
    FakePeerConnection.iceGatheringState = "gathering"
    const {room, socket} = client()
    const joining = room.join()
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    await settle()

    t.mock.timers.tick(99)
    await settle()
    assert.deepEqual(channel.pushed("publish"), [])
    t.mock.timers.tick(1)
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    const connected = await channel.next("connected")
    assert.equal(connected.payload.timings.ice_timed_out, true)
    connected.reply("ok", {})
    await joining
  })
})

describe("leaving while joining", () => {
  test("before the join reply: the join fails at once, and tears down once", async () => {
    const {room, socket, emitted} = client()
    const failed = assert.rejects(room.join(), /left while joining/)
    await room.leave()
    await failed

    assert.equal(socket.channels[0].left, true)
    assert.equal(room.state, "idle")
    assert.deepEqual(emitted("left"), ["left"])
    assert.deepEqual(browser.devices.userMediaCalls, [])
  })

  test("at the mic prompt: the devices are turned off when the prompt is answered", async () => {
    browser.devices.prompting = true
    const {room, socket, emitted} = client({video: true})
    const failed = assert.rejects(room.join(), /left while joining/)
    socket.channels[0].joinPush.reply("ok", joinReply())
    await settle()
    assert.equal(browser.devices.userMediaCalls.length, 1)

    await room.leave()
    await failed
    browser.devices.allow()
    await settle()

    const [stream] = browser.devices.streams
    assert.deepEqual(
      stream.getTracks().map((t) => t.readyState),
      ["ended", "ended"],
    )
    assert.equal(FakePeerConnection.instances.length, 0)
    assert.deepEqual(room.localTracks(), {})
    assert.deepEqual(emitted("left"), ["left"])
    assert.equal(room.state, "idle")
  })

  test("while publishing: closes the connection and frees the mic", async () => {
    const {room, socket, emitted} = client()
    const failed = assert.rejects(room.join(), /left while joining/)
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", joinReply())
    const publish = await channel.next("publish")

    await room.leave()
    await failed
    // The server's answer arrives after the client has gone.
    publish.reply("ok", {sdp: "cf-answer"})
    await settle()

    assert.equal(FakePeerConnection.last.closed, true)
    assert.equal(browser.devices.streams[0].getAudioTracks()[0].readyState, "ended")
    assert.deepEqual(channel.pushed("connected"), [])
    assert.deepEqual(emitted("left"), ["left"])
    assert.deepEqual(emitted("error"), [])
    assert.equal(room.state, "idle")
  })

  test("a join started right after isn't torn down by the one that was left", async () => {
    const {room, socket, emitted} = client()
    const failed = assert.rejects(room.join(), /left while joining/)
    room.leave()
    const joining = room.join()
    await failed

    const channel = socket.channels[1]
    channel.joinPush.reply("ok", joinReply())
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    ;(await channel.next("connected")).reply("ok", {})
    await joining

    assert.equal(room.state, "joined")
    assert.equal(channel.left, false)
    assert.deepEqual(emitted("left"), ["left"])
  })
})

describe("what the server pulls", () => {
  test("answers Cloudflare's offer, then plays the audio and lists the tracks", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    const sdp = remoteOffer({1: "audio", 2: "video"})

    channel.emit("renegotiate", {op_id: "op-1", sdp})
    const answer = await channel.next("answer")
    assert.deepEqual(answer.payload, {op_id: "op-1", sdp: `answer-to:${sdp}`})
    assert.deepEqual(pc.calls.slice(3), ["setRemoteDescription:offer", "createAnswer", "setLocalDescription:answer"])

    // Which mid is which track waits for the exchange to finish.
    channel.emit("tracks", {added: [BOB_MIC, BOB_CAMERA], removed: []})
    await settle()
    assert.deepEqual(room.tracks(), [])
    answer.reply("ok", {})
    await settle()

    const [audio] = browser.body.children
    assert.equal(browser.body.children.length, 1)
    assert.equal(audio.tag, "audio")
    assert.equal(audio.autoplay, true)
    assert.equal(audio.played, true)
    assert.equal(audio.volume, 0.5)
    assert.equal(audio.style.display, "none")
    assert.equal(audio.dataset.octoroomMid, "1")
    assert.deepEqual(audio.srcObject.tracks, [pc.mid("1").receiver.track])

    const [mic, camera] = room.tracks()
    assert.deepEqual({...mic, stream: null}, {...BOB_MIC, stream: null})
    assert.deepEqual({...camera, stream: null}, {...BOB_CAMERA, stream: null})
    // Video is the app's to show: a stream, and no element.
    assert.deepEqual(camera.stream.tracks, [pc.mid("2").receiver.track])
    assert.deepEqual(ctx.emitted("tracks").at(-1), room.tracks())
  })

  test("ignores a track whose mid it doesn't have", async () => {
    const {room, channel} = await join()
    channel.emit("tracks", {added: [BOB_MIC], removed: []})
    await settle()

    assert.deepEqual(room.tracks(), [])
    assert.deepEqual(browser.body.children, [])
  })

  test("a gain change sets the element's volume", async () => {
    const ctx = await join()
    await pull(ctx, [BOB_MIC])

    ctx.channel.emit("gain", {mid: "1", gain: 0.2})
    assert.equal(browser.body.children[0].volume, 0.2)
    assert.equal(ctx.room.tracks()[0].gain, 0.2)
    assert.equal(ctx.emitted("tracks").at(-1)[0].gain, 0.2)

    const before = ctx.emitted("tracks").length
    ctx.channel.emit("gain", {mid: "9", gain: 0.2})
    assert.equal(ctx.emitted("tracks").length, before)
  })

  test("a removed track stops playing", async () => {
    const ctx = await join()
    await pull(ctx, [BOB_MIC, BOB_CAMERA])
    const [audio] = browser.body.children

    ctx.channel.emit("tracks", {added: [], removed: ["1", "7"]})
    await settle()

    assert.deepEqual(browser.body.children, [])
    assert.equal(audio.srcObject, null)
    assert.deepEqual(
      ctx.room.tracks().map((t) => t.track),
      ["p2/camera"],
    )
  })

  test("closes the transceivers the server names and offers the result", async () => {
    const ctx = await join()
    const {channel, pc} = ctx
    await pull(ctx, [BOB_MIC, BOB_CAMERA])

    channel.emit("close", {op_id: "op-2", mids: ["1"]})
    const offer = await channel.next("close_offer")
    assert.deepEqual(offer.payload, {op_id: "op-2", sdp: "offer-2"})
    assert.equal(pc.mid("1").stopped, true)
    assert.equal(pc.mid("2").stopped, false)
    assert.equal(pc.mid("0").stopped, false)

    offer.reply("ok", {sdp: "cf-answer-2"})
    await settle()
    assert.deepEqual(pc.remoteDescription, {type: "answer", sdp: "cf-answer-2"})
    assert.equal(pc.signalingState, "stable")
  })

  test("runs one exchange at a time", async () => {
    const ctx = await join()
    const {channel, pc} = ctx
    await pull(ctx, [BOB_MIC])

    channel.emit("renegotiate", {op_id: "op-2", sdp: remoteOffer({2: "video"})})
    channel.emit("close", {op_id: "op-3", mids: ["1"]})
    const answer = await channel.next("answer")
    await settle()
    // The close hasn't started: the answer is still out.
    assert.equal(pc.mid("1").stopped, false)
    assert.deepEqual(channel.pushed("close_offer"), [])

    answer.reply("ok", {})
    const offer = await channel.next("close_offer")
    assert.equal(offer.payload.op_id, "op-3")
    assert.equal(pc.mid("1").stopped, true)
  })

  test("a failed exchange is reported and the next one still runs", async () => {
    const ctx = await join()
    const {channel, pc} = ctx

    pc.fail("setRemoteDescription", new Error("bad sdp"))
    channel.emit("renegotiate", {op_id: "op-1", sdp: remoteOffer({1: "audio"})})
    await settle()
    assert.deepEqual(
      ctx.emitted("error").map((e) => e.message),
      ["bad sdp"],
    )
    assert.deepEqual(channel.pushed("answer"), [])

    channel.emit("renegotiate", {op_id: "op-2", sdp: remoteOffer({1: "audio"})})
    assert.equal((await channel.next("answer")).payload.op_id, "op-2")
  })

  test("an answer the server refuses is reported", async () => {
    const ctx = await join()
    ctx.channel.emit("renegotiate", {op_id: "op-1", sdp: remoteOffer({1: "audio"})})
    ;(await ctx.channel.next("answer")).reply("error", {reason: "stale_op"})
    await settle()

    assert.deepEqual(
      ctx.emitted("error").map((e) => e.message),
      ["stale_op"],
    )
  })

  test("a reset keeps what's unchanged playing and drops the rest", async () => {
    const ctx = await join()
    const other = {mid: "3", track: "p3/mic", kind: "audio", source: "mic", participant_id: "p3", gain: 1}
    await pull(ctx, [BOB_MIC, BOB_CAMERA, other])
    const [bobAudio] = browser.body.children

    // Bob's mic is unchanged, mid 2 now carries another track, and p3's mic
    // isn't mentioned.
    const moved = {...BOB_CAMERA, track: "p3/camera", participant_id: "p3"}
    ctx.channel.emit("tracks", {added: [BOB_MIC, moved], removed: [], reset: true})
    await settle()

    assert.deepEqual(browser.body.children, [bobAudio])
    assert.notEqual(bobAudio.srcObject, null)
    assert.deepEqual(
      ctx.room.tracks().map((t) => [t.mid, t.track]),
      [
        ["1", "p2/mic"],
        ["2", "p3/camera"],
      ],
    )
  })
})

describe("publishing more", () => {
  test("asks the server, then offers the track when the server says it's its turn", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    const camera = new FakeTrack("video")

    const publishing = room.publish({camera})
    const request = await channel.next("publish_tracks")
    assert.deepEqual(request.payload, {sources: ["camera"]})
    assert.deepEqual(Object.keys(room.localTracks()), ["mic", "camera"])
    // Nothing is offered until the server asks.
    assert.equal(pc.getTransceivers().length, 1)

    channel.emit("push", {op_id: "op-2", sources: ["camera"]})
    const offer = await channel.next("push_offer")
    assert.deepEqual(offer.payload, {op_id: "op-2", sdp: "offer-2", mids: {camera: "1"}})
    assert.equal(pc.mid("1").sender.track, camera)
    assert.equal(pc.mid("1").direction, "sendonly")

    offer.reply("ok", {sdp: "cf-answer-2"})
    ;(await channel.next("connected")).reply("ok", {})
    assert.deepEqual(pc.remoteDescription, {type: "answer", sdp: "cf-answer-2"})

    request.reply("ok", {})
    await publishing
    assert.deepEqual(room.localTracks().camera, {track: camera, muted: false})
  })

  test("a refused request unpublishes the track and stops the camera it opened", async () => {
    const {room, channel, emitted} = await join()

    const failed = assert.rejects(room.startCamera(), /not_allowed/)
    ;(await channel.next("publish_tracks")).reply("error", {reason: "not_allowed"})
    await failed

    assert.deepEqual(browser.devices.userMediaCalls.at(-1), {video: true})
    assert.equal(browser.devices.streams.at(-1).getVideoTracks()[0].readyState, "ended")
    assert.deepEqual(Object.keys(room.localTracks()), ["mic"])
    assert.deepEqual(Object.keys(emitted("local").at(-1)), ["mic"])
  })

  test("a track it was given isn't stopped when unpublished", async () => {
    const ctx = await join()
    const camera = new FakeTrack("video")
    const starting = ctx.room.startCamera(camera)
    const request = await ctx.channel.next("publish_tracks")
    assert.deepEqual(request.payload, {sources: ["camera"]})
    request.reply("ok", {})
    await starting

    const stopping = ctx.room.stop("camera")
    ;(await ctx.channel.next("unpublish")).reply("ok", {})
    await stopping
    assert.equal(camera.readyState, "live")
  })

  test("can't publish before joining, or a source twice", async () => {
    const idle = client()
    await assert.rejects(idle.room.publish({camera: new FakeTrack("video")}), /can't publish while idle/)

    const {room, channel} = await join()
    await assert.rejects(room.publish({mic: new FakeTrack("audio")}), /mic is already published/)
    assert.deepEqual(channel.pushed("publish_tracks"), [])
  })

  test("a track that ended while queued gets an empty transceiver of its kind", async () => {
    const {room, channel, pc} = await join()
    const screen = new FakeTrack("video")
    const audio = new FakeTrack("audio")
    room.publish({screen, screen_audio: audio}).catch(() => {})
    await channel.next("publish_tracks")
    screen.stop()
    audio.stop()

    channel.emit("push", {op_id: "op-2", sources: ["screen", "screen_audio"]})
    const offer = await channel.next("push_offer")
    assert.deepEqual(offer.payload.mids, {screen: "1", screen_audio: "2"})
    assert.equal(pc.mid("1").sender.track, null)
    assert.equal(pc.mid("1").receiver.track.kind, "video")
    assert.equal(pc.mid("2").sender.track, null)
    assert.equal(pc.mid("2").receiver.track.kind, "audio")
  })

  test("a refused offer is rolled back and reported", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    room.publish({camera: new FakeTrack("video")}).catch(() => {})
    await channel.next("publish_tracks")

    channel.emit("push", {op_id: "op-2", sources: ["camera"]})
    ;(await channel.next("push_offer")).reply("error", {reason: "stale_op"})
    await settle()

    assert.equal(pc.calls.at(-1), "setLocalDescription:rollback")
    assert.equal(pc.signalingState, "stable")
    assert.equal(pc.mid("1").stopped, true)
    assert.deepEqual(
      ctx.emitted("error").map((e) => e.message),
      ["stale_op"],
    )
    // Only the join's: nothing new flows.
    assert.equal(channel.pushed("connected").length, 1)
  })

  test("stopping a source stops sending, frees the device and tells the server", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    const starting = room.startCamera({width: 640})
    const request = await channel.next("publish_tracks")
    channel.emit("push", {op_id: "push", sources: ["camera"]})
    ;(await channel.next("push_offer")).reply("ok", {sdp: "cf-answer-push"})
    ;(await channel.next("connected")).reply("ok", {})
    request.reply("ok", {})
    await starting
    assert.deepEqual(browser.devices.userMediaCalls.at(-1), {video: {width: 640}})
    const [camera] = browser.devices.streams.at(-1).getVideoTracks()

    const stopping = room.stop("camera")
    const unpublish = await channel.next("unpublish")
    assert.deepEqual(unpublish.payload, {source: "camera"})
    assert.equal(pc.mid("1").sender.track, null)
    assert.equal(camera.readyState, "ended")
    assert.deepEqual(Object.keys(room.localTracks()), ["mic"])
    // The server closes the transceiver, once nobody pulls the track.
    assert.equal(pc.mid("1").stopped, false)

    unpublish.reply("ok", {})
    await stopping
    await room.stop("camera")
    assert.equal(channel.pushed("unpublish").length, 1)
  })

  test("a screen share publishes the screen and its audio, and ends with the browser's button", async () => {
    const {room, channel} = await join()

    const sharing = room.shareScreen()
    const request = await channel.next("publish_tracks")
    assert.deepEqual(browser.devices.displayMediaCalls, [{video: true, audio: true}])
    assert.deepEqual(request.payload, {sources: ["screen", "screen_audio"]})
    request.reply("ok", {})
    await sharing

    const stream = browser.devices.streams.at(-1)
    stream.getVideoTracks()[0].end()
    const stopped = [await channel.next("unpublish"), await channel.next("unpublish")]
    assert.deepEqual(stopped.map((p) => p.payload.source).sort(), ["screen", "screen_audio"])
    assert.equal(stream.getAudioTracks()[0].readyState, "ended")
    assert.deepEqual(Object.keys(room.localTracks()), ["mic"])
  })

  test("a screen share without audio publishes only the screen", async () => {
    browser.devices.display = {video: true, audio: false}
    const {room, channel} = await join()

    room.shareScreen().catch(() => {})
    assert.deepEqual((await channel.next("publish_tracks")).payload, {sources: ["screen"]})
  })
})

describe("muting", () => {
  test("silences the track and tells the server, without renegotiating", async () => {
    const {room, channel, pc, emitted} = await join()
    const [mic] = browser.devices.streams[0].getAudioTracks()
    const calls = pc.calls.length

    room.setMuted(true)
    assert.equal(mic.enabled, false)
    assert.equal(room.muted, true)
    assert.deepEqual(channel.pushed("mute"), [{source: "mic", muted: true}])
    assert.deepEqual(emitted("local").at(-1), {mic: {track: mic, muted: true}})

    room.mute("mic", false)
    assert.equal(mic.enabled, true)
    assert.equal(room.muted, false)
    assert.deepEqual(channel.pushed("mute").at(-1), {source: "mic", muted: false})
    assert.equal(pc.calls.length, calls)
  })

  test("ignores a source that isn't published", async () => {
    const {room, channel} = await join()
    room.mute("camera", true)
    assert.deepEqual(channel.pushed("mute"), [])
  })
})

describe("reconnecting", () => {
  test("says so when the channel errors", async () => {
    const {channel, emitted} = await join()
    channel.error()
    assert.equal(emitted("reconnecting").length, 1)
  })

  test("rejoins with the latest resume token", async () => {
    const {channel} = await join()
    assert.deepEqual(channel.params(), {name: "alice", resume_token: "token-1"})

    channel.emit("resume_token", {token: "token-2"})
    assert.deepEqual(channel.params(), {name: "alice", resume_token: "token-2"})
  })

  test("resumed: keeps the peer connection and sends its mute flags again", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    await pull(ctx, [BOB_MIC])
    room.setMuted(true)

    channel.joinPush.reply("ok", joinReply({resumed: true, resume_token: "token-3", participants: [ALICE, BOB]}))
    await settle()

    assert.deepEqual(ctx.emitted("reconnected"), [{resumed: true}])
    assert.deepEqual(ctx.emitted("participants").at(-1), [ALICE, BOB])
    assert.deepEqual(channel.params(), {name: "alice", resume_token: "token-3"})
    assert.deepEqual(channel.pushed("mute"), [
      {source: "mic", muted: true},
      {source: "mic", muted: true},
    ])
    // The media never stopped.
    assert.equal(FakePeerConnection.instances.length, 1)
    assert.equal(pc.closed, false)
    assert.equal(channel.pushed("publish").length, 1)
    assert.equal(browser.body.children.length, 1)
  })

  test("not resumed: publishes again on a new peer connection, as a new participant", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    await pull(ctx, [BOB_MIC])
    room.setMuted(true)
    const [mic] = browser.devices.streams[0].getAudioTracks()

    channel.joinPush.reply("ok", joinReply({resumed: false, participant_id: "p9"}))
    const publish = await channel.next("publish")
    const fresh = FakePeerConnection.last

    assert.deepEqual(ctx.emitted("reconnected"), [{resumed: false}])
    assert.equal(room.participantId, "p9")
    assert.notEqual(fresh, pc)
    assert.equal(pc.closed, true)
    // What it heard came from the old session.
    assert.deepEqual(browser.body.children, [])
    assert.deepEqual(room.tracks(), [])
    assert.deepEqual(publish.payload, {sdp: "offer-1", mids: {mic: "0"}})
    assert.equal(fresh.mid("0").sender.track, mic)
    // The mic wasn't asked for again.
    assert.equal(browser.devices.userMediaCalls.length, 1)

    publish.reply("ok", {sdp: "cf-answer"})
    ;(await channel.next("connected")).reply("ok", {})
    await settle()
    assert.deepEqual(channel.pushed("mute").at(-1), {source: "mic", muted: true})
    assert.equal(channel.pushed("mute").length, 2)
    assert.equal(room.state, "joined")
  })

  test("republish: publishes every source again on a new peer connection", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    const camera = new FakeTrack("video")
    await publishMore(ctx, {camera})

    channel.emit("republish", {reason: "room_restarted"})
    const publish = await channel.next("publish")

    assert.equal(pc.closed, true)
    assert.deepEqual(publish.payload, {sdp: "offer-1", mids: {mic: "0", camera: "1"}})
    assert.equal(FakePeerConnection.last.mid("1").sender.track, camera)
    assert.equal(room.state, "joined")
  })

  test("a request cut short by a republish isn't an error: the track is published with the rest", async () => {
    const {room, channel} = await join()
    const camera = new FakeTrack("video")

    const publishing = room.publish({camera})
    ;(await channel.next("publish_tracks")).reply("error", {reason: "republishing"})
    await publishing
    assert.deepEqual(Object.keys(room.localTracks()), ["mic", "camera"])

    channel.emit("republish", {reason: "session_lost"})
    assert.deepEqual((await channel.next("publish")).payload.mids, {mic: "0", camera: "1"})
  })
})

describe("leaving", () => {
  test("leaves the channel, closes the connection and frees the mic", async () => {
    const ctx = await join()
    const {room, channel, pc} = ctx
    await pull(ctx, [BOB_MIC])

    await room.leave()

    assert.equal(channel.left, true)
    assert.equal(pc.closed, true)
    assert.equal(browser.devices.streams[0].getAudioTracks()[0].readyState, "ended")
    assert.deepEqual(browser.body.children, [])
    assert.equal(room.state, "idle")
    assert.deepEqual(ctx.emitted("left"), ["left"])
    assert.deepEqual(ctx.emitted("participants").at(-1), [])
    assert.deepEqual(ctx.emitted("local").at(-1), {})
    assert.deepEqual(ctx.emitted("error"), [])
    assert.deepEqual(browser.window.listeners.pagehide, [])
  })

  test("doesn't stop a stream it was given", async () => {
    const audio = new FakeTrack("audio")
    const {room} = await join({stream: new FakeStream([audio])})
    await room.leave()
    assert.equal(audio.readyState, "live")
  })

  test("can join again, as a new participant with no resume token", async () => {
    const {room, socket} = await join()
    await room.leave()

    const joining = room.join()
    const channel = socket.channels[1]
    assert.deepEqual(channel.joinPush.payload, {name: "alice"})
    channel.joinPush.reply("ok", joinReply({participant_id: "p5"}))
    ;(await channel.next("publish")).reply("ok", {sdp: "cf-answer"})
    ;(await channel.next("connected")).reply("ok", {})
    await joining

    assert.equal(room.participantId, "p5")
    assert.equal(browser.devices.userMediaCalls.length, 2)
  })

  test("leaves when the page is hidden", async () => {
    const {room, channel} = await join()
    browser.window.dispatch("pagehide")
    assert.equal(channel.left, true)
    assert.equal(room.state, "idle")
  })

  test("removed by the server: tears down and says so, without leaving again", async () => {
    const {room, channel, pc, emitted} = await join()
    channel.close()

    assert.equal(channel.left, false)
    assert.equal(pc.closed, true)
    assert.equal(room.state, "idle")
    assert.deepEqual(emitted("left"), ["closed"])
    assert.deepEqual(
      emitted("error").map((e) => e.message),
      ["removed from the room"],
    )
  })

  test("leaving twice, or before joining, does nothing", async () => {
    const {room, emitted} = await join()
    await room.leave()
    await room.leave()
    assert.deepEqual(emitted("left"), ["left"])

    const idle = client()
    await idle.room.leave()
    assert.deepEqual(idle.events, [])
  })
})

describe("the room", () => {
  test("room events keep the participant list current", async () => {
    const {room, channel, emitted} = await join()

    channel.emit("room_event", {type: "joined", participant: BOB})
    assert.deepEqual(room.participants, [ALICE, BOB])

    const muted = {...BOB, tracks: {mic: {muted: true}}}
    channel.emit("room_event", {type: "updated", participant: muted})
    assert.deepEqual(room.participants, [ALICE, muted])

    // A participant that joins again (a resume) isn't listed twice.
    channel.emit("room_event", {type: "joined", participant: BOB})
    assert.deepEqual(room.participants, [ALICE, BOB])

    channel.emit("room_event", {type: "left", participant: BOB})
    assert.deepEqual(room.participants, [ALICE])
    assert.deepEqual(emitted("participants").at(-1), [ALICE])
    assert.deepEqual(
      emitted("room_event").map((e) => e.type),
      ["joined", "updated", "joined", "left"],
    )
  })

  test("levels come from the mic's and the remote mics' stats", async () => {
    const ctx = await join()
    await pull(ctx, [BOB_MIC, BOB_CAMERA])
    const [mic] = browser.devices.streams[0].getAudioTracks()

    ctx.pc.stats = [
      {type: "inbound-rtp", kind: "audio", mid: "1", audioLevel: 0.4},
      {type: "inbound-rtp", kind: "video", mid: "2"},
      {type: "inbound-rtp", kind: "audio", mid: "8", audioLevel: 0.9},
      {type: "media-source", kind: "audio", trackIdentifier: mic.id, audioLevel: 0.7},
      {type: "media-source", kind: "audio", trackIdentifier: "another", audioLevel: 0.1},
    ]
    assert.deepEqual(await ctx.room.levels(), {local: 0.7, remote: {p2: 0.4}})

    await ctx.room.leave()
    assert.deepEqual(await ctx.room.levels(), {local: 0, remote: {}})
  })

  test("on() returns a function that removes the listener", async () => {
    const {room, channel} = await join()
    const seen = []
    const off = room.on("participants", (list) => seen.push(list.length))

    channel.emit("room_event", {type: "joined", participant: BOB})
    off()
    channel.emit("room_event", {type: "left", participant: BOB})
    assert.deepEqual(seen, [2])
  })
})
