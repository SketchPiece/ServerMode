# Server Mode

Toggles server mode on a MacBook: plugged in, lid closed, never sleeping. Unplugged, it is a normal laptop again.

## Menu bar app

```bash
./build.sh --install          # build and copy to ~/Applications
open ~/Applications/ServerMode.app
```

A laptop icon means server mode is off, an Xserve icon means it's on. The menu has:

- **Turn Server Mode On/Off**: asks for your admin password. Shows "paused on battery" while unplugged.
- **Virtual Display**: an invisible monitor (1280×800, 1440×900 or 1920×1080), so a closed-lid Mac still has a screen for computer use. It replaces the HDMI dummy plug and comes back when the app restarts. **On** keeps it all the time, so with the lid open it extends your desktop and windows can end up on it. **Auto** turns it on only while the lid is closed and no other monitor is connected, and removes it when you open the lid. Look at it through Screen Sharing.
- **Checklist** (a submenu that says "All Set" or how many items need fixing): power, display, SSH, Screen Sharing, Tailscale, screen saver, App Nap in T3 Code and Helm, FileVault. Clicking an item that isn't ready fixes it or opens the right System Settings pane. The Tailscale item copies the Tailscale IP.
- **Battery Care**: charge, health (with the change since the first day it was recorded), cycles and battery temperature, plus the macOS charge limit (80–95% or off) and Charge to Full Now. When the battery reaches 40 °C you get a notification. A plugged-in server should sit at 80%: a battery kept full and warm wears out fastest. Health is logged once a day to `~/Library/Application Support/ServerMode/battery-health.csv`.
- **Launch at Login**: turn this on so the virtual display comes back after a reboot.

The virtual display uses the private `CGVirtualDisplay` API (the same one BetterDisplay and DeskPad use), so a future macOS update may break it.

## Script

```bash
./server-mode status   # mode, SSH, Screen Sharing, power, readiness checks, Tailscale
./server-mode on       # sudo: never sleep, even with the lid closed
./server-mode off      # sudo: restore normal sleep
```

`on` saves the current AC power settings (to `/Library/Application Support/ServerMode/`), then sets `sleep 0`, `disksleep 0`, `displaysleep 0`, `standby 0`, `powernap 0`, `womp 1` and `tcpkeepalive 1`, and installs the `com.sketchpiece.servermode.guard` LaunchDaemon. `off` removes the daemon and restores the saved values.

The daemon checks every 10 seconds. On AC power it sets `pmset -a disablesleep 1`, which keeps the Mac awake with the lid closed. On battery it sets `disablesleep 0`, and if the lid is already closed it puts the Mac to sleep, so the laptop doesn't drain its battery in a bag. Plugging back in doesn't wake a sleeping Mac: open the lid once and server mode resumes.

## One-time manual setup

1. **A display for the closed lid**: the app's Virtual Display, or an HDMI dummy plug in the HDMI port. Without one, computer use has nothing to capture.
2. **System Settings → General → Sharing**: turn on Remote Login and Screen Sharing.
3. **Tailscale**, to connect from outside your home network: `brew install --cask tailscale`. Use its own app, turn on "Launch at login", and in the admin console disable key expiry for this machine.
4. **Screen saver**: off (the checklist item turns it off). A locked screen doesn't stop running agents; it only matters for controlling the screen, and you can type the password over Screen Sharing.
5. **App Nap in T3 Code and Helm**: click the checklist item (or `defaults write com.t3tools.t3code NSAppSleepDisabled -bool YES` and the same for `com.sketchpiece.helm`), then restart the app. Otherwise macOS may throttle it once its windows are hidden.
6. **Battery**: set the charge limit to 80% in Battery Care.

## Battery Care on macOS 27

macOS 27 firmware removed the SMC keys that AlDente, batt and similar apps used to stop charging (`CHTE`, `CH0B`, `CH0C`, `BCLM`), and locked their replacements behind Apple entitlements. What's left is Apple's own charge limit (macOS 26.4+, Apple silicon, 80% to 100%). The app sets it through the private `PowerUISmartChargeClient` class in PowerUI.framework, which needs no admin rights, and checks each method's signature first so a macOS update can't make it crash. The firmware keeps the limit across sleep and reboots, and macOS still charges to 100% now and then to recalibrate. Temperature comes from the SMC key `TB0T`, because macOS 27 no longer puts it in the I/O Registry.

## Rebooting with FileVault on

On Apple silicon with macOS 26 or later, FileVault can be unlocked over SSH, as long as Remote Login was on before the reboot:

```bash
ssh <user>@<laptop LAN IP>   # asks for the password, unlocks the disk, closes the connection
```

Then connect with Screen Sharing and log in: computer use needs an active GUI session.

Tailscale doesn't run until the disk is unlocked, so you have to connect from the same local network. Remote unlock works only through a Tailscale subnet router on your router or another always-on device on that network. For planned reboots, `sudo fdesetup authrestart` is simpler: the Mac comes back up without asking for the password.
