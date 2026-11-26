const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {webcrypto} = require("node:crypto");

const read = name => fs.readFileSync(path.join(__dirname, "../SafariExtension", name), "utf8");
const token = "a".repeat(32);
const posts = [];
const permissions = [];
let listener;
let tabRemoved;
let tabUpdated;
let streaming = false;
let saved;
let acceptedToken;
const ticket = "c".repeat(32);
let ticketRedeemed = false;
let granted = false;
const button = {addEventListener: (event, handler) => { permit = handler }};
const output = {};
let permit;
const reloaded = [];
const browser = {
  runtime: {
    onMessage: {addListener: fn => { listener = fn }},
    async sendMessage(message) { return listener(message, {}) },
  },
  permissions: {
    async request(access) { permissions.push(access.origins[0]); return granted },
    async contains() { return granted },
  },
  storage: {local: {
    get: async () => ({token: saved}),
    set: async ({token}) => { saved = token },
  } },
  tabs: {
    onRemoved: {addListener(fn) { tabRemoved = fn }},
    onUpdated: {addListener(fn) { tabUpdated = fn }},
    async query() { return [{id: 12, url: "http://127.0.0.1:49196/connect#" + ticket}] },
    async reload(id) { reloaded.push(id) },
  },
};
const domain = vm.createContext({
  browser, AbortSignal, URL,
  document: {querySelector: tag => tag === "button" ? button : output},
  importScripts(filename) { vm.runInContext(read(filename), domain) },
  async fetch(url, options) {
    posts.push({url, body: JSON.parse(options.body), credentials: options.credentials,
      redirect: options.redirect, type: options.headers["Content-Type"]});
    const request = posts.at(-1).body;
    if (request.operation === "pair") {
      if (ticketRedeemed || request.ticket !== ticket) return {status: 403, ok: false};
      ticketRedeemed = true;
      return {status: 200, ok: true, json: async () => ({token})};
    }
    if (acceptedToken && request.token !== acceptedToken) return {status: 403, ok: false};
    return {status: 200, ok: true, json: async () => streaming ? {ok: true, streaming: true} : {ok: true}};
  },
});

vm.runInContext(read("badge.js"), domain);
vm.runInContext(read("pair.js"), domain);

