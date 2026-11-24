const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const script = fs.readFileSync(path.join(__dirname, "../Resources/Video.js"), "utf8");

function video(left, top, width, height) {
  return {
    videoWidth: width, readyState: 4, paused: false, ended: false, currentTime: 55,
    duration: 120, volume: 0.6, muted: false, currentSrc: "https://example.test/test.mp4",
    getBoundingClientRect: () => ({ left, top, right: left + width, bottom: top + height }),
    seekable: { length: 1, start: () => 20, end: () => 60 },
    pause() { this.paused = true },
    play() { this.paused = false; return Promise.resolve() },
  };
}

const small = video(10, 15, 150, 85);
const large = video(100, 75, 800, 450);
const page = {
  title: "Deneme",
  defaultView: { getComputedStyle: () => ({visibility: "visible", opacity: "1"}) },
  querySelectorAll: selector => selector === "video" ? [small, large] : [],
};
const window = {};
const context = vm.createContext({
  window, document: page, location: { pathname: "/", search: "" }, innerWidth: 1000, innerHeight: 600, outerWidth: 1000, outerHeight: 700,
});
function probe(id = "", action = "", edge = "right", includePaused = "", returnTime = "", returnPlaying = "") {
  context.request = ["__test", id, action, edge, includePaused, returnTime, returnPlaying];
  const result = vm.runInContext(script, context);
  return result ? JSON.parse(result) : null;
}

const detected = probe();
assert.ok(detected.id);
assert.deepEqual(detected.rect, [0.1, 0.25, 0.8, 450 / 700]);
context.outerWidth = 1200;
assert.equal(probe().rect[0], 300 / 1200);
assert.equal(probe("", "", "left").rect[0], 100 / 1200);
context.outerWidth = 1000;
assert.equal(probe(detected.id, "toggle").paused, true);
assert.notEqual(probe().id, detected.id);
assert.equal(probe(detected.id, "toggle").paused, false);
probe(detected.id, "forward");
assert.equal(large.currentTime, 60);
probe(detected.id, "back");
assert.equal(large.currentTime, 50);
assert.equal(probe("other-page:1"), null);
context.location.search = "?v=next";
assert.notEqual(probe().id, detected.id);
assert.equal(probe(detected.id), null);
const next = probe().id;
large.ended = true;
assert.equal(probe(next), null);
assert.equal(probe(detected.id), null);
console.log("Video algılama, kırpma koordinatları, oynatma ve sarma kontrolleri geçti.");

large.ended = false;
small.paused = true;
large.paused = true;
assert.equal(probe(), null);
const paused = probe("", "", "right", "1");
assert.equal(paused.paused, true);
assert.equal(paused.mediaURL, large.currentSrc);
assert.equal(paused.seekable, true);
assert.equal(paused.volume, 0.6);
large.getBoundingClientRect = () => ({left: 100, top: -40, right: 820, bottom: 390});
assert.deepEqual(probe(paused.id).rect, [0.1, 100 / 700, 0.72, 390 / 700]);
large.getBoundingClientRect = () => ({left: 100, top: -800, right: 820, bottom: -400});
assert.equal(probe(paused.id, "toggle").paused, false);
assert.deepEqual(probe(paused.id, "pause").rect, []);
large.currentSrc = "blob:https://example.test/same-element";
assert.equal(probe(paused.id, "toggle"), null);
large.getBoundingClientRect = () => ({left: 100, top: 80, right: 820, bottom: 390});
assert.equal(probe("", "", "right", "1").mediaURL, null);
console.log("Duraklatılmış kaynak, kaydırma, video kaynağı değişimi ve doğrudan medya URL seçimi geçti.");


large.currentSrc = "https://example.test/returned.mp4";
const returning = probe("", "", "right", "1");
assert.equal(probe(returning.id, "returnPlayback", "right", "", "83", "").returnedPosition, true);
assert.equal(large.currentTime, 83);
assert.equal(large.paused, true);
assert.equal(probe(returning.id, "returnPlayback", "right", "", "45", "1").returnedPosition, true);
assert.equal(large.paused, false);
assert.equal(large.currentTime, 45);
console.log("Exact video identity and paused/playing position return passed.");

context.URL = URL;
context.location = new URL("https://www.youtube.com/watch?v=aqz-KE-bpKQ");
large.currentSrc = "blob:https://www.youtube.com/example";
large.classList = {contains: name => name === "html5-main-video"};
large.closest = selector => selector === ".html5-video-player";
const youtube = probe();
assert.equal(youtube.youtubeID, "aqz-KE-bpKQ");
assert.equal(youtube.mediaURL, null);
large.getBoundingClientRect = () => ({left: 0, top: -600, right: 800, bottom: -150});
assert.equal(probe(youtube.id, "pause").youtubeID, youtube.youtubeID);
console.log("YouTube identity remains available to browser automation after scrolling.");
