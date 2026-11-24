<img src="SafariExtension/icon.png" alt="Kadraj app icon" width="96">

# Kadraj

**English** · [Türkçe](README.tr.md)

Kadraj is an open-source macOS app that keeps a Safari video, a call window, or a selected region above your other apps. Hover over the floating window to make it transparent and click through to the app underneath. Hold **⌘** to show the controls.

[**Download Kadraj**](https://github.com/Emirbal23/Kadraj/releases/latest) · [Report an issue](https://github.com/Emirbal23/Kadraj/issues/new) · [MIT License](LICENSE)

## Install

1. On **macOS 14 or later**, open the [latest release](https://github.com/Emirbal23/Kadraj/releases/latest). Choose the Apple Silicon or Intel ZIP based on the chip or processor listed in ** → About This Mac**.
2. Unzip the download, move **Kadraj.app** to **Applications**, and open it. Kadraj appears in the menu bar. If you are updating, quit Kadraj first.
3. The download is ad hoc signed and has no Apple notarization. If macOS blocks the first launch and you trust the package, go to **System Settings → Privacy & Security → Open Anyway** after the first launch attempt. [Apple's launch instructions](https://support.apple.com/en-us/102445)

### Connect Safari

The app currently uses Turkish menu labels. These steps include the labels you will see in Kadraj.

1. Accept the first-launch prompt or choose **Kadraj → Ayarlar → Safari uzantısını etkinleştir…** (Settings → Enable Safari extension).
2. In Safari, go to **Settings → Advanced** and enable **Show features for web developers**. Under **Settings → Developer**, enable **Allow unsigned extensions**. Then go to **Settings → Extensions** and enable **Kadraj Safari**. Safari resets the unsigned-extension setting when you quit it. [Apple's Safari extension documentation](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)
3. From Kadraj's menu, choose **Safari’ye bağlan…** (Connect to Safari). The local tab pairs automatically. If Safari asks for local access, open the extension popup and click **Yerel bağlantıya izin ver** (Allow local connection).
4. Give the extension access to the video site, reload the tab, and play a video. Click **Kadraj’da aç** (Open in Kadraj) in the prompt next to the menu bar. If the five-second prompt disappears, look for **Bulunan videoyu Kadraj’da aç** (Open detected video in Kadraj) in the menu.

## Controls

| Action | How to use it |
| --- | --- |
| Control the window | Hover and hold **⌘**. You can pause and seek supported videos and see the elapsed time. Drag the window to move it or drag an edge to resize it. |
| Lock the aspect ratio | Click the lock icon in the controls. |
| Hide or show | Click the eye icon or press **⌃⌥⇧K**. Playback continues while hidden. |
| Close | Press **⌃⌥⇧W**. Configure the hide and close shortcuts under **Ayarlar → Klavye kısayolları** (Settings → Keyboard shortcuts). |
| Adjust transparency | Under **Kadraj → Ayarlar** (Settings), set the hover transparency and choose whether to show the **⌘** hint. |

## Supported sources

- **Safari and YouTube.** On supported YouTube videos, Kadraj shows frames from the original video tab. Safari handles playback and audio. When Safari grants access to the frames, you can switch tabs and keep the same video in Kadraj.
- **Direct media.** Kadraj can take over media URLs that macOS can play. When you close a video taken over from Safari, Kadraj attempts to return the current playback position to the original player.
- **Windows and regions.** Use **Videoyu yakala…** to capture a window region, **Pencereyi canlı sabitle…** to pin a live window such as a call, or **Görüntüyü sabitle…** to pin a single frame. macOS may ask for screen recording permission.
- **Limitations.** DRM-protected, session-restricted, and some embedded videos may be unavailable for direct playback. Capturing a visible region of a Safari tab depends on that tab staying visible.

## Safari permissions

The extension detects video elements on sites you allow. Pairing and frame transfer use the local connection (**127.0.0.1**) on your Mac. The pairing link is single-use. Kadraj does not transfer Safari cookies. Window and region capture use screen recording permission. Optional Apple Events detection uses Automation permission.

## Build from source

You'll need macOS 14 or later and Xcode or recent Xcode Command Line Tools. The build targets your Mac's processor architecture. Node.js is only needed for the JavaScript tests.

```sh
git clone https://github.com/Emirbal23/Kadraj.git
cd Kadraj
./build.sh
open build/Kadraj.app
```

```sh
node Tests/video.test.cjs
node Tests/safari-bridge.test.cjs
./build/Kadraj.app/Contents/MacOS/Kadraj --check-automation
./build/Kadraj.app/Contents/MacOS/Kadraj --check-window
```

When reporting an issue, include your macOS, Safari, and Kadraj versions and the steps to reproduce it. Keep pairing codes and private video links out of issue reports.

## License

Kadraj is released under the [MIT License](LICENSE). You may use, modify, and distribute the code, including commercially. Keep the copyright and license notices when distributing the software or a substantial part of it. The software is provided without warranty.