(async () => {
  const browserFrame = {tab: {id: 9}, frameId: 2};
  const offer = {operation: "poll", video: {id: "video-id", title: "Local test"}};
  assert.equal((await listener({type: "kadraj-video", available: true, request: offer}, browserFrame)).needsPairing, true);
  await permit();
  assert.equal(posts.length, 0);
  assert.deepEqual(permissions, ["http://127.0.0.1/*"]);

  granted = true;
  await permit();
  assert.deepEqual(reloaded, [12]);
  const pairRequest = {type: "kadraj-pair", ticket};
  assert.equal((await listener(pairRequest, {url: "https://youtube.com/connect"})).ok, false);
  assert.equal(posts.length, 0);
  const pairTab = {url: "http://127.0.0.1:49196/connect", frameId: 0};
  assert.equal((await listener(pairRequest, {...pairTab, frameId: 1})).ok, false);
  const status = {};
  const help = {};
  const history = {replaceState(...args) { this.state = args }};
  vm.runInNewContext(read("connect.js"), {
    location: new URL(pairTab.url + "#" + ticket), history,
    document: {getElementById: id => id === "pair-status" ? status : help},
    browser: {runtime: {sendMessage: message => listener(message, pairTab)}},
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(saved, token);
  assert.equal(status.textContent, "Kadraj’a bağlandı.");
  assert.deepEqual(history.state, [null, "", "/connect"]);
  assert.deepEqual(posts.at(-1).body, {operation: "pair", ticket});
  assert.equal((await listener(pairRequest, pairTab)).ok, false);
  await vm.runInContext("checkConnection()", domain);
  assert.match(output.value, /^Kadraj’a bağlandı\./);
  assert.equal(button.textContent, "Bağlantı sekmesini yenile");
  const updatedStatus = {};
  for (const [hash, pingOK, expected] of [
    ["", true, "Kadraj’a bağlandı."],
    ["#" + ticket, true, "Kadraj’a bağlandı."],
    ["#" + ticket, false, "Kadraj bağlantısı doğrulanamadı."],
  ]) {
    await vm.runInNewContext(read("connect.js"), {
      location: new URL(pairTab.url + hash), history,
      document: {getElementById: id => id === "pair-status" ? updatedStatus : null},
      browser: {runtime: {async sendMessage(message) {
        if (message.type === "kadraj-pair") throw new Error("lost response");
        return {ok: pingOK};
      }}},
    });
    assert.equal(updatedStatus.textContent, expected);
  }

  await listener({type: "kadraj-video", available: true, request: offer}, browserFrame);
  assert.deepEqual(posts.at(-1), {
    url: "http://127.0.0.1:49196/kadraj", body: {...offer, token},
    credentials: "omit", redirect: "error", type: "text/plain;charset=UTF-8",
  });
  await listener({type: "kadraj-video", available: false, request: {...offer, operation: "withdraw"}}, browserFrame);
  const mirror = {...offer, video: {...offer.video, mirrorOnly: true}, open: true, available: true};
  const count = posts.length;
  assert.equal((await listener({type: "kadraj-video", available: true, request: mirror}, browserFrame)).ok, false);
  assert.equal(posts.length, count);
  const inactive = {tab: {id: 9, active: false}, frameId: 0};
  await listener({type: "kadraj-video", available: true, request: mirror}, inactive);
  assert.equal(posts.at(-1).body.open, false);
  assert.equal(posts.at(-1).body.available, false);
  await listener({type: "kadraj-video", request: {...mirror, operation: "reply", reply: {media: {mirror: {crop: [0,0,1,1]}}}}}, inactive);
  assert.equal(posts.at(-1).body.reply.media.mirror, null);
  await listener({type: "kadraj-video", request: {...offer, operation: "frame", image: "fake"}}, inactive);
  assert.equal(String(posts.at(-1).url), "http://127.0.0.1:49196/frames");
  saved = acceptedToken = "b".repeat(32);
  const beforeCodeChange = posts.length;
  const nextFrameResult = await listener({type: "kadraj-video",
    request: {...offer, operation: "frame", image: "fake"}}, inactive);
  assert.equal(nextFrameResult.ok, true);
  assert.deepEqual(posts.slice(beforeCodeChange).map(post => post.body.token), [token, saved]);
  streaming = true;
  const sourceOffer = {...offer, video: {...offer.video, id: "source-tab-video"}};
  const activeTab = {tab: {id: 13}, frameId: 0};
  await listener({type: "kadraj-video", request: sourceOffer}, activeTab);
  const beforeClose = posts.length;
  await tabRemoved(14);
  assert.equal(posts.length, beforeClose);
  await tabRemoved(13);
  assert.equal(posts.at(-1).body.operation, "lost");
  assert.equal(posts.at(-1).body.video.id, "source-tab-video");
  await listener({type: "kadraj-video", request: sourceOffer}, activeTab);
  await tabUpdated(13, {status: "loading"});
  assert.equal(posts.at(-1).body.operation, "lost");
  streaming = false;
  console.log("Safari localhost permission, one-time pairing and video bridge passed.");

  const watchPage = new URL("https://www.youtube.com/watch?v=aqz-KE-bpKQ&t=25");
  const replies = [];
  const frames = [];
  const messages = [];
  const polls = [];
  let stopped = false;
  let nextFrame;
  let dropStartReply = true;
  let canvasWidth;
  let jpegBytes = 1;
  const jpegQualities = [];
  let stallPost = false;
  let releasePost;
  let frameResponse = {ok: true, streaming: true, frameSize: [640, 360]};
  const trackRates = [];
  let manualTrackFailure;
  let restrictedCanvas = false;
  const page = {title: "YouTube sample", hidden: false, createElement: () => ({
    getContext() { return {
      drawImage: () => { canvasWidth = this.width },
      getImageData() { if (restrictedCanvas) throw {name: "SecurityError"} },
    }},
    captureStream(rate) {
      trackRates.push(rate);
      if (rate === 0 && manualTrackFailure === "creation") throw new Error("manual capture unavailable");
      if (rate === 0 && manualTrackFailure === "empty") return {getVideoTracks: () => []};
      return {getVideoTracks: () => [{
        requestFrame() { if (manualTrackFailure === "request") throw new Error("frame request blocked") },
        stop() { stopped = true },
      }]};
    },
    toBlob(callback, _format, quality) {
      jpegQualities.push(quality);
      callback({size: jpegBytes, async arrayBuffer() { return new Uint8Array([0]).buffer }});
    },
  })};
  const source = {
    classList: {contains: name => name === "html5-main-video"},
    closest: selector => selector === ".html5-video-player",
    currentSrc: "blob:https://www.youtube.com/source",
    isConnected: true, currentTime: 25, duration: 590, volume: 0.5, paused: false, readyState: 4,
    videoWidth: 1280, videoHeight: 720,
    seekable: {length: 1, start: () => 0, end: () => 590},
    getBoundingClientRect: () => ({left: 0, top: 0, right: 640, bottom: 360}),
    addEventListener() {}, removeEventListener() {},
    requestVideoFrameCallback(callback) { nextFrame = callback; return 1 },
    cancelVideoFrameCallback() {},
    pause() { this.paused = true },
    play() { this.paused = false; return Promise.resolve() },
  };
  page.createTreeWalker = () => ({nextNode: () => null});
  page.querySelectorAll = () => [source];
  const youtubeContext = {
    location: watchPage, window: {}, document: page, URL, crypto: webcrypto, performance, setTimeout,
    innerWidth: 800, innerHeight: 500, NodeFilter: {SHOW_ELEMENT: 1},
    FileReader: class {
      readAsDataURL() { this.result = "data:image/jpeg;base64,AA=="; this.onload() }
    },
    browser: {runtime: {async sendMessage({request}) {
      messages.push(request.operation);
      if (request.operation === "poll") polls.push(request);
      if (request.reply) replies.push(request.reply);
      if (request.reply?.id === "start" && dropStartReply) {
        dropStartReply = false;
        return {ok: false, reason: "network"};
      }
      if (request.operation === "frame") {
        frames.push(request);
        if (stallPost) return await new Promise(resolve => { releasePost = resolve });
        return frameResponse;
      }
      return {ok: true, streaming: true, frameSize: [640, 360]};
    }}},
  };
  const videoLoop = '  document.addEventListener("playing", refresh, true);';
  vm.runInNewContext(read("video.js").replace(videoLoop,
    '  Object.assign(globalThis, {reference, runCommand, rank, refresh}); return;\n' + videoLoop), youtubeContext);
  const record = youtubeContext.reference(source);
  assert.equal(record.video.youtubeID, "aqz-KE-bpKQ");
  assert.equal(record.video.mirrorOnly, false);
  assert.equal(record.video.canMirror, false);

  await youtubeContext.runCommand(record, {id: "claim", kind: "claim"});
  assert.equal(replies.at(-1).success, false);
  assert.equal(source.paused, false);
  await youtubeContext.runCommand(record, {id: "start", kind: "startFrames"});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(replies.at(-1).success, true);
  assert.equal(source.paused, false);
  assert.equal(replies.filter(reply => reply.id === "start").length, 2);
  assert.equal(frames.at(-1).image, "AA==");
  assert.equal(frames.at(-1).media.mirror, null);
  assert.equal(canvasWidth, 640);
  assert.deepEqual(trackRates, [0]);

  const beforeStall = frames.length;
  stallPost = true;
  for (const time of [25.04, 25.08, 25.12]) {
    source.currentTime = time;
    nextFrame(0, {mediaTime: time});
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(frames.length, beforeStall + 1);
  stallPost = false;
  releasePost({ok: true, streaming: true});
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(frames.slice(beforeStall).map(frame => frame.media.time), [25.04, 25.12]);

  jpegBytes = 300_000;
  nextFrame(0, {mediaTime: 25.16});
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(jpegQualities.slice(-2), [0.78, 0.66]);
  jpegBytes = 100_000;
  nextFrame(0, {mediaTime: 25.20});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(canvasWidth, 560);
  for (let i = 1; i <= 180; i++) {
    nextFrame(0, {mediaTime: 25.20 + i * 0.04});
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.equal(canvasWidth, 640, "restore full panel resolution when frames fit again");
  assert.equal(jpegQualities.at(-1), 0.78, "restore JPEG quality after sustained headroom");

  const before50FPS = frames.length;
  for (let i = 1; i <= 50; i++) {
    const time = 32.40 + i / 50;
    source.currentTime = time;
    nextFrame(0, {mediaTime: time});
    await new Promise(resolve => setImmediate(resolve));
  }
  const sent50FPS = frames.length - before50FPS;
  assert.ok(sent50FPS >= 29 && sent50FPS <= 31, "keep a 30 FPS cadence when source frames arrive at 50 FPS");

  source.currentTime = 25;
  page.hidden = true;
  await youtubeContext.runCommand(record, {id: "pause", kind: "toggle"});
  assert.equal(source.paused, true);
  await youtubeContext.runCommand(record, {id: "seek", kind: "forward"});
  assert.equal(source.currentTime, 35);
  await youtubeContext.runCommand(record, {id: "play", kind: "toggle"});
  assert.equal(source.paused, false);

  watchPage.searchParams.set("v", "M7lc1UVf-VE");
  nextFrame();
  assert.equal(stopped, true);
  assert.equal(messages.at(-1), "lost");
  assert.equal(source.paused, false);

  const reopened = youtubeContext.reference(source);
  frameResponse = {ok: false, streaming: false, dismissed: false};
  await youtubeContext.runCommand(reopened, {id: "reopen", kind: "startFrames"});
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(youtubeContext.rank(source) > 0, "app restart should let the still-playing video be offered again");

  frameResponse = {ok: false, streaming: false, dismissed: true};
  await youtubeContext.runCommand(reopened, {id: "open", kind: "startFrames"});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(youtubeContext.rank(source), 0, "closing the captured panel should dismiss the currently playing video");
  watchPage.searchParams.set("v", "abcdefghijk");
  page.hidden = false;
  source.readyState = 4;
  youtubeContext.refresh();
  await new Promise(resolve => setImmediate(resolve));
  const offered = polls.at(-1);
  assert.equal(offered.available, true);
  source.readyState = 1;
  youtubeContext.refresh();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(polls.at(-1).available, false);
  assert.equal(polls.at(-1).video.id, offered.video.id, "temporarily unready source must still receive queued commands");

  const brieflyUnready = youtubeContext.reference(source);
  frameResponse = {ok: false, streaming: false, dismissed: false};
  const alreadyOpening = youtubeContext.runCommand(brieflyUnready, {id: "wait-for-frame", kind: "startFrames"});
  source.readyState = 4;
  await alreadyOpening;
  assert.equal(replies.at(-1).success, true);
  await new Promise(resolve => setImmediate(resolve));

  for (const failure of ["creation", "empty", "request"]) {
    manualTrackFailure = failure;
    stopped = false;
    const previous = trackRates.length;
    await youtubeContext.runCommand(brieflyUnready, {id: failure, kind: "startFrames"});
    assert.equal(replies.at(-1).success, true);
    assert.deepEqual(trackRates.slice(previous), [0, 30]);
    if (failure === "request") assert.equal(stopped, true);
    await new Promise(resolve => setImmediate(resolve));
  }
  restrictedCanvas = true;
  const previous = trackRates.length;
  await youtubeContext.runCommand(brieflyUnready, {id: "restricted", kind: "startFrames"});
  assert.equal(replies.at(-1).failure, "restricted");
  assert.equal(trackRates.length, previous, "restricted pixels must never start capture");
  console.log("YouTube mirrored frames and hidden-tab controls use the same source without taking over playback.");
})().catch(error => { console.error(error); process.exitCode = 1 });
