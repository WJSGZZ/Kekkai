<div align="center">

<img src="Assets/icon-1024.png" width="128" alt="Kekkai icon">

# Kekkai

**Run a Mac app so it can only see its own data.**

*Kekkai* (結界) is Japanese for a protective barrier.

[English](README.md) · [简体中文](README.zh-CN.md)

</div>

Some apps scan your home folder, read your clipboard and leave files all over your Mac. Kekkai launches them inside macOS's built-in sandbox. The app keeps using its own data, so you stay signed in and keep your history, but your documents, desktop, downloads and other apps' data simply don't exist as far as it can tell. There's no virtual machine, and the app itself is never modified or re-signed.

## Quick start

You need macOS and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/WJSGZZ/Kekkai.git
cd Kekkai
./install.sh
```

Open `~/Applications/Kekkai.app`, pick an app from the list (or drag one onto the window), and click **Open in Kekkai**.

Quit the app completely before opening it from Kekkai. Copies launched from their own icon or from a web link aren't restricted.

## Features

- **Only its own data.** The app reads and writes its own folders in `~/Library`. Everything else gets "no such file", not "permission denied". That includes Downloads, Desktop, Documents, external drives and other apps' data. In the temp and cache folders every app shares, it sees only its own entries, and its temporary files go into its own folder instead. Its folders are found three ways: the bundle IDs of the app and its bundled helpers and extensions (`com.tencent.qq` and `com.tencent.qq.share` count, `com.tencent.qqmusic` doesn't), the group containers it declares, and folders in the usual data locations named exactly after the app (such as 微信开发者工具).
- **No peeking at your other apps.** System folders such as `/Applications` and `/Library/Application Support` can't be listed, asking macOS where an app is installed returns nothing, Spotlight returns none of your files, and other processes are hidden.
- **Folders on request.** If the app needs somewhere to save downloads, allow a folder for it on the detail page. You can remove it any time.
- **Always-blocked folders.** These override every allowed folder, apply in Learn Mode too, and can't be reached through symlinks. The defaults are `~/.ssh`, `~/.gnupg` and `~/.aws`.
- **Hidden user name.** The app sees the user name `user`.
- **Clipboard blocking.** Cut an app off from the clipboard entirely, including drag and drop. Camera, microphone and location are left to macOS, which already controls them per app; the detail page links to the right System Settings pages.
- **Per-app time zone.** Each app can show its own time zone.
- **Virtual location.** Search for a place or click the map, and that's the location the app gets whenever it asks macOS. There's no permission prompt, and the real location never reaches the app. In mainland China, the map's GCJ-02 coordinates are converted to the GPS (WGS-84) coordinates apps expect. The app runs as a copy while this is on. Apps that work out your location from your IP address need a proxy instead.
- **No escaping through other apps.** Apps launched through macOS run outside Kekkai (in testing, a helper launched this way went on to ask for Desktop access). So by default the app can't open other apps or send them automation commands. The catch is that links won't open in your browser; turn on "Allow opening other apps and links" on the detail page when you need that.
- **Block Log.** Every launch adds what the app tried to reach and was refused, grouped into categories such as "Checking which apps you have" and "Your personal files".
- **Trial run, then you decide.** The first time you open an app, Kekkai runs it with minimal access for about 40 seconds to see whether it works, whether its own log shows errors and whether macOS itself refused anything, then lists every request it denied, flagging suspicious ones such as checking which apps you have. Allow or deny each one. If the app quits, the requests denied just before it quit are flagged so you can allow them and try again. The macOS sandbox refuses on the spot and can't pause to ask, so you decide after the run rather than in a pop-up. Shared parent folders that would expose other apps' data, such as `~/Library/HTTPStorages`, can't be allowed.

The interface follows your system language (English or Chinese).

## Tested apps

Tested on macOS 27.2:

| App | Result |
|---|---|
| Baidu Netdisk | Starts on its existing data, stays signed in and fetches its file list. Downloads, Desktop and Documents are hidden, and an allowed folder can be read and written |
| Tencent Meeting | Starts on its existing data. Its Block Log shows that at launch it checks for Chrome, ChatGPT and a test copy of Chrome in `~/.cache`, all blocked |
| WeChat DevTools | Starts on its existing data, and the trial run shows no errors |
| QQ, WeChat | The unsandboxed copy reaches the QR sign-in screen, and the trial run shows no errors. At launch WeChat tries to list the shared temp and cache folders and is blocked. The copy keeps its own data (see below) |

With the clipboard blocked, the app can't reach the clipboard service at all. This goes further than macOS's own Paste from Other Apps setting, which only asks before an app reads the clipboard on its own.

## Apps with Apple's App Sandbox (QQ, WeChat)

Wrapped directly, these apps crash at launch inside macOS's own sandbox setup, however loose the Kekkai rules are. This happened with both QQ and WeChat. Instead, Kekkai makes an APFS clone of the app at `/Users/Shared/Kekkai/<bundle id>/Applications`, removes Apple's sandbox and any entitlements that need a developer certificate, re-signs the copy locally, and runs that copy inside Kekkai. The copy can't use the original data. macOS's System Policy lets only the app with the original signature into its sandbox container (`~/Library/Containers/<bundle id>`), and the re-signed copy is refused outright (tested: EPERM, logged as System Policy, not Kekkai). So the copy keeps its data in `/Users/Shared/Kekkai/<bundle id>`. You sign in once, and it stays.

- The original app isn't touched, and opening it from its own icon works as before. When the original updates, the copy is rebuilt on the next launch.
- The clone takes almost no space. Only the re-signed files use extra disk.
- The copy is signed differently, so you'll grant camera and microphone access again.
- The original and the copy each keep their own chat history. The copy only has what syncs from the cloud after you sign in.
- Without Apple's sandbox, the copy is limited only by Kekkai's rules.

## Compared with Apple's App Sandbox

Both use the same macOS sandbox engine, but the rules work in opposite directions:

- **Apple's App Sandbox** blocks everything by default and opens only what the app declares, such as network access, the camera, or files you pick. The developer decides whether to use it, and most apps from mainland China don't (on this Mac only QQ and WeChat do).
- **Kekkai** allows by default, then blocks the parts that matter: files, process information and launching other apps. It works on any app without the developer's help. The trade-off is that anything not explicitly blocked stays open, including the network, Bluetooth, USB and most system services.

So:
- For apps with no sandbox, like Baidu Netdisk and Tencent Meeting, Kekkai goes from nothing to a lot and is clearly stricter.
- For apps that already have Apple's sandbox, like QQ and WeChat, Kekkai's copy removes it, so the result isn't strictly stronger. Kekkai adds a hidden Downloads folder, hidden processes, the Block Log and virtual location, but loses Apple's "nothing unless declared" baseline. Unless you need a virtual location or want Downloads hidden, the original app is fine.

## Command line

The interface runs a Python script installed at `~/Library/Application Support/Kekkai/bin/kekkai`:

```text
kekkai run|trial|stop|blocked <App.app>
kekkai decide <bundle id> allow|deny <operation> <target>
kekkai list
kekkai allow <bundle id> add|rm <folder>
kekkai set-tz <bundle id> <time zone|->
kekkai set-block <bundle id> clipboard <on|off>
kekkai set-open <bundle id> <on|off>
kekkai set-location <bundle id> <latitude> <longitude> [name] | -
kekkai never list|add|rm [path]
```

A few apps need extra rules, which live in `rules/<bundle id>.json`. For example, Tencent Meeting creates lock files with random hex names in `/tmp` and in the home folder, and its `system_regex` allows only names like that. An app that really needs the shared temp folders can be given `"shared_tmp": true`.

The command line also keeps a disposable private space (`set-mode <bundle id> space`), where the app starts from scratch in its own home folder. It's handy for trying an app you don't trust yet.

## Limits

- Kekkai can't hide itself completely. An app can tell it's sandboxed, and the user ID is real.
- Only the time zone changes, not the clock. An app can still work out your location from your IP address or server time.
- A virtual location only replaces the macOS location API. An app that scans nearby Wi-Fi or uses your IP address may still find your real location.
- Network access isn't restricted, including probing ports on your own Mac (Baidu Netdisk logs that it "detected a local server").
- The list of running apps can't be hidden. It comes from macOS LaunchServices, and blocking that stops apps from launching at all (tested).
- The Block Log only covers refused requests, and the system log keeps only some repeats of the same request. What an app does inside its own data, and its network traffic, aren't logged.
- The keychain works as normal. The `block_keychain` rule blocks it, but sign-ins that rely on the keychain may then fail.
- Always-blocked folders are matched by path, so a hard link that already exists can still be read.
- System extensions, such as a cloud drive's sync extension, aren't restricted.
- It won't stop a program built to escape sandboxes. Apple has deprecated `sandbox-exec`, so a future macOS update could break Kekkai.

## License

[MIT](LICENSE)
