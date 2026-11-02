<div align="center">

<img src="Assets/icon-1024.png" width="128" alt="Kekkai icon">

# Kekkai

**Run a Mac app so it can only see its own data.**

*Kekkai* (結界) is Japanese for a protective barrier.

[English](README.md) · [简体中文](README.zh-CN.md)

</div>

Some apps scan your home folder, read your clipboard and leave files all over your Mac. Kekkai launches them inside macOS's built-in sandbox, with one rule for every app: each app gets its own Kekkai folder, and its existing data is copied in automatically the first time, so you stay signed in and keep your history. From then on it works only inside that folder, and your documents, desktop, downloads and other apps' data simply don't exist as far as it can tell. No virtual machine, and no per-app rules to write.

## Quick start

You need macOS and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/WJSGZZ/Kekkai.git
cd Kekkai
./install.sh
```

To install on another Mac, run `scripts/make-dmg.sh`; the disk image lands in `build/`, and installing is a drag to Applications. The image is ad-hoc signed, not notarized, so the first launch there needs **Open Anyway** in System Settings › Privacy & Security. That Mac also needs the Command Line Tools, whose Python runs Kekkai's helper script.

Open `Kekkai.app` in Applications, click **+** at the top right to pick an app, or drag one onto the window. Adding an app is its first trial run: it's added only if it starts properly in Kekkai; if not, Kekkai tells you why and leaves it out, and any permission it can't do without is found along the way. Added apps appear as large icons: double-click one to open it in Kekkai, or click once to see its settings and Block Log on the right.

Quit the app completely before opening it from Kekkai. Copies launched from their own icon or from a web link aren't restricted.

## Features

- **Lives in its own Kekkai folder.** Each app's data goes in `/Users/Shared/Kekkai.noindex/<bundle id>`, and its home folder points there too, so it can't even see your user name in a path. At first launch Kekkai finds the app's existing data three ways and clones it in with APFS (almost no extra space, original untouched): the bundle IDs of the app and its bundled helpers and extensions (`com.tencent.qq` and `com.tencent.qq.share` count, `com.tencent.qqmusic` doesn't), the group containers it declares, and folders in the usual data locations named exactly after the app (such as 微信开发者工具). If something is missed, the app just has a bit less of its own old data; it can't reach anyone else's. After that the app and the original keep separate data; choose Import Data from Original on the detail page to sync again. Everything else gets "no such file", not "permission denied", and in the temp and cache folders every app shares, it sees only its own entries.
- **A few apps run in place.** Tencent Meeting remembers its data folder with a bookmark that breaks if the folder moves, so it would have to sign in again (tested). Its rule keeps it on its existing data in place, still unable to see anything else.
- **No peeking at your other apps.** System folders such as `/Applications` and `/Library/Application Support` can't be listed, asking macOS where an app is installed returns nothing, Spotlight returns none of your files, and other processes are hidden.
- **Folders on request.** If the app needs somewhere to save downloads, allow a folder for it on the detail page. You can remove it any time.
- **Always-blocked folders.** These override every allowed folder, apply in Learn Mode too, and can't be reached through symlinks. The defaults are `~/.ssh`, `~/.gnupg` and `~/.aws`.
- **Permissions.** Set per app; on means allowed, and everything is off by default: Clipboard and drag and drop, Your keychain, Other processes, Ports on this Mac, and Opening other apps and links. Baidu Netdisk, Tencent Meeting, WeChat and QQ all start with everything off and show no errors. Your real user name is always hidden. Time zone and virtual location live under Disguise.
- **Finds the permissions an app needs on first launch.** It opens with the optional permissions off. If the app quits within 30 seconds, Kekkai looks at what was blocked just before and turns on only the matching permission. The system log doesn't always record it (a program that quit instantly left nothing, tested), so failing that, Kekkai turns them all on and switches them back off one at a time, keeping only the ones the app needs. Tested with a program that quits when it can't reach a local port: within 39 seconds only Ports on this Mac was turned on. This only shows whether the app starts. Whether sign-in, pasting and the like still work is something you'll see when you use it.
- **A keychain per app.** Each app's keychain lives in its own Kekkai folder (`Library/Keychains/kekkai.keychain-db`), with a random password that Kekkai keeps and uses to unlock it before each launch. Sign-ins the app saves stay there and are remembered next time. It can't read your keychain or list what's in it. Tested inside WeChat DevTools' sandbox: it could store and read its own item, couldn't find the "Chrome Safe Storage" item that exists in your keychain, and your keychain list never changed. The catch is that sign-ins stored in your keychain don't come along, so you sign in once more. The file can't be named `login.keychain-db`: macOS treats that name specially and won't unlock it (tested).
- **Hidden user name.** The system's user lookups are blocked for every app. When an app's signature allows injection (most do, and so do the copies Kekkai re-signs), a small Kekkai library answers instead: you are `user` and your home is the Kekkai folder. Child processes get the same answer, so tools such as WeChat DevTools, whose compiler looks up the user, keep working. Apps whose signature forbids injection are simply blocked, and a few may fail because of it. Two places can't be hidden: the path of any folder you approve contains your user name, and Tencent Meeting runs in place with your real home folder.
- **Disguised device.** The serial number, hardware UUID, network addresses and computer name an app sees are a set Kekkai made for that app alone (the computer name is the model, such as "MacBook Air"). Each app gets a different set that never changes, so sign-ins aren't treated as a new device every time, and apps can't link you through device IDs. Apps whose signature forbids injection just can't read these. Things many Macs share, such as model and macOS version, are left as is. New Identity on the detail page makes a new set; device IDs an app saved itself go only when you clear its data. Your IP address is outside Kekkai's reach; use a proxy for that.
- **No touching other programs' ports.** Proxy dashboards, dev servers and local interfaces opened by other apps are out of reach, except the system proxy's port. In testing, Baidu Netdisk probed every 32nd port from 7475 at launch and QQ tried 9210–9219; all were blocked and both kept working. Connections to temporary ports above 49152 usually come from the app's own parts, so they're listed first in the Block Log for you to decide. Apps whose job is local development, such as WeChat DevTools, are allowed by their rule, and you can change that under Permissions. Kekkai can't block devices on your network: the macOS sandbox only accepts "any address" or "this Mac" (a subnet is rejected, tested). Turn that off under Privacy & Security › Local Network.
- **Clipboard.** Cut off entirely by default, along with drag and drop, so even copy and paste inside the app stops working; turn it on per app when you need it. Camera, microphone and location are left to macOS, which already controls them per app; the detail page links to the right System Settings pages.
- **Per-app time zone.** Each app can show its own time zone.
- **Virtual location.** Search for a place or click the map, and that's the location the app gets whenever it asks macOS. There's no permission prompt, and the real location never reaches the app. In mainland China, the map's GCJ-02 coordinates are converted to the GPS (WGS-84) coordinates apps expect. The app runs as a copy while this is on. Apps that work out your location from your IP address need a proxy instead.
- **No escaping through other apps.** Apps launched through macOS run outside Kekkai (in testing, a helper launched this way went on to ask for Desktop access). So by default the app can't open other apps or send them automation commands. The catch is that links won't open in your browser; turn on "Allow opening other apps and links" on the detail page when you need that.
- **Open new apps directly.** No rules to write and no test run first. Any app sees only its own data by default, and an app kept in Downloads still can't see Downloads. Tested with a never-seen test app built for the purpose: it could write its own data but couldn't see Downloads or the shared temp folders.
- **Live Block Log, and you decide.** While the app runs in Kekkai, its detail page refreshes every few seconds with what was blocked. You don't need to do anything with it day to day. If the app quits unexpectedly, requests that were blocked just before and can be allowed come first, and you allow or deny each one; changes apply when you reopen it. Everything else is folded into three tiers, all still blocked: Overreach (probing beyond what the app is for, such as scanning installed apps, inspecting other running programs or probing local ports), Worth a look (may be normal, but you should know), and Routine (sent by system frameworks on their own, such as spell checking and crash reports). Places that would expose other apps' data, such as `~/Library/HTTPStorages`, the shared temp folders and the keychain, can't be allowed. If the app quits within a minute of opening, the page says so and shows errors from its own log.

The interface follows your system language (English or Chinese).

## Tested apps

Tested on macOS 27.2:

| App | Result |
|---|---|
| Baidu Netdisk | Runs in its Kekkai folder, stays signed in after its data is copied in, and fetches its file list. Downloads, Desktop and Documents are hidden, and an allowed folder can be read and written |
| Tencent Meeting (direct download) | It checks its own signature, so a copy won't run. In a Kekkai folder it asks you to re-grant its data folder at every launch (it tracks its data with a bookmark and lacks the entitlement to make a new one), so it runs in place and stays signed in. Its Block Log shows that at launch it checks for Chrome, ChatGPT and a test copy of Chrome in `~/.cache`, all blocked |
| Tencent Meeting (App Store, VooV Meeting) | The unsandboxed copy runs in its Kekkai folder and reaches the sign-in screen with no prompts; the fake user and device can be injected |
| WeChat DevTools | Runs in its Kekkai folder with its project history carried over and no errors; with its own keychain, you scan the sign-in code once more |
| QQ, WeChat | The unsandboxed copy reaches the QR sign-in screen, and a 40-second trial run shows no errors. In one session QQ was logged looking at other processes more than 600 times and checking which apps you have 15 times. At launch WeChat tries to list the shared temp and cache folders and is blocked. The copy keeps its own data (see below) |

With the clipboard blocked, the app can't reach the clipboard service at all. This goes further than macOS's own Paste from Other Apps setting, which only asks before an app reads the clipboard on its own.

## Apps with Apple's App Sandbox (QQ, WeChat)

Wrapped directly, these apps crash at launch inside macOS's own sandbox setup, however loose the Kekkai rules are. This happened with both QQ and WeChat. Instead, Kekkai makes an APFS clone of the app at `/Users/Shared/Kekkai.noindex/<bundle id>/Applications`, removes Apple's sandbox and any entitlements that need a developer certificate, re-signs the copy locally, and runs that copy inside Kekkai. The copy can't use the original data. macOS's System Policy lets only the app with the original signature into its sandbox container (`~/Library/Containers/<bundle id>`), and the re-signed copy is refused outright (tested: EPERM, logged as System Policy, not Kekkai). So the copy keeps its data in `/Users/Shared/Kekkai.noindex/<bundle id>`. Apple's sandbox keeps all of such an app's data in its container, so it's clear what to bring along: when the copy is first created, Kekkai clones the container's data into it with APFS, leaving the original untouched. In testing, QQ recognized the account after the import but still stopped at its one-click sign-in screen, because sign-in credentials are held by Apple per signature and the copy can't read them. You can also choose Import Data from Original on the detail page at any time to replace the copy's data.

- The original app isn't touched, and opening it from its own icon works as before. When the original updates, the copy is rebuilt on the next launch.
- The clone takes almost no space. Only the re-signed files use extra disk.
- The copy is signed differently, so you'll grant camera and microphone access again.
- After an import, the two don't sync. Opening the original directly uses the original's data, outside Kekkai. To always go through Kekkai, use the arrow next to Open in Kekkai to add a launcher such as "QQ Kekkai" to Applications, then keep it in the Dock or open it from Spotlight.
- Without Apple's sandbox, the copy is limited only by Kekkai's rules.
- Apps that check their App Store purchase receipt (tested: Bandizip, exit code 173) can't run as a copy, and Kekkai says why. Use the original for those; it already runs in Apple's sandbox.

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
kekkai blocked <App.app> --json
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
- Internet access isn't restricted, and devices on your network are left to macOS's Local Network permission.
- The list of running apps can't be hidden. It comes from macOS LaunchServices, and blocking that stops apps from launching at all (tested).
- The Block Log only covers refused requests, and the system log keeps only some repeats of the same request. What an app does inside its own data, and its network traffic, aren't logged.
- Apps that run in place (such as Tencent Meeting) don't get their own keychain. With Your keychain off, the keychain is blocked entirely, and sign-ins that rely on it may fail.
- Always-blocked folders are matched by path, so a hard link that already exists can still be read.
- System extensions, such as a cloud drive's sync extension, aren't restricted.
- macOS Gatekeeper still refuses downloaded apps that aren't notarized by Apple, and Kekkai doesn't get around it. The detail page explains why; whether to click Open Anyway in Privacy & Security is up to you.
- It won't stop a program built to escape sandboxes. Apple has deprecated `sandbox-exec`, so a future macOS update could break Kekkai.

## License

[MIT](LICENSE)
