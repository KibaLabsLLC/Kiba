<p align="center">
  <img src="https://raw.githubusercontent.com/KibaLabsLLC/Kiba/main/branding/A25ACB5D-92F7-4408-8972-CBD562BE4898.png" width="250" alt="KibaOS Banner">
</p>

<p align="center">
  <a href="https://github.com/sponsors/KibaLabsLLC">
    <img src="https://img.shields.io/badge/Sponsor-Kiba_Labs-ea4aaa?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="Sponsor Kiba Labs">
  </a>
</p>

> [!IMPORTANT]
> KibaOS only supports UEFI-based systems. The mobile version only supports Android devices that support TrebleDroid and have TWRP. It cannot be above or below Android 9 or compatibility will fail.

<div align="center">

# [KibaOS](https://kibaos.com)
### An OS by Kiba Labs, LLC

<p align="center">
  <img src="https://raw.githubusercontent.com/KibaLabsLLC/Kiba/main/branding/oin-member-2-0-horiz-1.png" alt="OIN Member" width="200">
</p>

**A friendly, ready-to-use Linux desktop, built for people switching to simple.**

[![Build Status](https://img.shields.io/github/actions/workflow/status/KibaLabsLLC/Kiba/build.yml?branch=main&label=Build&style=for-the-badge&logo=githubactions&logoColor=white)](https://github.com/KibaLabsLLC/Kiba/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-3DDC97?style=for-the-badge&logo=opensourceinitiative&logoColor=white)](#license)
[![SourceForge](https://img.shields.io/sourceforge/dt/kibaos?style=for-the-badge&color=orange&logo=sourceforge&logoColor=white)](https://sourceforge.net/projects/kibaos/)

<img src="https://img.shields.io/github/repo-size/KibaLabsLLC/Kiba?style=flat-square&color=blue" alt="Repo Size">
<img src="https://img.shields.io/github/stars/KibaLabsLLC/Kiba?style=flat-square&color=yellow" alt="Stars">
<img src="https://img.shields.io/github/forks/KibaLabsLLC/Kiba?style=flat-square&color=lightgrey" alt="Forks">
<img src="https://img.shields.io/github/last-commit/KibaLabsLLC/Kiba?style=flat-square&color=green" alt="Last Commit">

<br>

[![Download KibaOS](https://a.fsdn.com/con/app/sf-download-button)](https://sourceforge.net/projects/kibaos/files/latest/download)

</div>

---

<p align="center">
  <img width="1000" alt="KibaOS Desktop Screenshot" src="https://distrowatch.com/images/slinks/kibaos.png">
</p>

---

KibaOS is built on **Arch Linux** (the "Rolling" release, meaning it's always kept up to date rather than released in big yearly versions). It uses the **Budgie** desktop environment and is designed so that anyone can sit down and use it immediately, without having to configure anything first.

Every piece of it — the installer, the app icons, the terminal, even the boot screen — is chosen or built with one rule in mind: **nothing should look or feel like it's still showing you the plumbing.**

KibaOS is built and maintained by **Kiba Labs, LLC**.

> [!NOTE]
> New to Linux? A "distribution" (or "distro") is just a complete, ready-to-install version of the Linux operating system, bundled with a desktop environment, apps, and settings. KibaOS is one such distribution.
---

<img width="2172" height="724" alt="Kiba Labs banner" src="https://github.com/user-attachments/assets/0dfcfaf9-1fbc-4fd4-88d2-addd1bb46507" />

## Table of Contents

- [What KibaOS Includes](#what-kibaos-includes)
- [Design & Theming](#design--theming)
- [Getting Started](#getting-started)
  - [Step 1: Download the ISO](#step-1-download-the-iso)
  - [Step 2: Write It to a USB Drive](#step-2-write-it-to-a-usb-drive)
  - [Step 3: Try the Live Session](#step-3-try-the-live-session)
  - [Step 4: Install KibaOS](#step-4-install-kibaos)
- [System Requirements](#system-requirements)
- [Everyday Use](#everyday-use)
  - [Managing Apps with pacman](#managing-apps-with-pacman)
  - [Running Windows Programs with Windows Workspace](#running-windows-programs-with-windows-workspace)
  - [Automatic Updates](#automatic-updates)
- [Building KibaOS Yourself](#building-kibaos-yourself)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)
- [About](#about)

---

## What KibaOS Includes

KibaOS aims to work well right out of the box, so there's no need to spend an afternoon installing extra software just to get a usable computer.

| Feature | What it means for you |
| --- | --- |
| **A solid foundation** | Built on Arch Linux, a well-respected base known for staying current and supporting the newest hardware. |
| **A clean, familiar desktop** | The Budgie desktop environment provides a taskbar, a centered dock, and a clock applet, laid out so everything is easy to find. |
| **Everyday apps, already installed** | A file manager (Nemo), a web browser, a calculator, a calendar, email (Geary), notes, music, and a to-do list app — all picked or relabeled so they read as plain, simple tools instead of a pile of separately-branded software. |
| **A simple terminal, when you need it** | The built-in terminal is deliberately minimal — one window, no tabs, no menus — for the rare moments you need it, without it ever feeling like the "real" way to use the computer. |
| **`kiba`, a friendly app manager** | Install, remove, and update software with plain-language commands instead of memorizing package-manager flags. See [Managing Apps with pacman](#managing-apps-with-pacman). |
| **A guided setup experience** | KibaOS's own built-in installer (the OOBE app, short for "Out-Of-Box Experience") asks you one simple question at a time. |
| **A calm, uncluttered live session** | The trial/install session never dims, locks, or falls asleep on you mid-setup, and stays free of raw system dialogs, developer tools, and other things you'd never need to see. |
| **Windows Workspace** | A real Windows environment runs alongside KibaOS and opens full-screen with one click — Office, Photoshop, and most other Windows programs work as they normally would. |
| **Automatic background updates** | Small fixes download and apply on their own, without interrupting what you're doing. |

> [!TIP]
> If a word here is unfamiliar — like "desktop environment" or "ISO" — don't worry. We explain each one the first time it comes up.

---

## Design & Theming

KibaOS's look isn't an afterthought bolted onto stock Arch + Budgie — every visual layer is deliberately chosen so the system feels like one coherent product, not a collection of default Linux app icons and system dialogs.

| Layer | What's used | Why |
| --- | --- | --- |
| **Boot splash** | Custom KibaOS Plymouth theme | Replaces the default boot screen with a clean, branded animated splash — the first thing you see sets the tone. |
| **App icons** | Kora icon theme | A consistent, modern, colorful icon set across every app, providing visual cohesion. |
| **Window & UI theme** | Ant-Dark with Dracula color scheme | A calm dark base with Dracula palette that avoids visual noise while staying easy on the eyes. |
| **Motion** | KibaOS's own "Organic Motion Language" | A shared set of named, natural-feeling animation curves used consistently across the desktop and installer. |
| **App branding** | De-branded where it matters | Apps that would otherwise show separate branding are relabeled to plain, generic names — "Browser," "App Store," "Settings" — so the desktop reads as one cohesive product. |

---

## Getting Started

### Step 1: Download the ISO

An **ISO file** is a single file that contains an entire disc's (or USB drive's) worth of data. It's how most Linux operating systems are distributed. You'll write this ISO onto a USB drive, then boot your computer from that USB drive to try or install KibaOS.

You can download the latest KibaOS ISO file here:

[![SourceForge](https://img.shields.io/badge/Download-SourceForge-orange?style=for-the-badge&logo=sourceforge)](https://sourceforge.net/projects/kibaos/files/)

> [!IMPORTANT]
> Each release comes with a SHA256 checksum, which is a short code used to verify your download wasn't corrupted or tampered with. It's good practice to check it, though not strictly required to get started.

### Step 2: Write It to a USB Drive

You'll need a USB flash drive (8 GB or larger is recommended) that you don't mind erasing — everything currently on it will be deleted.

Free graphical tools like [Balena Etcher](https://etcher.balena.io) or [Ventoy](https://www.ventoy.net) make this easy — you just select the ISO file and the USB drive, and click "Flash."

> [!TIP]
> On Linux, you can also use `dd` command: `sudo dd if=kibaos.iso of=/dev/sdX bs=4M status=progress && sync` (replace `sdX` with your USB device)

### Step 3: Try the Live Session

A **live session** lets you try KibaOS directly from the USB drive, without installing anything or changing your computer in any way. This is a great way to check that your hardware (Wi-Fi, graphics, etc.) works well with KibaOS before committing to install it.

1. Plug in the USB drive
2. Restart your computer and open the boot menu (usually by pressing a key like `F12`, `F2`, `Esc`, or `Del` right after powering on — it varies by computer)
3. Choose the USB drive from the list
4. KibaOS will boot and log you in automatically

> [!NOTE]
> Anything you do in the live session — files you create, settings you change — is **not saved** once you restart. It's meant only for trying things out. To make KibaOS permanent, continue to Step 4.

#### Default Login (Live Session Only)

These accounts only exist while you're trying KibaOS from the USB drive — they are replaced by your own account when you install:

| Account | Password |
| ------- | -------- |
| `liveuser` | `live` |

### Step 4: Install KibaOS

From the live desktop, open the **"Install KibaOS"** icon. This launches KibaOS's own built-in installer (Calamares), which asks you a few simple questions one at a time:

1. Your preferred language and region
2. Your keyboard layout
3. Which disk to install onto
4. Your username and password
5. A short confirmation screen before anything is written to disk

After you confirm, the installer prepares your disk, copies KibaOS onto it, sets up the GRUB bootloader, and finishes by creating your personal user account. Behind the scenes, it uses the well-tested [Calamares](https://calamares.io) installer framework with custom KibaOS branding and modules.

> [!CAUTION]
> Installing KibaOS will erase the disk you choose in step 3 above. Make sure you've backed up anything important, and double check you're installing to the correct disk if your computer has more than one.

Once installation finishes, restart your computer, remove the USB drive, and KibaOS will start normally from your computer's own disk.

---

## System Requirements

| Component | Minimum                | Recommended         |
| --------- | ---------------------- | -------------------- |
| **CPU**   | 64-bit (x86_64)        | Dual-core or better |
| **RAM**   | 2 GB                   | 4 GB (recommended) |
| **Disk**  | 20 GB free space       | SSD recommended for best performance |
| **Graphics** | GPU supporting OpenGL 2.0 | Dedicated graphics card for best experience |

---

## Everyday Use

### Managing Apps with pacman

KibaOS includes **KibaStore** (Bazaar) as the primary graphical app store for managing Flatpaks. For terminal users, **pacman** is configured as the primary package manager with helpful aliases.

> [!TIP]
> Most people won't need the terminal for package management — **KibaStore** handles installing and updating apps visually. The terminal commands are there for power users who prefer typing.

### Using KibaStore (Graphical)
- Browse and install Flatpak applications from Flathub
- Automatic updates for installed applications
- Clean, modern GTK4 interface

### Using Terminal (pacman)

Common package management commands:
```bash
update          # Update all packages (alias for sudo pacman -Syu)
install <pkg>   # Install a package
remove <pkg>    # Remove a package
search <term>   # Search for packages
```

### Running Windows Programs with Windows Workspace

### Windows Workspace (Optional Feature)

KibaOS includes **Windows Workspace** — the reverse of what its name implies: instead of Windows running a Linux environment inside it, KibaOS can run a real Windows environment inside itself. This lets you use Windows-only programs like Microsoft Office or Photoshop without leaving KibaOS or setting up a separate computer.

The first time you open **"Run Windows Workspace"** from the app menu, KibaOS downloads and installs Windows automatically in the background — no product key or install disc needed. This takes 15-20 minutes and requires about 30 GB of free disk space.

After that, opening **"Run Windows Workspace"** brings up the full Windows desktop, full-screen. Press `Super+K` at any time to switch back to your KibaOS desktop without closing Windows — everything stays running in the background, ready when you switch back.

> [!TIP]
> Not every Windows program will work perfectly — this depends on the program itself, not on KibaOS. Windows Workspace works best with at least 4 GB of RAM allocated to the Windows environment on top of what KibaOS itself is using.

> [!NOTE]
> Windows Workspace is an optional feature that must be manually enabled and configured after installation.

### Automatic Updates

KibaOS checks for updates in the background and can apply them automatically, without interrupting your work. You can also manually update by running `update` in the terminal or using KibaStore.

---

## Building KibaOS Yourself

If you'd like to build your own copy of the KibaOS ISO from source instead of downloading the prebuilt one, you'll need:

- [Docker](https://www.docker.com) installed
- A Linux computer with at least 15 GB of free disk space

```bash
git clone https://github.com/KibaLabsLLC/Kiba
cd Kiba
docker run --rm --privileged \
  -v "$PWD:/w" \
  -e RUN_NUM=local \
  archlinux:latest \
  /w/build.sh
```

> [!NOTE]
> The `build.sh` script orchestrates the entire build process: it sets up the Arch Linux base, configures the Budgie desktop with Dracula theme, applies KibaOS customizations, builds KibaStore, and packages everything into a bootable ISO file. The official KibaOS releases on SourceForge are built automatically using this exact same script via GitHub Actions every time changes are pushed to the project.

---

## Project Structure

```
Kiba/
├── .github/
│   └── workflows/
│       └── kiba.yml           # GitHub Actions build configuration
├── branding/                 # Logos, banners, and brand assets
├── build.sh                  # Main build script
└── README.md                 # This file
```

---

## Project Structure

```text
Kiba/
├── .github/
│   └── workflows/
│       └── kiba.yml           # Tells GitHub Actions when and how to build KibaOS
├── branding/
│   └── kibaos_banner.png      # KibaOS logo and brand images
├── build.sh                   # The full build script — the heart of the project
└── README.md                  # This file
```

---

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for detailed information on how to contribute to KibaOS.

Issues and pull requests are welcome at the [KibaLabsLLC/Kiba](https://github.com/KibaLabsLLC/Kiba) repository. If you're planning a larger change, please open an issue first so we can discuss it — thanks!

---

## License

KibaOS is a distribution, not a single piece of software — it bundles together many separate projects (the Linux kernel, Budgie, Docker, Kora, and more), each with its own license. The build scripts and configuration files in this repository are released under the **MIT License**.

---

## About

KibaOS is a project by **Kiba Labs, LLC**.

- [Visit our GitHub Organization](https://github.com/KibaLabsLLC)
- [Download on SourceForge](https://sourceforge.net/projects/kibaos/)
- [View our Wiki](WIKI.md)
