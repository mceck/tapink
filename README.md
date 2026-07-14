# TapInk

Draw on top of your screen.
Live, over whatever is running underneath across every monitor you have connected. 


![TapInk](docs/logo.png)

TapInk lives quietly in the menu bar. Turns your whole desktop into a canvas whenever you need to point something out annotate a video call or mark up what's on screen.

[![TapInk](docs/demo.webp)](#)


## Installation

[Download here](https://github.com/mceck/tapink/releases/latest/download/TapInk.dmg)

Or build it from sources
```bash
Scripts/build.sh
Scripts/install.sh
```

TapInk isn't signed with a paid Apple Developer certificate, so macOS flags it as "unverified".
You'll need to allow opening in System Settings → Privacy & Security
or run this: `xattr -cr /Applications/TapInk.app`

## Features

* **Live overlay, not a screenshot.** The canvas shows on top of your screen in real time. If a video is playing underneath it keeps playing while you draw over it.

* **Multi-monitor support.** Draw across every display at once; the tool sidebar lives on one screen and can be dragged to another.

* **Full annotation tools.** Pen, highlighter, four shapes (rectangle, ellipse, line, arrow) a spotlight/flashlight tool that dims everything except a circle around your cursor and a text tool.

* **Two screenshot options.** Capture the display or drag out just the region you want and send either one straight to the clipboard or to disk. With a camera-shutter sound.

* **Screen recording, too.** Record the full display or just a selected region, saved as a video right next to your screenshots.

* **Global undo/redo.** One history shared across every monitor.

* **Unobtrusive design.** No Dock icon or app-switcher entry by default; toggle both back on whenever you want. Optional launch at login.

* **Customizable shortcuts.** Every action. Including drawing-tool selection. Has its keyboard shortcut, editable from Settings.

## Requirements

* macOS 14 (Sonoma). Later

* Xcode 15+ / the Swift 5.10 toolchain, if you're building from source

## First Launch: Permissions

TapInk needs two permissions:

| Permission | Why 
|---|---|
| System Settings → Privacy & Security → Accessibility | **Accessibility** For the ⌥Tab shortcut |
| System Settings → Privacy & Security → Screen Recording | **Screen Recording** For screenshots and recordings |

## Usage

### The menu bar icon

TapInk sits in the menu bar. Click it for:

* **Enable/Disable Drawing Mode**

* **Settings…**

* **About TapInk**

* **Quit TapInk**

### Entering Draw Mode

Press **⌥Tab** or use the menu. The screen doesn't freeze; everything keeps running with a

layer on top. A small floating toolbar appears on the screen with your cursor.

### Multi-monitor behavior

Draw on every display at once. The toolbar appears on one screen at a time.

### Taking screenshots

** screen:**

* **⌘S** saves a PNG to disk.

* **⌘C** copies it to the clipboard.

**Selected area:**

Click the camera dropdown or press **⌘⇧A**; drag out the region.

### Recording the screen

The camera button in the toolbar is a dropdown with four options: Screenshot Screen, Screenshot Area,
Record Screen, Record Area. Recordings save as `.mov` files in the same folder as your screenshots.

**Full screen:** press **⌘⇧R** to start, press it again to stop.

**Selected area:** press **⌘⌥R**, drag out the region to start recording it; press **⌘⌥R** again to stop.

Only one recording can run at a time. Leaving Draw Mode while recording finishes and saves the file
automatically. The mouse cursor is included in recordings by default (toggle it off in Settings).

### Undo, redo and clearing

* **⌘Z** / **⌘⇧Z** undo/redo one action at a time.

* **Delete** clears everything.

### Settings

Open, via the menu bar icon → **Settings…**:

* **Start at Login**

* **Hide from Dock and App Switcher**

* **Screenshot folder**

* **Selected-area screenshots go to**

* **Show cursor in recordings**

* **Start draw mode with sidebar hidden**

* **Shortcuts**

### Default shortcuts

Action | Default |
|---|---|
| Activate Draw Mode | ⌥ Tab |
| Exit Draw Mode | Esc |
| Copy Screenshot | ⌘C |
| Save Screenshot | ⌘S |
| Selected-Area Screenshot | ⌘⇧A |
| Record Screen | ⌘⇧R |
| Selected-Area Recording | ⌘⌥R |
| Freeze Background | L |
| Clear Canvas | Delete |
| Undo | ⌘Z |
| Redo | ⌘⇧Z |
| Pen Tool | P |
| Highlighter Tool | H |
| Shape Tool | S |
| Rectangle Shape | 1 |
| Ellipse Shape | 2 |
| Line Shape | 3 |
| Arrow Shape | 4 |
| Spotlight Tool | F |
| Text Tool | T |
| Move Tool | V |
| Eraser Tool | D |
| Hide Canvas | E |
| Toggle Sidebar | ⌥W |
| Hide Sidebar | ⌘W |
| Auto-Fade Drawings | Space |