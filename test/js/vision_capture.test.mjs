import {describe, it, beforeEach} from "node:test"
import assert from "node:assert/strict"
import {RoomClient} from "../../priv/static/octoroom.mjs"
import {FakeSocket, installBrowser, settle} from "./fakes.mjs"

const JPEG_B64 = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]).toString("base64")

describe("RoomClient video capture", () => {
  let socket

  beforeEach(() => {
    installBrowser()
    socket = new FakeSocket()
  })

  async function joinRoom(opts = {}) {
    const captured = []
    const room = new RoomClient({
      socket,
      topic: "room:vision",
      video: true,
      captureFrame: async (track, config, source) => {
        captured.push({track, config, source})
        return {data: JPEG_B64, mime_type: "image/jpeg", width: 640, height: 360}
      },
      ...opts,
    })

    const joinPromise = room.join()
    const channel = socket.channels[0]
    channel.joinPush.reply("ok", {
      participant_id: "alice",
      participants: [{id: "alice", meta: {}, tracks: {}}],
      ice_servers: [],
      resume_token: "tok",
      workers: [],
      capture: opts.initialCapture || {sources: {}},
    })

    const pub = await channel.next("publish")
    pub.reply("ok", {sdp: "answer"})
    const conn = await channel.next("connected")
    conn.reply("ok", {})
    await joinPromise
    return {room, channel, captured}
  }

  it("auto-captures published unmuted camera on server capture directive and pauses on mute/opt-out", async () => {
    const events = []
    const {room, channel} = await joinRoom()
    room.on("capture", (e) => events.push(e))

    assert.deepEqual(room.capturingSources(), [])

    channel.emit("capture", {
      sources: {camera: {fps: 2, max_dimension: 768, quality: 0.75}},
    })

    const framePush = await channel.next("video_frame")
    assert.equal(framePush.payload.source, "camera")
    assert.equal(framePush.payload.mime_type, "image/jpeg")
    assert.equal(framePush.payload.width, 640)
    assert.equal(framePush.payload.height, 360)
    assert.equal(framePush.payload.data, JPEG_B64)
    framePush.reply("ok", {})

    assert.deepEqual(room.capturingSources(), ["camera"])
    assert.deepEqual(events.at(-1).sources, ["camera"])

    // Muting camera stops capturing immediately.
    room.mute("camera", true)
    assert.deepEqual(room.capturingSources(), [])
    assert.deepEqual(events.at(-1).sources, [])

    // Unmuting resumes capturing.
    room.mute("camera", false)
    assert.deepEqual(room.capturingSources(), ["camera"])
    const framePush2 = await channel.next("video_frame")
    framePush2.reply("ok", {})

    // Client-side opt-out stops capturing even though directive is active.
    room.setCaptureEnabled(false)
    assert.deepEqual(room.capturingSources(), [])
    assert.equal(events.at(-1).enabled, false)

    // Re-enabling resumes capturing.
    room.setCaptureEnabled(true)
    assert.deepEqual(room.capturingSources(), ["camera"])

    // Server clearing directive stops capture.
    channel.emit("capture", {sources: {}})
    assert.deepEqual(room.capturingSources(), [])

    await room.leave()
  })

  it("honors initial capture directive from join reply", async () => {
    const {room, channel} = await joinRoom({
      initialCapture: {sources: {camera: {fps: 1, max_dimension: 768, quality: 0.75}}},
    })

    const framePush = await channel.next("video_frame")
    assert.equal(framePush.payload.source, "camera")
    framePush.reply("ok", {})
    assert.deepEqual(room.capturingSources(), ["camera"])

    await room.leave()
    await settle()
    assert.deepEqual(room.capturingSources(), [])
  })

  it("respects capture: false constructor option", async () => {
    const {room, channel} = await joinRoom({
      capture: false,
      initialCapture: {sources: {camera: {fps: 2, max_dimension: 768, quality: 0.75}}},
    })

    await settle()
    assert.deepEqual(room.capturingSources(), [])
    assert.equal(channel.pushed("video_frame").length, 0)

    await room.leave()
  })
})
