# Dropbox Usage

A small native macOS menu-bar app that displays Dropbox quota as:

```text
2.31 / 2.5
```

Both values use binary gigabytes (GiB), matching the Dropbox quota display.

It calls Dropbox's `users/get_space_usage` endpoint every 15 minutes. The only
requested permission is `account_info.read`. OAuth uses PKCE, so the app does
not contain or request an App secret. The long-lived refresh token is stored in
the macOS Keychain.

## Build and install

The app requires macOS 13 or newer. To build it, install Apple's command-line
developer tools (`xcode-select --install`) with Swift 6 or newer, then run these
commands from this directory.

```zsh
./scripts/build-app.sh
./scripts/install.sh
open "$HOME/Applications/Dropbox Usage.app"
```

## One-time Dropbox setup

1. Open the [Dropbox App Console](https://www.dropbox.com/developers/apps) and
   choose **Create app**.
2. Choose **Scoped access**, **App folder**, and any unique app name.
3. On the app's **Permissions** tab, enable `account_info.read` and submit the
   change.
4. In Dropbox Usage, choose **Connect Dropbox…**, paste the **App key** from the
   app console, and continue.
5. Approve access in the browser. Dropbox displays an authorization code; copy
   it back into Dropbox Usage.
6. Optionally enable **Launch at Login** from the menu-bar menu.

The App secret is not used. **App folder** is selected only because Dropbox
requires a content-access choice when creating an API app; this program never
reads or modifies files.

## Menu commands

- **Refresh Now** immediately requests current quota.
- **Reconnect Dropbox…** repeats authorization, for example after revocation.
- **Open Dropbox Plan** opens Dropbox's account plan page.
- **Launch at Login** uses macOS's native login-item registration.
