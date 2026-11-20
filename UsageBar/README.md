# UsageBar

UsageBar shows your remaining Claude and Codex usage in the macOS menu bar.
The top row shows the five-hour session and the bottom row shows the weekly
limit. Each row includes a reset countdown.

## Build and open

You need an Apple silicon Mac running macOS 13 or later and Apple's Command
Line Tools with Swift 6 or newer. If the tools are missing, run
`xcode-select --install`.

Run these commands from the root of this repository.

```sh
cd UsageBar
./build.sh
open "./Usage Bar.app"
```

## Connect your accounts

- **Claude.** Click UsageBar in the menu bar, choose **Sign In to Claude…**,
  and close the sign-in window when you're done.
- **Codex.** Install the ChatGPT desktop app in `/Applications` and sign in
  there. UsageBar reads your limits through the Codex CLI bundled with
  `ChatGPT.app`.

UsageBar refreshes about every two minutes. Choose **Refresh Now** in the menu
to check immediately.
