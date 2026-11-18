// Fakes for testing the browser client under Node: a Phoenix socket and
// channel the test plays the server on, and just enough of the browser
// (RTCPeerConnection, media streams and devices, window, document) for the
// client to run its signaling against.

/** A Phoenix push: the test answers it with `reply(status, payload)`. */
export class FakePush {
  constructor(event, payload, timeout) {
    this.event = event
    this.payload = payload
    this.timeout = timeout
    this.hooks = []
    this.taken = false
  }

  receive(status, callback) {
    this.hooks.push({status, callback})
    return this
  }

  reply(status, payload) {
    for (const hook of this.hooks) if (hook.status === status) hook.callback(payload)
  }
}

export class FakeChannel {
  constructor(topic, params) {
    this.topic = topic
    this.paramsFn = params
    this.handlers = {}
    this.errorCallbacks = []
    this.closeCallbacks = []
    this.pushes = []
    this.waiters = []
    this.left = false
  }

  // -- what the client calls --

  on(event, callback) {
    ;(this.handlers[event] ||= []).push(callback)
  }

  onError(callback) {
    this.errorCallbacks.push(callback)
  }

  onClose(callback) {
    this.closeCallbacks.push(callback)
  }

  join(timeout) {
    this.joinPush = new FakePush("phx_join", this.params(), timeout)
    return this.joinPush
  }

  push(event, payload, timeout) {
    const push = new FakePush(event, payload, timeout)
    this.pushes.push(push)
    this.waiters = this.waiters.filter((waiter) => !waiter(push))
    return push
  }

  leave() {
    this.left = true
    for (const callback of this.closeCallbacks) callback()
  }

  // -- what the test calls, as the server --

  /** The params the channel would join (or rejoin) with now. */
  params() {
    return typeof this.paramsFn === "function" ? this.paramsFn() : this.paramsFn
  }

  /** A message from the server. */
  emit(event, payload) {
    for (const callback of this.handlers[event] || []) callback(payload)
  }

  /** The socket dropped: Phoenix will rejoin. */
  error() {
    for (const callback of this.errorCallbacks) callback()
  }

  /** The server closed the channel. */
  close() {
    for (const callback of this.closeCallbacks) callback()
  }

  /** The client's next push of `event` that no earlier `next` returned. */
  next(event) {
    const take = (push) => {
      if (push.event !== event || push.taken) return false
      push.taken = true
      return true
    }
    const pushed = this.pushes.find(take)
    if (pushed) return Promise.resolve(pushed)
    return new Promise((resolve) => {
      this.waiters.push((push) => take(push) && (resolve(push), true))
    })
  }

  /** Payloads of every push of `event` so far. */
  pushed(event) {
    return this.pushes.filter((push) => push.event === event).map((push) => push.payload)
  }
}

export class FakeSocket {
  constructor() {
    this.channels = []
  }

  channel(topic, params) {
    const channel = new FakeChannel(topic, params)
    this.channels.push(channel)
    return channel
  }
}

let trackIds = 0

export class FakeTrack {
  constructor(kind) {
    this.kind = kind
    this.id = `track-${++trackIds}`
    this.enabled = true
    this.readyState = "live"
    this.listeners = {}
  }

  stop() {
    this.readyState = "ended"
  }

  addEventListener(event, callback) {
    ;(this.listeners[event] ||= []).push(callback)
  }

  /** The browser ended the track, e.g. "Stop sharing". */
  end() {
    this.readyState = "ended"
    for (const callback of this.listeners.ended || []) callback()
  }
}

export class FakeStream {
  constructor(tracks = []) {
    this.tracks = tracks
  }

  getTracks() {
    return this.tracks
  }

  getAudioTracks() {
    return this.tracks.filter((track) => track.kind === "audio")
  }

  getVideoTracks() {
    return this.tracks.filter((track) => track.kind === "video")
  }
}

class FakeTransceiver {
  constructor(track, kind, direction) {
    this.mid = null
    this.direction = direction
    this.stopped = false
    this.sender = {
      track,
      replaceTrack: async (next) => {
        this.sender.track = next
      },
    }
    this.receiver = {track: new FakeTrack(kind)}
  }

  stop() {
    this.stopped = true
  }
}

/**
 * Records what the client does to it. An offer gives every new transceiver
 * the next mid. A remote offer's SDP names the transceivers it adds:
 * `remoteOffer({"3": "audio"})`. Unless `autoConnect` is off, the connection
 * is up once the first answer is applied.
 */
export class FakePeerConnection {
  static instances = []
  static autoConnect = true
  // What a new connection's ICE gathering state is: "gathering" makes the
  // client wait for a candidate (`addCandidate`), or for
  // `setIceGatheringState("complete")`.
  static iceGatheringState = "complete"

  constructor(config) {
    this.config = config
    this.transceivers = []
    this.calls = []
    this.listeners = {}
    this.failures = {}
    this.signalingState = "stable"
    this.connectionState = "new"
    this.iceGatheringState = FakePeerConnection.iceGatheringState
    this.localDescription = null
    this.remoteDescription = null
    this.closed = false
    this.offers = 0
    this.stats = []
    FakePeerConnection.instances.push(this)
  }

  static get last() {
    return FakePeerConnection.instances.at(-1)
  }

  /** Makes the next call of `method` throw. */
  fail(method, error = new Error(`${method} failed`)) {
    this.failures[method] = error
  }

  called(method, arg) {
    this.calls.push(arg === undefined ? method : `${method}:${arg}`)
    const error = this.failures[method]
    delete this.failures[method]
    if (error) throw error
  }

