importScripts("bridge.js");

const sources = new Map();
let frameToken;

async function callFromWorker(request, frames = false) {
  const token = frames && frameToken ? frameToken : (await browser.storage.local.get("token")).token;
  let result = await callKadraj(token, request);
  if (frames && result.reason === "code") {
    frameToken = undefined;
    const saved = (await browser.storage.local.get("token")).token;
    if (saved !== token) result = await callKadraj(saved, request);
    if (result.ok) frameToken = saved;
  } else if (result.ok) frameToken = token;
  return result;
}

async function closeTabSources(tabId) {
  const active = sources.get(tabId);
  sources.delete(tabId);
  if (!active?.size) return;
  await Promise.allSettled([...active.values()].map(video =>
    callFromWorker({operation: "lost", video})));
}

browser.runtime.onMessage.addListener(async (message, sender) => {
  if (message?.type === "kadraj-status") return await callFromWorker({operation: "ping"});
  if (message?.type === "kadraj-pair") {
    const from = sender.url ? new URL(sender.url) : null;
    if (from?.origin !== kadrajConnect.origin || from.pathname !== kadrajConnect.pathname
        || (sender.frameId ?? 0) !== 0 || !/^[a-f0-9]{32}$/.test(message.ticket ?? "")) return {ok: false, reason: "code"};
    const result = await postKadraj({operation: "pair", ticket: message.ticket});
    if (!/^[a-f0-9]{32}$/.test(result.token ?? "")) return {ok: false, reason: result.reason};
    await browser.storage.local.set({token: result.token});
    frameToken = result.token;
    return {ok: true};
  }
  const tabId = sender.tab?.id;
  if (message?.type !== "kadraj-video" || !Number.isInteger(tabId)) return;
  let request = message.request;
  if (request?.video?.mirrorOnly) {
    if ((sender.frameId ?? 0) !== 0) return {ok: false};
    if (sender.tab.active === false && request.operation === "poll") {
      request = {...request, available: false, open: false};
    }
    if (sender.tab.active === false && request.reply?.media?.mirror) {
      request = {...request, reply: {...request.reply, media: {...request.reply.media, mirror: null}}};
    }
  }
  let active = sources.get(tabId);
  if (!active) {
    active = new Map();
    sources.set(tabId, active);
  }
  const video = request?.video;
  const frames = request?.operation === "frame" || request?.operation === "frameWait";
  if (video && frames) active.set(video.id, video);
  if (video && request.operation === "lost") active.delete(video.id);
  const result = await callFromWorker(request, frames);
  if (video && sources.get(tabId) === active) {
    if (result.streaming || result.owned) active.set(video.id, video);
    else if (result.streaming === false && !result.owned) active.delete(video.id);
  }
  return result;
});

browser.tabs.onRemoved.addListener(closeTabSources);
browser.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === "loading") return closeTabSources(tabId);
});
