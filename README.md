<div align="center">

<img src="Assets/icon-1024.png" width="128" alt="Kekkai icon">

# Kekkai

**Run a Mac app so it can only see its own files.**

*Kekkai* (結界) is Japanese for a protective barrier.

[English](README.md) · [简体中文](README.zh-CN.md)

</div>

Some apps scan your home folder, read your clipboard and leave files all over your Mac. Kekkai launches them inside macOS's built-in sandbox. The app works as usual, but your documents, your desktop and other apps' data simply don't exist as far as it can tell. There's no virtual machine, and the app itself is never modified or re-signed.

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

- **Private space.** Each app gets its own home folder at `/Users/Shared/Kekkai/<bundle id>` and starts as a fresh install. Your existing copy of the app and its data stay untouched. Every change stays in the private space, and you can discard it with one click. If you'd rather stay signed in, turn on **Bring existing data on first launch**. Kekkai then makes an APFS clone, which takes no extra disk space.
- **Hidden means missing.** Your home folder, `/Applications`, external drives, `/private/tmp` and other apps' data all look like they don't exist. The app gets "no such file", not "permission denied".
- **Hidden user name.** The app sees the user name `user`.
- **Clipboard blocking.** Cut an app off from the clipboard entirely, including drag and drop. Camera, microphone and location are left to macOS, which already controls them per app; the detail page links to the right System Settings pages.
- **Always-blocked folders.** These override every other rule, apply in Learn Mode too, and can't be reached through symlinks. The defaults are `~/.ssh`, `~/.gnupg` and `~/.aws`.
- **Learn Mode.** Run an app once without isolation to log which outside paths it touches, then decide what to allow.
- **Per-app time zone.** Each app can show its own time zone.
- **Exchange folder.** Use **Open Exchange Folder** to pass files in and out.

The interface follows your system language (English or Chinese).

## Tested apps

Tested on macOS 27.2:

| App | Result |
|---|---|
| Baidu Netdisk | Starts fresh to the sign-in screen. With existing data it stays signed in, lists files, and leaves the real data folder unchanged |
| Tencent Meeting | Reached the sign-in screen on three launches in a row |
| WeChat DevTools | Launches and writes only inside its private space |
| QQ, WeChat | Run as an unsandboxed copy. Both reach the QR sign-in screen and leave the real data folders unchanged. Use after sign-in hasn't been tested |

With the clipboard blocked, the app can't reach the clipboard service at all. This goes further than macOS's own Paste from Other Apps setting, which only asks before an app reads the clipboard on its own.

## Apps with Apple's App Sandbox (QQ, WeChat)

Wrapped directly, these apps crash at launch inside macOS's own sandbox setup, however loose the Kekkai rules are. This happened with both QQ and WeChat. Instead, Kekkai puts an APFS clone of the app in its private space, removes Apple's sandbox and any entitlements that need a developer certificate, re-signs the copy locally, and runs that copy inside Kekkai.

- The original app and its data aren't touched. Opening it from its own icon works as before.
- The copy starts fresh, so you'll sign in again. When the original updates, the copy is rebuilt on the next launch.
- The clone takes almost no space. Only the re-signed files use extra disk.
- macOS treats the copy as a different app, so you'll grant camera and microphone access again.
- Without Apple's sandbox, the copy is limited only by Kekkai's rules.

## Command line

The interface runs a Python script installed at `~/Library/Application Support/Kekkai/bin/kekkai`:

```text
kekkai run|learn|stop|report|reset <App.app>
kekkai list
kekkai set-tz <bundle id> <time zone|->
kekkai set-mode <bundle id> <space|real>
kekkai set-bring-old <bundle id> <on|off>
kekkai set-block <bundle id> clipboard <on|off>
kekkai never list|add|rm [path]
```

A few apps need extra rules, which live in `rules/<bundle id>.json`. For example, Tencent Meeting's `space_hide_stat` hides its old data folder at launch so it stops asking for access to "App Store version data".

## Limits

- Kekkai can't hide itself completely. An app can tell it's sandboxed, and the user ID is real.
- Only the time zone changes, not the clock. An app can still work out your location from your IP address or server time.
- Network access isn't restricted.
- The keychain works as normal. The `block_keychain` rule blocks it, but sign-ins that rely on the keychain may then fail.
- Preferences in group containers are still written to the real location.
- Always-blocked folders are matched by path, so a hard link that already exists can still be read.
- System extensions, such as a cloud drive's sync extension, aren't restricted.
- It won't stop a program built to escape sandboxes. Apple has deprecated `sandbox-exec`, so a future macOS update could break Kekkai.

## License

[MIT](LICENSE)
