(() => {
  const [session, selected, action, viewportEdge, includePaused, returnTime, returnPlaying] = request;
  const pageURL = location.pathname + location.search;
  if (window[session]?.url !== pageURL) {
    window[session] = { url: pageURL, ids: new WeakMap(), next: 0, page: Math.random().toString(36).slice(2) };
  }
  const state = window[session];
  const candidates = [];
  function visit(root, doc, x, y, clip) {
    for (const video of root.querySelectorAll("video")) {
      let box = video.getBoundingClientRect();
      const style = doc.defaultView.getComputedStyle(video);
      if (!video.videoWidth || style.visibility !== "visible" || Number(style.opacity) === 0) continue;
      if (style.objectPosition === "50% 50%" && ["contain", "scale-down"].includes(style.objectFit)) {
        const scale = Math.min(box.width / video.videoWidth, box.height / video.videoHeight,
          style.objectFit === "scale-down" ? 1 : Infinity);
        const dx = (box.width - video.videoWidth * scale) / 2;
        const dy = (box.height - video.videoHeight * scale) / 2;
        box = {left: box.left + dx, right: box.right - dx, top: box.top + dy, bottom: box.bottom - dy};
      }
      const left = Math.max(x + box.left, clip[0]), top = Math.max(y + box.top, clip[1]);
      const right = Math.min(x + box.right, clip[2]), bottom = Math.min(y + box.bottom, clip[3]);
      const visible = right - left >= 100 && bottom - top >= 60;
      let identity = state.ids.get(video);
      if (!identity || identity.source !== video.currentSrc) {
        identity = {id: state.page + ":" + ++state.next, source: video.currentSrc};
        state.ids.set(video, identity);
      }
      if (!visible && identity.id !== selected) continue;
      candidates.push({ video, id: identity.id, visible, left, top, right, bottom });
    }
    for (const frame of root.querySelectorAll("iframe")) {
      const sub = frame.contentDocument;
      if (!sub) continue;
      const b = frame.getBoundingClientRect();
      const l = x + b.left + frame.clientLeft, t = y + b.top + frame.clientTop;
      const visible = [Math.max(l, clip[0]), Math.max(t, clip[1]),
        Math.min(l + frame.clientWidth, clip[2]), Math.min(t + frame.clientHeight, clip[3])];
      if (visible[2] > visible[0] && visible[3] > visible[1]) visit(sub, sub, l, t, visible);
    }
    if (typeof doc.createTreeWalker === "function") {
      const walker = doc.createTreeWalker(root, 1);
      for (let element = walker.nextNode(); element && shadowBudget > 0; element = walker.nextNode()) {
        shadowBudget--;
        if (element.shadowRoot) visit(element.shadowRoot, doc, x, y, clip);
      }
    }
  }
  let shadowBudget = 7000;
  visit(document, document, 0, 0, [0, 0, innerWidth, innerHeight]);
  const area = o => (o.right - o.left) * (o.bottom - o.top);
  const match = selected ? candidates.find(o => o.id === selected) :
    candidates.filter(o => o.visible && (includePaused || !o.video.paused) && !o.video.ended && o.video.readyState >= 2
      && o.video.webkitPresentationMode !== "picture-in-picture"
      && o.video.ownerDocument?.pictureInPictureElement !== o.video)
      .sort((a, b) => Number(a.video.paused) - Number(b.video.paused) || area(b) - area(a))[0];
  if (!match || match.video.ended || outerWidth <= 0 || outerHeight <= 0) return "";
  const {video, id, visible, left, top, right, bottom} = match;
  let youtubeID = null;
  if (location.protocol === "https:" && /^(?:(?:www|m)\.)?youtube\.com$/i.test(location.hostname)) {
    if (video.mediaKeys || !video.classList.contains("html5-main-video")
        || !video.closest(".html5-video-player") || video.closest(".ad-showing, .ad-interrupting")) return "";
    const candidate = location.pathname === "/watch"
      ? new URL(location.href).searchParams.get("v")
      : /^\/(?:shorts|live|embed)\/([^/]+)\/?$/.exec(location.pathname)?.[1];
    if (!/^[\w-]{11}$/.test(candidate ?? "")) return "";
    youtubeID = candidate;
  }
  if (action === "pause") video.pause();
  if (action === "toggle") {
    if (video.paused) video.play().catch(() => {});
    else video.pause();
  }
  if (action === "back" || action === "forward") {
    const ranges = video.seekable;
    for (let i = 0; i < ranges.length; i++) {
      if (video.currentTime < ranges.start(i) || video.currentTime > ranges.end(i)) continue;
      const target = video.currentTime + (action === "back" ? -10 : 10);
      video.currentTime = Math.max(ranges.start(i), Math.min(ranges.end(i), target));
      break;
    }
  }
  let returnedPosition = null;
  if (action === "returnPlayback") {
    returnedPosition = false;
    if (returnTime && Number.isFinite(Number(returnTime)) && Number.isFinite(video.duration)) {
      const target = Math.max(0, Math.min(video.duration, Number(returnTime)));
      try {
        video.currentTime = target;
        returnedPosition = Math.abs(video.currentTime - target) < 0.5;
      } catch {}
    }
    if (returnPlaying) void video.play().catch(() => {});
    else video.pause();
  }
  // shortcut: Toolbar offset is approximate with sidebars and page zoom; refine with browser geometry if needed.
  const zoom = window.visualViewport && window.visualViewport.scale > 1
    ? window.visualViewport.scale : 1;
  const viewportWidth = Math.min(outerWidth, innerWidth * zoom);
  const side = viewportEdge === "right" ? outerWidth - viewportWidth : 0;
  const chrome = Math.max(0, outerHeight - innerHeight * zoom);
  return JSON.stringify({ id, title: document.title.slice(0, 260), paused: video.paused,
    rect: visible ? [(side + left * zoom) / outerWidth, (chrome + top * zoom) / outerHeight,
      (right - left) * zoom / outerWidth, (bottom - top) * zoom / outerHeight] : [],
    youtubeID, mediaURL: !youtubeID && /^https?:[/][/]/i.test(video.currentSrc) && !video.mediaKeys ? video.currentSrc : null,
    time: video.currentTime, returnedPosition, duration: Number.isFinite(video.duration) ? video.duration : null,
    volume: video.muted ? 0 : video.volume, seekable: video.seekable.length > 0 });
})()
