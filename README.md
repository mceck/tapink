# Drawzee

Draw on top of your screen.
Live, over whatever is running underneath across every monitor you have connected. 

![Drawzee](docs/logo.png)

Drawzee lives quietly in the menu bar. Turns your whole desktop into a canvas whenever you need to point something out annotate a video call or mark up what's on screen.

## Features

* **Live overlay, not a screenshot.** The canvas shows on top of your screen in real time.

If a video is playing underneath it keeps playing while you draw over it.

* **Multi-monitor support.** Draw across every display at once; the tool sidebar lives on one

screen and can be dragged to another.

* **Full annotation tools.** Pen, highlighter, four shapes (rectangle, ellipse, line, arrow) a

spotlight/flashlight tool that dims everything except a circle around your cursor and a text tool.

* **Two screenshot options.** Capture the display or drag out just the region you want and send

either one straight to the clipboard or to disk. With a camera-shutter sound.

* **Global undo/redo.** One history shared across every monitor.

* **Unobtrusive design.** No Dock icon or app-switcher entry by default; toggle both back on whenever

you want. Optional launch at login.

* **Customizable shortcuts.** Every action. Including drawing-tool selection. Has its keyboard

shortcut, editable from Settings.

## Requirements

* macOS 14 (Sonoma). Later

* Xcode 15+ / the Swift 5.10 toolchain, if you're building from source

## Building & Installing

Drawzee is a Swift Package. To build and install:

```bash

# quick compile check

swift build

# run the unit tests

swift test

# build a real signed.app bundle. Install it into /Applications

Scripts/build.sh

Scripts/install.sh

```

Then launch it like any other Mac app:

```bash

open /Applications/Drawzee.app

```

Installing to `/Applications` makes **Start at Login** work reliably.

> **Note:** always launch the `.app` bundle (`open Drawzee.app`) not the compiled binary.

## First Launch: Permissions

Drawzee needs two permissions:

| Permission | Why 
|---|---|
| System Settings → Privacy & Security → Accessibility | **Accessibility** For the ⌥Tab shortcut |
| System Settings → Privacy & Security → Screen Recording | **Screen Recording** For screenshots |

## Usage

### The menu bar icon

Drawzee sits in the menu bar. Click it for:

* **Enable/Disable Drawing Mode**

* **Settings…**

* **About Drawzee**

* **Quit Drawzee**

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

Click the camera button or press **⌘⇧A**; drag out the region.

### Undo, redo and clearing

* **⌘Z** / **⌘⇧Z** undo/redo one action at a time.

* **Delete** clears everything.

### Settings

Open, via the menu bar icon → **Settings…**:

* **Start at Login**

* **Hide from Dock and App Switcher**

* **Screenshot folder**

* **Selected-area screenshots go to**

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