  addTransceiver(trackOrKind, {direction}) {
    const track = typeof trackOrKind === "string" ? null : trackOrKind
    const kind = track ? track.kind : trackOrKind
    const transceiver = new FakeTransceiver(track, kind, direction)
    this.transceivers.push(transceiver)
    return transceiver
  }

  getTransceivers() {
    return this.transceivers
  }

  mid(mid) {
    return this.transceivers.find((t) => t.mid === mid)
  }

  async createOffer() {
    this.called("createOffer")
    return {type: "offer", sdp: `offer-${++this.offers}`}
  }

  async createAnswer() {
    this.called("createAnswer")
    return {type: "answer", sdp: `answer-to:${this.remoteDescription.sdp}`}
  }

  async setLocalDescription(description) {
    this.called("setLocalDescription", description.type)
    if (description.type === "rollback") {
      this.signalingState = "stable"
      return
    }
    if (description.type === "offer") {
      this.signalingState = "have-local-offer"
      for (const t of this.transceivers) if (t.mid === null) t.mid = String(this.nextMid())
    } else {
      this.signalingState = "stable"
    }
    this.localDescription = description
  }

  async setRemoteDescription(description) {
    this.called("setRemoteDescription", description.type)
    this.remoteDescription = description
    if (description.type === "offer") {
      this.signalingState = "have-remote-offer"
      for (const [mid, kind] of Object.entries(JSON.parse(description.sdp))) {
        if (this.mid(mid)) continue
        const transceiver = new FakeTransceiver(null, kind, "recvonly")
        transceiver.mid = mid
        this.transceivers.push(transceiver)
      }
    } else {
      this.signalingState = "stable"
      if (FakePeerConnection.autoConnect) this.setConnectionState("connected")
    }
  }

  nextMid() {
    return Math.max(-1, ...this.transceivers.map((t) => (t.mid === null ? -1 : Number(t.mid)))) + 1
  }

  setConnectionState(state) {
    if (this.connectionState === state) return
    this.connectionState = state
    this.onconnectionstatechange?.()
    for (const callback of [...(this.listeners.connectionstatechange || [])]) callback()
  }

  // A candidate gathered: it's in the local description from now on.
  addCandidate(line = "a=candidate:1 1 udp 2122260223 abc.local 50000 typ host") {
    const {type, sdp} = this.localDescription
    this.localDescription = {type, sdp: `${sdp}\r\n${line}`}
    for (const callback of [...(this.listeners.icecandidate || [])]) callback({candidate: {candidate: line}})
  }

  setIceGatheringState(state) {
    this.iceGatheringState = state
    for (const callback of [...(this.listeners.icegatheringstatechange || [])]) callback()
  }

  addEventListener(event, callback) {
    ;(this.listeners[event] ||= []).push(callback)
  }

  removeEventListener(event, callback) {
    this.listeners[event] = (this.listeners[event] || []).filter((c) => c !== callback)
  }

  async getStats() {
    return this.stats
  }

  close() {
    this.closed = true
  }
}

/** The SDP of a Cloudflare offer that adds these transceivers: {mid: kind}. */
export function remoteOffer(mids) {
  return JSON.stringify(mids)
}

class FakeElement {
  constructor(tag, body) {
    this.tag = tag
    this.body = body
    this.dataset = {}
    this.style = {}
    this.played = false
  }

  async play() {
    this.played = true
  }

  remove() {
    this.body.children = this.body.children.filter((child) => child !== this)
  }
}

/**
 * Installs the browser globals the client uses, fresh for each test.
 * Returns what a test inspects: `devices` (the getUserMedia and
 * getDisplayMedia calls, `display` to choose what a screen share has, and
 * `prompting` to hold getUserMedia until `allow()`),
 * `window` (with `dispatch(event)`) and `body` (its `children` are the
 * audio elements).
 */
export function installBrowser() {
  FakePeerConnection.instances = []
  FakePeerConnection.autoConnect = true
  FakePeerConnection.iceGatheringState = "complete"

  const body = {
    children: [],
    appendChild(element) {
      this.children.push(element)
    },
  }

  const window = {
    listeners: {},
    addEventListener(event, callback) {
      ;(this.listeners[event] ||= []).push(callback)
    },
    removeEventListener(event, callback) {
      this.listeners[event] = (this.listeners[event] || []).filter((c) => c !== callback)
    },
    dispatch(event) {
      for (const callback of [...(this.listeners[event] || [])]) callback()
    },
  }

  const devices = {
    userMediaCalls: [],
    displayMediaCalls: [],
    streams: [],
    display: {video: true, audio: true},
    async getUserMedia(constraints) {
      this.userMediaCalls.push(constraints)
      if (this.denied) throw new Error("Permission denied")
      // The permission prompt is up until the test calls `allow()`.
      if (this.prompting) await new Promise((resolve) => (this.allow = resolve))
      return this.open(constraints)
    },
    async getDisplayMedia(options) {
      this.displayMediaCalls.push(options)
      return this.open(this.display)
    },
    open({audio, video}) {
      const tracks = []
      if (audio) tracks.push(new FakeTrack("audio"))
      if (video) tracks.push(new FakeTrack("video"))
      const stream = new FakeStream(tracks)
      this.streams.push(stream)
      return stream
    },
  }

  const globals = {
    RTCPeerConnection: FakePeerConnection,
    MediaStream: FakeStream,
    MediaStreamTrack: FakeTrack,
    navigator: {mediaDevices: devices},
    window,
    document: {body, createElement: (tag) => new FakeElement(tag, body)},
  }
  for (const [name, value] of Object.entries(globals)) {
    Object.defineProperty(globalThis, name, {value, configurable: true, writable: true})
  }

  return {devices, window, body}
}

/** Lets everything already queued (promise callbacks included) run. */
export function settle() {
  return new Promise((resolve) => setImmediate(resolve))
}
