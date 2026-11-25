(() => {
  if (globalThis.__kadrajVideoObservers) return;
  globalThis.__kadrajVideoObservers = true;
  const dismissed = new WeakMap();
  const observed = new WeakSet();
  const known = new WeakMap();
  const owned = new Set();
  let target;
  let recentTarget;
  let transfer;
  let busy = false;
  let sourceFrames;

  function mediaURL(video) {
    return /^https?:[/][/]/i.test(video.currentSrc) && !video.mediaKeys ? video.currentSrc : null;
  }

  function youtubeID(video) {
    if (location.protocol !== "https:" || !/^(?:(?:www|m)\.)?youtube\.com$/i.test(location.hostname)
        || !video.closest(".html5-video-player") || !video.classList.contains("html5-main-video")) return null;
    const id = location.pathname === "/watch"
      ? new URL(location.href).searchParams.get("v")
      : /^\/(?:shorts|live|embed)\/([^/]+)\/?$/.exec(location.pathname)?.[1];
    return /^[\w-]{11}$/.test(id ?? "") ? id : null;
  }

  function sourceIdentity(video) {
    if (video.mediaKeys) return null;
    const url = mediaURL(video);
    const topLevel = window.top === window;
    const youtube = /(^|\.)youtube[.]com$/i.test(location.hostname);
    const id = youtubeID(video);
    if (id) return {url: null, youtubeID: id, canMirror: false, key: "youtube:" + id};
    if (youtube) return null;
    const canMirror = topLevel && video.currentSrc.startsWith("blob:");
    if (!url && !canMirror) return null;
    const page = location.pathname + location.search;
    return {url, canMirror, key: canMirror ? video.currentSrc + "\n" + page : url};
  }

  function reference(video) {
    const source = sourceIdentity(video);
    if (!source) return null;
    const old = known.get(video);
    if (old?.key === source.key) return old;
    const random = crypto.getRandomValues(new Uint8Array(16));
    const hex = [...random].map(n => n.toString(16).padStart(2, "0")).join("");
    const id = [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
    const record = {element: video, ...source,
      video: {id, title: document.title.slice(0, 230), supportsHandback: true,
        protocolVersion: 3, youtubeID: source.youtubeID,
        mirrorOnly: !source.url && !source.youtubeID, canMirror: source.canMirror}};
    known.set(video, record);
    return record;
  }

  function videos(root, output, budget) {
    output.push(...root.querySelectorAll("video"));
    const elements = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let element = elements.nextNode(); element && budget.count > 0; element = elements.nextNode()) {
      budget.count--;
      if (element.shadowRoot) videos(element.shadowRoot, output, budget);
    }
  }

  function rank(video) {
    const source = sourceIdentity(video);
    if (video.paused || video.ended || video.readyState < 2 || !video.videoWidth
        || (source?.youtubeID && video.closest(".ad-showing, .ad-interrupting"))
        || !source || dismissed.get(video) === source.key || owned.has(known.get(video))
        || sourceFrames?.record.element === video) return 0;
    const frame = video.getBoundingClientRect();
    const width = Math.min(innerWidth, frame.right) - Math.max(0, frame.left);
    const height = Math.min(innerHeight, frame.bottom) - Math.max(0, frame.top);
    return width >= 120 && height >= 68 ? width * height : 0;
  }

  function message(record, operation, extra = {}, available) {
    return browser.runtime.sendMessage({
      type: "kadraj-video", request: {operation, video: record.video, available, ...extra},
    });
  }

  function clearTarget() {
    if (target) recentTarget = {record: target, deadline: Date.now() + 10000};
    withdraw(target);
    target = undefined;
  }

  function withdraw(record) {
    if (record) message(record, "withdraw", {}, false).catch(() => {});
  }

  function mirrorGeometry(video) {
    if (document.hidden || outerWidth <= 0 || outerHeight <= 0) return null;
    const {left, right, top, bottom} = video.getBoundingClientRect();
    const x = Math.max(left, 0), y = Math.max(top, 0);
    const width = Math.min(right, innerWidth) - x, height = Math.min(bottom, innerHeight) - y;
    if (width < 100 || height < 60) return null;
    const side = Math.max(0, outerWidth - innerWidth);
    const chrome = Math.max(0, outerHeight - innerHeight);
    return {
      window: [screenX, screenY, outerWidth, outerHeight],
      crop: [(side + x) / outerWidth, (chrome + y) / outerHeight, width / outerWidth, height / outerHeight],
      title: document.title.slice(0, 230),
    };
  }

  function snapshot(record) {
    const element = record.element;
    return {
      url: record.url, time: element.currentTime, duration: Number.isFinite(element.duration) ? element.duration : null,
      volume: element.muted ? 0 : element.volume, paused: element.paused,
      seekable: element.seekable.length > 0, mirror: record.canMirror ? mirrorGeometry(element) : null,
    };
  }

  function sameSource(record) {
    return record.element.isConnected && sourceIdentity(record.element)?.key === record.key;
  }

  function stopFrames(state, lost = false, dismiss = true) {
    if (sourceFrames !== state) return;
    sourceFrames = undefined;
    if (transfer?.record === state.record) transfer = undefined;
    const video = state.record.element;
    video.cancelVideoFrameCallback(state.callback);
    for (const event of state.events) video.removeEventListener(event, state.update);
    video.removeEventListener("ended", state.ended);
    state.track.stop();
    if (lost) message(state.record, "lost", {}, false).catch(() => {});
    else if (dismiss) dismissed.set(video, state.record.key);
  }

  function sizeFrameCanvas(canvas, video, bounds, resolution = 1) {
    if (!video.videoWidth || !video.videoHeight) return;
    const scale = Math.min(1, bounds[0] * resolution / video.videoWidth, bounds[1] * resolution / video.videoHeight);
    const width = Math.max(1, Math.floor(video.videoWidth * scale));
    const height = Math.max(1, Math.floor(video.videoHeight * scale));
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
  }

  function updateFrameBounds(state, result) {
    const [width, height] = result?.frameSize ?? [];
    if (Number.isInteger(width) && width > 0 && width <= 1920 &&
        Number.isInteger(height) && height > 0 && height <= 1080 &&
        (width !== state.bounds[0] || height !== state.bounds[1])) {
      state.bounds = [width, height];
      return true;
    }
    return false;
  }

  async function startFrames(record) {
    const video = record.element;
    if (!video.requestVideoFrameCallback) return {failure: "captureUnavailable"};
    const deadline = Date.now() + 1500;
    while (true) {
      if (!video.isConnected) return {failure: "sourceChanged"};
      if (video.mediaKeys) return {failure: "restricted"};
      if (!sameSource(record) || video.ended) return {failure: "sourceChanged"};
      if (!video.seeking && video.readyState >= 2 && video.videoWidth && video.videoHeight) break;
      if (Date.now() >= deadline) return {failure: "notReady"};
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    const canvas = document.createElement("canvas");
    const bounds = [960, 540];
    sizeFrameCanvas(canvas, video, bounds);
    const painter = canvas.getContext("2d");
    if (!painter) return {failure: "captureUnavailable"};
    let track;
    try {
      painter.drawImage(video, 0, 0, canvas.width, canvas.height);
      painter.getImageData(0, 0, 1, 1);
      // Keep WebKit's capture active without sampling every canvas update twice.
      try {
        track = canvas.captureStream(0).getVideoTracks()[0];
        track?.requestFrame();
      } catch {
        track?.stop();
        track = undefined;
      }
      if (!track) {
        track = canvas.captureStream(30).getVideoTracks()[0];
      }
      if (!track) return {failure: "captureUnavailable"};
      if (sourceFrames) stopFrames(sourceFrames);
      const state = {record, canvas, painter, track, bounds, lastMediaTime: -Infinity,
        resolution: 1, quality: 0.78,
        events: ["play", "pause", "seeked"]};
      state.update = () => {
        void sendFrame(state, true);
        void waitForFrameCommand(state);
      };
      state.ended = () => stopFrames(state, true);
      const next = (_, metadata) => {
        if (sourceFrames !== state) return;
        state.callback = video.requestVideoFrameCallback(next);
        void sendFrame(state, false, metadata?.mediaTime);
      };
      state.callback = video.requestVideoFrameCallback(next);
      for (const event of state.events) video.addEventListener(event, state.update);
      video.addEventListener("ended", state.ended);
      sourceFrames = state;
      return {frames: state};
    } catch (error) {
      track?.stop();
      return {failure: error?.name === "SecurityError" ? "restricted" : "captureUnavailable"};
    }
  }

  async function jpeg(canvas, quality) {
    const blob = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", quality));
    if (!blob || blob.size > 270_000) return null;
    if (typeof Uint8Array.prototype.toBase64 === "function") {
      return new Uint8Array(await blob.arrayBuffer()).toBase64();
    }
    return await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result.split(",")[1]);
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  }

  async function waitForFrameCommand(state) {
    if (!state.active || state.waiting) return;
    state.waiting = true;
    try {
      while (sourceFrames === state && state.record.element.paused) {
        if (!sameSource(state.record)) { stopFrames(state, true); break; }
        const result = await message(state.record, "frameWait");
        if (sourceFrames !== state) break;
        if (result?.streaming === false) { stopFrames(state, false, result.dismissed ?? true); break; }
        if (!result?.ok) break;
        if (updateFrameBounds(state, result)) void sendFrame(state, true);
        if (result.command) await runCommand(state.record, result.command);
      }
    } catch {}
    finally { state.waiting = false; }
  }

  async function sendFrame(state, forced = false, mediaTime = state.record.element.currentTime) {
    if (sourceFrames !== state || !state.active) return;
    if (!forced && state.retryAt > Date.now()) return;
    if (state.encoding) { state.refreshNeeded ||= forced; return; }
    const {record, canvas, painter} = state;
    const video = record.element;
    if (!sameSource(record)) { stopFrames(state, true); return; }
    const elapsed = mediaTime - state.lastMediaTime;
    if (!forced && elapsed >= 0 && elapsed < 0.031) return;
    state.encoding = true;
    state.lastMediaTime = mediaTime;
    try {
      sizeFrameCanvas(canvas, video, state.bounds, state.resolution);
      painter.drawImage(video, 0, 0, canvas.width, canvas.height);
      const media = snapshot(record);
      let image = await jpeg(canvas, state.quality);
      if (!image && state.quality > 0.66) {
        state.quality = 0.66;
        image = await jpeg(canvas, state.quality);
      }
      if (sourceFrames !== state) return;
      if (!image) {
        state.resolution = Math.max(0.625, state.resolution - 0.125);
        if (!forced) return;
      }
      state.latest = {image, media};
      void postLatestFrame(state);
    } catch {}
    finally {
      state.encoding = false;
      if (state.refreshNeeded) {
        state.refreshNeeded = false;
        void sendFrame(state, true);
      }
    }
  }

  async function postLatestFrame(state) {
    if (state.sending) return;
    state.sending = true;
    try {
      while (sourceFrames === state && state.latest) {
        const frame = state.latest;
        state.latest = undefined;
        const result = await message(state.record, "frame", frame).catch(() => null);
        if (sourceFrames !== state) break;
        if (result?.streaming === false) { stopFrames(state, false, result.dismissed ?? true); break; }
        if (result?.ok) {
          state.retryAt = 0;
          updateFrameBounds(state, result);
          if (result.command) {
            state.latest = undefined;
            await runCommand(state.record, result.command);
          }
        } else state.retryAt = Date.now() + 200;
      }
    } finally { state.sending = false; }
  }

  function release(record) {
    owned.delete(record);
    if (record.enforcePause) {
      record.element.removeEventListener("play", record.enforcePause);
      record.element.removeEventListener("playing", record.enforcePause);
      record.enforcePause = undefined;
    }
  }

  function restorePosition(element, time) {
    if (!Number.isFinite(time) || time < 0) return false;
    const ranges = element.seekable;
    let target;
    for (let i = 0; i < ranges.length; i++) {
      const bounded = Math.max(ranges.start(i), Math.min(ranges.end(i), time));
      if (target === undefined || Math.abs(bounded - time) < Math.abs(target - time)) target = bounded;
    }
    if (target === undefined && Number.isFinite(element.duration)) target = Math.min(time, element.duration);
    if (target === undefined) return false;
    try {
      element.currentTime = target;
      return Math.abs(element.currentTime - target) < 0.5;
    } catch { return false; }
  }

  async function runCommand(record, command) {
    const element = record.element;
    const matches = sameSource(record);
    const reply = {id: command.id, success: matches};
    let previouslyPlaying = false;
    let frames;
    if (matches && command.kind === "describe") {
      transfer = {record, deadline: Date.now() + 22000};
      reply.media = snapshot(record);
    } else if (record.youtubeID && command.kind === "startFrames") {
      const started = await startFrames(record);
      frames = started.frames;
      reply.success = Boolean(frames);
      if (frames) reply.media = snapshot(record);
      else reply.failure = started.failure;
    } else if (matches && (record.canMirror || sourceFrames?.record === record)
        && !owned.has(record) && ["toggle", "back", "forward"].includes(command.kind)) {
      if (command.kind === "toggle") {
        if (element.paused) {
          if (sourceFrames?.record === record) {
            try { await element.play(); }
            catch { reply.success = false; }
          } else void element.play().catch(() => {});
        } else element.pause();
      } else {
        reply.success = restorePosition(element, Math.max(0, element.currentTime + (command.kind === "back" ? -10 : 10)));
      }
      reply.media = snapshot(record);
    } else if (matches && record.url && command.kind === "claim") {
      previouslyPlaying = !element.paused;
      element.pause();
      reply.claimed = element.paused;
      reply.success = reply.claimed;
      if (reply.claimed) {
        record.lastContact = Date.now();
        owned.add(record);
        record.enforcePause = () => {
          if (!sameSource(record)) { release(record); return; }
          if (Date.now() - record.lastContact > 6000) {
            void exchange();
            return;
          }
          if (!element.paused) element.pause();
        };
        element.addEventListener("play", record.enforcePause);
        element.addEventListener("playing", record.enforcePause);
      }
    } else if (command.kind === "returnPlayback") {
      const held = owned.has(record);
      release(record);
      if (transfer?.record === record) transfer = undefined;
      reply.success = matches && held;
      if (reply.success) {
        reply.positioned = restorePosition(element, command.time);
        // Returning playback should not immediately offer to capture the same video again.
        dismissed.set(element, record.key);
        if (command.play) void element.play().catch(() => {});
        else element.pause();
      }
    } else if (command.kind !== "describe") {
      reply.success = false;
    }
    let ack;
    const acknowledge = () => message(record, "reply", {reply}).catch(() => null);
    ack = await acknowledge();
    if (command.kind === "startFrames" && (!ack || ack.reason === "network")) {
      ack = await acknowledge();
    }
    if (frames) {
      if (ack?.ok && ack.streaming !== false) {
        updateFrameBounds(frames, ack);
        frames.active = true;
        frames.update();
      } else stopFrames(frames, false, ack?.dismissed ?? false);
    }
    if (command.kind === "claim" && !ack?.ok) {
      release(record);
      if (previouslyPlaying && sameSource(record)) void element.play().catch(() => {});
    }
  }

  async function exchange() {
    if (busy) return;
    if (transfer && (Date.now() > transfer.deadline || !sameSource(transfer.record))) transfer = undefined;
    if (recentTarget && Date.now() > recentTarget.deadline) recentTarget = undefined;
    const records = new Set([transfer?.record, sourceFrames?.record, ...owned, target, recentTarget?.record].filter(Boolean));
    if (!records.size) return;
    busy = true;
    try {
      for (const record of records) {
        const frames = sourceFrames?.record === record ? sourceFrames : undefined;
        if (frames && !sameSource(record)) { stopFrames(frames, true); continue; }
        const playingOwned = owned.has(record);
        if (playingOwned && !sameSource(record)) {
          release(record);
          await message(record, "lost", {}, false).catch(() => {});
          continue;
        }
        let result;
        try {
          result = await message(record, "poll", {}, target === record && !playingOwned && !document.hidden);
        } catch {}
        if (frames?.active && result?.ok) {
          if (result.streaming === false) stopFrames(frames, false, result.dismissed ?? true);
          else {
            updateFrameBounds(frames, result);
            void waitForFrameCommand(frames);
          }
        }
        if (playingOwned) {
          if (result?.ok && result.owned) {
            record.lastContact = Date.now();
            if (!record.element.paused) record.element.pause();
          } else if ((result?.ok && !result.owned) || Date.now() - record.lastContact > 12000) {
            release(record);
          }
        }
        if (result?.command) await runCommand(record, result.command);
      }
    } finally {
      busy = false;
    }
  }

  function refresh() {
    if (document.hidden) {
      clearTarget();
      void exchange();
      return;
    }
    if (sourceFrames || owned.size || transfer) {
      clearTarget();
      void exchange();
      return;
    }
    const found = [];
    videos(document, found, {count: 9000});
    const video = found.map(element => ({element, weight: rank(element)}))
      .filter(candidate => candidate.weight > 0)
      .sort((a, b) => b.weight - a.weight)[0]?.element;
    if (!video) {
      clearTarget();
      void exchange();
      return;
    }
    if (!observed.has(video)) {
      observed.add(video);
      video.addEventListener("pause", () => {
        if (!owned.has(known.get(video))) dismissed.delete(video);
        refresh();
      });
    }
    const record = reference(video);
    if (!record) return;
    if (record !== target) {
      clearTarget();
      target = record;
    }
    void exchange();
  }

  document.addEventListener("playing", refresh, true);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden && transfer?.record.canMirror) withdraw(transfer.record);
    refresh();
  });
  window.addEventListener("pagehide", () => {
    if (transfer?.record.canMirror) message(transfer.record, "lost", {}, false).catch(() => {});
    clearTarget();
    if (sourceFrames) stopFrames(sourceFrames, true);
    for (const record of owned) {
      release(record);
      message(record, "lost", {}, false).catch(() => {});
    }
  });
  setInterval(refresh, 1100);
  setInterval(() => { if (transfer || sourceFrames || owned.size || recentTarget) void exchange(); }, 625);
  refresh();
})();
