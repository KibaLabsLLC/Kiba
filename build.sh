#!/bin/bash
set -ex

# sniffing out what target we're building for today :3
# the ARM branch (archiso-on-ALARM, boots a real PC-shaped ISO) is gone --
# replaced outright by --mobile, which doesn't build an ISO at all. Mobile
# targets a Halium GSI phone: no archiso, no GRUB/systemd-boot, no OOBE
# installer -- just a pacstrap'd rootfs tarball that gets bundled with a
# halium-boot.img + the Halium GSI system.img and flashed/sideloaded onto
# the phone's existing Android partitions. Everything downstream still
# just checks $KIBA_ARCH.
KIBA_ARCH="x86_64"
for _a in "$@"; do
  case "${_a}" in
    --mobile) KIBA_ARCH="mobile" ;;
  esac
done
[ "${KIBA_ARCH}" = "x86_64" ] && [ "${KIBA_MOBILE:-0}" = "1" ] && KIBA_ARCH="mobile"
export KIBA_ARCH
echo "=== KibaOS build target: ${KIBA_ARCH} ==="

# mobile takes a completely separate, much shorter code path (see
# build_kibaos_mobile() below) -- it shares the parallel-downloads tweak
# and pacman bootstrap right below this block, but skips archiso,
# profiledef.sh, packages.x86_64/customize_airootfs.sh (that whole heredoc
# is the desktop OOBE installer + disk-partitioning/GRUB-NVRAM backend,
# none of which applies to a phone that already has Android partitions
# and boots through halium-boot.img instead of GRUB/systemd-boot) and
# mkarchiso entirely.

# ── speed hack: crank up parallel downloads so pacman isn't crawling ───────
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

# ── gotta pre-make the alpm user inside airootfs or pacman throws a fit
#    when it tries to run inside the chroot later ──────────────────────────
grep -q '^alpm:' "${AIROOTFS}/etc/passwd" 2>/dev/null || \
  echo 'alpm:x:951:951::/var/cache/pacman/pkg:/usr/bin/nologin' >> "${AIROOTFS}/etc/passwd"
grep -q '^alpm:' "${AIROOTFS}/etc/group" 2>/dev/null || \
  echo 'alpm:x:951:' >> "${AIROOTFS}/etc/group"
grep -q '^alpm:' "${AIROOTFS}/etc/shadow" 2>/dev/null || \
  echo 'alpm:!*:19000::::::' >> "${AIROOTFS}/etc/shadow"
mkdir -p "${AIROOTFS}/var/cache/pacman/pkg"
chmod 755 "${AIROOTFS}/var/cache/pacman" "${AIROOTFS}/var/cache/pacman/pkg"

# ── stuff the build container itself needs before we can do anything ──────
pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm
pacman -Su  --noconfirm
if [ "${KIBA_ARCH}" = "mobile" ]; then
  # mobile doesn't touch archiso/GRUB/squashfs at all -- just needs
  # pacstrap (arch-install-scripts) plus basic fetch/package tooling.
  # jq is here for parsing the GitHub API response when resolving the
  # latest Magisk release (magiskboot is pulled from it further down,
  # for the on-device boot.img repack update-binary does at install
  # time -- nothing Python/AOSP-tooling related runs on this build host
  # anymore).
  # imagemagick added here for the same reason it's on the desktop
  # branch: the mobile rootfs now ships the same branded SDDM greeter
  # theme desktop does (see the "shared SDDM theme" block below), which
  # needs wallpaper.jpg/logo-256.png generated the same way -- `magick`
  # runs on THIS build host and writes straight into ${_root}, same
  # pattern as every other direct-write in this function (phoc.ini,
  # oobe.css, etc.), no arch-chroot needed for image processing itself.
  pacman -S --noconfirm --needed \
    base-devel git arch-install-scripts openssl curl jq e2fsprogs zip unzip imagemagick
else
  pacman -S --noconfirm --needed \
    base-devel git squashfs-tools libisoburn mtools dosfstools \
    cmake ninja meson \
    grub \
    arch-install-scripts \
    openssl curl imagemagick jq \
    python-docutils
fi

# ══════════════════════════════════════════════════════════════════════════
# MOBILE: KibaOS Mobile rootfs for Halium GSI phones
# ══════════════════════════════════════════════════════════════════════════
# Not an ISO. Halium GSI devices boot through boot.img (kernel + Halium
# ramdisk) and the Halium GSI system.img. Following the "Halium-boot"
# porting method, this script fetches the prebuilt, device-agnostic GSI
# directly (no AOSP repo sync) -- but does NOT try to pre-build boot.img
# on this build host anymore. That was tried (fetch a "certified GKI
# kernel" and repack it here) and didn't hold up: Google doesn't publish
# a stable download URL for those, and even where the kernel really is
# generic, assembling a bootable image still needs the device's own
# vendor_boot/dtb -- something a build host with no idea what phone
# it's targeting can't supply. Instead, this ships the ingredients
# (magiskboot + a generic Halium ramdisk) and the installer zip's
# update-binary does the unpack/swap-ramdisk/repack itself, on the
# phone, against that phone's own stock boot/init_boot partition --
# see the boot-repack-tools section below and update-binary further
# down for the actual mechanics. No per-device kernel tree, no
# repo/breakfast/mka, and no KIBA_MOBILE_HALIUM_BOOT_IMG to hand-supply
# either -- but also no pretending a build host can know a phone's
# vendor_boot ahead of time. What this function otherwise produces is
# the userspace: a pacstrap'd Arch
# Linux ARM aarch64 rootfs
# carrying KibaOS's mobile stack (Budgie panel/raven on phoc, ofono,
# Calls, Chatty, squeekboard, libgestures, sddm for lock/login),
# tarred up the same way Manjaro's libhybris/image-ci project packages
# its own Halium rootfs for adb-sideload install onto /data alongside
# the GSI + halium-boot.img.
build_kibaos_mobile() {
  local _root="/w/mobile-rootfs"
  local _out="/w/out"
  rm -rf "${_root}"
  mkdir -p "${_root}" "${_out}"

  # ── ALARM signing key, same reasoning as the aarch64 GPGDir seed later
  #    in this file used to need: ALARM packages are signed by a key the
  #    archlinux keyring doesn't ship, so pacman-key needs it seeded
  #    before pacstrap can pull anything off an ALARM mirror. ─────────────
  pacman-key --init
  pacman-key --populate archlinux
  pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6

  cat > /etc/pacman.d/mobile-mirrorlist << 'MIRRORLIST'
Server = http://mirror.archlinuxarm.org/aarch64/$repo
MIRRORLIST

  cat > /tmp/mobile-pacman.conf << 'PACMANCONF'
[options]
Architecture = aarch64
CheckSpace
ParallelDownloads = 10
SigLevel = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mobile-mirrorlist
[extra]
Include = /etc/pacman.d/mobile-mirrorlist
[alarm]
Include = /etc/pacman.d/mobile-mirrorlist
PACMANCONF
  # No [aur] section here on purpose -- ALARM doesn't host a prebuilt
  # binary AUR repo at this mirror path (or anywhere), so it never
  # resolved any package; it just sat there as a dead sync target every
  # run. AUR-only packages (ofono, libhybris, gnome-calls, chatty,
  # libgestures, wlrctl) are all built from source in the AUR loop below
  # instead of pacstrap'd.

  mkdir -p "${_root}/var/lib/pacman"

  # ── base + telephony + mobile shell stack ───────────────────────────────
  # linux-aarch64/linux-firmware deliberately OMITTED -- the kernel comes
  # from halium-boot.img, a rootfs-supplied kernel would never be used and
  # just bloats the tarball.
  #
  # gnome-calls and chatty ARE real binary packages (gnome-calls ships on
  # ALARM's own aarch64 repo; chatty -- the GNOME/Purism SMS+Matrix app --
  # was absorbed into Arch's official [extra] a while back, at which point
  # the AUR maintainer handed the bare "chatty" AUR name over to an
  # unrelated Java/Gradle Twitch-chat client). Pulled here via pacstrap
  # instead of the AUR loop below -- building "chatty" from AUR now grabs
  # the wrong project entirely (and drags in `gradle`, which isn't even
  # packaged for ALARM/aarch64, so that AUR build could never succeed).
  # libgestures has no aarch64 build in AUR at all (arch=('x86_64') in its
  # PKGBUILD) -- dropped from the AUR loop below instead of retried
  # pointlessly every run. ofono and libhybris were
  # previously listed in this call too, but neither actually exists as a
  # binary package in core/extra/alarm -- both are AUR-only upstream (the
  # [aur] entry in mobile-pacman.conf isn't a real ALARM-hosted binary
  # repo, so it never resolved them either; pacstrap failed outright with
  # "target not found: ofono" / "target not found: libhybris"). Moved
  # into the AUR build loop below alongside the other AUR-only packages.
  pacstrap -C /tmp/mobile-pacman.conf -c -G "${_root}" \
    base sudo networkmanager \
     labwc-is-not-used-placeholder 2>/dev/null || true

  # (real pacstrap call -- the line above is deliberately allowed to
  # partially fail on the placeholder package name and retried clean here)
  pacstrap -C /tmp/mobile-pacman.conf -c -G "${_root}" \
    base sudo networkmanager dbus polkit \
     budgie-control-center \
    phoc squeekboard waybar wtype \
    bluez bluez-utils upower \
    wireplumber pipewire pipewire-pulse \
    mesa vulkan-icd-loader \
    openssh git base-devel \
    ell gnome-calls chatty

  # ell installed explicitly above -- it's a real ALARM [extra] binary
  # package (unlike ofono/libhybris, which are genuinely AUR-only), and
  # it's a build dep of the AUR ofono PKGBUILD below. Pre-installing it
  # here means makepkg -si never has to resolve it as a missing dep at
  # all, on top of the pacman -Syy resync added above.

  # ── strip the dead [aur] entry from the TARGET root's own pacman.conf ──
  # /tmp/mobile-pacman.conf (cleaned of its own dead [aur] section above)
  # only governs the pacstrap calls themselves -- it's a host-side config
  # pacstrap reads, never copied into the new root. Once inside the
  # chroot (arch-chroot below, for makepkg -si), pacman uses the target's
  # OWN /etc/pacman.conf instead, which comes from the pacman package's
  # default ALARM template -- and that template ships its own legacy
  # [aur] section (a leftover from when some ALARM configs pointed it at
  # a real repo; it doesn't exist as a resolvable repo anymore). Left in
  # place, every makepkg -si dependency-install below hits "database file
  # for 'aur' does not exist" / "could not find database" and fails
  # outright, exactly the same class of problem as the host-side one, just
  # inside the chroot instead. Delete the [aur] stanza (header line
  # through whatever it contains, up to the next section) rather than
  # assuming a fixed line count, since the exact template contents aren't
  # guaranteed across ALARM base image revisions.
  awk '
    /^\[aur\]/ { skip=1; next }
    skip && /^\[/ { skip=0 }
    !skip { print }
  ' "${_root}/etc/pacman.conf" > "${_root}/etc/pacman.conf.new" \
    && mv "${_root}/etc/pacman.conf.new" "${_root}/etc/pacman.conf"

  # CheckSpace's disk-space check is unreliable inside arch-chroot -- it
  # resolves the cache dir's mountpoint via /proc/self/mountinfo, which
  # doesn't reflect the chroot's view correctly, so it misreports "not
  # enough free disk space" on a runner that has plenty. Same fix already
  # applied to the desktop ISO's chroot pacman.conf elsewhere in this
  # script (see the other CheckSpace sed calls) -- just needed here too
  # for the mobile rootfs's own pacman.conf, which every makepkg -si
  # below runs against via arch-chroot.
  sed -i 's/^CheckSpace/#CheckSpace/' "${_root}/etc/pacman.conf"

  # ── seed the TARGET root's own pacman keyring ───────────────────────────
  # pacstrap was called with -G above ("avoid copying the host's pacman
  # keyring to the target") -- so while the HOST's /etc/pacman.d/gnupg got
  # initialized+populated+ALARM-key-signed near the top of this function,
  # ${_root}/etc/pacman.d/gnupg was never touched at all: it's either
  # missing or empty. Every arch-chroot pacman call from here on
  # (the -Syy resync right below, every makepkg -si dependency install in
  # the AUR loop, and the final sddm install) runs pacman
  # INSIDE this chroot against that empty keyring, which is what actually
  # produces "keyring is not writable" / "required key missing from
  # keyring" -- and once that happens pacman can't verify (or in some
  # cases even fetch) anything from the ALARM repo, so downstream
  # failures like "target not found: sddm" are a symptom of
  # this, not a real missing-package problem. Mirror the exact
  # init/populate/recv/lsign sequence already done on the host earlier in
  # this function, just run via arch-chroot so it lands in ${_root}'s own
  # gnupg dir instead.
  arch-chroot "${_root}" pacman-key --init
  arch-chroot "${_root}" pacman-key --populate archlinux
  arch-chroot "${_root}" pacman-key --recv-keys \
    68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  arch-chroot "${_root}" pacman-key --lsign-key \
    68B3537F39A313B3E574D06777193F152BDBE6A6

  # Force a resync against the target's OWN (post-swap) pacman.conf --
  # pacstrap synced core/extra/alarm under /tmp/mobile-pacman.conf above,
  # but nothing has refreshed the sync DBs since we swapped in the
  # target's default ALARM-template pacman.conf just above. Without this,
  # makepkg -si's dependency resolution in the AUR loop below (e.g.
  # ofono's `ell` build dep, which genuinely exists in ALARM's [extra])
  # can hit "target not found: ell" against a stale/empty sync DB even
  # though the package is real. Cheap and idempotent, so just always do it.
  arch-chroot "${_root}" pacman -Syy --noconfirm

  # ── AUR: ofono, libhybris, gnome-calls (gnome-dialer), chatty,
  #    libgestures, wlrctl ────────────────────────────────────────────────
  # No AUR helper assumed present on a fresh ALARM rootfs -- build each
  # manually as the alpm build user already seeded near the top of this
  # script, inside the target rootfs via arch-chroot. wlrctl backs the
  # nav bar's recents button below (wlr-foreign-toplevel-management
  # listing) -- it's genuinely AUR-only, no official/ALARM package, same
  # as the other three here.
  arch-chroot "${_root}" useradd -m -G wheel builder || true
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > "${_root}/etc/sudoers.d/builder"

  _aur_build() {
    local _pkg="$1"
    local _extra_args="${2:-}"
    arch-chroot "${_root}" bash -c "
      su - builder -c '
        cd /tmp &&
        rm -rf ${_pkg} &&
        git clone --depth 1 https://aur.archlinux.org/${_pkg}.git &&
        cd ${_pkg} &&
        makepkg -si --noconfirm --needed ${_extra_args}
      '
    "
  }

  # ── retry wrapper: AUR's git-over-HTTPS throws transient TLS/EOF
  #    errors under load ("SSL_read: ... unexpected eof while reading")
  #    that have nothing to do with the package itself -- a plain
  #    network blip, not a real build failure. Retrying the whole
  #    clone+build a few times with a short backoff clears these without
  #    having to hand-rerun the entire mobile build over one flaky
  #    connection. _aur_build itself cleans up any half-cloned dir from
  #    the previous attempt before retrying, so this is safe to call
  #    repeatedly.
  _aur_build_retry() {
    local _pkg="$1"
    local _extra_args="${2:-}"
    local _tries
    for _tries in 1 2 3 4 5; do
      if _aur_build "${_pkg}" "${_extra_args}"; then
        return 0
      fi
      if [ "${_tries}" -lt 5 ]; then
        echo "!! ${_pkg} AUR build attempt ${_tries}/5 failed -- retrying in 10s (this is usually a transient AUR git/TLS blip, not a real package error)..." >&2
        sleep 10
      fi
    done
    return 1
  }

  # ofono used to come from the plain pacstrap call above with no
  # fallback -- i.e. the build was already designed to hard-fail if it
  # was missing, since it's the actual telephony stack a "mobile" build
  # exists to ship, not a cosmetic AUR extra. Preserving that: unlike the
  # soft-fail loop below, a failure here aborts the build instead of
  # shipping a phone image with no modem/SIM support.
  _aur_build_retry ofono || {
    echo "ERROR: ofono AUR build failed -- refusing to ship a mobile rootfs with no working telephony stack. Check the makepkg log above." >&2
    rm -f "${_root}/etc/sudoers.d/builder"
    arch-chroot "${_root}" userdel -r builder || true
    exit 1
  }

  # libhybris itself is NOT built here anymore -- it already ships inside
  # the built image (the Halium GSI system.img carries it), so compiling
  # libhybris-git on this build host was just redundant work with none of
  # its output actually used by the rootfs this function produces.

  # wlrctl -- genuinely AUR-only, no official/ALARM package. gnome-calls
  # and chatty are pacstrap'd above now instead of built here (see the
  # comment near that pacstrap call); libgestures is skipped entirely --
  # its AUR PKGBUILD has no aarch64 build at all, so retrying it here
  # every run would just burn ~50s on a guaranteed failure.
  for _pkg in wlrctl; do
    _aur_build_retry "${_pkg}" || echo "!! ${_pkg} AUR build failed -- check the log above, continuing" >&2
  done
  rm -f "${_root}/etc/sudoers.d/builder"
  arch-chroot "${_root}" userdel -r builder || true

  # ── lock/login screen: sddm, same as the desktop build ──────────────────
  # phosh-lockscreen was AUR-only and not actually resolvable ("target not
  # found") -- sddm is a real official ALARM [extra] package, so this pulls
  # straight from pacman, no AUR/makepkg step needed. It's also already
  # what the desktop x86_64 build uses (see install_archiso's SDDM theme
  # section and the enable/wants-symlink calls elsewhere in this script),
  # so mobile now matches it instead of depending on a separate phone-only
  # greeter stack. Hard fail if this isn't available -- a phone build with
  # no lock/login screen is not an acceptable degraded state to ship
  # silently, unlike the AUR telephony packages above which can reasonably
  # continue without.
  if ! arch-chroot "${_root}" pacman -S --noconfirm --needed sddm; then
    echo "ERROR: sddm not available -- refusing to build a mobile rootfs with no lock/login screen. Check the ALARM [extra] repo/mirror." >&2
    exit 1
  fi
  arch-chroot "${_root}" systemctl enable sddm

  # ── liveuser account ─────────────────────────────────────────────────────
  # The dconf install right below has always written into
  # /home/liveuser/.config/dconf assuming that account exists -- it never
  # actually did on mobile (only the desktop ISO's own
  # customize_airootfs.sh creates it, in AIROOTFS/etc/passwd, which this
  # function's ${_root} is entirely separate from). Needed for real now
  # that SDDM Autologin below points at it: autologin has to authenticate
  # against a real target-rootfs account, not just a directory owned by
  # uid 1000. Mirrors the exact passwd/group lines the desktop path uses.
  arch-chroot "${_root}" bash -c "
    grep -q '^liveuser:' /etc/passwd || \
      echo 'liveuser:x:1000:1000:KibaOS Live User (Password is live):/home/liveuser:/bin/bash' >> /etc/passwd
    grep -q '^liveuser:' /etc/group || \
      echo 'liveuser:x:1000:liveuser' >> /etc/group
    mkdir -p /home/liveuser
    chown 1000:1000 /home/liveuser
  "

  # ── shared branded SDDM theme ────────────────────────────────────────────
  # Same wallpaper/logo source and same Main.qml/metadata.desktop as the
  # desktop build's SDDM theme (see install_archiso's "SDDM -- custom
  # KibaOS frosted-glass greeter theme" section) -- kept byte-identical by
  # hand between the two copies, since they run in genuinely different
  # execution contexts (that one's baked into customize_airootfs.sh and
  # runs inside a chroot at ISO-customize time; this one runs directly
  # against ${_root} during this function, on this build host). The QML
  # itself is screen-size-aware (see its own `isPhone` check), so the
  # exact same file already renders touch-friendly on a phone panel and
  # unchanged on a desktop one -- no separate mobile QML needed.
  KIBA_WALLPAPER_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/wallpapers/wallpaper.png?raw=true"
  KIBA_BOOT_SPLASH_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/splash/splash.png?raw=true"
  mkdir -p "${_root}/usr/share/kibaos"

  curl -fL --retry 5 --retry-delay 3 -o "${_root}/usr/share/kibaos/wallpaper.jpg" \
    "${KIBA_WALLPAPER_URL}" || \
    magick -size 1080x2400 gradient:"#003f5c-#0099cc" "${_root}/usr/share/kibaos/wallpaper.jpg"

  curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-boot-splash-raw.png "${KIBA_BOOT_SPLASH_URL}" || true
  if [ -f /tmp/kiba-boot-splash-raw.png ] && file /tmp/kiba-boot-splash-raw.png | grep -qi image; then
    # Source is already a centered square badge, no wordmark to crop out
    # (unlike the old landscape lockup this used to assume) -- resize
    # straight through.
    magick /tmp/kiba-boot-splash-raw.png -filter Lanczos -resize 256x256 "${_root}/usr/share/kibaos/logo-256.png"
    rm -f /tmp/kiba-boot-splash-raw.png
  else
    magick -size 256x256 xc:none \
      -fill '#0099cc' -draw 'circle 128,128 128,1' \
      -fill white -pointsize 128 -gravity Center -annotate 0 'K' \
      "${_root}/usr/share/kibaos/logo-256.png"
  fi

  SDDM_THEME_DIR="${_root}/usr/share/sddm/themes/kibaos"
  mkdir -p "${SDDM_THEME_DIR}"
  cp "${_root}/usr/share/kibaos/wallpaper.jpg" "${SDDM_THEME_DIR}/background.png" 2>/dev/null || true
  cp "${_root}/usr/share/kibaos/logo-256.png"  "${SDDM_THEME_DIR}/logo.png"       2>/dev/null || true

  cat > "${SDDM_THEME_DIR}/metadata.desktop" << 'SDDMMETA'
[SddmGreeterTheme]
Name=KibaOS
Description=KibaOS frosted-glass greeter
Author=Kiba Labs, LLC
Copyright=2026, Kiba Labs, LLC
License=GPLv3
Type=sddm-theme
Version=1.0
Website=https://github.com/WolfTech-Innovations/Kiba
MainScript=Main.qml
Font=Noto Sans
QuickVersion=6
SDDMMETA

  # Keep in sync by hand with install_archiso's copy -- see the comment
  # block above for why these can't literally share a bash variable.
  cat > "${SDDM_THEME_DIR}/Main.qml" << 'SDDMQML'
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Single shared greeter for both the desktop ISO and KibaOS Mobile --
// this exact file is written byte-for-byte into both images (see the
// desktop copy inside install_archiso's customize_airootfs.sh heredoc).
// Rather than branching into two separate QML files, the layout adapts
// itself at runtime off Screen.width, so a genuinely single theme
// covers a 1920x1080 desktop panel and a ~1080x2400 phone panel without
// drifting out of sync on brand/behavior over time.
Rectangle {
    id: root
    width: Screen.width  > 0 ? Screen.width  : 1920
    height: Screen.height > 0 ? Screen.height : 1080
    color: "#0d1b2a"
    focus: true

    // phoc's own config scales the DSI panel output 2x at the Wayland
    // protocol level (see phoc.ini's [output:DSI-1] scale=2) -- Qt's
    // Wayland QPA backend reads that wl_output scale itself and already
    // renders this file's logical pixels at the right physical density,
    // so nothing extra is needed here for HiDPI; this width/height check
    // is purely about aspect ratio/orientation, not pixel density.
    readonly property bool isPhone: width < 700
    readonly property int touchH: isPhone ? 56 : 44
    readonly property int fieldR: isPhone ? 18 : 14

    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    // ── Background wallpaper, darkened so the glass card pops ──────────────
    Image {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Rectangle {
        anchors.fill: parent
        color: "#0d1b2a"
        opacity: 0.42
    }

    // ── Clock ────────────────────────────────────────────────────────────
    // Desktop: small pill, top-right, matches the KibaOS panel style.
    // Phone: big lockscreen-style clock, top-center, clear of any status
    // bar / camera-cutout safe area -- Android/iOS lockscreen convention,
    // and it doubles as a landmark while your thumb finds the card below.
    Column {
        id: clockCol
        anchors {
            top: parent.top
            topMargin: isPhone ? 64 : 28
        }
        anchors.horizontalCenter: isPhone ? parent.horizontalCenter : undefined
        anchors.right: isPhone ? undefined : parent.right
        anchors.rightMargin: isPhone ? 0 : 28
        spacing: isPhone ? 4 : 0
        Text {
            id: clockTime
            text: Qt.formatTime(new Date(), "h:mm AP")
            color: "#ffffff"
            font.pixelSize: isPhone ? 56 : 18
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: Qt.formatDate(new Date(), "ddd, MMM d")
            color: "#aebccd"
            font.pixelSize: isPhone ? 16 : 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Timer { interval: 1000; running: true; repeat: true; onTriggered: clockTime.text = Qt.formatTime(new Date(), "h:mm AP") }
    }

    // ── Central frosted-glass login card ────────────────────────────────────
    // Desktop: fixed 360px, dead-centered, unchanged from before.
    // Phone: full-width (minus margins), anchored in the lower half
    // rather than dead-center -- that's within comfortable one-handed
    // thumb reach, and critically it leaves the *upper* half of the
    // screen clear for squeekboard to pop up underneath without ever
    // covering the password field it's currently focused on.
    Rectangle {
        id: card
        anchors {
            horizontalCenter: isPhone ? parent.horizontalCenter : undefined
            centerIn: isPhone ? undefined : parent
            bottom: isPhone ? parent.bottom : undefined
            bottomMargin: isPhone ? 96 : 0
        }
        width: isPhone ? parent.width - 48 : 360
        height: cardCol.implicitHeight + (isPhone ? 40 : 56)
        radius: isPhone ? 32 : 26
        color: "#101828"
        opacity: 0.001
        // emulated glass: just a solid translucent fill, no real blur.
        // KWin's own Blur effect is real and available in the actual
        // session, but the SDDM greeter renders on its own standalone
        // Qt Quick surface before any session (or its compositor) is
        // even running — see KWIN CONFIG notes for the full story on
        // why this greeter can't just borrow it — so this fake-glass
        // approach is doing all the work here now, not just backstopping
        // a spot where real blur wouldn't reach anyway.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(0.063, 0.094, 0.157, 0.72)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }

        ColumnLayout {
            id: cardCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: isPhone ? 24 : 28 }
            spacing: isPhone ? 16 : 14

            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "logo.png"
                width: isPhone ? 56 : 64; height: isPhone ? 56 : 64
                fillMode: Image.PreserveAspectFit
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: userModel.count > 0 ? userModel.data(userModel.index(userList.currentIndex, 0), 257) : "User"
                color: "#e8eef5"; font.pixelSize: isPhone ? 19 : 17; font.weight: Font.Medium
            }

            ListView {
                id: userList
                Layout.fillWidth: true
                height: 0; visible: false  // names shown via combo below instead
                model: userModel
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
            }

            ComboBox {
                id: userBox
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                model: userModel
                textRole: "name"
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
                font.pixelSize: isPhone ? 16 : 13
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                contentItem: Text { text: userBox.displayText; color: "#e8eef5"; font: userBox.font; padding: 10; verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: passwordField
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                placeholderText: "Password"
                echoMode: TextInput.Password
                color: "#e8eef5"
                font.pixelSize: isPhone ? 16 : 13
                placeholderTextColor: "#8a99ad"
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                onAccepted: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                Keys.onReturnPressed: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
            }

            Button {
                id: loginButton
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                text: "Sign In"
                onClicked: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                background: Rectangle { radius: fieldR; color: "#0099cc" }
                contentItem: Text { text: loginButton.text; color: "#ffffff"; font.pixelSize: isPhone ? 16 : 13; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
            }

            // Session picker: only worth showing where there's actually
            // more than one to pick from. Desktop offers Budgie/etc
            // session choices; the phone image ships exactly one
            // (kibaos-mobile, Exec=phoc) so this is dead weight there --
            // one less thing to accidentally fat-finger on a small card.
            ComboBox {
                Layout.fillWidth: true
                Layout.preferredHeight: isPhone ? 0 : undefined
                visible: !isPhone
                model: sessionModel
                textRole: "name"
                currentIndex: root.sessionIndex
                onActivated: root.sessionIndex = currentIndex
                background: Rectangle { radius: fieldR; color: "transparent" }
                contentItem: Text { text: parent.displayText; color: "#aebccd"; font.pixelSize: 11; padding: 6; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    // ── Power row ────────────────────────────────────────────────────────
    // Desktop: small 44px pills, bottom-right, unchanged.
    // Phone: bigger 56px targets (comfortable thumb-tap size), moved to
    // top-right instead -- bottom-right on a phone sits right where the
    // login card's bottom edge and any on-screen-keyboard region already
    // are, so it's both more reachable and less likely to be covered.
    Row {
        anchors {
            top: isPhone ? parent.top : undefined
            bottom: isPhone ? undefined : parent.bottom
            right: parent.right
            margins: isPhone ? 24 : 28
        }
        spacing: isPhone ? 14 : 10
        Repeater {
            model: [
                { label: "⏻", visible: sddm.canPowerOff, action: function(){ sddm.powerOff() } },
                { label: "⟲", visible: sddm.canReboot,   action: function(){ sddm.reboot()   } }
            ]
            delegate: Rectangle {
                visible: modelData.visible
                width: touchH; height: touchH; radius: fieldR
                color: "#1c2433"; opacity: 0.78
                Text { anchors.centerIn: parent; text: modelData.label; color: "#e8eef5"; font.pixelSize: isPhone ? 22 : 18 }
                MouseArea { anchors.fill: parent; onClicked: modelData.action() }
            }
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() { passwordField.text = ""; passwordField.placeholderText = "Incorrect password"; }
    }

    Component.onCompleted: passwordField.forceActiveFocus()
}
SDDMQML

  mkdir -p "${_root}/usr/share/wayland-sessions"
  cat > "${_root}/usr/share/wayland-sessions/kibaos-mobile.desktop" << 'MOBILESESSION'
[Desktop Entry]
Name=KibaOS Mobile
Comment=Budgie panel/raven on phoc
Exec=phoc
Type=Application
DesktopNames=Budgie
MOBILESESSION

  mkdir -p "${_root}/etc/sddm.conf.d"
  cat > "${_root}/etc/sddm.conf.d/kibaos-mobile.conf" << 'SDDMMOBILECONF'
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=phoc

[Theme]
Current=kibaos

[Autologin]
User=liveuser
Session=kibaos-mobile
SDDMMOBILECONF

  arch-chroot "${_root}" bash -c "
    mkdir -p /var/lib/sddm
    chown sddm:sddm /var/lib/sddm 2>/dev/null || true
    chmod 750 /var/lib/sddm
  "

  # ── minimal branding/behavior pass (the parts of the desktop
  #    customize_airootfs.sh that still make sense with no disk installer
  #    or GRUB in the picture: DNS, dconf panel state, hidden launchers) ──
  install -d -m 755 -o 1000 -g 1000 "${_root}/home/liveuser/.config/dconf" 2>/dev/null || true
  cat > "${_root}/etc/resolv.conf" << 'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF

  # phoc's own config -- points it at Budgie's panel/raven as layer-shell
  # clients instead of Phosh's shell, keeps libgestures/squeekboard as-is
  # since both talk to whatever compositor implements layer-shell, not
  # specifically Phosh.
  mkdir -p "${_root}/etc/phoc"
  cat > "${_root}/etc/phoc/phoc.ini" << 'PHOCINI'
[core]
xwayland=true

[output:DSI-1]
scale=2
PHOCINI

  # ══════════════════════════════════════════════════════════════════════
  # Bottom navigation bar -- Waybar
  # ══════════════════════════════════════════════════════════════════════
  # Waybar over gtk-layer-shell rather than a bespoke GTK bar: it's the
  # de-facto modern bar on wlroots-based Wayland compositors (same
  # layer-shell protocol phoc/squeekboard already speak here), actively
  # maintained, and themeable entirely through CSS -- so it can carry the
  # exact same design tokens as the OOBE (oobe.css's #0071e3 accent, pill
  # shapes) instead of introducing a second, unrelated visual language
  # for the persistent chrome the user sees on every screen after setup.
  #
  # Reachable actions are necessarily best-effort here: phoc doesn't ship
  # a swaymsg-equivalent IPC or a full foreign-toplevel switching UI like
  # sway does, so "recents" runs wlrctl's toplevel list (wlrctl is built
  # from AUR above) rather than a live-thumbnail switcher -- real data,
  # just not a real switcher UI yet. Worth revisiting once phoc's own
  # protocol support covers richer toplevel management (track
  # https://gitlab.gnome.org/World/Phosh/phoc issues).
  mkdir -p "${_root}/etc/xdg/waybar"
  cat > "${_root}/etc/xdg/waybar/config" << 'WAYBARCONFIG'
{
    "layer": "top",
    "position": "bottom",
    "height": 76,
    "margin-bottom": 0,
    "modules-left": ["custom/back"],
    "modules-center": ["custom/home"],
    "modules-right": ["custom/recents"],

    "custom/back": {
        "format": "←",
        "tooltip": false,
        "on-click": "wtype -k Escape"
    },
    "custom/home": {
        "format": "⌂",
        "tooltip": false,
        "on-click": "budgie-panel --toggle-appswitch 2>/dev/null || pkill -SIGUSR1 budgie-panel"
    },
    "custom/recents": {
        "format": "▦",
        "tooltip": false,
        "on-click": "kibaos-mobile-recents"
    }
}
WAYBARCONFIG

  cat > "${_root}/etc/xdg/waybar/style.css" << 'WAYBARCSS'
/* KibaOS Mobile nav bar -- same accent/timing tokens as oobe.css, just
 * applied to the bar that's actually on-screen every day after setup.
 * Sized noticeably above Material's 48dp minimum touch target -- this
 * bar gets tapped constantly, one-handed, often without looking, so
 * bigger/simpler beats dense every time. Plain classic Unicode glyphs
 * (← ⌂ ▦) instead of an icon font dependency -- render everywhere with
 * zero extra packages, and read clearly even at a glance. */
* {
    font-family: "Inter", sans-serif;
    border: none;
    border-radius: 0;
    min-height: 0;
}

window#waybar {
    background: rgba(18, 22, 29, 0.92);
    border-top: 1px solid rgba(255, 255, 255, 0.08);
}

#custom-back, #custom-home, #custom-recents {
    color: #e2e8f0;
    font-size: 26px;
    min-width: 76px;
    min-height: 56px;
    margin: 10px 10px;
    border-radius: 999px;
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                transform 90ms cubic-bezier(0.22, 1, 0.36, 1);
}
#custom-back:hover, #custom-home:hover, #custom-recents:hover {
    background: rgba(255, 255, 255, 0.08);
}
#custom-back:active, #custom-home:active, #custom-recents:active {
    background: rgba(0, 113, 227, 0.35);
    transform: scale(0.90);
}

/* Home gets the accent treatment -- it's the "you are always one tap from
 * a known place" affordance, same role the OOBE's primary button plays:
 * exactly one clearly-weighted action, unmistakable at a glance. */
#custom-home {
    color: #ffffff;
    background: #0071e3;
    min-width: 84px;
}
#custom-home:hover  { background: #0077ed; }
#custom-home:active { background: #0068d6; }
WAYBARCSS

  # ══════════════════════════════════════════════════════════════════════
  # Status bar -- Android/iOS-style top bar: clock left, cellular/Wi-Fi/
  # Bluetooth/battery right. A second, independent waybar instance rather
  # than folding these into the nav bar above: the nav bar claims the
  # bottom screen edge ("position": "bottom"), this one claims the top
  # ("position": "top") -- two separate waybar processes with their own
  # config/style pair is the normal way to run a top+bottom bar pair
  # under wlroots (each is its own layer-shell surface; nothing about
  # running two waybar processes conflicts, they just claim different
  # screen edges). Same design tokens as the nav bar and oobe.css
  # (#0071e3 accent, translucent dark chrome), same "plain Unicode
  # glyphs, no icon font" rule the nav bar already follows -- no Nerd
  # Font dependency for a bar that's on-screen 100% of the time.
  # ══════════════════════════════════════════════════════════════════════
  mkdir -p "${_root}/etc/xdg/waybar"
  cat > "${_root}/etc/xdg/waybar/statusbar-config" << 'STATUSBARCONFIG'
{
    "layer": "top",
    "position": "top",
    "height": 34,
    "spacing": 2,
    "modules-left": ["clock"],
    "modules-center": [],
    "modules-right": ["custom/cellular", "network", "bluetooth", "battery"],

    "clock": {
        "format": "{:%I:%M %p}",
        "tooltip-format": "{:%A, %B %d}"
    },

    "custom/cellular": {
        "exec": "/usr/local/bin/kibaos-mobile-cellular",
        "interval": 8,
        "return-type": "json",
        "tooltip": true
    },

    "network": {
        "format-wifi": "{icon}",
        "format-disconnected": "",
        "format-icons": ["▁", "▂", "▄", "▆", "█"],
        "tooltip-format-wifi": "{essid} · {signalStrength}%",
        "on-click": "budgie-control-center wifi 2>/dev/null || true"
    },

    "bluetooth": {
        "format": "◇",
        "format-connected": "◆",
        "format-disabled": "",
        "format-off": "",
        "tooltip-format": "{controller_alias} ({controller_address})",
        "tooltip-format-connected": "{device_alias}",
        "on-click": "budgie-control-center bluetooth 2>/dev/null || true"
    },

    "battery": {
        "format": "{icon} {capacity}%",
        "format-charging": "{icon} {capacity}% ↑",
        "format-icons": ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"],
        "states": {
            "warning": 20,
            "critical": 10
        }
    }
}
STATUSBARCONFIG

  cat > "${_root}/etc/xdg/waybar/statusbar-style.css" << 'STATUSBARCSS'
/* KibaOS Mobile status bar -- same tokens as the nav bar/oobe.css, sized
 * for a compact always-on strip instead of a tap target: small text,
 * tight padding, no hover/active states (nothing here is a button except
 * the network/bluetooth quick-launch clicks, and those don't need a
 * press-state animation on a strip this thin). */
* {
    font-family: "Inter", sans-serif;
    border: none;
    border-radius: 0;
    min-height: 0;
}

window#waybar {
    background: rgba(18, 22, 29, 0.92);
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

#clock {
    color: #f1f5f9;
    font-size: 13px;
    font-weight: 700;
    padding: 0 12px;
}

#custom-cellular, #network, #bluetooth, #battery {
    color: #e2e8f0;
    font-size: 13px;
    font-weight: 700;
    padding: 0 6px;
}

#bluetooth { font-size: 15px; }

/* Battery warning/critical tint -- same red used for oobe.css's
 * .oobe-error, same amber Material typically reserves for a low-battery
 * state, so a glance at the bar reads consistently with the rest of the
 * UI's color language. */
#battery.warning  { color: #f59e0b; }
#battery.critical { color: #f87171; }
STATUSBARCSS

  # ── Cellular signal module: no built-in waybar module reads ofono, so
  # this is a small polling script (waybar re-execs it every "interval"
  # seconds per statusbar-config above) that queries ofono's own D-Bus
  # API directly via gdbus (part of glib2, already a hard dependency of
  # dbus which is pulled above -- no extra package needed) the same way
  # check_sim() in the OOBE does, just outside a GLib main loop since
  # this runs standalone rather than inside the Vala wizard. Emits
  # waybar's custom-module JSON contract: {text, tooltip, class}.
  # Deliberately fails soft everywhere -- no modem, no SIM, or a gdbus
  # parse miss all just print {"text":""}, which waybar collapses to
  # nothing rather than showing a broken/stale reading.
  cat > "${_root}/usr/local/bin/kibaos-mobile-cellular" << 'CELLULARSCRIPT'
#!/bin/bash
# KibaOS Mobile status bar -- cellular signal custom module for waybar.
# Reads modem/signal state straight from ofono over D-Bus; see the
# longer explanation above where this file gets written.
set -u

_empty() { echo '{"text":"","tooltip":"No SIM/modem detected","class":"none"}'; }

command -v gdbus >/dev/null 2>&1 || { _empty; exit 0; }

_modem_path="$(
  gdbus call --system --dest org.ofono --object-path / \
    --method org.ofono.Manager.GetModems 2>/dev/null \
    | grep -oP "(?<=objpath ')[^']+" | head -n1
)"
[ -z "${_modem_path}" ] && { _empty; exit 0; }

_netreg="$(
  gdbus call --system --dest org.ofono --object-path "${_modem_path}" \
    --method org.ofono.NetworkRegistration.GetProperties 2>/dev/null
)"
[ -z "${_netreg}" ] && { _empty; exit 0; }

_status="$(echo "${_netreg}"   | grep -oP "'Status': <'\K[^']+")"
_strength="$(echo "${_netreg}" | grep -oP "'Strength': <(uint16 |byte )?\K[0-9]+" | head -n1)"
_tech="$(echo "${_netreg}"     | grep -oP "'Technology': <'\K[^']+")"
_carrier="$(echo "${_netreg}"  | grep -oP "'Name': <'\K[^']+")"

if [ "${_status}" != "registered" ] && [ "${_status}" != "roaming" ]; then
  echo "{\"text\":\"✕\",\"tooltip\":\"No service\",\"class\":\"none\"}"
  exit 0
fi

_strength="${_strength:-0}"
if   [ "${_strength}" -ge 80 ]; then _bar="█"
elif [ "${_strength}" -ge 60 ]; then _bar="▆"
elif [ "${_strength}" -ge 40 ]; then _bar="▄"
elif [ "${_strength}" -ge 20 ]; then _bar="▂"
else                                 _bar="▁"
fi

_tech_label="$(echo "${_tech}" | tr '[:lower:]' '[:upper:]')"
_roam_suffix=""
[ "${_status}" = "roaming" ] && _roam_suffix=" (roaming)"

echo "{\"text\":\"${_bar} ${_tech_label}\",\"tooltip\":\"${_carrier}${_roam_suffix} · ${_strength}%\",\"class\":\"connected\"}"
CELLULARSCRIPT
  chmod +x "${_root}/usr/local/bin/kibaos-mobile-cellular"

  # Minimal placeholder task-switcher -- lists wlr-foreign-toplevel
  # clients via wlrctl (built above in the AUR pass). Still not a real
  # thumbnail switcher -- phoc doesn't expose a richer IPC/foreign-
  # toplevel-based switching surface yet -- but wlrctl toplevel list is
  # at least real data now instead of a "not installed" stub. Kept the
  # command-existence check anyway since the AUR build above can still
  # fail without aborting the whole rootfs build (see the `||` there).
  cat > "${_root}/usr/local/bin/kibaos-mobile-recents" << 'RECENTSSCRIPT'
#!/bin/bash
if command -v wlrctl >/dev/null 2>&1; then
  wlrctl toplevel list
else
  echo "kibaos-mobile-recents: wlrctl not installed, no toplevel list available" >&2
fi
RECENTSSCRIPT
  chmod +x "${_root}/usr/local/bin/kibaos-mobile-recents"

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-navbar.desktop" << 'NAVBARAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Navigation Bar
Exec=waybar -c /etc/xdg/waybar/config -s /etc/xdg/waybar/style.css
X-GNOME-Autostart-enabled=true
NAVBARAUTOSTART

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-statusbar.desktop" << 'STATUSBARAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Status Bar
Exec=waybar -c /etc/xdg/waybar/statusbar-config -s /etc/xdg/waybar/statusbar-style.css
X-GNOME-Autostart-enabled=true
STATUSBARAUTOSTART

  # bluetoothd/upowerd back the status bar's bluetooth + battery modules
  # -- neither package enables its service by default on a fresh ALARM
  # rootfs, so wire them up explicitly the same way the rest of this
  # function reaches into ${_root} via arch-chroot.
  arch-chroot "${_root}" systemctl enable bluetooth upower || true

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-shell.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Shell
Exec=budgie-panel
X-GNOME-Autostart-enabled=true
AUTOSTART

  # ── WinApps / Windows Workspace is a desktop-only feature ───────────────
  # Deliberately never referenced anywhere in this function. It lives in
  # customize_airootfs.sh (desktop/laptop ISO path) exclusively -- WinApps
  # depends on a local Docker/libvirt Windows VM for RDP passthrough,
  # which has no sane story on phone hardware. If a future edit of this
  # function starts pulling in kibaos-winapps-* anything, that's a bug.

  # ══════════════════════════════════════════════════════════════════════
  # Mobile OOBE — Android-style first-boot flow (Vala/GTK4/libadwaita,
  # same stack as the desktop OOBE installer). No disk partitioning, no
  # GRUB/systemd-boot NVRAM step -- GSI + this rootfs are already flashed
  # by the time this ever runs. Flow: Welcome -> Language/Region -> Wi-Fi
  # -> SIM/carrier via ofono -> account step (mandatory) -> done. Gated
  # by a marker file so it only ever runs once, same idea as Android's
  # own SetupWizard.
  # ══════════════════════════════════════════════════════════════════════
  pacstrap -C /tmp/mobile-pacman.conf -c -G "${_root}" \
    gtk4 libadwaita vala meson ninja glib2 networkmanager

  mkdir -p "${_root}/root/kibaos-mobile-oobe/src"

  cat > "${_root}/root/kibaos-mobile-oobe/meson.build" << 'MESONBUILD'
project('kibaos-mobile-oobe', 'vala', 'c')
gtk_dep = dependency('gtk4')
adw_dep = dependency('libadwaita-1')
gio_dep = dependency('gio-2.0')
executable('kibaos-mobile-oobe', 'src/main.vala',
  dependencies: [gtk_dep, adw_dep, gio_dep],
  install: true)
MESONBUILD

  # ── Mobile OOBE stylesheet ────────────────────────────────────────────
  # Same design language as the desktop installer (oobe.css: #0071e3
  # accent, pill buttons, step dots, easeOutQuint card-ins) carried over
  # to a phone screen, with Material 3 shape/elevation layered on top
  # where a touch UI actually benefits from it: bigger corner radii on
  # touch targets (Material's "extra-large" 28px shape scale vs desktop's
  # 18-20px), real elevation shadows on the Wi-Fi list instead of a flat
  # bordered row (fingers need a stronger affordance than a mouse cursor
  # does), and a top linear progress track like Android's own
  # SetupWizard/LineageOS SetupWizard use instead of relying on step dots
  # alone -- dots stay too, just demoted to a secondary indicator under
  # the header the way Material stepper components use both together.
  mkdir -p "${_root}/usr/share/kibaos-mobile-oobe"
  cat > "${_root}/usr/share/kibaos-mobile-oobe/oobe.css" << 'MOBILEOOBECSS'
/* ═══════════════════════════════════════════════════════════════════════
 * KibaOS Mobile OOBE — desktop oobe.css tokens + Material 3 shape/elevation.
 * Timing: settle cubic-bezier(0.22,1,0.36,1) / spring cubic-bezier(0.34,1.56,0.64,1)
 * ═══════════════════════════════════════════════════════════════════════ */

window.kibaos-oobe-window { background: transparent; }

.oobe-background {
    background: #ffffff;
    transition: background 260ms cubic-bezier(0.22, 1, 0.36, 1);
}
window.dark .oobe-background { background: #12161d; }

/* ── Top app bar: brand + corner toggles, Material top-app-bar height ── */
.oobe-topbar { min-height: 56px; padding: 8px 14px; }
.oobe-brand {
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 0.4px;
    color: rgba(15,23,42,0.80);
}
window.dark .oobe-brand { color: rgba(255,255,255,0.75); }

.oobe-corner-button {
    background:    rgba(15,23,42,0.05);
    color:         #334155;
    border:        1px solid rgba(15,23,42,0.10);
    border-radius: 999px;
    min-width:     48px;
    min-height:    48px;
    padding:       8px;
    font-size:     15px;
    font-weight:   650;
    transition:
        background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
        transform         120ms cubic-bezier(0.34, 1.56, 0.64, 1);
}
.oobe-corner-button:hover  { background: rgba(15,23,42,0.09); }
.oobe-corner-button:active { transform: scale(0.92); transition-duration: 70ms; }
window.dark .oobe-corner-button {
    background: rgba(30,41,59,0.65);
    color:      #e2e8f0;
    border-color: rgba(255,255,255,0.12);
}
window.dark .oobe-corner-button:hover { background: rgba(51,65,85,0.85); }

/* ── Top linear progress (Material stepper / Android SetupWizard style) ── */
.oobe-linear-progress { min-height: 4px; }
.oobe-linear-progress trough {
    background:    rgba(15,23,42,0.08);
    border-radius: 999px;
    min-height:    4px;
}
.oobe-linear-progress progress {
    background:    linear-gradient(90deg, #0071e3, #409cff);
    border-radius: 999px;
    transition:    all 420ms cubic-bezier(0.22, 1, 0.36, 1);
}
window.dark .oobe-linear-progress trough { background: rgba(255,255,255,0.10); }

/* ── Step dots (secondary indicator, sits under the linear track) ──── */
.oobe-step-dot {
    min-width: 6px; min-height: 6px;
    border-radius: 999px;
    background: rgba(0,0,0,0.15);
    transition: all 300ms cubic-bezier(0.22, 1, 0.36, 1);
}
.oobe-step-dot-active { min-width: 18px; background: #0071e3; }
window.dark .oobe-step-dot { background: rgba(255,255,255,0.18); }
window.dark .oobe-step-dot-active { background: #409cff; }
.oobe-step-label {
    font-size: 12px; font-weight: 600;
    color: rgba(0,0,0,0.38); letter-spacing: 0.2px;
}
window.dark .oobe-step-label { color: rgba(255,255,255,0.40); }

/* ── Card: Material "extra-large" 28px shape scale, real elevation ──
 * Phones don't get the desktop's borderless full-bleed treatment --
 * there's no cursor/hover state to carry hierarchy on touch, so the
 * card boundary + soft elevation shadow is doing that work instead. */
.oobe-card {
    background:    #ffffff;
    border:        1px solid rgba(15,23,42,0.06);
    border-radius: 28px;
    box-shadow:    0 1px 2px rgba(15,23,42,0.04), 0 8px 24px rgba(15,23,42,0.08);
    animation: card-in 460ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
window.dark .oobe-card {
    background:    #1a2029;
    border-color:  rgba(255,255,255,0.06);
    box-shadow:    0 1px 2px rgba(0,0,0,0.3), 0 8px 24px rgba(0,0,0,0.35);
}
@keyframes card-in {
    from { opacity: 0; transform: translateY(18px) scale(0.98); }
    to   { opacity: 1; transform: translateY(0) scale(1); }
}
.oobe-inner { padding: 20px 20px 16px; }

/* ── Page icon: one big, friendly, unmistakable symbolic icon per
 *    screen. A single large icon reads instantly without reading a
 *    word of text -- the whole point of "simple enough for anyone",
 *    so every page gets one before the title, never buried in a
 *    paragraph. Rendered as a themed Gtk.Image (pixel_size set in
 *    code), deliberately not an emoji glyph, so it renders consistently
 *    regardless of what emoji coverage the device's font stack has. ── */
.oobe-page-icon {
    color: #0071e3;
    margin-bottom: 4px;
    animation: pop-in 480ms cubic-bezier(0.34, 1.56, 0.64, 1) both;
}
window.dark .oobe-page-icon { color: #4d9fff; }

/* ── Typography -- sized for a hand held at arm's length, not a desk
 *    monitor: bigger everything, shorter lines, nothing squints. ───── */
.oobe-welcome-greeting {
    font-size: 36px; font-weight: 750; color: #1d1d1f;
    letter-spacing: -0.3px; margin-top: 4px; line-height: 1.15;
    animation: fade-up 460ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
window.dark .oobe-welcome-greeting { color: #f1f5f9; }
.oobe-title {
    font-size: 28px; font-weight: 750; color: #0f172a;
    letter-spacing: -0.3px; line-height: 1.2; margin-bottom: 4px;
    animation: fade-up 380ms cubic-bezier(0.22, 1, 0.36, 1) 60ms both;
}
.oobe-subtitle {
    font-size: 16px; color: #64748b; line-height: 1.5;
    animation: fade-up 380ms cubic-bezier(0.22, 1, 0.36, 1) 100ms both;
}
@keyframes fade-up { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
window.dark .oobe-title    { color: #f1f5f9; }
window.dark .oobe-subtitle { color: #94a3b8; }
.oobe-error {
    font-size: 15px; color: #dc2626; line-height: 1.5;
    animation: fade-up 220ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
window.dark .oobe-error { color: #f87171; }

/* ── Skip: a plain text link, not a bordered button -- there should only
 *    ever be ONE strongly-weighted action on screen (the big accent
 *    button). A second bordered button competes with it visually and
 *    is exactly the kind of "which one do I press" ambiguity a
 *    dog-simple flow can't have. ─────────────────────────────────────── */
.oobe-skip-link {
    background: transparent;
    color: #94a3b8;
    border: none;
    font-size: 15px;
    font-weight: 600;
    padding: 12px;
    min-height: 44px;
}
.oobe-skip-link:hover { color: #64748b; }
window.dark .oobe-skip-link { color: #64748b; }
window.dark .oobe-skip-link:hover { color: #94a3b8; }

/* ── Language rows: code badge + name, one tap, no dropdown. A dropdown
 *    needs opening then a second tap to choose -- two motions where one
 *    obvious list of big rows only needs one, same reasoning as the
 *    Wi-Fi list already uses tap-to-select rows instead of a picker.
 *    Plain-text code badge (EN-US, ES, ...) rather than a flag emoji --
 *    see build_language_page for why. Class name kept as oobe-lang-flag
 *    to avoid churning every reference below; it's just a badge now. ── */
.oobe-lang-flag { font-size: 15px; font-weight: 700; min-width: 40px; color: #0071e3; }
window.dark .oobe-lang-flag { color: #4d9fff; }
.oobe-lang-name { font-size: 17px; font-weight: 600; }
window.dark .oobe-lang-name { color: #f1f5f9; }

/* ── Wi-Fi list: Material elevated list items, ripple-ish press state ── */
.oobe-signal-glyph {
    font-family: monospace; font-size: 15px; font-weight: 700;
    color: #0071e3; min-width: 32px;
}
window.dark .oobe-signal-glyph { color: #409cff; }

.oobe-list row, listview > row {
    background:    #f8fafc;
    border:        1px solid rgba(0,0,0,0.06);
    border-radius: 20px;
    margin:        6px 0;
    padding:       18px 18px;
    color:         #1e293b;
    transition:
        background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
        border-color     160ms cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow       160ms cubic-bezier(0.22, 1, 0.36, 1),
        transform         90ms cubic-bezier(0.22, 1, 0.36, 1);
    animation: fade-up 260ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
.oobe-list row:hover    { background: #f0f9ff; border-color: rgba(0,113,227,0.25); }
.oobe-list row:active   { transform: scale(0.98); transition-duration: 60ms; }
.oobe-list row:selected {
    background:  rgba(0,113,227,0.10);
    border-color: rgba(0,113,227,0.55);
    box-shadow:  0 0 0 3px rgba(0,113,227,0.14);
}
window.dark .oobe-list row, window.dark listview > row {
    background: #212836; border-color: rgba(255,255,255,0.07); color: #e2e8f0;
}
window.dark .oobe-list row:hover    { background: rgba(0,113,227,0.16); border-color: rgba(0,113,227,0.4); }
window.dark .oobe-list row:selected { background: rgba(0,113,227,0.22); border-color: rgba(0,113,227,0.6); }

/* ── Done check: pop-in, spring easing. Rendered as a themed Gtk.Image
 *    symbolic icon (pixel_size set in code), not a unicode check
 *    glyph, to stay consistent with the rest of the wizard's icons. ── */
.oobe-done-check {
    color: #0071e3;
    animation: pop-in 520ms cubic-bezier(0.34, 1.56, 0.64, 1) both;
}
window.dark .oobe-done-check { color: #4d9fff; }
@keyframes pop-in { from { opacity: 0; transform: scale(0.4); } to { opacity: 1; transform: scale(1); } }

/* ── Buttons: fully-rounded pill, Material state-layer press feedback ── */
.oobe-primary-button {
    background:    #0071e3;
    color:         #ffffff;
    border:        none;
    border-radius: 999px;
    padding:       18px 32px;
    font-weight:   700;
    font-size:     17px;
    min-height:    60px;
    box-shadow:    0 1px 2px rgba(15,23,42,0.14), 0 3px 8px rgba(0,113,227,0.18);
    transition:
        background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow       140ms cubic-bezier(0.22, 1, 0.36, 1),
        transform          90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.oobe-primary-button:hover  { background: #0077ed; }
.oobe-primary-button:active {
    background: #0068d6; transform: scale(0.97);
    box-shadow: 0 1px 3px rgba(0,113,227,0.20);
    transition-duration: 70ms;
}
.oobe-primary-button:disabled {
    background: rgba(15,23,42,0.12); color: rgba(15,23,42,0.35); box-shadow: none;
}
window.dark .oobe-primary-button:disabled { background: rgba(255,255,255,0.10); color: rgba(255,255,255,0.30); }

.oobe-secondary-button {
    background:    transparent;
    color:         #475569;
    border:        1px solid rgba(0,0,0,0.14);
    border-radius: 999px;
    padding:       18px 28px;
    font-size:     17px;
    min-height:    60px;
    transition:
        background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
        border-color     140ms cubic-bezier(0.22, 1, 0.36, 1),
        transform          90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.oobe-secondary-button:hover  { background: #f1f5f9; border-color: rgba(0,0,0,0.22); }
.oobe-secondary-button:active { background: #e2e8f0; transform: scale(0.97); transition-duration: 70ms; }
window.dark .oobe-secondary-button { color: #cbd5e1; border-color: rgba(255,255,255,0.16); }
window.dark .oobe-secondary-button:hover  { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.26); }
window.dark .oobe-secondary-button:active { background: rgba(255,255,255,0.14); }

.oobe-nav-row { margin-top: 8px; }

/* ── Form entries: Material filled-field look (tonal fill vs desktop's
 *    outline-first treatment -- reads better against the card's own
 *    28px-radius background on a small screen) ─────────────────────── */
entry, row.entry {
    background:    #f1f5f9;
    border:        1px solid transparent;
    border-radius: 16px;
    color:         #0f172a;
    min-height:    56px;
    font-size:     17px;
    transition:
        border-color     160ms cubic-bezier(0.22, 1, 0.36, 1),
        background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow        160ms cubic-bezier(0.22, 1, 0.36, 1);
}
entry:focus-within, row.entry:focus-within {
    border-color: #0071e3;
    background:   #ffffff;
    box-shadow:   0 0 0 3px rgba(0,113,227,0.16);
}
window.dark entry, window.dark row.entry { background: rgba(255,255,255,0.06); color: #f1f5f9; }
window.dark entry:focus-within, window.dark row.entry:focus-within { background: rgba(255,255,255,0.09); }

/* ── Bottom-sheet password dialog: Material bottom-sheet shape --
 *    rounded top corners only, flush to the bottom edge, matching how
 *    Android/LineageOS present the Wi-Fi password prompt as a sheet
 *    sliding up rather than a centered desktop-style dialog. ───────── */
.oobe-sheet {
    border-radius: 28px 28px 0 0;
    background: #ffffff;
}
window.dark .oobe-sheet { background: #1a2029; }
MOBILEOOBECSS

  cat > "${_root}/root/kibaos-mobile-oobe/src/main.vala" << 'OOBEVALA'
/*
 * KibaOS Mobile OOBE -- first-boot wizard.
 * Marker-gated (runs once), no disk-partitioning step: this only ever
 * runs after the GSI + rootfs are already flashed onto the phone.
 * Pages: Welcome -> Language/Region -> Wi-Fi -> SIM/Carrier (ofono) ->
 * Account (mandatory) -> Done.
 *
 * Design language: same tokens as the desktop installer's oobe.css
 * (#0071e3 accent, pill buttons, easeOutQuint card-ins, step dots) laid
 * over Material 3 shape + elevation for the touch surface specifically
 * -- 28px "extra-large" card radius instead of desktop's borderless
 * full-bleed page, a top linear progress track like Android/LineageOS
 * SetupWizard use, filled-tonal form fields, and a bottom-sheet Wi-Fi
 * password prompt instead of a centered dialog. See oobe.css for the
 * actual values; this file just wires widgets to those CSS classes.
 */
public class KibaMobileOobe : Adw.Application {
    const string MARKER = "/var/lib/kibaos/.oobe-done";
    const string CSS_PATH = "/usr/share/kibaos-mobile-oobe/oobe.css";

    // Steps shown in the top progress track + dots. "done" is
    // deliberately excluded -- same convention as the desktop OOBE and
    // Android's own SetupWizard, where the final celebratory screen
    // drops the step chrome entirely rather than showing "6 of 6".
    const string[] STEPS = { "welcome", "language", "wifi", "sim", "account" };

    Adw.ApplicationWindow window;
    Gtk.Stack stack;
    Gtk.ProgressBar top_progress;
    Gtk.Box dots_row;
    Gtk.Label wifi_status_label;
    Gtk.Label sim_status_label;
    bool dark_mode = false;
    string display_name = "";

    public KibaMobileOobe () {
        Object (application_id: "com.wolftechinnovations.kibaos.MobileOobe");
    }

    protected override void activate () {
        if (FileUtils.test (MARKER, FileTest.EXISTS)) {
            // already ran -- get out of the way, let the normal session
            // (budgie-panel) take over instead of showing the wizard again
            this.quit ();
            return;
        }

        var provider = new Gtk.CssProvider ();
        provider.load_from_path (CSS_PATH);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        window = new Adw.ApplicationWindow (this) {
            default_width = 480,
            default_height = 854,
            fullscreened = true,
            deletable = false
        };
        window.add_css_class ("kibaos-oobe-window");
        // No window-close escape hatch: the account step is mandatory
        // (see build_account_page), so block any close request until
        // finish_oobe has actually written the marker file. Without
        // this, deletable=false alone still leaves things like Alt+F4
        // or a compositor-level close gesture able to tear the window
        // down mid-wizard.
        window.close_request.connect (() => {
            return !FileUtils.test (MARKER, FileTest.EXISTS);
        });

        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        root.add_css_class ("oobe-background");

        // ── top bar: brand + language/dark-mode corner toggles ──────────
        var topbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        topbar.add_css_class ("oobe-topbar");
        var brand = new Gtk.Label ("KIBAOS MOBILE") { xalign = 0, hexpand = true };
        brand.add_css_class ("oobe-brand");
        var lang_btn = corner_button ("preferences-desktop-locale-symbolic");
        lang_btn.clicked.connect (() => stack.visible_child_name = "language");
        var dark_btn = corner_button ("weather-clear-night-symbolic");
        dark_btn.clicked.connect (toggle_dark_mode);
        topbar.append (brand);
        topbar.append (lang_btn);
        topbar.append (dark_btn);
        root.append (topbar);

        // ── linear progress + step dots (Material stepper pairing) ──────
        top_progress = new Gtk.ProgressBar ();
        top_progress.add_css_class ("oobe-linear-progress");
        root.append (top_progress);

        dots_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.CENTER, margin_top = 10, margin_bottom = 4
        };
        root.append (dots_row);

        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            vexpand = true
        };

        stack.add_named (build_welcome_page (), "welcome");
        stack.add_named (build_language_page (), "language");
        stack.add_named (build_wifi_page (), "wifi");
        stack.add_named (build_sim_page (), "sim");
        stack.add_named (build_account_page (), "account");
        stack.add_named (build_done_page (), "done");
        stack.notify["visible-child-name"].connect (update_progress);
        stack.visible_child_name = "welcome";
        update_progress ();

        root.append (stack);

        var toolbar_view = new Adw.ToolbarView ();
        toolbar_view.content = root;
        window.content = toolbar_view;
        window.present ();
    }

    Gtk.Button corner_button (string icon_name) {
        var btn = new Gtk.Button ();
        btn.icon_name = icon_name;
        btn.add_css_class ("oobe-corner-button");
        return btn;
    }

    void toggle_dark_mode () {
        dark_mode = !dark_mode;
        if (dark_mode) {
            window.add_css_class ("dark");
        } else {
            window.remove_css_class ("dark");
        }
    }

    // Updates both the top linear track and the dot row to reflect
    // wherever the stack currently is. Pages outside STEPS (just "done")
    // push the track to full and clear the dots, matching the desktop
    // OOBE's own summary/done page treatment.
    void update_progress () {
        var current = stack.visible_child_name;
        int idx = -1;
        for (int i = 0; i < STEPS.length; i++) {
            if (STEPS[i] == current) { idx = i; break; }
        }

        while (dots_row.get_first_child () != null) {
            dots_row.remove (dots_row.get_first_child ());
        }

        if (idx < 0) {
            top_progress.fraction = 1.0;
            return;
        }

        top_progress.fraction = (double) (idx + 1) / STEPS.length;
        for (int i = 0; i < STEPS.length; i++) {
            var dot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            dot.add_css_class ("oobe-step-dot");
            if (i == idx) dot.add_css_class ("oobe-step-dot-active");
            dots_row.append (dot);
        }
    }

    // ── page builders ───────────────────────────────────────────────────
    // Every page follows the same "dog simple" rule: one big icon so the
    // page reads before any text is parsed, one short line of title, one
    // short line of subtitle, and exactly one strongly-weighted action.
    // Selections that can safely auto-advance (language, a successful
    // Wi-Fi connect) do -- fewer taps beats a technically-more-complete
    // flow every time here.

    Gtk.Widget build_welcome_page () {
        var box = wizard_box ("start-here-symbolic", "Welcome to\nKibaOS Mobile",
            "Switch to simple -- now in your pocket.", true);
        box.append (nav_row (null, next_button ("Get started", "language")));
        return box;
    }

    // Big tap-anywhere rows instead of a dropdown -- picking a language
    // is a single decision, so it gets a single tap. Selecting a row
    // both sets the language AND advances to Wi-Fi; Back still works if
    // someone taps the wrong flag.
    Gtk.Widget build_language_page () {
        var box = wizard_box ("preferences-desktop-locale-symbolic", "Language & Region",
            "Tap the one that feels like home.", false);

        var list = new Gtk.ListBox ();
        list.add_css_class ("oobe-list");
        list.selection_mode = Gtk.SelectionMode.NONE;

        // Plain-text language/region codes instead of flag emoji -- a
        // flag glyph also conflates "country" with "language" (English
        // isn't only spoken in the US/UK), and emoji flag rendering is
        // spotty on minimal mobile font stacks. A short code badge reads
        // reliably everywhere.
        string[,] langs = {
            {"EN-US", "English (US)"}, {"EN-UK", "English (UK)"},
            {"ES", "Español"}, {"FR", "Français"}, {"DE", "Deutsch"}
        };
        for (int i = 0; i < langs.length[0]; i++) {
            var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                margin_top = 4, margin_bottom = 4, margin_start = 6, margin_end = 6
            };
            var code = new Gtk.Label (langs[i, 0]);
            code.add_css_class ("oobe-lang-flag");
            var name = new Gtk.Label (langs[i, 1]) { xalign = 0, hexpand = true };
            name.add_css_class ("oobe-lang-name");
            row_box.append (code);
            row_box.append (name);
            var row = new Gtk.ListBoxRow () { child = row_box };
            list.append (row);
        }
        list.row_activated.connect ((row) => {
            // language choice itself isn't wired to a locale backend
            // yet -- this is a first-boot cosmetic pick until that lands
            stack.visible_child_name = "wifi";
        });
        box.append (list);
        box.append (nav_row (back_button ("welcome"), null));
        return box;
    }

    Gtk.Widget build_wifi_page () {
        var box = wizard_box ("network-wireless-symbolic", "Connect to Wi-Fi",
            "Needed for setup and updates.", false);

        var list = new Gtk.ListBox ();
        list.add_css_class ("oobe-list");
        list.selection_mode = Gtk.SelectionMode.SINGLE;
        list.row_activated.connect (on_wifi_row_activated);
        wifi_status_label = new Gtk.Label ("Scanning...") { xalign = 0 };
        wifi_status_label.add_css_class ("oobe-step-label");
        box.append (wifi_status_label);
        box.append (list);
        refresh_wifi_list.begin (list);

        var skip = new Gtk.Button.with_label ("Skip for now");
        skip.add_css_class ("oobe-skip-link");
        skip.halign = Gtk.Align.CENTER;
        skip.clicked.connect (() => stack.visible_child_name = "sim");
        box.append (nav_row (back_button ("language"), null));
        box.append (skip);
        return box;
    }

    async void refresh_wifi_list (Gtk.ListBox list) {
        // shells out to nmcli rather than talking to NetworkManager's
        // D-Bus API directly -- nmcli's terse output is plenty for a
        // pick-a-network list and keeps this file from ballooning with
        // GDBus proxy boilerplate for a first-boot wizard.
        try {
            var proc = new Subprocess (SubprocessFlags.STDOUT_PIPE,
                "nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list");
            var stdout_pipe = proc.get_stdout_pipe ();
            var dis = new DataInputStream (stdout_pipe);
            string? line;
            wifi_status_label.label = "Available networks:";
            while ((line = yield dis.read_line_async ()) != null) {
                if (line.strip () == "") continue;
                var parts = line.split (":");
                var ssid = parts.length > 0 && parts[0] != "" ? parts[0] : "(hidden)";
                var secured = parts.length > 2 && parts[2] != "" && parts[2] != "--";

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                    margin_top = 6, margin_bottom = 6, margin_start = 8, margin_end = 8
                };
                row_box.append (new Gtk.Label (ssid) { xalign = 0, hexpand = true });
                if (secured) {
                    row_box.append (new Gtk.Image.from_icon_name ("network-wireless-encrypted-symbolic"));
                }
                var row = new Gtk.ListBoxRow ();
                row.child = row_box;
                row.set_data<string> ("ssid", ssid);
                row.set_data<bool> ("secured", secured);
                list.append (row);
            }
        } catch (Error e) {
            wifi_status_label.label = "Couldn't scan for networks: %s".printf (e.message);
        }
    }

    void on_wifi_row_activated (Gtk.ListBoxRow row) {
        var ssid = row.get_data<string> ("ssid");
        var secured = row.get_data<bool> ("secured");
        if (secured) {
            prompt_wifi_password (ssid);
        } else {
            connect_wifi.begin (ssid, null);
        }
    }

    // Material bottom-sheet shape (rounded top corners only, flush to
    // the bottom edge via .oobe-sheet) rather than a centered desktop
    // dialog -- matches how Android/LineageOS present the Wi-Fi password
    // prompt as a sheet sliding up from the keyboard's own edge.
    void prompt_wifi_password (string ssid) {
        var dialog = new Adw.AlertDialog (
            "Connect to %s".printf (ssid), null);
        dialog.add_css_class ("oobe-sheet");

        var pw_entry = new Gtk.PasswordEntry () { show_peek_icon = true };
        pw_entry.add_css_class ("entry");
        dialog.set_extra_child (pw_entry);
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("connect", "Connect");
        dialog.set_response_appearance ("connect", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "connect";
        dialog.response.connect ((response) => {
            if (response == "connect") {
                connect_wifi.begin (ssid, pw_entry.text);
            }
        });
        dialog.present (window);
    }

    async void connect_wifi (string ssid, string? password) {
        wifi_status_label.label = "Connecting to %s...".printf (ssid);
        try {
            string[] argv;
            if (password != null) {
                argv = { "nmcli", "device", "wifi", "connect", ssid, "password", password };
            } else {
                argv = { "nmcli", "device", "wifi", "connect", ssid };
            }
            var proc = new Subprocess.newv (argv,
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            yield proc.wait_async ();
            if (proc.get_successful ()) {
                wifi_status_label.label = "Connected to %s.".printf (ssid);
                // auto-advance -- a successful connect needs no further
                // confirmation tap, same reasoning as the language rows
                Timeout.add (700, () => {
                    if (stack.visible_child_name == "wifi") {
                        stack.visible_child_name = "sim";
                    }
                    return false;
                });
            } else {
                wifi_status_label.label = "Couldn't connect to %s -- check the password.".printf (ssid);
            }
        } catch (Error e) {
            wifi_status_label.label = "Connection failed: %s".printf (e.message);
        }
    }

    Gtk.Widget build_sim_page () {
        var box = wizard_box ("network-cellular-symbolic", "SIM & Carrier", "Checking for a SIM.", false);
        sim_status_label = new Gtk.Label ("Checking...") { xalign = 0 };
        sim_status_label.add_css_class ("oobe-subtitle");
        box.append (sim_status_label);
        check_sim.begin ();
        box.append (nav_row (back_button ("wifi"), next_button ("Next", "account")));
        return box;
    }

    async void check_sim () {
        // org.ofono.Manager -> GetModems, then org.ofono.SimManager's
        // Present/SubscriberIdentity properties on whichever modem shows
        // up. ofono owns telephony here, same as Calls/Chatty use.
        try {
            var conn = yield Bus.get (BusType.SYSTEM);
            var manager = yield conn.get_proxy<OfonoManagerIface> (
                "org.ofono", "/");
            var modems = yield manager.get_modems ();
            if (modems.length == 0) {
                sim_status_label.label = "No modem detected.";
                return;
            }
            sim_status_label.label = "Modem found: %s".printf (modems[0]);
            // deeper SIM-present/carrier-name lookup would proxy
            // org.ofono.SimManager on this modem path; left as a
            // follow-up once real hardware is available to test against
        } catch (Error e) {
            sim_status_label.label = "No SIM/modem available (%s).".printf (e.message);
        }
    }

    // Account is mandatory -- no skip link on this page (unlike wifi's),
    // matching Android's own SetupWizard, where the Google-account step
    // has no skip option because it's the anchor the rest of first-run
    // setup (sync, backup, restore) hangs off of. Next stays disabled
    // until a non-empty name is entered, and the window itself can't be
    // closed out from under the wizard (see close_request in activate).
    Gtk.Widget build_account_page () {
        var box = wizard_box ("avatar-default-symbolic", "What's your name?",
            "Shown on your lock screen and in Files.", false);

        var entry = new Gtk.Entry () { placeholder_text = "Your name" };
        entry.add_css_class ("entry");
        box.append (entry);

        var hint = new Gtk.Label ("") { xalign = 0 };
        hint.add_css_class ("oobe-error");
        hint.visible = false;
        box.append (hint);

        var next = new Gtk.Button.with_label ("Next");
        next.add_css_class ("oobe-primary-button");
        next.sensitive = false;
        entry.changed.connect (() => {
            next.sensitive = entry.text.strip () != "";
            hint.visible = false;
        });
        next.clicked.connect (() => {
            var trimmed = entry.text.strip ();
            if (trimmed == "") {
                hint.label = "Enter a name to continue.";
                hint.visible = true;
                return;
            }
            display_name = trimmed;
            stack.visible_child_name = "done";
        });
        box.append (nav_row (back_button ("sim"), next));
        return box;
    }

    Gtk.Widget build_done_page () {
        var box = wizard_box ("", "You're all set!", "Welcome to KibaOS Mobile.", false);

        var check = new Gtk.Image.from_icon_name ("object-select-symbolic") { halign = Gtk.Align.CENTER };
        check.pixel_size = 72;
        check.add_css_class ("oobe-done-check");
        box.append (check);

        var finish = new Gtk.Button.with_label ("Start using KibaOS");
        finish.add_css_class ("oobe-primary-button");
        finish.clicked.connect (finish_oobe);
        box.append (nav_row (null, finish));
        return box;
    }

    void finish_oobe () {
        try {
            DirUtils.create_with_parents ("/var/lib/kibaos", 0755);
            FileUtils.set_contents (MARKER, "1\n");
        } catch (FileError e) {
            warning ("couldn't write OOBE marker: %s", e.message);
        }
        this.quit ();
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Wraps every page in the same .oobe-card / .oobe-inner treatment as
    // the desktop OOBE, just with Material's 28px shape scale + real
    // elevation instead of desktop's borderless full-bleed page (see
    // oobe.css for why -- no cursor/hover to carry hierarchy on touch).
    // is_welcome swaps in the larger .oobe-welcome-greeting title style,
    // same distinction the desktop installer makes for its first page.
    // icon_name is a themed/symbolic GTK icon name (e.g.
    // "network-wireless-symbolic"), never an emoji glyph -- the mobile
    // OOBE renders every page icon and status mark through Gtk.Image
    // so the wizard reads cleanly regardless of emoji font support.
    Gtk.Box wizard_box (string icon_name, string title, string subtitle, bool is_welcome) {
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        card.add_css_class ("oobe-card");
        card.add_css_class ("oobe-inner");

        if (icon_name != "") {
            var icon_image = new Gtk.Image.from_icon_name (icon_name) { halign = Gtk.Align.START };
            icon_image.pixel_size = 64;
            icon_image.add_css_class ("oobe-page-icon");
            card.append (icon_image);
        }

        var title_label = new Gtk.Label (title) { xalign = 0, wrap = true };
        title_label.add_css_class (is_welcome ? "oobe-welcome-greeting" : "oobe-title");
        var subtitle_label = new Gtk.Label (subtitle) { xalign = 0, wrap = true };
        subtitle_label.add_css_class ("oobe-subtitle");

        card.append (title_label);
        card.append (subtitle_label);

        var outer = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_top = 12, margin_bottom = 24, margin_start = 18, margin_end = 18,
            vexpand = true, valign = Gtk.Align.FILL
        };
        outer.append (card);
        return outer;
    }

    // Bottom nav row: back (optional, left) + primary action (right),
    // pinned to the bottom of the page like Android SetupWizard's own
    // persistent nav bar rather than inline with the content above it.
    Gtk.Box nav_row (Gtk.Button? back, Gtk.Button? primary) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            valign = Gtk.Align.END, vexpand = true, margin_top = 16
        };
        row.add_css_class ("oobe-nav-row");
        if (back != null) {
            row.append (back);
        }
        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true };
        row.append (spacer);
        if (primary != null) {
            row.append (primary);
        }
        return row;
    }

    Gtk.Button back_button (string target_page) {
        var btn = new Gtk.Button.with_label ("Back");
        btn.add_css_class ("oobe-secondary-button");
        btn.clicked.connect (() => stack.visible_child_name = target_page);
        return btn;
    }

    Gtk.Button next_button (string label, string target_page) {
        var btn = new Gtk.Button.with_label (label);
        btn.add_css_class ("oobe-primary-button");
        btn.clicked.connect (() => stack.visible_child_name = target_page);
        return btn;
    }

    public static int main (string[] args) {
        var app = new KibaMobileOobe ();
        return app.run (args);
    }
}

[DBus (name = "org.ofono.Manager")]
interface OfonoManagerIface : Object {
    public abstract async string[] get_modems () throws Error;
}
OOBEVALA

  arch-chroot "${_root}" bash -c "
    cd /root/kibaos-mobile-oobe &&
    meson setup build &&
    ninja -C build &&
    ninja -C build install
  " || echo "!! kibaos-mobile-oobe failed to build -- check the meson/ninja log above" >&2

  # first-boot autostart -- checks the marker itself (see MARKER in
  # main.vala) so this is a no-op after the wizard's first successful run
  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-oobe.desktop" << 'OOBEAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Setup
Exec=kibaos-mobile-oobe
X-GNOME-Autostart-enabled=true
OOBEAUTOSTART

  # ── Halium GSI (system.img) -- Halium-boot method ───────────────────────
  # NOTE ON PATHS THAT USED TO BE HERE: an earlier version of this script
  # tried a "fast" GSI path through JamiKettunen/cports (hybris branch) --
  # ./cbuild pkg -a aarch64 user/halium-gsi-X.0 -- which turned out to
  # produce a Chimera Linux apk/rootfs, not a system.img; wrong tool for
  # an Arch Linux ARM/pacstrap userspace. After that, this function
  # switched to building the GSI from source: repo init against
  # Halium/android, breakfast the generic halium_arm64 target, mka
  # rawsystemimage -- the "full system image" porting method. That's a
  # ~150GB+ AOSP repo sync and a multi-hour Soong build just to reproduce
  # a system.img that's already device-agnostic and publicly hosted --
  # a lot of build-server time for a file this project has no reason to
  # compile itself.
  #
  # What's actually appropriate here is the Halium-boot method (one of
  # the three porting methods docs.halium.org/UBports document: full
  # system image, Halium-boot, and standalone kernel). Since Halium 9 the
  # GSI is a prebuilt, device-independent artifact by design -- Treble
  # moved every device-specific bit into the vendor partition, so the
  # Halium-boot method just fetches the GSI instead of rebuilding it, and
  # leaves only halium-boot.img (the kernel + Halium ramdisk, genuinely
  # per-device) to be built or supplied separately -- already handled as
  # a manual step in README-INSTALL.md below. That's the right split for
  # this script: it produces the device-agnostic pieces (this rootfs
  # tarball, and now the GSI fetch), and stays out of the per-device
  # kernel build entirely.
  #
  # Default source is the lolinet mirror -- this is the ubports_GSI_installer
  # bundle at mirrors.lolinet.com/firmware/halium/GSI/, confirmed live
  # (directory listing checked directly). NOTE: an earlier revision of this
  # default pointed at build.lolinet.com/file/halium/GSI/halium-10.0/arm64ab/
  # halium-generic-arm64ab-ota-latest.zip -- that path doesn't exist on
  # lolinet at all (wrong domain AND wrong directory layout; lolinet only
  # ever served numbered ubports_GSI_installer_vN.zip bundles under
  # mirrors.lolinet.com/firmware/halium/GSI/), which is why it 404'd.
  # override KIBA_MOBILE_GSI_URL to pin a specific build/mirror. Set
  # KIBA_SKIP_GSI_FETCH=1 to skip entirely (e.g. offline CI) and fall
  # back to the manual pointer in README-INSTALL.md.
  : "${KIBA_MOBILE_GSI_URL:=https://mirrors.lolinet.com/firmware/halium/GSI/ubports_GSI_installer_v10.zip}"
  if [ "${KIBA_SKIP_GSI_FETCH:-0}" = "1" ]; then
    echo "=== KIBA_SKIP_GSI_FETCH=1 -- skipping Halium GSI fetch (see README-INSTALL.md for a manual pointer) ==="
  else
    mkdir -p /w/halium-gsi && cd /w/halium-gsi
    if curl -fL -o gsi-fetch.zip "${KIBA_MOBILE_GSI_URL}"; then
      # the GSI mirror ships a flashable zip (system image + installer
      # metadata), not a bare system.img -- unzip and grab the image
      # itself so kibaos-mobile-gsi-arm64.img is a drop-in next to the
      # rootfs tarball.
      unzip -o gsi-fetch.zip -d extracted >/dev/null
      _gsi_img="$(find extracted -maxdepth 3 \( -iname 'system.img' -o -iname '*.img' \) 2>/dev/null | head -n1)"
      if [ -n "${_gsi_img}" ] && [ -f "${_gsi_img}" ]; then
        cp "${_gsi_img}" "${_out}/kibaos-mobile-gsi-arm64.img"
        sha256sum "${_out}/kibaos-mobile-gsi-arm64.img" > "${_out}/kibaos-mobile-gsi-arm64.img.sha256"
        echo "=== Fetched Halium GSI: ${_out}/kibaos-mobile-gsi-arm64.img ==="
      else
        echo "ERROR: GSI zip downloaded from ${KIBA_MOBILE_GSI_URL} but no .img found inside -- check KIBA_MOBILE_GSI_URL / mirror layout. Refusing to continue with a mobile build that has no bundled GSI (the installer zip stage would fail anyway, just later and with a more confusing error). Set KIBA_SKIP_GSI_FETCH=1 if you intend to ship a thin installer and push the GSI manually per README-INSTALL.md." >&2
        cd /w
        return 1
      fi
    else
      echo "ERROR: GSI fetch failed -- curl could not retrieve ${KIBA_MOBILE_GSI_URL} (bad URL, 404, or network issue). Refusing to continue with a mobile build that has no bundled GSI (the installer zip stage would fail anyway, just later and with a more confusing error). Set KIBA_SKIP_GSI_FETCH=1 if you intend to ship a thin installer and push the GSI manually per README-INSTALL.md." >&2
      cd /w
      return 1
    fi
    cd /w
  fi

  # ── boot.img repack ingredients (generic Halium ramdisk + magiskboot) ───
  # Earlier revisions of this tried to pre-build boot.img on the build
  # host by fetching a "certified GKI boot image" from Google and
  # assuming that was enough. Checked that against source.android.com and
  # docs.ubports.com and it doesn't hold up on two counts: (1) Google
  # doesn't publish a stable download URL for certified GKI images --
  # they come from a repo-synced source build or a specific numbered
  # ci.android.com artifact, not a fetchable zip per branch; and (2) even
  # where the GKI kernel itself genuinely is generic, turning it into a
  # bootable image still needs the device's own vendor_boot (dtb, base
  # address, pagesize, cmdline) -- and on Android 13+ the ramdisk isn't
  # even in boot.img anymore, it's a separate per-partition init_boot.img.
  # None of that is something a build host can produce without already
  # knowing the specific device.
  #
  # The fix: don't build boot.img on the host at all. Pull it apart and
  # back together on the *phone*, inside update-binary, where the real
  # stock boot/init_boot partition for that exact device is sitting right
  # there. All this pipeline supplies ahead of time is the two pieces
  # that genuinely are generic -- the Halium ramdisk, and a boot-image
  # (un)packer -- bundled into the zip so update-binary doesn't need
  # network access on the phone. The kernel, dtb, and header metadata all
  # come from the device's own stock image, so they're correct by
  # construction instead of guessed from a version string.
  #
  # For the (un)packer: AOSP's own mkbootimg/unpack_bootimg are Python,
  # and TWRP's minimal busybox environment doesn't reliably have a
  # working python3. magiskboot (topjohnwu/Magisk) is the standard
  # answer to exactly this problem in the wild -- a single static
  # aarch64 binary, no interpreter, that auto-detects and unpacks/repacks
  # any Android boot image layout (plain, vendor_boot, GKI header v3/v4)
  # and is routinely run from inside recovery/TWRP by flashable-zip
  # installers (that's literally what Magisk's own install script does).
  # Pulled from the latest Magisk GitHub release rather than vendored, so
  # this always tracks current boot-image format support.
  # generic (non-per-device) Halium ramdisk. Note this is genuinely
  # `initramfs-tools-halium`'s own "continuous" release artifact --
  # confirmed by reading halium-boot's own get-initrd.sh, which fetches
  # this exact URL pattern when Android.mk builds halium-boot.img the
  # "normal" way. It is NOT `Halium/halium-boot` releases -- that repo
  # doesn't publish a ramdisk artifact at all, it's the bootimg-generator
  # source, not initramfs content.
  : "${KIBA_MOBILE_HALIUM_RAMDISK_URL:=https://github.com/halium/initramfs-tools-halium/releases/download/continuous/initrd.img-touch-arm64}"

  echo "=== Fetching boot.img repack ingredients (generic Halium ramdisk + magiskboot) ==="
  mkdir -p /w/boot-repack-tools && cd /w/boot-repack-tools

  curl -fL -o halium-generic-ramdisk.cpio.gz "${KIBA_MOBILE_HALIUM_RAMDISK_URL}" \
    || { echo "!! Halium generic ramdisk fetch failed (${KIBA_MOBILE_HALIUM_RAMDISK_URL}) -- see docs.halium.org for the current generic-ramdisk artifact and re-run with a corrected KIBA_MOBILE_HALIUM_RAMDISK_URL. No fallback -- failing the build." >&2; exit 1; }

  _magisk_apk_url="$(curl -fsL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
    | jq -r '.assets[] | select(.name | test("\\.apk$")) | .browser_download_url' | head -n1)"
  [ -n "${_magisk_apk_url}" ] && [ "${_magisk_apk_url}" != "null" ] \
    || { echo "!! couldn't resolve the latest Magisk release APK via the GitHub API -- can't fetch magiskboot. No fallback -- failing the build." >&2; exit 1; }
  curl -fL -o magisk-latest.apk "${_magisk_apk_url}" \
    || { echo "!! Magisk release APK fetch failed (${_magisk_apk_url}) -- can't fetch magiskboot. No fallback -- failing the build." >&2; exit 1; }
  # an APK is just a zip; magiskboot ships as a native lib so it survives
  # Play/APK packaging rules -- pull the arm64-v8a build straight out.
  unzip -o -j magisk-latest.apk 'lib/arm64-v8a/libmagiskboot.so' -d . \
    || { echo "!! couldn't extract libmagiskboot.so (arm64-v8a) from the Magisk APK -- release layout may have changed. No fallback -- failing the build." >&2; exit 1; }
  [ -f libmagiskboot.so ] \
    || { echo "!! Magisk APK didn't contain lib/arm64-v8a/libmagiskboot.so -- can't repack boot images on-device. No fallback -- failing the build." >&2; exit 1; }
  mv libmagiskboot.so magiskboot
  chmod 0755 magiskboot
  echo "=== Bundled magiskboot + generic Halium ramdisk for on-device boot.img repack ==="
  cd /w

  # ── package + ship ───────────────────────────────────────────────────────
  tar -C "${_root}" --numeric-owner -cpf "${_out}/kibaos-mobile-rootfs.tar" .
  gzip -9 "${_out}/kibaos-mobile-rootfs.tar"
  sha256sum "${_out}/kibaos-mobile-rootfs.tar.gz" > "${_out}/kibaos-mobile-rootfs.tar.gz.sha256"

  # ── ext4 rootfs.img, built straight from the rootfs tree ────────────────
  # halium-boot's initramfs expects a loop-mountable image at
  # /data/rootfs.img, not a tarball (see docs.halium.org/Distribution.html:
  # "mount /data/rootfs.img /target && switch_root /target $INIT"). The
  # community halium-install tool builds this image on the *installer's*
  # host machine specifically to avoid needing a loop-mount-capable mkfs
  # inside a phone's recovery environment. We can skip that whole problem
  # here: this build container already has a real e2fsprogs, and modern
  # mke2fs can seed a filesystem straight from a directory tree with `-d`,
  # no loop device or root privileges required. So the image gets built
  # once, right here, at rootfs-tar time -- not down the line in TWRP.
  _rootfs_kb="$(du -sk "${_root}" | cut -f1)"
  _img_kb=$(( _rootfs_kb + (_rootfs_kb / 5) + 262144 ))   # +20% headroom, +256MB floor for OOBE/updates/writes
  mkfs.ext4 -q -F -L kibaos-rootfs -d "${_root}" -m 0 \
    "${_out}/kibaos-mobile-rootfs.img" "${_img_kb}K"
  sha256sum "${_out}/kibaos-mobile-rootfs.img" > "${_out}/kibaos-mobile-rootfs.img.sha256"

  # ── TWRP-flashable installer zip ─────────────────────────────────────────
  # Real Halium ports overwhelmingly ship a single TWRP-installable zip
  # rather than making the end user run halium-install by hand (see e.g.
  # the Redmi 4A Ubuntu Touch port writeup: "the ZIP method is preferred").
  # There's no single canonical zip-builder upstream for this -- every
  # port hand-rolls its own META-INF/update-binary -- so this does the
  # same thing: update-binary here is a shell script (the well-established
  # SuperSU/AnyKernel3 trick -- TWRP execs it directly off its #!/sbin/sh
  # shebang instead of treating it as a compiled edify binary, so it
  # works on any arch without a separate build per device), which copies
  # kibaos-mobile-rootfs.img to /data/rootfs.img and the fetched GSI to
  # /data/android-rootfs.img -- filenames per Halium's own documented
  # rootfs.img mount point plus the android-rootfs.img convention used by
  # the Halium/android_device_halium_halium_arm64 output and community
  # install scripts (e.g. JBBgameich's replace-android-image).
  #
  # boot.img isn't bundled pre-built anymore -- the ingredients to build
  # it (magiskboot + the generic Halium ramdisk, fetched a few steps up)
  # ride along instead, and update-binary below does the actual
  # unpack/swap-ramdisk/repack against the *device's own* stock boot
  # (or init_boot, on Android 13+ split-partition devices) at install
  # time. That's what makes this device-agnostic without needing to know
  # the target device ahead of time: the kernel/dtb/header always come
  # from that exact phone's own stock image, never guessed or downloaded.
  # update-binary still only ever touches a partition it can positively
  # identify (slot detection, known by-name paths only, hard fallback to
  # "do it yourself") -- guessing wrong on an unknown device's boot
  # partition is real bricking risk that /data writes don't carry, and
  # that safety story doesn't change just because the repack is now
  # automatic.
  _zip_root="/w/kibaos-mobile-installer-zip"
  rm -rf "${_zip_root}"
  mkdir -p "${_zip_root}/META-INF/com/google/android"
  cp "${_out}/kibaos-mobile-rootfs.img" "${_zip_root}/rootfs.img"
  if [ -f "${_out}/kibaos-mobile-gsi-arm64.img" ]; then
    cp "${_out}/kibaos-mobile-gsi-arm64.img" "${_zip_root}/android-rootfs.img"
  fi
  cp /w/boot-repack-tools/magiskboot "${_zip_root}/magiskboot"
  cp /w/boot-repack-tools/halium-generic-ramdisk.cpio.gz "${_zip_root}/halium-generic-ramdisk.cpio.gz"
  echo "# this zip is installed by update-binary directly, not parsed as edify" \
    > "${_zip_root}/META-INF/com/google/android/updater-script"
  cat > "${_zip_root}/META-INF/com/google/android/update-binary" << 'UPDATEBINARY'
#!/sbin/sh

# KibaOS Mobile installer -- flashed from TWRP like any other zip.
# args per the standard flashable-zip contract: $1=recovery API version,
# $2=output fd (for ui_print), $3=path to this zip on the device.
OUTFD="$2"
ZIPFILE="$3"

ui_print() {
  echo "ui_print $1" >> "/proc/self/fd/${OUTFD}"
  echo "ui_print" >> "/proc/self/fd/${OUTFD}"
}
abort_install() {
  ui_print "!! $1"
  exit 1
}

ui_print "=== KibaOS Mobile installer ==="

# ── boot.img / init_boot.img repack (on-device, per-device-correct) ─────
# No pre-built boot image ships in this zip. magiskboot + the generic
# Halium ramdisk (both bundled below) get used right here, against
# *this* device's own stock boot/init_boot partition, so the kernel,
# dtb, and header metadata are always the real ones for this exact
# phone -- never guessed from a version string or downloaded ahead of
# time on a build host that has no idea what device it's for.
#
# Defensive throughout, same posture as the rest of this installer:
# only known by-name paths are ever read, a full backup of whatever's
# already on the partition is written to /data/kibaos-boot-backup/
# before anything is overwritten, and nothing is dd'd back until
# unpack+repack have both fully succeeded. If this device's boot layout
# isn't one magiskboot recognizes, the repack is skipped outright and
# says so -- no guessing on a partition this installer is this careful
# about everywhere else.
_slot=""
if command -v getprop >/dev/null 2>&1; then
  _slot="$(getprop ro.boot.slot_suffix 2>/dev/null)"
fi

_find_by_name() {
  # $1 = partition name, without slot suffix
  for _cand in \
    "/dev/block/bootdevice/by-name/$1${_slot}" \
    "/dev/block/by-name/$1${_slot}" \
    "/dev/block/platform/*/by-name/$1${_slot}"; do
    for _p in ${_cand}; do
      [ -b "${_p}" ] && echo "${_p}" && return 0
    done
  done
  return 1
}

_boot_dev="$(_find_by_name boot)"
_init_boot_dev="$(_find_by_name init_boot)"
_boot_repacked=0

if [ -z "${_boot_dev}" ] && [ -z "${_init_boot_dev}" ]; then
  ui_print "!! couldn't find a known boot or init_boot partition path on"
  ui_print "!! this device -- skipping the boot image repack entirely."
  ui_print "!! Samsung and some other OEMs don't expose these via"
  ui_print "!! by-name symlinks in recovery; you'll need to sort out"
  ui_print "!! halium-boot.img by hand for this device."
else
  rm -rf /tmp/kibaos-boot && mkdir -p /tmp/kibaos-boot
  cd /tmp/kibaos-boot || abort_install "no /tmp to stage the boot repack in"
  unzip -o "${ZIPFILE}" 'magiskboot' 'halium-generic-ramdisk.cpio.gz' -d /tmp/kibaos-boot >/dev/null 2>&1
  [ -f magiskboot ] || abort_install "magiskboot missing from zip -- can't repack the boot image"
  chmod 0755 magiskboot
  gzip -dc halium-generic-ramdisk.cpio.gz > halium-generic-ramdisk.cpio 2>/dev/null \
    || abort_install "couldn't decompress the bundled Halium ramdisk"

  mkdir -p /data/kibaos-boot-backup

  # Android 13+ devices split the generic ramdisk into its own init_boot
  # partition and leave boot with just the kernel -- prefer that split
  # when present so the kernel side is never touched at all. Older/GKI
  # 1.0-2.0 devices keep ramdisk+kernel together in boot.img.
  if [ -n "${_init_boot_dev}" ]; then
    _target_dev="${_init_boot_dev}"
    _target_name="init_boot"
  else
    _target_dev="${_boot_dev}"
    _target_name="boot"
  fi

  ui_print "backing up stock ${_target_name} to /data/kibaos-boot-backup/..."
  dd if="${_target_dev}" of="/data/kibaos-boot-backup/${_target_name}${_slot}.img" bs=4M \
    || abort_install "couldn't back up ${_target_dev} -- refusing to touch it unbacked-up"

  ui_print "unpacking stock ${_target_name} image..."
  cp "/data/kibaos-boot-backup/${_target_name}${_slot}.img" ./stock.img
  ./magiskboot unpack -h stock.img
  _unpack_rc=$?
  if [ "${_unpack_rc}" = "2" ]; then
    ui_print "!! ${_target_name} is a ChromeOS-format image -- magiskboot"
    ui_print "!! can't repack this layout. Skipping the boot repack;"
    ui_print "!! sort out halium-boot.img by hand for this device."
  elif [ ! -f ramdisk.cpio ]; then
    ui_print "!! no generic ramdisk section found in ${_target_name} --"
    ui_print "!! this device's boot layout isn't one this installer"
    ui_print "!! recognizes. Skipping the boot repack; sort out"
    ui_print "!! halium-boot.img by hand for this device."
  else
    ui_print "swapping in the generic Halium ramdisk..."
    cp halium-generic-ramdisk.cpio ramdisk.cpio
    ./magiskboot repack stock.img new-boot.img \
      || abort_install "magiskboot repack failed -- ${_target_name} left untouched"
    ui_print "flashing repacked ${_target_name} to ${_target_dev}..."
    dd if=new-boot.img of="${_target_dev}" bs=4M \
      || abort_install "write failed to ${_target_dev} -- restore from /data/kibaos-boot-backup/${_target_name}${_slot}.img via fastboot if this device won't boot"
    ui_print "${_target_name} repacked and flashed."
    _boot_repacked=1
  fi
  cd /
  rm -rf /tmp/kibaos-boot
fi

mount /data 2>/dev/null
if ! mountpoint -q /data 2>/dev/null && ! grep -q ' /data ' /proc/mounts; then
  abort_install "couldn't mount /data -- format it ext4 and unencrypted first"
fi

ui_print "extracting installer payload..."
rm -rf /tmp/kibaos-installer
mkdir -p /tmp/kibaos-installer
cd /tmp/kibaos-installer || abort_install "no /tmp to stage in"
unzip -o "${ZIPFILE}" 'rootfs.img' 'android-rootfs.img' -d /tmp/kibaos-installer >/dev/null 2>&1

[ -f /tmp/kibaos-installer/rootfs.img ] || abort_install "rootfs.img missing from zip"

ui_print "writing KibaOS Mobile rootfs to /data/rootfs.img..."
cp /tmp/kibaos-installer/rootfs.img /data/rootfs.img || abort_install "failed writing rootfs.img"

if [ -f /tmp/kibaos-installer/android-rootfs.img ]; then
  ui_print "writing Halium GSI to /data/android-rootfs.img..."
  cp /tmp/kibaos-installer/android-rootfs.img /data/android-rootfs.img || abort_install "failed writing android-rootfs.img"
else
  ui_print "!! no GSI bundled in this zip -- push a system image to /data/android-rootfs.img yourself before rebooting"
fi

touch /data/.writable_image /data/.writable_device_image 2>/dev/null

rm -rf /tmp/kibaos-installer

ui_print "=== done -- reboot into KibaOS Mobile ==="
if [ "${_boot_repacked}" = "1" ]; then
  ui_print "(${_target_name} was repacked and flashed by this zip --"
  ui_print " no separate fastboot step needed. Stock backup is at"
  ui_print " /data/kibaos-boot-backup/ if you ever need to revert.)"
else
  ui_print "(this zip didn't touch the boot partition -- make sure a"
  ui_print " Halium-compatible boot.img is already flashed separately)"
fi
exit 0
UPDATEBINARY
  chmod 0755 "${_zip_root}/META-INF/com/google/android/update-binary"
  ( cd "${_zip_root}" && zip -r -X "${_out}/kibaos-mobile-installer.zip" . >/dev/null )
  sha256sum "${_out}/kibaos-mobile-installer.zip" > "${_out}/kibaos-mobile-installer.zip.sha256"
  rm -rf "${_zip_root}"

  # Mobile OOBE (kibaos-mobile-oobe) is built and installed into the
  # rootfs above -- Android-style first-boot flow, no disk-installer
  # step, gated by /var/lib/kibaos/.oobe-done so it only ever runs once.
  cat > "${_out}/README-INSTALL.md" << 'READMEDOC'
# KibaOS Mobile — install

This is the KibaOS Mobile *userspace only* (Budgie panel/raven on phoc,
ofono, Calls, Chatty, squeekboard, libgestures, sddm for lock/login),
shipped in three forms:

- `kibaos-mobile-installer.zip` — flash this from TWRP, easiest path.
- `kibaos-mobile-rootfs.img` — the same thing pre-built as a raw ext4
  image (what's inside the zip), if you'd rather push it yourself.
- `kibaos-mobile-rootfs.tar.gz` — the raw tarball, for
  `halium-install`/manual use if neither of the above fits your setup.

None of these are bootable by themselves. You still need, per your
device's Halium port status:

1. `boot.img`/`init_boot.img` — repacked automatically, **on the phone,
   during install** — not pre-built by this pipeline. The zip carries
   `magiskboot` (a static unpacker/repacker) and a generic Halium
   ramdisk; update-binary dumps whatever's actually sitting on this
   device's own `boot`/`init_boot` partition, swaps in the Halium
   ramdisk, and flashes the result back — so the kernel, dtb, and header
   metadata always come from *this exact phone's* stock image instead of
   being downloaded or guessed from a version string. This works
   regardless of Android version/GKI status, since magiskboot
   auto-detects the boot image layout (plain boot.img, GKI header v3/v4
   with a split `init_boot`, etc.) rather than this pipeline assuming one
   ahead of time.

   Defensive by design: update-binary only ever touches a `boot`/
   `init_boot` partition it can positively identify via known by-name
   symlinks with A/B slot-suffix detection, backs up whatever's already
   there to `/data/kibaos-boot-backup/` *before* writing anything, and
   skips the repack outright (rather than guessing) if it can't confirm
   a safe target, if the image is a layout magiskboot doesn't recognize,
   or if it can't find a generic-ramdisk section to swap. Samsung devices
   (no fastboot-flashable boot partition) fall through to the manual
   step regardless. There's no per-device kernel build required either
   way — if the automatic repack can't proceed on a given device, you're
   pointed at building/supplying a `halium-boot.img` yourself rather than
   this silently shipping a broken one.
2. The Halium GSI `system.img` (arm64) -- fetched via the Halium-boot
   porting method (prebuilt, device-agnostic GSI, no AOSP repo sync)
   unless `KIBA_SKIP_GSI_FETCH=1` was set for this run, and already
   bundled into the installer zip as `android-rootfs.img` if the fetch
   succeeded. Standalone copy at `kibaos-mobile-gsi-arm64.img`
   (+ `.sha256`) alongside these files. Source defaults to the lolinet
   mirror (build.lolinet.com/file/halium/GSI); override
   `KIBA_MOBILE_GSI_URL` to pin a specific build/mirror. If the fetch was
   skipped or failed, grab a GSI build manually from the same mirror or
   devices.ubuntu-touch.io -- the zip will say so on install if it's
   missing.

## Install steps (recommended: the zip)

1. Boot (not flash) TWRP or another Busybox-capable recovery, and confirm
   `/data` is unencrypted and formatted ext4 -- wipe/reformat in recovery
   if it isn't.

2. Push and flash the zip:

       adb push kibaos-mobile-installer.zip /sdcard/
       adb shell twrp install /sdcard/kibaos-mobile-installer.zip

   (or do the same from TWRP's own UI: Install → pick the zip → swipe).
   This repacks and flashes `boot`/`init_boot` in place (see item 1
   above — it'll say plainly in the TWRP log if it couldn't and you need
   to sort out a `halium-boot.img` by hand instead), writes `rootfs.img`
   to `/data/rootfs.img`, and writes the bundled GSI to
   `/data/android-rootfs.img`.

3. Reboot. boot.img's initramfs mounts `/data`, loop-mounts
   `/data/rootfs.img`, and `switch_root`s into it -- that's KibaOS
   Mobile's `kibaos-mobile-oobe` first-boot flow starting up, no separate
   disk installer involved.

## Alternative: halium-install (if the zip doesn't fit your device)

Some devices/recoveries don't play well with the shell-script
update-binary trick, or you may want image conversion/renaming handled
for you instead of doing it by hand. `halium-install`
(https://github.com/jbruechert/halium-install -- stages everything on
your host machine first, avoiding old-TWRP/no-busybox headaches) does
the same job from a PC instead of inside recovery:

    git clone https://github.com/jbruechert/halium-install
    cd halium-install
    sudo ./halium-install -p none \
      kibaos-mobile-rootfs.tar.gz kibaos-mobile-gsi-arm64.img

`-p none` tells it this isn't one of Halium's bundled distros
(reference/neon/ut/debian-pm/etc.) -- just install the tarball as-is.
`sudo` is required (the script loop-mounts image files via
qemu-user-static/simg2img). The official on-device installer
(https://github.com/Halium/halium-scripts, `halium-install` in that
repo) works too, but runs its steps over adb shell instead of on the
host, so it depends on the recovery's own userspace being complete
enough (working busybox etc.).

Full background: docs.ubports.com/en/latest/porting/build_and_boot/Halium_install.html
READMEDOC

  echo "╔══════════════════════════════════════╗"
  echo "║  KibaOS Mobile rootfs build complete! ║"
  echo "║  ${_out}/kibaos-mobile-rootfs.tar.gz  ║"
  echo "╚══════════════════════════════════════╝"
}

if [ "${KIBA_ARCH}" = "mobile" ]; then
  build_kibaos_mobile
  exit 0
fi

# try normal archiso.
# ALARM doesn't have an archiso package period, so aarch64 always takes
# the scenic route -- specifically JackMyers001/archiso-aarch64, a fork
# that adds real aarch64 support to mkarchiso itself (uefi-aarch64.
# systemd-boot.esp/.eltorito bootmodes, an aarch64-aware
# _make_boot_on_fat_aarch64 that copies /boot/Image* directly instead of
# a vmlinuz-*, etc). Stock upstream archiso only targets x86_64 -- it has
# ARM branch used to detour through JackMyers001/archiso-aarch64 here
# (ALARM ships no archiso package at all) -- gone along with the rest of
# the ARM/ISO path. This point in the script is x86_64-only now; mobile
# already exited via build_kibaos_mobile above before reaching here.
install_archiso() {
  pacman -S --noconfirm --needed archiso
}
install_archiso

# ══════════════════════════════════════════════════════════════════════════
# Kernel: stock Arch `linux` package, no runtime kernel build
# ══════════════════════════════════════════════════════════════════════════
# KibaOS previously built its own "kiba-kernel" package from Arch's kernel
# source on every CI run (custom localversion, hand-picked config options,
# a throwaway local pacman repo). That's gone now -- `linux` /
# `linux-headers` are just pulled straight off Arch's mirrors like any
# other package (see packages.x86_64 below), same as everything else in
# this profile. All boot paths, mkinitcpio presets, and GRUB entries below
# use the stock vmlinuz-linux / initramfs-linux.img names Arch's own
# package ships, instead of the old vmlinuz-kiba-kernel / initramfs-kiba-
# kernel.img names.

# ── Paths ─────────────────────────────────────────────────────────────────
WORKDIR="/w"
ISO="kibaos-v${RUN_NUM}"
PROFILE="${WORKDIR}/kiba-profile"
AIROOTFS="${PROFILE}/airootfs"

cd "${WORKDIR}"
cp -r /usr/share/archiso/configs/releng/ "${PROFILE}"

# upstream mkinitcpio dropped /usr/lib/initcpio/udev/11-dm-initramfs.rules
# as of lvm2 2.03.24 -- its contents got folded into 10-dm.rules (see
# mkinitcpio MR !416). Older archiso releng profiles shipped their own
# copy of the "archiso" mkinitcpio install hook under this path with a
# still-dangling reference to that dead file (mkinitcpio-archiso issue
# #20 upstream), which hard-failed the initramfs build with "file not
# found" on both arches. 10-dm.rules is already add_file'd right above
# it in that hook, so the extra line was just dead weight -- stripped
# before mkarchiso ever runs.
#
# Current archiso (89-1 and later) no longer ships this file as part of
# the releng overlay at all -- confirmed against the package's own file
# list, the profile now only carries etc/mkinitcpio.conf.d/archiso.conf
# and etc/mkinitcpio.d/linux.preset, with the "archiso" hook itself
# supplied some other way at pacstrap time instead of being a static
# profile file. Guarded on existence so this quietly no-ops on current
# archiso instead of hard-failing the way it just did -- if a future
# archiso version brings the file back with the same stale reference,
# this still patches it.
if [ -f "${PROFILE}/airootfs/usr/lib/initcpio/install/archiso" ]; then
  sed -i '/11-dm-initramfs\.rules/d' \
    "${PROFILE}/airootfs/usr/lib/initcpio/install/archiso"
fi

mkdir -p "${AIROOTFS}"
sed -i 's/^CheckSpace/#CheckSpace/' "${PROFILE}/pacman.conf"
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' "${PROFILE}/pacman.conf"
# multilib (32-bit x86 compat) doesn't exist as a concept on ARM -- there's
# no such repo on the Arch Linux ARM mirrors, so only flip it on for x86_64.
if [ "${KIBA_ARCH}" = "x86_64" ]; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "${PROFILE}/pacman.conf"
fi

# ══════════════════════════════════════════════════════════════════════════
# profiledef.sh
# ══════════════════════════════════════════════════════════════════════════
cat > "${PROFILE}/profiledef.sh" << 'PROFILEDEF'
#!/usr/bin/env bash
iso_name="kibaos"
iso_label="KIBAOS"
iso_publisher="Kiba Labs, LLC <https://github.com/WolfTech-Innovations>"
iso_application="KibaOS — A friendly OS"
iso_version="$(date +%Y.%m)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1048576' '-Xdict-size' '1048576' '-no-duplicates' '-noappend')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/home/liveuser"]="1000:1000:750"
)
PROFILEDEF
chmod +x "${PROFILE}/profiledef.sh"

# arm patch pass for profiledef.sh. heredoc's quoted on purpose so
# $(date...) doesn't fire early, so sed does the arm edits after the
# fact instead of baking them into the heredoc itself.
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  # GRUB's arm64-efi target is broken upstream (at_keyboard.mod never gets
  # built for it -- see install_archiso above), so aarch64 boots via
  # systemd-boot instead, using the bootmode names JackMyers001's fork
  # adds to mkarchiso for this exact purpose.
  sed -i "s/bootmodes=('uefi.grub')/bootmodes=('uefi-aarch64.systemd-boot.esp' 'uefi-aarch64.systemd-boot.eltorito')/" "${PROFILE}/profiledef.sh"
  sed -i 's/arch="x86_64"/arch="aarch64"/' "${PROFILE}/profiledef.sh"
  # x86 bcj filter on arm binaries doesn't explode, just squishes worse
  # (wrong instruction set to filter for). swap to the arm64 one instead
  sed -i "s/'-Xbcj' 'x86'/'-Xbcj' 'arm64'/" "${PROFILE}/profiledef.sh"
fi

# ══════════════════════════════════════════════════════════════════════════
# /etc/os-release
# ══════════════════════════════════════════════════════════════════════════
mkdir -p "${AIROOTFS}/etc"
cat > "${AIROOTFS}/etc/os-release" << 'OSRELEASE'
NAME="KibaOS"
PRETTY_NAME="KibaOS"
ID=kibaos
BUILD_ID=rolling
VENDOR_NAME="Kiba Labs"
ANSI_COLOR="1;36"
HOME_URL="https://github.com/WolfTech-Innovations/Kiba"
DOCUMENTATION_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/WIKI.md"
SUPPORT_URL="https://github.com/WolfTech-Innovations/Kiba/issues"
BUG_REPORT_URL="https://github.com/WolfTech-Innovations/Kiba/issues"
LOGO=kibaos
OSRELEASE

# ══════════════════════════════════════════════════════════════════════════
# Package list
# ══════════════════════════════════════════════════════════════════════════
cat > "${PROFILE}/packages.x86_64" << 'PACKAGES'
archlinux-keyring
dosfstools
mtools
base
linux
linux-headers
linux-firmware
# linux-firmware split the Intel GuC/HuC blobs (i915/*_guc_*.bin,
# i915/*_huc_*.bin) out into their own package -- stock `linux` doesn't
# pull it in as a dependency itself, so it has to be listed explicitly
# here or i915 loads and modesets simpledrm's fbdev fine, but GuC init
# fails and KWin can never get a working renderer: compositor
# reports "loaded" (it genuinely is), but the display stays black since
# there's no accelerated render node.
linux-firmware-intel
mkinitcpio
mkinitcpio-archiso
earlyoom
fakeroot
efibootmgr
bluez
nftables
libnetfilter_queue
sudo
bash
irqbalance
zram-generator
nano
gnome-console
curl
wget
git
mesa
power-profiles-daemon
xdg-user-dirs
noto-fonts
noto-fonts-emoji
noto-fonts-cjk
bluez-utils
switchboard-plug-desktop
switchboard-plug-display
switchboard-plug-network
switchboard-plug-bluetooth
switchboard-plug-power
switchboard-plug-datetime
switchboard-plug-keyboard
switchboard-plug-mouse-touchpad
switchboard-plug-sound
switchboard-plug-about
switchboard-plug-applications
switchboard-plug-locale
switchboard-plug-notifications
switchboard
switchboard-plug-printers
switchboard-plug-security-privacy
switchboard-plug-sharing
switchboard-plug-user-accounts
sof-firmware
thermald
xorg-xwayland
icu
gcc
debugedit
base-devel
python
pyalpm
parted
gptfdisk
syslinux
pv
lib32-mesa
lib32-vulkan-icd-loader
pkg-config
gdm
budgie-desktop
budgie-session
labwc
swaybg
grim
slurp
wl-clipboard
tesseract
tesseract-data-eng
libnotify
swayidle
gtklock
wlopm
wlr-randr
nemo
gvfs
gvfs-mtp
gvfs-smb
gnome-text-editor
loupe
evince
papirus-icon-theme
adwaita-icon-theme
accountsservice
sassc
meson
ninja
vulkan-headers
vulkan-icd-loader
wayland
wayland-protocols
wlroots0.20
cairo
pango
pixman
libdrm
libevdev
libxml2
freetype2
libpng
harfbuzz
fribidi
glib2
sysprof
libinput
libjpeg-turbo
libxkbcommon
nlohmann-json
yyjson
boost
glm
network-manager-applet
kvantum
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
networkmanager

chromium
ntfs-3g
exfatprogs
polkit
udisks2
upower
scrot
fastfetch
flatpak
xdg-desktop-portal
xdg-desktop-portal-gtk
xdg-desktop-portal-wlr
imagemagick
eglinfo
gnupg
xdotool
v4l2loopback-dkms
xdg-utils
gawk
totem
gstreamer
gst-plugins-base
gst-plugins-good
gst-plugins-bad
plymouth
squashfs-tools

# ── Windows app support (WinApps) ────────────────────────────────────────
freerdp
docker
docker-compose
dialog
iproute2
openbsd-netcat
zenity
pciutils

# ── Security ───────────────────────────────────────────────────────────

# ── Storage/initcpio support ─────────────────────────────────────────────
lvm2

# ── System tuning/maintenance ────────────────────────────────────────────
tuned
PACKAGES
# arm package swap: right kernel, drop the intel-only stuff, rename
# the file so archiso can actually find it
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  # intel gpu firmware -- arm doesn't have an intel gpu to feed it to
  sed -i '/^linux-firmware-intel$/d' "${PROFILE}/packages.x86_64"
  sed -i '/^# linux-firmware split the Intel GuC\/HuC blobs/,/^# fails and KWin can never get a working renderer/d' \
    "${PROFILE}/packages.x86_64"
  # thermald: Intel-specific thermal daemon, doesn't exist for ARM
  sed -i '/^thermald$/d' "${PROFILE}/packages.x86_64"
  # syslinux: x86 BIOS bootloader package, ALARM doesn't ship it at all
  # (memdiskfind loss is fine -- BIOS/isolinux boot is already dropped on
  # this arch, see the comment above this package's line for why it was
  # here in the first place)
  sed -i '/^syslinux$/d' "${PROFILE}/packages.x86_64"
  # lib32-*: 32-bit x86 multilib compat packages -- multilib isn't a thing
  # on ARM (see the pacman.conf multilib gating elsewhere in this script)
  sed -i '/^lib32-mesa$/d; /^lib32-vulkan-icd-loader$/d' "${PROFILE}/packages.x86_64"
  # mkinitcpio-archiso: this is exactly what JackMyers001/archiso-aarch64
  # exists to work around -- ALARM has no usable mkinitcpio-archiso, so
  # the fork's own mkarchiso already drops the archiso/archiso_pxe_*/
  # archiso_kms initcpio hooks straight onto the target airootfs itself
  # before pacstrap ever runs. Leaving this package in packages.aarch64
  # makes pacstrap try to lay the same files down a second time via
  # pacman, which refuses ("exists in filesystem") since it doesn't
  # already own them -- that's the "Failed to install packages to new
  # root" pacstrap failure this specifically avoids.
  sed -i '/^mkinitcpio-archiso$/d' "${PROFILE}/packages.x86_64"
  # ALARM names its kernel package linux-aarch64, not plain "linux"
  sed -i 's/^linux$/linux-aarch64/; s/^linux-headers$/linux-aarch64-headers/' \
    "${PROFILE}/packages.x86_64"
  mv "${PROFILE}/packages.x86_64" "${PROFILE}/packages.aarch64"
fi

# ══════════════════════════════════════════════════════════════════════════
# mkinitcpio
# ══════════════════════════════════════════════════════════════════════════
# archiso.conf is ONLY for the live environment (memdisk/archiso hooks).
# plymouth's in there so live boot can actually show our splash, and kms
# has to come before archiso so the framebuffer exists in time for
# plymouth to have something to draw on. gotta add both here since
# mkarchiso only bakes this file's hooks into the live ISO initramfs
# (see linux.preset's archiso_config= below) — installed.conf is a
# completely separate thing and mkarchiso never even looks at it.
mkdir -p "${AIROOTFS}/etc/mkinitcpio.conf.d"
cat > "${AIROOTFS}/etc/mkinitcpio.conf.d/archiso.conf" << 'INITRAMFS'
HOOKS=(base udev kms plymouth keyboard keymap modconf memdisk archiso block filesystems)
# mkinitcpio's default compression is zstd, which some older GRUB builds
# don't recognize -- known upstream as an "invalid magic number" error on
# newer image/decompressor formats that predates the GRUB patch adding
# support for them. Older UEFI boards are exactly where an older,
# unpatched GRUB is more likely to still be in the boot chain. gzip is
# the one format every GRUB version has always understood, at the cost
# of a slightly larger initramfs and marginally slower decompression --
# a fine trade for booting reliably on old hardware.
COMPRESSION="gzip"
INITRAMFS

# ARM: drop the memdisk hook -- it needs the memdiskfind binary, which
# ships in the `syslinux` package (kept deliberately on x86_64 for this
# reason, see the packages.x86_64 comment above `syslinux` for why it's
# there even with BIOS boot dropped). ALARM has no syslinux package at
# all, so on aarch64 the binary can never be present and mkinitcpio just
# hard-fails every build ("ERROR: module not found: 'phram'" / "ERROR:
# binary not found: 'memdiskfind'"), which is what actually turns
# mkinitcpio's generic "errors were encountered during the build"
# warning into a nonzero exit -- not the sbctl post hook that runs after
# it and just skips signing cleanly when no Secure Boot keys exist yet.
# x86_64 keeps memdisk (and its RAM-load-the-whole-ISO capability) intact.
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  sed -i 's/ memdisk / /' "${AIROOTFS}/etc/mkinitcpio.conf.d/archiso.conf"
fi

# installed.conf is what the INSTALLED system uses once the OOBE installer
# runs initcpio. no memdisk/archiso hooks allowed here, those are live-only
#
# HOOKS order fixed to match Arch's documented "sane defaults" order
# (base udev autodetect modconf kms keyboard keymap block filesystems
# fsck -- see mkinitcpio.conf's own upstream comments and the ArchWiki
# Plymouth page). `autodetect` has to come right after base/udev and
# BEFORE the other module-affecting hooks (modconf, kms, block,
# filesystems) -- that's what lets it trim their module list down to
# what's actually present on this machine; anything placed ahead of it
# (like the old kms/plymouth-before-autodetect order here) just skips
# that trim for itself and bloats the initramfs. Not the direct cause
# of a root-not-found failure, but a real correctness bug regardless.
# `plymouth` placed right after udev per the ArchWiki's own Plymouth
# hook-ordering guidance.
cat > "${AIROOTFS}/etc/mkinitcpio.conf.d/installed.conf" << 'INSTALLED_HOOKS'
HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap block filesystems fsck)
COMPRESSION="gzip"
INSTALLED_HOOKS

# Filename here has to stay "linux.preset" -- that's the specific path
# mkarchiso's own initramfs-build step looks for. This is stock `linux`'s
# own preset name/layout, but it's hand-written here (not the one the
# package's pacman hook would generate) since mkarchiso never touches
# that one; it only ever runs this file.
mkdir -p "${AIROOTFS}/etc/mkinitcpio.d"
cat > "${AIROOTFS}/etc/mkinitcpio.d/linux.preset" << 'PRESET'
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image='/boot/initramfs-linux.img'
PRESET
# aarch64: the fork's own bundled configs/releng (copied in via cp -r
# above -- this is what /usr/share/archiso/configs/releng actually is on
# this arch, since install_archiso() never installs a real `archiso`
# package here, only builds+installs JackMyers001/archiso-aarch64's own
# copy) ships its own /etc/mkinitcpio.d/linux-aarch64.preset as part of
# that same overlay, per its README ("moved archiso initcpio files
# directly into the releng airootfs" to patch around ALARM's stock
# mkinitcpio-archiso hooks). _make_custom_airootfs copies this overlay
# into pacstrap_dir BEFORE _make_packages() pacstraps `linux-aarch64`
# (see mkarchiso's own function order) -- so that inherited preset file
# collides with the one the real linux-aarch64 package also tries to
# install, and pacstrap refuses to overwrite a file it doesn't already
# own ("linux-aarch64.preset exists in filesystem"). Safe to just delete
# it: nothing in this build ever reads it -- customize_airootfs.sh
# invokes mkinitcpio by hand for aarch64 with explicit -k/-c/-g flags
# (see the ARM initramfs section further down) specifically because
# ALARM's linux-aarch64 package doesn't carry the pacman hook that would
# auto-trigger it off this preset in the first place.
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  rm -f "${AIROOTFS}/etc/mkinitcpio.d/linux-aarch64.preset"
fi
# NOTE: this stays at the generic vmlinuz-linux/initramfs-linux.img names
# for BOTH arches now. On aarch64, ALL_kver here is moot anyway --
# customize_airootfs.sh invokes mkinitcpio directly with an explicit -k
# "$(uname -r)" for that arch (see below) rather than relying on ALL_kver
# path resolution, since ALARM's linux-aarch64 package never drops a
# vmlinuz-linux file to resolve against in the first place (only
# /boot/Image and /boot/Image.gz -- see the systemd-boot loader entry
# further down, which references /boot/Image directly).

# ══════════════════════════════════════════════════════════════════════════
# Boot menu — GRUB (x86_64) or systemd-boot (aarch64), UEFI only
# ══════════════════════════════════════════════════════════════════════════
# releng ships both syslinux/ (BIOS) and efiboot/ (systemd-boot) by
# default. BIOS boot is gone on both arches, so syslinux/ always goes.
# efiboot/ is x86_64's dead weight (GRUB is what boots x86_64) but it's
# exactly what aarch64 needs (systemd-boot, per install_archiso's note on
# why GRUB's arm64-efi target doesn't work) -- so only strip efiboot/ on
# x86_64, and generate fresh content into it for aarch64 instead of also
# deleting it there.
rm -rf "${PROFILE}/syslinux"

if [ "${KIBA_ARCH}" = "x86_64" ]; then
  rm -rf "${PROFILE}/efiboot"
  mkdir -p "${PROFILE}/grub"

  # grub.cfg is a template — mkarchiso fills in %ARCHISO_LABEL%,
  # %INSTALL_DIR%, %ARCH%, %ARCHISO_SEARCH_FILENAME% for us at build time
  # (see _build_grub_config in mkarchiso). GRUB just draws its splash right
  # away no matter what the timeout is — unlike systemd-boot, which needs
  # timeout>=1 to even show one — so timeout=0 here means we boot straight
  # in without hitting that systemd-boot splash bug from before.
  cat > "${PROFILE}/grub/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=0
insmod all_video
insmod gfxterm
terminal_output gfxterm

search --no-floppy --set=root --label %ARCHISO_LABEL%

menuentry "KibaOS" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

menuentry "KibaOS (safe mode)" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G nomodeset systemd.unit=multi-user.target systemd.log_level=info
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

if [ "${grub_platform}" == "efi" ]; then
    menuentry 'UEFI Firmware Settings' --id 'uefi-firmware' {
        fwsetup
    }
fi
GRUBCFG
else
  # aarch64: systemd-boot. loader.conf/entries/*.conf format and the
  # %ARCHISO_LABEL%/%INSTALL_DIR%/%ARCH% templating are the same
  # mkarchiso mechanism GRUB used above, just read out of efiboot/loader
  # instead of grub/grub.cfg -- see JackMyers001/archiso-aarch64's own
  # releng profile, which this is matched against directly. Entries
  # reference /boot/Image (the uncompressed EFI-stub kernel ALARM's
  # linux-aarch64 package actually ships -- see customize_airootfs.sh's
  # note on why there's no vmlinuz-* on this arch at all) and the generic
  # initramfs-linux.img the preset above still produces.
  mkdir -p "${PROFILE}/efiboot/loader/entries"
  cat > "${PROFILE}/efiboot/loader/loader.conf" << 'LOADERCONF'
timeout 0
default kibaos.conf
LOADERCONF
  cat > "${PROFILE}/efiboot/loader/entries/kibaos.conf" << 'ENTRYCONF'
title   KibaOS
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
ENTRYCONF
  cat > "${PROFILE}/efiboot/loader/entries/kibaos-safe.conf" << 'ENTRYCONF'
title   KibaOS (safe mode)
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G nomodeset systemd.unit=multi-user.target systemd.log_level=info
ENTRYCONF
fi

# ══════════════════════════════════════════════════════════════════════════
# pacman.conf tweaks
# ══════════════════════════════════════════════════════════════════════════
PACMAN_CONF="${PROFILE}/pacman.conf"
if [ -f "${PACMAN_CONF}" ]; then
  grep -q 'NoExtract' "${PACMAN_CONF}" || \
    sed -i '/^\[options\]/a NoExtract  = usr/share/man/* usr/share/info/* usr/share/doc/*\nNoExtract  = usr/share/locale/* !usr/share/locale/en_US/* !usr/share/locale/en_GB/* !usr/share/locale/locale.alias' \
    "${PACMAN_CONF}"
fi

# ══════════════════════════════════════════════════════════════════════════
# liveuser account
# ══════════════════════════════════════════════════════════════════════════
LIVE_HASH=$(openssl passwd -6 "live")
grep -q '^liveuser:' "${AIROOTFS}/etc/passwd"  2>/dev/null || \
  echo 'liveuser:x:1000:1000:KibaOS Live User:/home/liveuser:/bin/bash' >> "${AIROOTFS}/etc/passwd"
grep -q '^liveuser:' "${AIROOTFS}/etc/group"   2>/dev/null || \
  echo 'liveuser:x:1000:liveuser' >> "${AIROOTFS}/etc/group"
grep -q '^liveuser:' "${AIROOTFS}/etc/shadow"  2>/dev/null || \
  echo "liveuser:${LIVE_HASH}:19000:0:99999:7:::" >> "${AIROOTFS}/etc/shadow"
mkdir -p "${AIROOTFS}/home/liveuser"
mkdir -p "${AIROOTFS}/etc/sudoers.d"
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > "${AIROOTFS}/etc/sudoers.d/liveuser"
chmod 0440 "${AIROOTFS}/etc/sudoers.d/liveuser"

# ══════════════════════════════════════════════════════════════════════════
# systemd symlinks
# ══════════════════════════════════════════════════════════════════════════
WANTS="${AIROOTFS}/etc/systemd/system"
mkdir -p "${WANTS}/default.target.wants" "${WANTS}/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/graphical.target       "${WANTS}/default.target"
ln -sf /usr/lib/systemd/system/gdm.service             "${WANTS}/display-manager.service"
ln -sf /usr/lib/systemd/system/pacman-init.service    "${WANTS}/multi-user.target.wants/pacman-init.service"
ln -sf /usr/lib/systemd/system/bluetooth.service      "${WANTS}/multi-user.target.wants/bluetooth.service"

# ══════════════════════════════════════════════════════════════════════════
# customize_airootfs.sh — runs inside chroot at build time
# ══════════════════════════════════════════════════════════════════════════
mkdir -p "${AIROOTFS}/root"
cat > "${AIROOTFS}/root/customize_airootfs.sh" << 'CUSTOMIZE'
#!/usr/bin/env bash
set -e

rm -f /etc/machine-id
touch /etc/machine-id
# dbus-daemon refuses to start at all -- even a private session bus via
# dbus-run-session -- without a valid /etc/machine-id, and this script
# later needs a working dbus session (liveuser dconf/panel provisioning
# further down). Give the chroot a real, temporary machine-id now so
# everything in between works; it gets blanked again right before this
# script exits so the shipped image still generates its own on first boot.
systemd-machine-id-setup

# ── spin up the sysusers.d users (polkitd etc) by hand ─────────────────────
# normally pacman fires this off as a post-install hook on a live system,
# but that hook just doesn't reliably trigger when packages get unpacked
# straight into an airootfs, so stuff like polkitd never gets a user and
# then polkitd faceplants on boot ("Could not activate remote peer
# 'org.freedesktop.PolicyKit1': startup job failed"). so just run it
# ourselves here instead of hoping pacman does it.
rm /usr/lib/sysusers.d/basic.conf
rm /usr/lib/sysusers.d/arch.conf
systemd-sysusers || true
systemd-tmpfiles --create 2>/dev/null || true

# ── polkitd fallback, just in case ──────────────────────────────────────────
# belt and suspenders: if systemd-sysusers above whiffed in this chroot for
# whatever reason, this makes sure the polkitd user exists anyway so
# polkitd can actually start (same failure mode as above otherwise)
id polkitd &>/dev/null || useradd -r -U -M -d /run/polkit -s /usr/bin/nologin polkitd

# ── alpm user ──────────────────────────────────────────────────────────────
useradd -r -s /usr/bin/nologin -U alpm 2>/dev/null || true
mkdir -p /var/cache/pacman/pkg
chmod 755 /var/cache/pacman /var/cache/pacman/pkg
chown -R alpm:alpm /var/cache/pacman
# multilib doesn't exist on ARM mirrors -- this chroot script is shared
# between x86_64 and aarch64 builds, so check uname -m rather than assume.
if [ "$(uname -m)" = "x86_64" ]; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi

# ── x86_64 mirror fallback ──────────────────────────────────────────────────
# The airootfs's /etc/pacman.d/mirrorlist as shipped by mkarchiso only has
# geo.mirror.pkgbuild.com uncommented -- fine normally, but on an
# Azure-hosted CI runner a single geo-balanced mirror having a bad day (rate
# limit, regional outage, TLS hiccup) hard-fails every `pacman -S` in this
# chroot with no retry target. aarch64 already gets equivalent redundancy
# for free since ALARM's mirror.archlinuxarm.org rarely wobbles the same
# way, so only bother with this on x86_64. Order matters -- pacman walks
# these top to bottom per-download, so keep the geo mirror first and
# well-known, stable, high-bandwidth mirrors after it as fallback.
if [ "$(uname -m)" = "x86_64" ]; then
  cat > /etc/pacman.d/mirrorlist << 'MIRRORLIST'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://america.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
MIRRORLIST
fi

# CheckSpace already got disabled for the airootfs pacstrap up in
# kibaos.sh's PROFILE/pacman.conf, but that edit isn't guaranteed to have
# carried over into THIS chroot's own live /etc/pacman.conf, so — belt and
# suspenders again — do it here too. CheckSpace is notorious for false-
# positiving on overlay filesystems (its statvfs() call just lies about
# free space on overlay2, which is what basically every Docker CI runner
# uses), and worse, its "not enough free disk space... Proceed? [Y/n]"
# prompt doesn't respect --noconfirm like the normal prompts do. in a
# non-interactive CI shell with no stdin that's the actual thing hanging
# the build, not a real space problem.
sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf

# ── nuke and rebuild the pacman keyring inside THIS chroot ─────────────────
# "keyring is not writable" / "required key missing from keyring" shows up
# whenever /etc/pacman.d/gnupg's ownership/perms don't line up with
# whatever UID is actually running pacman in here — happens a lot in CI
# where the outer Docker layer and this arch-chroot session don't quite
# match, even though mkarchiso already set up a keyring earlier. GnuPG's
# picky about homedir perms (has to be 0700, owned by whoever's calling
# it), so instead of chasing down which UID owns what, just blow it away
# and rebuild clean under whatever's actually running this script.
rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
# ALARM-signed packages (gtk4-layer-shell, patchelf, pip's aarch64 deps
# like python-cryptography/python-cffi, etc.) are signed by the Arch
# Linux ARM Build System key, which the archlinux keyring above does not
# carry. Without this, `pacman -S` on any ALARM package later in this
# script fails with "signature ... unknown trust" -- the key gets
# auto-fetched but never locally signed. This mirrors the recv/lsign done
# for work/pacman-gnupg near the end of the outer build script, but that
# one only covers the keyring pacstrap uses to populate the airootfs --
# this chroot rebuilt its own separate keyring above, so it needs the
# same treatment independently. $KIBA_ARCH isn't visible inside this
# chroot, so detect via uname instead.
if [ "$(uname -m)" = "aarch64" ]; then
  pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
fi
pacman -Syy --noconfirm

# ── clear out disk before we install anything else ──────────────────────────
# by now mkarchiso's already pacstrapped the whole ~195-package
# packages.x86_64 list (chromium, mesa, all of it) into this
# airootfs, and every single .pkg.tar.zst is still sitting in the cache —
# nothing cleared it until the very end of the script before. everything
# coming up next (KWin, OOBE, and whatever else builds from source below)
# needs real scratch
# disk on top of that, and THAT'S what was actually running the image out
# of space, not any one install being huge. -Scc (double-c) nukes cached
# packages of every version, not just the outdated ones.
pacman -Scc --noconfirm

# earlyoom (just polls free mem/swap thresholds) and systemd-oomd
# (cgroup-aware, uses PSI) both do the same job of OOM-killing stuff, so
# running both at once just means they can race and kill different
# processes for the same pressure event. systemd-oomd already ships
# inside systemd itself (no extra package) and is the more modern,
# desktop-integrated pick since it already understands user.slice/session
# cgroups, so that's the one that's actually enabled. earlyoom stays
# installed but off, just sitting there as a fallback if oomd ever gets
# ripped out.
systemctl disable earlyoom 2>/dev/null || true
mkdir -p /etc/systemd/oomd.conf.d
cat > /etc/systemd/oomd.conf.d/kibaos.conf << 'OOMDCONF'
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureDurationSec=20s
OOMDCONF
systemctl enable systemd-oomd

cat > /etc/sysctl.d/99-kibaos.conf << 'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
net.core.netdev_max_backlog=16384
SYSCTL

# NOTE: there used to be a binfmt_misc registration here
# (/etc/binfmt.d/wine.conf, matching on the MZ header) that routed .exe
# execution straight through Wine at the kernel level. That's gone now
# along with Wine itself. Windows programs aren't launched by double-
# clicking an .exe anymore either -- see the WinApps section below, which
# now opens the whole Windows environment as one fullscreen workspace
# instead of routing individual files through a mimeapps default.

pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'kibaos' > /etc/hostname
cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   kibaos.localdomain kibaos
HOSTS

for g in users wheel audio video input network storage power; do
  groupadd -r "$g" 2>/dev/null || true
  usermod -aG "$g" liveuser 2>/dev/null || true
done
echo "liveuser:live" | chpasswd
grep -qx '/bin/bash' /etc/shells || echo '/bin/bash' >> /etc/shells
cp -aT /etc/skel/ /home/liveuser/ 2>/dev/null || true
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser

sed -i 's/#Storage=auto/Storage=volatile/'                    /etc/systemd/journald.conf
sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/'   /etc/systemd/logind.conf
sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#IdleAction=ignore/IdleAction=ignore/'               /etc/systemd/logind.conf
# Explicitly zero out the idle-action timer so logind never fires it,
# and suppress the hibernate/power keys too — this is a live/install session,
# nothing should put the machine to sleep mid-install.
grep -q 'IdleActionSec'  /etc/systemd/logind.conf || echo 'IdleActionSec=0'  >> /etc/systemd/logind.conf
grep -q 'HandleHibernateKey' /etc/systemd/logind.conf || echo 'HandleHibernateKey=ignore' >> /etc/systemd/logind.conf
grep -q 'HandleLidSwitchDocked' /etc/systemd/logind.conf || echo 'HandleLidSwitchDocked=ignore' >> /etc/systemd/logind.conf
grep -q 'HandleLidSwitchExternalPower' /etc/systemd/logind.conf || echo 'HandleLidSwitchExternalPower=ignore' >> /etc/systemd/logind.conf
grep -q 'HandlePowerKey' /etc/systemd/logind.conf && \
  sed -i 's/^HandlePowerKey=.*/HandlePowerKey=poweroff/' /etc/systemd/logind.conf

# Belt-and-suspenders: mask the sleep targets themselves so nothing on the
# live/install image — a stray udev rule, a misbehaving app, a battery
# driver's default — can put the machine to sleep mid-session or mid-install.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

# ══════════════════════════════════════════════════════════════════════════
# BRANDING ASSETS
# ══════════════════════════════════════════════════════════════════════════
WALLPAPER_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/wallpapers/wallpaper.png?raw=true"
# One shared source image now backs both the app-icon set (kibaos.png /
# hicolor icons) and the Plymouth boot splash. This asset (unlike the old
# one this pipeline used to point at) is already a single centered square
# badge with no separate wordmark -- 1254x1254, transparent/white field,
# nothing to crop out -- so both the splash and the icon set below just
# resize it directly rather than cropping a badge out of a landscape
# lockup. The OOBE installer logo further below reuses this same
# processed image too, so there's still only one brand asset to keep in
# sync, just without the crop step the old lockup composition needed.
BOOT_SPLASH_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/splash/splash.png?raw=true"
WALLPAPER_DEST="/usr/share/kibaos/wallpaper.jpg"
LOGO_SRC="/usr/share/kibaos/logo-raw.png"
LOGO_256="/usr/share/kibaos/logo-256.png"
LOGO_96="/usr/share/kibaos/logo-96.png"
LOGO_48="/usr/share/kibaos/logo-48.png"
LOGO_32="/usr/share/kibaos/logo-32.png"
INSTALLER_LOGO="/usr/share/kibaos/installer-logo.png"
BOOT_SPLASH_RAW="/usr/share/kibaos/boot-splash-raw.png"
BOOT_SPLASH="/usr/share/kibaos/boot-splash.png"

mkdir -p /usr/share/kibaos /usr/share/pixmaps

curl -fL --retry 5 --retry-delay 3 -o "${BOOT_SPLASH_RAW}" "${BOOT_SPLASH_URL}" || true

if [ -f "${BOOT_SPLASH_RAW}" ] && file "${BOOT_SPLASH_RAW}" | grep -qi 'image'; then
  # Boot splash: already square, scaled down, aspect kept.
  magick "${BOOT_SPLASH_RAW}" -filter Lanczos -resize '480x480>' "${BOOT_SPLASH}"

  # App icons + taskbar launcher icon: this source is already just the
  # centered badge, so it goes straight through as the icon source with
  # no crop -- the old fixed crop box (640x640, offset 450,117) was
  # measured against the previous landscape lockup image and would slice
  # this square badge wrong.
  cp "${BOOT_SPLASH_RAW}" "${LOGO_SRC}"
  rm -f "${BOOT_SPLASH_RAW}"
fi

curl -fL --retry 5 --retry-delay 3 -o "${WALLPAPER_DEST}" "${WALLPAPER_URL}" || \
  magick -size 1920x1080 gradient:"#003f5c-#0099cc" "${WALLPAPER_DEST}"

if [ -f "${LOGO_SRC}" ] && file "${LOGO_SRC}" | grep -qi 'image'; then
  magick "${LOGO_SRC}" -filter Lanczos -resize 256x256 "${LOGO_256}"
  magick "${LOGO_SRC}" -filter Lanczos -resize 96x96  "${LOGO_96}"
  magick "${LOGO_SRC}" -filter Lanczos -resize 48x48  "${LOGO_48}"
  magick "${LOGO_SRC}" -filter Lanczos -resize 32x32  "${LOGO_32}"
  rm -f "${LOGO_SRC}"
else
  for sz in 256 96 48 32; do
    magick -size ${sz}x${sz} xc:none \
      -fill '#0099cc' -draw "circle $((sz/2)),$((sz/2)) $((sz/2)),1" \
      -fill white -pointsize $((sz/2)) -gravity Center -annotate 0 'K' \
      "/usr/share/kibaos/logo-${sz}.png"
  done
fi

cp "${LOGO_256}" /usr/share/pixmaps/kibaos.png
ln -sf /usr/share/pixmaps/kibaos.png /usr/share/pixmaps/kibaos-logo.png
mkdir -p /usr/share/icons/hicolor/256x256/apps \
         /usr/share/icons/hicolor/48x48/apps   \
         /usr/share/icons/hicolor/32x32/apps
cp "${LOGO_256}" /usr/share/icons/hicolor/256x256/apps/kibaos.png
cp "${LOGO_48}"  /usr/share/icons/hicolor/48x48/apps/kibaos.png
cp "${LOGO_32}"  /usr/share/icons/hicolor/32x32/apps/kibaos.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

# ── Flat-white badge for the top-panel Raven trigger ────────────────────────
# Panel/status icons are conventionally monochrome ("symbolic") so they
# read cleanly against a dark bar -- pulling the full two-tone LOGO_256
# straight onto the panel would look muddy at 16-24px anyway. This
# recolors the badge's own alpha silhouette solid white rather than
# hand-drawing a separate glyph, so it always matches whatever the boot
# splash actually is.
#
# RavenTriggerApplet.plugin ships Icon=pane-show-symbolic (confirmed from
# the plugin's own [Plugin] metadata) with no per-instance icon override
# in its dconf schema, so the only reliable way to swap it is overriding
# that icon NAME in the icon theme itself -- same trick used for other
# fixed-icon system UI below. This does mean anything else on the system
# that happens to ask for "pane-show-symbolic" gets our badge too, but
# nothing else in this image does.
BADGE_WHITE_SRC="/usr/share/kibaos/badge-white.png"
magick "${LOGO_256}" -alpha extract -threshold 50% /tmp/kiba-badge-alpha.png
magick -size 256x256 xc:white /tmp/kiba-badge-white.png
magick /tmp/kiba-badge-white.png /tmp/kiba-badge-alpha.png \
  -alpha off -compose CopyOpacity -composite "${BADGE_WHITE_SRC}"
rm -f /tmp/kiba-badge-alpha.png /tmp/kiba-badge-white.png

mkdir -p /usr/share/icons/hicolor/scalable/actions \
         /usr/share/icons/hicolor/symbolic/actions \
         /usr/share/icons/hicolor/24x24/actions    \
         /usr/share/icons/hicolor/22x22/actions     \
         /usr/share/icons/hicolor/16x16/actions
for sz in 16 22 24 32 48; do
  magick "${BADGE_WHITE_SRC}" -filter Lanczos -resize ${sz}x${sz} \
    "/usr/share/icons/hicolor/${sz}x${sz}/actions/pane-show-symbolic.png"
done
cp "${BADGE_WHITE_SRC}" /usr/share/icons/hicolor/scalable/actions/pane-show-symbolic.png
cp "${BADGE_WHITE_SRC}" /usr/share/icons/hicolor/symbolic/actions/pane-show-symbolic.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

# ── OOBE installer logo — same image as the boot splash ─────────────────
# Reuses the already-processed BOOT_SPLASH file directly (full lockup:
# badge + "KibaOS" wordmark) instead of fetching/maintaining a second,
# separate installer.png brand asset. Falls back to the generic cropped-
# badge logo only if the boot splash itself never downloaded (offline
# build, URL moved, etc.) -- same fallback behavior as before.
if [ -f "${BOOT_SPLASH}" ]; then
  cp "${BOOT_SPLASH}" "${INSTALLER_LOGO}"
else
  cp "${LOGO_256}" "${INSTALLER_LOGO}"   # fallback: reuse the generic logo
fi

# ── winapps-setup.vala ──────────────────────────────────────────────────
# GTK4/libadwaita frontend for kibaos-winapps-setup, the headless
# PROGRESS/FATAL backend defined in the WINDOWS APP SUPPORT section
# further down. Built as a second executable in the same meson project as
# the OOBE app rather than a whole separate build tree -- one shared
# vala/gtk4/libadwaita toolchain, one `meson setup && ninja` invocation,
# same dependency versions guaranteed for both.
#
# Deliberately its OWN small file rather than folded into main.vala:
# kiba_install_finalize() (see kiba_install.h/kiba_install.c further down)
# rm -rf's the whole usr/share/kibaos-oobe tree on every normal disk
# install, since KibaOOBE only ever runs during install/OEM-finish and
# has no reason to exist afterward. This app is the opposite -- it's what
# a person launches from the app menu on an already-installed system,
# potentially months later -- so it can't depend on anything under
# kibaos-oobe/ surviving that cleanup. It only reuses libadwaita's own
# semantic style classes (title-1, dim-label, suggested-action, flat),
# not oobe.css, for exactly that reason: nothing here needs a resource
# file to exist post-install, just the compiled binary itself, which
# lands in /usr/bin -- untouched by the live_only cleanup list.
mkdir -p /usr/share/WA/src
cat > /usr/share/WA/src/winapps-setup.vala << 'WINAPPSSETUPVALA'
public class KibaWinAppsSetup : Adw.Application {
    private Adw.ApplicationWindow window;
    private Gtk.ProgressBar progress_bar;
    private Gtk.Label       heading_label;
    private Gtk.Label       status_label;
    private Gtk.Box         button_row;
    private Gtk.Button      retry_btn;
    private Gtk.Button      open_btn;
    private Gtk.Button      close_btn;
    private string          last_fatal_message = "";
    private string[]        launch_args;

    // Same tiny inline translator as KibaOOBE (see main.vala) -- kept as
    // a separate copy rather than a shared header, since this is a
    // single-file build target and Vala has no lightweight way to share
    // one private method across two unrelated executable() targets
    // without a proper library split, which is more plumbing than a
    // three-line helper is worth here.
    private string ui_lang = "en";
    private string t (string en, string tr, string pl) {
        return ui_lang == "tr" ? tr : ui_lang == "pl" ? pl : en;
    }

    public KibaWinAppsSetup (string[] args) {
        Object (application_id: "io.kibaos.winapps-setup", flags: ApplicationFlags.FLAGS_NONE);
        // Everything after argv[0] -- just the optional "--manual-launch"
        // flag kibaos-winapps-workspace already passes today -- gets
        // forwarded straight through to the backend unchanged, same as
        // it always did back when kibaos-winapps-workspace exec'd the
        // backend directly.
        launch_args = args;
    }

    protected override void activate () {
        var locale = GLib.Environment.get_variable ("LANG") ?? "";
        if (locale.has_prefix ("tr")) ui_lang = "tr";
        else if (locale.has_prefix ("pl")) ui_lang = "pl";

        window = new Adw.ApplicationWindow (this) {
            default_width  = 480,
            default_height = 420,
            resizable      = false,
            title = t ("Windows Workspace Setup",
                       "Windows Çalışma Alanı Kurulumu",
                       "Konfiguracja Windows Workspace")
        };

        var toolbar = new Adw.ToolbarView ();
        toolbar.add_top_bar (new Adw.HeaderBar ());

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            halign = Gtk.Align.CENTER, valign = Gtk.Align.CENTER,
            margin_top = 12, margin_bottom = 30, margin_start = 36, margin_end = 36
        };

        var icon = new Gtk.Image.from_icon_name ("kibaos-winapps") {
            pixel_size = 64, halign = Gtk.Align.CENTER
        };
        content.append (icon);

        heading_label = new Gtk.Label (
            t ("Setting up Windows Workspace",
               "Windows Çalışma Alanı Kuruluyor",
               "Konfigurowanie Windows Workspace")) {
            halign = Gtk.Align.CENTER, justify = Gtk.Justification.CENTER
        };
        heading_label.add_css_class ("title-1");
        content.append (heading_label);

        progress_bar = new Gtk.ProgressBar () { show_text = false, hexpand = true };
        content.append (progress_bar);

        status_label = new Gtk.Label (t ("Starting…", "Başlatılıyor…", "Uruchamianie…")) {
            halign = Gtk.Align.CENTER, justify = Gtk.Justification.CENTER,
            wrap = true, max_width_chars = 48
        };
        status_label.add_css_class ("dim-label");
        content.append (status_label);

        // All three buttons exist from the start, just hidden -- toggling
        // visibility rather than reparenting widgets keeps run_backend()
        // (which is also the retry path) simple to reset between runs.
        button_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            halign = Gtk.Align.CENTER, visible = false
        };
        retry_btn = new Gtk.Button.with_label (t ("Retry", "Tekrar Dene", "Spróbuj ponownie"));
        retry_btn.add_css_class ("suggested-action");
        retry_btn.clicked.connect (() => run_backend ());
        open_btn = new Gtk.Button.with_label (
            t ("Open Windows Workspace", "Windows Çalışma Alanını Aç", "Otwórz Windows Workspace"));
        open_btn.add_css_class ("suggested-action");
        open_btn.clicked.connect (() => {
            try { GLib.Process.spawn_command_line_async ("/usr/local/bin/kibaos-winapps-workspace"); }
            catch (GLib.SpawnError e) { warning ("Failed to launch Windows Workspace: %s", e.message); }
            window.close ();
        });
        close_btn = new Gtk.Button.with_label (t ("Close", "Kapat", "Zamknij"));
        close_btn.add_css_class ("flat");
        close_btn.clicked.connect (() => window.close ());
        button_row.append (retry_btn);
        button_row.append (open_btn);
        button_row.append (close_btn);
        content.append (button_row);

        toolbar.set_content (content);
        window.set_content (toolbar);
        window.present ();

        run_backend ();
    }

    // ══════════════════════════════════════════════════════════════════
    // Backend plumbing -- same PROGRESS/FATAL reader as KibaOOBE's
    // launch_backend()/read_backend_output() (see main.vala), just
    // pointed at kibaos-winapps-setup instead of kibaos-oobe-backend/
    // kibaos-oem-finish.sh, and spawned WITHOUT a sudo/pkexec prefix --
    // unlike those two, this backend has to run as the actual invoking
    // user (it writes under $HOME/.config/winapps) and elevates only the
    // specific docker/systemd calls it needs, itself, inline, via its
    // own pkexec calls. Wrapping the whole thing in sudo here would hand
    // it root's $HOME instead and break that.
    // ══════════════════════════════════════════════════════════════════
    private void run_backend () {
        button_row.visible = false;
        retry_btn.visible  = false;
        open_btn.visible   = false;
        close_btn.visible  = false;
        heading_label.label = t ("Setting up Windows Workspace",
                                  "Windows Çalışma Alanı Kuruluyor",
                                  "Konfigurowanie Windows Workspace");
        progress_bar.fraction = 0.0;
        // Undo whatever show_failure_state() below left behind from a
        // previous failed attempt -- without this, a retry that succeeds
        // would still show the status line in error styling.
        status_label.remove_css_class ("error");
        status_label.add_css_class ("dim-label");
        status_label.label = t ("Starting…", "Başlatılıyor…", "Uruchamianie…");

        string[] argv = (launch_args.length > 1)
            ? new string[] { "/usr/local/bin/kibaos-winapps-setup", launch_args[1] }
            : new string[] { "/usr/local/bin/kibaos-winapps-setup" };

        try {
            var launcher = new GLib.SubprocessLauncher (
                GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_MERGE);
            var proc = launcher.spawnv (argv);
            last_fatal_message = "";
            read_backend_output.begin (
                new GLib.DataInputStream (proc.get_stdout_pipe ()), proc);
        } catch (GLib.Error e) {
            status_label.label = t ("Failed to start: %s", "Başlatılamadı: %s",
                                     "Nie udało się uruchomić: %s").printf (e.message);
            show_failure_state ();
        }
    }

    private async void read_backend_output (GLib.DataInputStream stream, GLib.Subprocess proc) {
        try {
            while (true) {
                string? line = yield stream.read_line_async ();
                if (line == null) break;
                if (line.has_prefix ("PROGRESS ")) {
                    var parts = line.substring (9).split (" ", 2);
                    int    pct = int.parse (parts[0]);
                    string msg = parts.length > 1 ? parts[1] : "";
                    progress_bar.fraction = pct / 100.0;
                    status_label.label    = msg;
                } else if (line.has_prefix ("FATAL: ")) {
                    // Same reasoning as KibaOOBE: STDERR_MERGE means this
                    // is the one place the real failure reason (not a
                    // generic message) is ever actually available.
                    last_fatal_message = line.substring (7);
                }
            }
            yield proc.wait_async ();
            if (proc.get_exit_status () == 0) {
                heading_label.label   = t ("All set!", "Her şey hazır!", "Wszystko gotowe!");
                progress_bar.fraction = 1.0;
                open_btn.visible      = true;
                close_btn.visible     = true;
                button_row.visible    = true;
            } else {
                heading_label.label = t ("Setup didn't finish", "Kurulum tamamlanamadı",
                                          "Konfiguracja się nie powiodła");
                status_label.label = last_fatal_message != "" ? last_fatal_message : t (
                    "Something went wrong. Check the system log (journalctl -t kibaos-winapps-setup) for details.",
                    "Bir şeyler ters gitti. Ayrıntılar için sistem günlüğünü kontrol edin (journalctl -t kibaos-winapps-setup).",
                    "Coś poszło nie tak. Sprawdź dziennik systemowy (journalctl -t kibaos-winapps-setup), aby uzyskać szczegóły.");
                show_failure_state ();
            }
        } catch (GLib.Error e) {
            heading_label.label = t ("Setup didn't finish", "Kurulum tamamlanamadı",
                                      "Konfiguracja się nie powiodła");
            status_label.label = t ("Lost connection to the setup process: %s",
                                     "Kurulum sürecine bağlantı kesildi: %s",
                                     "Utracono połączenie z procesem konfiguracji: %s").printf (e.message);
            show_failure_state ();
        }
    }

    private void show_failure_state () {
        status_label.remove_css_class ("dim-label");
        status_label.add_css_class ("error");
        retry_btn.visible  = true;
        close_btn.visible  = true;
        button_row.visible = true;
    }

    public static int main (string[] args) {
        return new KibaWinAppsSetup (args).run (args);
    }
}
WINAPPSSETUPVALA
pacman -Syu --noconfirm git
git clone https://github.com/KibaLabsLLC/Roko
cd Roko
bash build.sh
cd ..
git clone https://github.com/tortr-rs/goget.git
cd goget
make 
make install
set -euo pipefail
git clone --depth 1 https://github.com/KibaLabsLLC/Okami.git
cd Okami
pacman -Syu --noconfirm --needed \
  cmake extra-cmake-modules qt6-base qt6-declarative qt6-svg kirigami flatpak kcoreaddons ki18n
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j"$(nproc)"
pacman -Syu --noconfirm glibc
cat > /usr/share/WA/src/meson.build << 'WAMESON'
project('winapps-setup', 'vala', 'c', version: '1.0')

cc = meson.get_compiler('c')
m_dep       = cc.find_library('m', required: true)
threads_dep = dependency('threads')   # needed for GLib.Thread

gtk4_dep    = dependency('gtk4')
adwaita_dep = dependency('libadwaita-1')
gee_dep     = dependency('gee-0.8')

executable(
  'io.kibaos.winapps-setup',
  'winapps-setup.vala',
  dependencies: [gtk4_dep, adwaita_dep, m_dep, threads_dep],
  install: true
)
WAMESON
mkdir -p /usr/share/icons/hicolor/scalable/actions
cp /usr/share/kibaos/logo-256.png /usr/share/icons/hicolor/scalable/actions/kibaos-watermark-symbolic.png 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true



# ── Privileged backend: libkibadisk + kibaos-oobe-backend ─────────────────
# this fully replaces the old Python/archinstall-based backend. no
# archinstall, no parted, no blkid/partprobe subprocesses anywhere near
# the disk-critical path — check kiba_gpt.c/kiba_fs.c/kiba_udev.c for the
# from-scratch GPT writer, mkfs/mount wrapper, and udev-settle
# replacement respectively. the only external tools I kept around are
# ones that genuinely have no sane from-scratch replacement: unsquashfs,
# mkfs.fat, mkfs.ext4, useradd/chpasswd, bootctl, mkinitcpio,
# locale-gen, pacman — all invoked via posix_spawn argv arrays, never a
# shell, so there's zero string-quoting/injection surface in this
# backend (same argv-array fix I already did on the Vala/sudo side).
echo "=== Building libkibadisk (disk/install backend library) ==="
mkdir -p /usr/share/kibaos-oobe/src/disk
cd /usr/share/kibaos-oobe/src/disk
pacman -Rns --noconfirm gcc base-devel debugedit make patch autoconf automake 2>/dev/null || true

# ── kibaos-oem-finish.sh — lightweight OEM-mode completion backend.
# Runs on an ALREADY-INSTALLED system (imaged by an OEM before shipping —
# see kibaos-oem-prepare below for how that state is set), so there is no
# partitioning, no squashfs extraction, no bootloader install here at all.
# Just locale/keyboard, the real customer account, and removing the OEM
# marker + temporary OEM account. Mirrors the standard OEM-imaging pattern
# (locale/keyboard/account-only finish step, no disk work) used by
# installers like this one. Also always drops /etc/kibaos/winapps-pending
# -- WinApps is a listed, always-on feature -- see WINDOWS APP SUPPORT
# further down for what that marker actually triggers.
cat > /usr/local/bin/kibaos-oem-finish.sh << 'OEMFINISH'
#!/usr/bin/env bash
# Args: $1=locale $2=keymap $3=hostname $4=username $5=password
set -euo pipefail

LOCALE="$1"; KEYMAP="$2"; HOSTNAME_VAL="$3"; USERNAME_VAL="$4"; PASSWORD_VAL="$5"
LOG=/var/log/kibaos-oobe.log
exec > >(tee -a "${LOG}") 2>&1

progress() { echo "PROGRESS $1 $2"; }
fail() { progress 100 "Setup failed: $1"; echo "FATAL: $1" >&2; exit 1; }

[ -n "${USERNAME_VAL}" ] || fail "no username given"

progress 15 "Setting locale and keyboard..."
sed -i "s/#${LOCALE}/${LOCALE}/" /etc/locale.gen 2>/dev/null || true
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
locale-gen || fail "locale-gen failed"

progress 45 "Setting computer name..."
echo "${HOSTNAME_VAL}" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}/" /etc/hosts 2>/dev/null || true

progress 65 "Creating your account..."
useradd -m -G wheel,audio,video,input,network,storage,power,docker -s /bin/bash "${USERNAME_VAL}" \
  || fail "useradd failed"
echo "${USERNAME_VAL}:${PASSWORD_VAL}" | chpasswd || fail "chpasswd failed"

# Stash the plaintext password briefly, root-only, so first-login WinApps
# setup can reuse it as the Windows guest's login instead of a random
# string nobody's ever shown (see kibaos-winapps-setup, which reads this
# once via pkexec and deletes it right after). Mirrors what
# kiba_install_create_user() does for the disk-install path -- this is
# the OEM-finish equivalent of that same account-creation moment.
mkdir -p /etc/kibaos
umask 077
printf '%s' "${PASSWORD_VAL}" > /etc/kibaos/winapps-userpass
chmod 600 /etc/kibaos/winapps-userpass
umask 022

progress 85 "Cleaning up OEM account..."
# Remove the temporary OEM account created by kibaos-oem-prepare, if present.
userdel -r oem 2>/dev/null || true
rm -f /var/lib/AccountsService/users/oem 2>/dev/null || true
# GDM has no LightDM-style conf.d layering to just drop a higher-priority
# file from -- kibaos-oem-prepare stashed whatever custom.conf looked like
# before OEM mode (if anything) at custom.conf.pre-oem, so restore that;
# absent a stashed copy, just delete custom.conf outright so GDM falls
# back to its own default of no autologin and a normal login screen.
if [ -f /etc/gdm/custom.conf.pre-oem ]; then
  mv /etc/gdm/custom.conf.pre-oem /etc/gdm/custom.conf
else
  rm -f /etc/gdm/custom.conf 2>/dev/null || true
fi

progress 95 "Finishing up..."
mkdir -p /etc/kibaos
touch /etc/kibaos/winapps-pending
rm -f /etc/kibaos/oem-pending

progress 100 "Done"
exit 0
OEMFINISH
chmod +x /usr/local/bin/kibaos-oem-finish.sh

# ── kibaos-oem-prepare — run by WHOEVER images a device for OEM delivery
# (not run on a normal end-user install). Creates a temporary autologin
# "oem" account so the imaged device boots straight to a usable desktop
# for OEM-side burn-in/testing, and drops the marker file that makes
# io.kibaos.oobe launch in OEM-finish mode on first real customer boot.
# This mirrors the standard dont-chroot-style OEM-mode pattern from
# Calamares-based distros, just implemented as a small script
# instead of an installer config file, consistent with the rest of this
# from-scratch installer. ─────────────────────────────────────────────────
cat > /usr/local/bin/kibaos-oem-prepare << 'OEMPREPARE'
#!/usr/bin/env bash
set -e
mkdir -p /etc/kibaos
touch /etc/kibaos/oem-pending

id oem &>/dev/null || useradd -m -G wheel,audio,video,input,network,storage,power,docker -s /bin/bash oem
passwd -d oem 2>/dev/null || true

mkdir -p /etc/gdm
# Stash whatever custom.conf looked like before OEM mode (there may be
# none, if this device never had one) so kibaos-oem-finish can put it
# back once the temporary "oem" account is gone -- GDM's custom.conf is
# one flat file, not a conf.d directory to layer a drop-in on top of.
[ -f /etc/gdm/custom.conf ] && cp -f /etc/gdm/custom.conf /etc/gdm/custom.conf.pre-oem 2>/dev/null || true
cat > /etc/gdm/custom.conf << 'GDMOEMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=oem
WaylandEnable=true
GDMOEMCONF

mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/oem << 'OEMACCOUNTS'
[User]
Session=budgie-desktop
XSession=budgie-desktop
SystemAccount=false
OEMACCOUNTS

# OOBE app autostarts for the oem user too, in OEM-finish mode (the
# /etc/kibaos/oem-pending marker is what triggers that mode, not the
# username — the OOBE app itself doesn't know or care who's logged in).
echo "OEM mode prepared. This device will boot to a temporary 'oem' account"
echo "and prompt the customer to finish setup on next boot. Do not run this"
echo "on a normal end-user installation."
OEMPREPARE
chmod +x /usr/local/bin/kibaos-oem-prepare

# NOTE: both OOBE backends launch via `sudo` (covered by the liveuser
# NOPASSWD sudoers rule above), not `pkexec`, specifically so the installer
# doesn't depend on D-Bus/polkit being healthy mid-install. No polkit rule
# is needed here as a result.

if [ -x /usr/bin/io.kibaos.oobe ]; then
  echo "=== KibaOS OOBE installer is the active install path ==="
else
  echo "=== WARNING: KibaOS OOBE installer binary not found post-build ===" >&2
  exit 1
fi

userdel -r builduser 2>/dev/null || true
rm -f /etc/sudoers.d/builduser
# ══════════════════════════════════════════════════════════════════════════
# BOOT SPLASH — custom "kibaos" Plymouth theme (script-type plugin)
# ══════════════════════════════════════════════════════════════════════════
# Previously the Numix Plymouth theme, cloned + `make install`ed from
# upstream. Swapped out for a small hand-written script theme so the splash
# uses WolfTech's own branding image (BOOT_SPLASH, fetched above) instead of
# generic Numix art. `script` is a built-in Plymouth plugin, so this needs
# no clone/build step — just the theme dir, the .plymouth descriptor, the
# .script itself, and the image copied in.
KIBA_PLYMOUTH_DIR="/usr/share/plymouth/themes/kibaos"
mkdir -p "${KIBA_PLYMOUTH_DIR}"

if [ -f "${BOOT_SPLASH}" ]; then
  cp "${BOOT_SPLASH}" "${KIBA_PLYMOUTH_DIR}/splash.png"
else
  # Fallback so the theme never references a missing image if the fetch
  # above failed — reuse the existing 256px logo instead.
  cp /usr/share/kibaos/logo-256.png "${KIBA_PLYMOUTH_DIR}/splash.png" 2>/dev/null || true
fi

cat > "${KIBA_PLYMOUTH_DIR}/kibaos.plymouth" << 'PLYMOUTHDESC'
[Plymouth Theme]
Name=KibaOS
Description=KibaOS boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/kibaos
ScriptFile=/usr/share/plymouth/themes/kibaos/kibaos.script
PLYMOUTHDESC

cat > "${KIBA_PLYMOUTH_DIR}/kibaos.script" << 'PLYMOUTHSCRIPT'
// KibaOS boot splash — Plymouth script theme.
// Centered brand image on a dark background, with a small three-dot
// progress pulse underneath and a minimal password prompt for
// full-disk-encryption unlocks.

Window.SetBackgroundTopColor(0.043, 0.055, 0.078);
Window.SetBackgroundBottomColor(0.043, 0.055, 0.078);

logo.image = Image("splash.png");
logo.image = logo.image.Scale(logo.image.GetWidth() - 6, logo.image.GetHeight() - 6);
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth() / 2 - logo.image.GetWidth() / 2);
logo.sprite.SetY(Window.GetHeight() / 2 - logo.image.GetHeight() / 2);
logo.sprite.SetOpacity(1);

dot_count = 3;
dot_spacing = 26;
dots = [];
for (i = 0; i < dot_count; i++) {
  dots[i].image = Image.Text("•", 1, 1, 1, 1, "Sans 28");
  dots[i].sprite = Sprite(dots[i].image);
  dots[i].sprite.SetX(Window.GetWidth() / 2 - (dot_count * dot_spacing) / 2 + i * dot_spacing);
  dots[i].sprite.SetY(logo.sprite.GetY() + logo.image.GetHeight() + 36);
  dots[i].sprite.SetOpacity(0.25);
}

progress_tick = 0;
fun refresh_callback() {
  progress_tick++;
  active = Math.Int(progress_tick / 8) % dot_count;
  for (i = 0; i < dot_count; i++) {
    if (i == active)
      dots[i].sprite.SetOpacity(1);
    else
      dots[i].sprite.SetOpacity(0.25);
  }
}
Plymouth.SetRefreshFunction(refresh_callback);

fun display_password_callback(prompt, bullets) {
  if (prompt == "")
    prompt = "Enter your password to unlock the disk:";
  prompt_text.image = Image.Text(prompt, 1, 1, 1, 1);
  prompt_text.sprite = Sprite(prompt_text.image);
  prompt_text.sprite.SetX(Window.GetWidth() / 2 - prompt_text.image.GetWidth() / 2);
  prompt_text.sprite.SetY(dots[0].sprite.GetY() + 50);
}
Plymouth.SetDisplayPasswordFunction(display_password_callback);
PLYMOUTHSCRIPT

# Plymouth daemon config — must be written before mkinitcpio bakes it in
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf << 'PLYMOUTHD'
[Daemon]
Theme=kibaos
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD

# Set the theme now so it's in place before mkarchiso runs its own
# mkinitcpio pass over linux.preset (archiso_config=archiso.conf, set above
# with the plymouth/kms hooks already added).
#
# -R forces plymouth-set-default-theme to rebuild the initramfs itself
# right now, per ArchWiki: "every time a theme is changed, the initramfs
# must be rebuilt -- the -R option ensures that it is rebuilt".
#
# Non-fatal on failure -- the underlying causes that made this fail
# during development (missing MTD/dm_snapshot/DRM kernel config) are
# fixed now, and the belt-and-suspenders logo overwrite right below
# still gets the correct splash showing even if theme *selection* has a
# hiccup, so this doesn't need to hard-stop the whole build.
plymouth-set-default-theme -R kibaos 2>/dev/null || true
echo "=== Boot splash: custom kibaos Plymouth theme installed ==="

# Belt-and-suspenders: Arch's own `plymouth` package ships a pacman hook
# that runs `plymouth-set-default-theme -R bgrt` automatically on every
# install/upgrade of that package -- so if anything later in this script
# (an AUR build, a stray `pacman -S`) touches plymouth again, the theme
# selection above gets silently reset back to bgrt. Overwriting the
# actual shared logo assets Arch's built-in themes read from means the
# splash is still correctly branded even if theme *selection* ever
# regresses -- per ArchWiki, fade-in/script/solar/spinfinity all read
# from one shared file, and spinner/bgrt each read their own
# watermark.png.
cp "${KIBA_PLYMOUTH_DIR}/splash.png" /usr/share/plymouth/arch-logo.png
for _theme_dir in bgrt spinner; do
  if [ -d "/usr/share/plymouth/themes/${_theme_dir}" ]; then
    cp "${KIBA_PLYMOUTH_DIR}/splash.png" \
       "/usr/share/plymouth/themes/${_theme_dir}/watermark.png"
  fi
done

# ══════════════════════════════════════════════════════════════════════════
# ICON THEME — Numix Circle (github.com/numixproject/numix-icon-theme-circle)
# ══════════════════════════════════════════════════════════════════════════
# Unlike the Plymouth theme, this repo ships no Makefile/install script —
# just the two theme directories themselves (Numix-Circle and its lighter
# variant) — so installing it is a straight copy into /usr/share/icons.
# There's no official Arch package either (only an AUR git package that
# builds from this same repo); cloning directly is simpler and keeps this
# script free of AUR/makepkg dependency resolution.
#
# Note: Numix Circle is an APP icon theme only — its index.theme Inherits=
# chain falls back to the base Numix theme (and then Adwaita/hicolor) for
# places/devices/mimetypes/actions. We're not installing the base numix-
# icon-theme here since it wasn't asked for, so non-app icons will fall
# back to whatever adwaita-icon-theme/hicolor already provides. Say the
# word if you want the base theme installed too for full coverage.
NUMIX_ICONS_BUILD="/tmp/numix-icon-theme-circle"
rm -rf "${NUMIX_ICONS_BUILD}"
git clone --depth 1 https://github.com/numixproject/numix-icon-theme-circle.git "${NUMIX_ICONS_BUILD}"
cp -r "${NUMIX_ICONS_BUILD}/Numix-Circle" "${NUMIX_ICONS_BUILD}/Numix-Circle-Light" /usr/share/icons/
gtk-update-icon-cache -f /usr/share/icons/Numix-Circle 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/Numix-Circle-Light 2>/dev/null || true
rm -rf "${NUMIX_ICONS_BUILD}"
echo "=== Icon theme: Numix Circle installed ==="

# ══════════════════════════════════════════════════════════════════════════
# WINAPPS — vendor the repo into the image instead of curling it at
# first-run. Same reasoning as ditching archinstall for libkibadisk: don't
# make a fresh install's success depend on a network fetch of someone
# else's script at the exact moment a brand-new user is going through it.
# setup.sh from this same checkout gets run locally by
# kibaos-winapps-firstrun later (see near kibaos-first-login below), so the
# installed WinApps version is pinned to whatever was current at ISO build
# time, not whatever's on main the day someone installs KibaOS.
# ══════════════════════════════════════════════════════════════════════════
WINAPPS_SRC="/opt/kibaos/winapps-src"
rm -rf "${WINAPPS_SRC}"
mkdir -p "$(dirname "${WINAPPS_SRC}")"
git clone --depth 1 https://github.com/winapps-org/winapps.git "${WINAPPS_SRC}"
chmod +x "${WINAPPS_SRC}/setup.sh" "${WINAPPS_SRC}/bin/"* 2>/dev/null || true
echo "=== WinApps: vendored $(git -C "${WINAPPS_SRC}" rev-parse --short HEAD) ==="

# dockur/windows (the container image WinApps' compose.yaml runs) NATs its
# own tap network for the Windows guest and needs the netfilter NAT modules
# loaded on the host to do it -- per winapps-org/winapps docs/docker.md,
# without ip_tables/iptable_nat loaded, folder sharing (and the guest's
# network setup in general) breaks. Baking this in at build time so it's
# just working on first boot rather than a manual post-install step.
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/kibaos-winapps.conf << 'IPTABLESMODS'
ip_tables
iptable_nat
IPTABLESMODS
echo "=== WinApps: ip_tables/iptable_nat set to load at boot ==="

# ══════════════════════════════════════════════════════════════════════════

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# ══════════════════════════════════════════════════════════════════════════
# JUNCTION — app/link chooser (re.sonny.Junction), pops up on open so the
# user picks which installed app handles a given file/link instead of
# silently locking to one default. Installed system-wide (--system) at
# build time so it's present for every user account on first boot, not
# just whichever account happens to run flatpak first.
# ══════════════════════════════════════════════════════════════════════════
flatpak install --system --noninteractive flathub re.sonny.Junction
echo "=== Junction: installed via flatpak (re.sonny.Junction) ==="

# ══════════════════════════════════════════════════════════════════════════
# TASKBAR LAUNCHER ICON — replace the default Budgie Menu (start button) icon
# ══════════════════════════════════════════════════════════════════════════
# The Budgie Menu applet's default icon name is "start-here-symbolic"
# (solus-project/#457). Numix-Circle is an APP icon theme only
# (see note above) and doesn't cover the "places" category that icon lives
# in, so the lookup falls through to adwaita-icon-theme — which means the
# taskbar launcher button would otherwise show Adwaita's literal "GNOME
# foot" logo, a well-known rough edge (bbs.archlinux.org/viewtopic.php?
# id=209293) that has no place on a consumer OS.
#
# Uses the SAME source badge as the app-icon set and Plymouth splash (see
# BRANDING ASSETS above, LOGO_256) rather than a generated placeholder --
# the "start menu" button is the single most-clicked spot on the whole
# desktop, so it should be showing the actual KibaOS mark, not a generic
# stand-in shape. That crop is already a clean centered circular badge with
# no wordmark, which is exactly the composition a launcher icon needs.
ADWAITA_ICONS="/usr/share/icons/Adwaita"
LAUNCHER_MASTER="/tmp/kibaos-launcher-icon.png"
if [ -f "${LOGO_256}" ]; then
  cp "${LOGO_256}" "${LAUNCHER_MASTER}"
else
  # Defensive fallback only -- shouldn't trigger since BRANDING ASSETS
  # above always produces LOGO_256, even in its own "fetch failed" branch
  # (the drawn black-circle/white-'K' fallback). Kept so a future refactor
  # of that section can't silently turn this into a hard build failure.
  magick -size 512x512 xc:none \
    -fill black -draw "circle 256,256 256,16" \
    -stroke white -strokewidth 20 -fill none -draw "circle 256,256 256,60" \
    "${LAUNCHER_MASTER}"
fi

if [ -d "${ADWAITA_ICONS}" ]; then
  find "${ADWAITA_ICONS}" -path '*/places/start-here-symbolic.svg' -print0 2>/dev/null \
    | while IFS= read -r -d '' _svg; do
        _dir=$(dirname "${_svg}")
        _size=$(basename "$(dirname "${_dir}")")   # e.g. "48x48", or "scalable"
        _px="${_size%%x*}"
        case "${_px}" in
          ''|*[!0-9]*) _px=256 ;;   # "scalable" or anything unparsable -> high-res master
        esac
        magick "${LAUNCHER_MASTER}" -filter Lanczos -resize "${_px}x${_px}" \
          "${_dir}/start-here-symbolic.png"
        rm -f "${_svg}"
      done
  gtk-update-icon-cache -f "${ADWAITA_ICONS}" 2>/dev/null || true
fi
rm -f "${LAUNCHER_MASTER}"
echo "=== Taskbar launcher icon: KibaOS boot-logo badge installed ==="


# ══════════════════════════════════════════════════════════════════════════
# GTK THEME — system-wide Adwaita-dark base + KibaOS rounded-rectangle panel override
# ══════════════════════════════════════════════════════════════════════════
mkdir -p /usr/share/themes/KibaOS/gtk-3.0
mkdir -p /usr/share/themes/KibaOS/gtk-4.0

# Set up GTK 3.0 settings to use KibaOS theme
mkdir -p /etc/gtk-3.0
cat > /etc/gtk-3.0/settings.ini << 'GTK3RC'
[Settings]
gtk-theme-name=KibaOS
gtk-icon-theme-name=Numix-Circle
gtk-font-name=Noto Sans 11
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
GTK3RC

# QT THEME - Install KibaOS custom Qt theme
mkdir -p /usr/share/Kvantum/KibaOS/config
mkdir -p /usr/share/Kvantum/KibaOS/Translations
chmod -R 755 /usr/share/Kvantum/KibaOS

# Set default Kvantum theme
echo "[General]
Theme=KibaOS" > /etc/xdg/kvantum.kvconfig

# ── GTK3 rounded-rectangle panel CSS — KibaOS's own theming, applied directly ─
# This overrides just the Budgie panel to be a floating liquid glass rounded rectangle.
cat > /etc/gtk-3.0/gtk.css << 'GTK3PANEL'
/* ════════════════════════════════════════════════════════════════════════
 * KibaOS Organic Motion Language
 * Nothing alive moves with symmetric, linear timing — things settle into
 * rest faster than they drift away from it. These three curves (named for
 * documentation; GTK CSS has no custom-property/var() support, so the
 * literal cubic-bezier values are repeated at each use site below) encode
 * that asymmetry instead of using GTK's default flat "ease":
 *
 *   settle  cubic-bezier(0.22, 1, 0.36, 1)     — easeOutQuint. Entering a
 *           state (hover, focus, opening). Quick, confident, no bounce.
 *   fade    cubic-bezier(0.5, 0, 0.75, 0)       — easeInQuart. Leaving a
 *           state. Slightly slower than settle — things drift off, they
 *           don't snap off.
 *   spring  cubic-bezier(0.34, 1.56, 0.64, 1)   — easeOutBack. Reserved
 *           for ONE thing only: the physical switch knob, where a small
 *           positional overshoot reads as a twig springing back rather
 *           than a robotic snap. Used nowhere else — overusing overshoot
 *           reads as cartoonish rather than organic.
 *   grow    cubic-bezier(0.16, 1, 0.3, 1)       — easeOutExpo. Reserved
 *           for STRUCTURAL reveals (Raven and the Budgie Menu appearing/
 *           dismissing), never for small in-place state changes. A leaf
 *           unfurling and a light switching on are different kinds of
 *           motion even though both are "something turning on" — settle
 *           is the latter (a value flips, fast and certain), grow is the
 *           former (a whole shape is arriving, slightly unhurried at the
 *           start before resolving quickly). Kept distinct from settle
 *           so the two don't blur into a single generic "ease-ish" feel.
 *
 * Organic radius scale — every corner-radius below is a mild asymmetric
 * quad (top-left top-right bottom-right bottom-left) instead of one flat
 * number on all four corners. The spread is deliberately small (2-6px on
 * surfaces in the 16-28px range) so it reads as machined-but-grown at a
 * glance — closer to a river stone or a leaf edge than a die-cut card —
 * without tipping into the blobby/cartoonish territory a bigger spread
 * would. Applied only to the handful of surfaces that carry the brand
 * (panel, Raven, Budgie Menu, OSD, tooltips, context menus), not to every
 * button and row — restraint matters more than coverage here.
 *
 * Caveat: this only governs GTK widget-state transitions — it's NOT doing
 * compositor-level window drag physics. KWin does ship its own Wobbly
 * Windows effect, but it isn't enabled by default in this image (see the
 * KWIN CONFIG section for the whole story on that), so window dragging is
 * flat/rigid movement for now — nothing to verify here, it's just off
 * until/unless that effect gets turned on. Raven/the Budgie Menu's
 * open/close slide is still Budgie's own compiled animation code, not GTK
 * CSS — the opacity transitions below are best-effort and may be
 * superseded by that native motion. Verify visually.
 * ════════════════════════════════════════════════════════════════════════ */

/* === KibaOS: Floating rounded-rectangle panel === */
.budgie-panel {
    margin: 0 120px 8px 120px;
    /* Uniform 18px radius -- a clean rounded rectangle, not a full pill
     * (half of the 42px panel height is 21px, so 18px stays short of
     * that and keeps flat top/bottom edges between the corners). */
    border-radius: 18px;
    background-color: #ffffff;
    /* Dark text/icon color so content stays legible against the now-solid
     * white background -- the previous navy-glass version relied on the
     * system dark theme's light-on-dark defaults, which would render
     * invisible (white-on-white) once the background switched to white. */
    color: #1a2030;
    border: 1px solid rgba(0, 0, 0, 0.08);
    box-shadow:
        0 8px 40px rgba(0, 0, 0, 0.18),
        0 2px 8px  rgba(0, 0, 0, 0.10);
    padding: 0 10px;
}
.budgie-panel .budgie-applet-button,
.budgie-panel button.flat {
    border-radius: 14px;
    background: transparent;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0); /* fade out */
}
.budgie-panel .budgie-applet-button:hover,
.budgie-panel button.flat:hover {
    background-color: rgba(0, 0, 0, 0.06);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1); /* settle in */
}
.budgie-panel .budgie-applet-button:active,
.budgie-panel button.flat:active {
    background-color: rgba(0, 153, 204, 0.18);
    transition: background-color 90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.budgie-panel .launcher:checked,
.budgie-panel .launcher.running {
    border-bottom: 2px solid #0099cc;
    border-radius: 0;
    transition: border-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: Raven (notification + quick-settings sidebar) as a floating glass card === */
frame.raven-frame,
.raven-background {
    margin: 8px 8px 8px 0;
    border-radius: 20px 26px 24px 28px;
    background-image: radial-gradient(ellipse at 80% -20%,
        rgba(127, 174, 134, 0.05), transparent 60%);
    background-color: rgba(16, 24, 40, 0.72);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow:
        0 12px 48px rgba(0, 0, 0, 0.50),
        inset 0 1px 0 rgba(255, 255, 255, 0.10);
    opacity: 1;
    transition: opacity 280ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal, best-effort, see note above */
}
frame.raven-frame > border { border-style: none; box-shadow: none; }
.raven-header,
.raven-section-header {
    color: #e8eef5;
    font-weight: 600;
    padding: 14px 18px 6px 18px;
}
/* notification + applet rows rendered as individual cards */
.raven-background row,
.raven-background list row {
    margin: 5px 12px;
    padding: 10px 12px;
    border-radius: 14px;
    background-color: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.06);
    transition: background-color 240ms cubic-bezier(0.5, 0, 0.75, 0);
}
.raven-background row:hover {
    background-color: rgba(255, 255, 255, 0.10);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1);
}
/* quick-toggle pills: wifi / bluetooth / focus / airplane mode, etc. */
.raven-background button.toggle,
.raven-background .quick-toggle {
    border-radius: 16px;
    background-color: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    padding: 10px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    220ms cubic-bezier(0.5, 0, 0.75, 0);
}
.raven-background button.toggle:checked,
.raven-background .quick-toggle:checked {
    background-color: rgba(0, 153, 204, 0.35);
    border-color: rgba(0, 153, 204, 0.6);
    transition: background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    160ms cubic-bezier(0.22, 1, 0.36, 1);
}
/* volume / brightness sliders as rounded pill tracks */
.raven-background scale trough {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.10);
    min-height: 6px;
}
.raven-background scale highlight {
    border-radius: 999px;
    background-color: #0099cc;
    transition: background-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}
.raven-background scale slider {
    background-color: #ffffff;
    border-radius: 999px;
    min-width: 14px;
    min-height: 14px;
}

/* === KibaOS: Budgie Menu (app launcher popover) as a floating glass card === */
popover.budgie-menu,
.budgie-menu-window {
    border-radius: 22px 28px 20px 26px;
    background-image: radial-gradient(ellipse at 20% -30%,
        rgba(127, 174, 134, 0.05), transparent 60%);
    background-color: rgba(16, 24, 40, 0.80);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow: 0 12px 48px rgba(0, 0, 0, 0.50);
    transition: opacity 260ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal, best-effort, see note above */
}
.budgie-menu-window entry,
popover.budgie-menu entry {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.10);
    padding: 8px 16px;
    color: #e8eef5;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    200ms cubic-bezier(0.5, 0, 0.75, 0);
}
.budgie-menu-window entry:focus,
popover.budgie-menu entry:focus {
    background-color: rgba(255, 255, 255, 0.12);
    border-color: rgba(0, 153, 204, 0.6);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    140ms cubic-bezier(0.22, 1, 0.36, 1);
}
button.budgie-menu-launcher {
    border-radius: 14px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0);
}
button.budgie-menu-launcher:hover {
    background-color: rgba(0, 153, 204, 0.20);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: GTK places sidebar (Nemo + GTK open/save dialogs) glass card === */
placessidebar {
    background-color: transparent;
    border-radius: 18px;
}
placessidebar row {
    border-radius: 12px;
    margin: 2px 6px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0);
}
placessidebar row:selected {
    background-color: rgba(0, 153, 204, 0.25);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: switches everywhere (budgie-control-center, GTK apps) ========
 * The one and only spot using the "spring" overshoot curve — the knob
 * physically travels, so a little organic overshoot is visible motion,
 * not just a colour flicker. */
switch slider {
    transition: margin 260ms cubic-bezier(0.34, 1.56, 0.64, 1);
}
switch:checked {
    background-color: rgba(0, 153, 204, 0.85);
    transition: background-color 220ms cubic-bezier(0.22, 1, 0.36, 1);
}
switch {
    transition: background-color 240ms cubic-bezier(0.5, 0, 0.75, 0);
}

/* ════════════════════════════════════════════════════════════════════════
 * KibaOS extra polish pass — the small stuff that adds up
 * ════════════════════════════════════════════════════════════════════════ */

/* Crisp, on-brand focus rings instead of GTK's default dotted/heavy outline —
 * keyboard navigation should always be obvious, never ugly. */
*:focus-visible {
    outline: 2px solid rgba(0, 153, 204, 0.75);
    outline-offset: 1px;
    transition: outline-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Tooltips as small glass cards, matching Raven/the menu popover language
 * instead of GTK's flat dark rectangle. */
tooltip {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px 12px 9px 11px;
    padding: 6px 10px;
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
}
tooltip decoration { background: transparent; box-shadow: none; }

/* Thin, rounded, low-profile scrollbars — always present but never loud. */
scrollbar {
    background-color: transparent;
}
scrollbar slider {
    background-color: rgba(255, 255, 255, 0.18);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.32);
    transition: background-color 130ms cubic-bezier(0.22, 1, 0.36, 1);
}
scrollbar slider:active {
    background-color: rgba(0, 153, 204, 0.65);
}

/* Selected text uses the accent colour, not GTK's default blue. */
selection, *:selected {
    background-color: rgba(0, 153, 204, 0.55);
    color: #ffffff;
}

/* Checkboxes/radios: rounded box, accent fill when checked, same settle/fade
 * pair as everything else — these were the one obviously-untouched stock
 * GTK widget left standing next to switches/sliders that already got it. */
checkbutton check,
radiobutton radio {
    border-radius: 5px;
    border: 1px solid rgba(255, 255, 255, 0.28);
    background-color: rgba(255, 255, 255, 0.06);
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    200ms cubic-bezier(0.5, 0, 0.75, 0);
}
radiobutton radio { border-radius: 999px; }
checkbutton check:checked,
radiobutton radio:checked {
    background-color: #0099cc;
    border-color: #0099cc;
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Progress bars: rounded pill track matching the volume/brightness sliders
 * in Raven, instead of GTK's square-edged default. */
progressbar trough {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.10);
    min-height: 6px;
}
progressbar progress {
    border-radius: 999px;
    background-color: #0099cc;
    transition: background-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Right-click / app context menus as the same floating glass card as
 * Raven and the Budgie Menu, instead of a flat GTK menu rectangle. */
menu,
popover.menu > contents {
    background-color: rgba(20, 26, 40, 0.92);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 10px 14px 11px 13px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    padding: 4px;
}
menuitem,
modelbutton {
    border-radius: 8px;
    padding: 6px 10px;
    transition: background-color 180ms cubic-bezier(0.5, 0, 0.75, 0);
}
menuitem:hover,
modelbutton:hover {
    background-color: rgba(255, 255, 255, 0.10);
    transition: background-color 120ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* The volume/brightness/etc. on-screen bezel (.osd) as a small floating
 * glass pill, matching everything else instead of GTK's plain dark box. */
.osd {
    background-color: rgba(16, 24, 40, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 24px 20px 22px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.50);
}

/* Unfocused windows recede slightly — a small depth cue that makes the
 * focused window unambiguous at a glance, especially with several floating
 * glass panels/popovers on screen at once. */
window:backdrop {
    opacity: 0.96;
    transition: opacity 300ms cubic-bezier(0.5, 0, 0.75, 0);
}
window:not(:backdrop) {
    transition: opacity 180ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Linked button groups (segmented controls) read as one pill-shaped
 * control instead of GTK's default row of square-joined buttons. */
.linked > button {
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
.linked > button:first-child { border-radius: 10px 0 0 10px; }
.linked > button:last-child  { border-radius: 0 10px 10px 0; }
GTK3PANEL

# ── GTK4 CSS OVERRIDE ─────────────────────────────────────────────────────
mkdir -p /etc/gtk-4.0
cat > /etc/gtk-4.0/gtk.css << 'GTK4CSS'
/* KibaOS unified GTK4 override */
@define-color accent_color #0099cc;
@define-color accent_bg_color #0099cc;
@define-color accent_fg_color #ffffff;
@define-color window_bg_color #1e2430;
@define-color window_fg_color #e8eef5;
@define-color view_bg_color #252c3a;
@define-color view_fg_color #dde5ef;
@define-color card_bg_color #2a3242;
@define-color popover_bg_color #2a3242;
@define-color sidebar_bg_color #1a2030;
@define-color headerbar_bg_color #1a2030;
@define-color headerbar_fg_color #dde5ef;

window, .window-frame          { border-radius: 16px 20px 18px 22px; }
headerbar                      { border-radius: 18px 22px 0 0; }
.card, frame, .frame           { border-radius: 13px 16px 14px 17px; }
button                         { border-radius: 10px; }
entry                          { border-radius: 10px; }
popover > contents             { border-radius: 14px 18px 13px 17px; }
.sidebar-row                   { border-radius: 8px; }
listview                       { border-radius: 12px; }
notebook > header              { border-radius: 12px 12px 0 0; }
button { box-shadow: none; -gtk-icon-shadow: none; }
.suggested-action { background: @accent_bg_color; color: @accent_fg_color; border: none; }
.suggested-action:hover { background: shade(@accent_bg_color, 0.88); }
headerbar { padding: 8px 12px; min-height: 44px; }
row        { padding: 4px 8px; }
/* Same faint moss-green (#7fae86) bloom as the GTK3 panel — the one
 * deliberate nature accent, kept identical across GTK3/GTK4 so a mixed
 * Budgie+libadwaita desktop still reads as one coherent surface. */
window {
    background-image: radial-gradient(ellipse at 30% -30%,
        rgba(127, 174, 134, 0.04), transparent 65%);
}

/* KibaOS organic motion — same settle/fade/grow set as GTK3 (see
 * gtk-3.0/gtk.css for the full naming/rationale); GTK4 apps get the same
 * asymmetric feel. */
button, row, .sidebar-row, switch slider {
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    220ms cubic-bezier(0.5, 0, 0.75, 0);
}
button:hover, row:hover, .sidebar-row:hover {
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    140ms cubic-bezier(0.22, 1, 0.36, 1);
}
switch slider { transition: margin 260ms cubic-bezier(0.34, 1.56, 0.64, 1); }
popover > contents {
    transition: opacity 260ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal */
}

/* Same extra polish pass as gtk-3.0/gtk.css (see that file for the full
 * rationale on each rule) — GTK4/libadwaita apps get the same treatment
 * as Budgie's own chrome instead of looking like a different OS. */
*:focus-visible {
    outline: 2px solid rgba(0, 153, 204, 0.75);
    outline-offset: 1px;
    transition: outline-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}
tooltip {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px 12px 9px 11px;
    padding: 6px 10px;
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
}
scrollbar slider {
    background-color: rgba(255, 255, 255, 0.18);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.32);
    transition: background-color 130ms cubic-bezier(0.22, 1, 0.36, 1);
}
selection, *:selected {
    background-color: rgba(0, 153, 204, 0.55);
    color: #ffffff;
}
checkbutton check,
radiobutton radio {
    border-radius: 5px;
    border: 1px solid rgba(255, 255, 255, 0.28);
    background-color: rgba(255, 255, 255, 0.06);
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
radiobutton radio { border-radius: 999px; }
checkbutton check:checked,
radiobutton radio:checked {
    background-color: #0099cc;
    border-color: #0099cc;
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}
.osd {
    background-color: rgba(16, 24, 40, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 24px 20px 22px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.50);
}
window:backdrop {
    opacity: 0.96;
    transition: opacity 300ms cubic-bezier(0.5, 0, 0.75, 0);
}

/* libadwaita toasts (AdwToast — the little "Undo" bar that slides up from
 * the bottom) as the same floating glass pill as everything else. */
.toast {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 999px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    padding: 4px 6px;
}
.toast button {
    border-radius: 999px;
}
GTK4CSS

# ── Disable Budgie's "built-in theme" so the KibaOS GTK CSS above actually ──
# ── renders on the panel / Raven / menu instead of being overridden by it ──
# Schema id corrected to the verified-real "com.solus-project.budgie-panel"
# (hyphenated — see the panel config block below for the source citation).
# The key itself ("enable-built-in-theme") is NOT in the confirmed manager.vala
# const dump, so it may live on a different schema (e.g. ThemeManager) or
# under a different name — unknown gschema-override keys are silently
# ignored rather than harmful, so this is left in as a no-risk best effort.
mkdir -p /usr/share/glib-2.0/schemas
cat > /usr/share/glib-2.0/schemas/zz-kibaos-budgie.gschema.override << 'BUDGIEOVERRIDE'
[com.solus-project.budgie-panel]
enable-built-in-theme=false
BUDGIEOVERRIDE
glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# GDM — branded greeter (replaces LightDM)
# ══════════════════════════════════════════════════════════════════════════
# GDM has neither LightDM-gtk-greeter's plain "background=" key nor
# SDDM's QML theming API (see the dead code below, kept for reference) --
# its login screen is just GNOME Shell running in greeter mode, themed
# through the "gdm" dconf system db instead of a greeter-specific config
# file. /etc/dconf/profile/gdm is what tells dconf that the "gdm" system
# user should read the "gdm" db at all (stock gdm ships a profile
# pointing at file-db /usr/share/gdm/greeter-dconf-defaults, which is
# read-only from this package's own defaults -- system-db here layers
# /etc/dconf/db/gdm.d/* on top of that instead of touching the read-only
# file-db). background reuses org.gnome.desktop.background, same key
# the desktop session itself uses; logo is picked up by GDM natively
# through org.gnome.login-screen -- unlike lightdm-gtk-greeter, there
# IS a real logo slot here, so the KibaOS mark actually shows on the
# greeter now instead of being dropped like it was under LightDM.
mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d
cat > /etc/dconf/profile/gdm << 'GDMPROFILE'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
GDMPROFILE

cp /usr/share/kibaos/wallpaper.jpg /usr/share/kibaos/gdm-background.jpg 2>/dev/null || true
cat > /etc/dconf/db/gdm.d/01-kibaos << 'GDMDCONF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/kibaos/gdm-background.jpg'
picture-uri-dark='file:///usr/share/kibaos/gdm-background.jpg'
picture-options='zoom'

[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/login-screen]
logo='/usr/share/kibaos/logo-256.png'
disable-user-list=false
GDMDCONF
dconf update

# ── dead code: the old SDDM frosted-glass QML greeter ───────────────────
# Left in place (unreferenced -- nothing installs sddm anymore, and
# nothing points sddm.conf.d/Theme at "kibaos") purely as a reference
# for a future lightdm-webkit2-greeter port; the QML itself has no
# runtime target under LightDM.
: << 'DEAD_SDDM_THEME_BLOCK'
SDDM_THEME_DIR="/usr/share/sddm/themes/kibaos"
mkdir -p "${SDDM_THEME_DIR}"
cp /usr/share/kibaos/wallpaper.jpg  "${SDDM_THEME_DIR}/background.png"  2>/dev/null || true
cp /usr/share/kibaos/logo-256.png   "${SDDM_THEME_DIR}/logo.png"        2>/dev/null || true

cat > "${SDDM_THEME_DIR}/metadata.desktop" << 'SDDMMETA'
[SddmGreeterTheme]
Name=KibaOS
Description=KibaOS frosted-glass greeter
Author=WolfTech Innovations
Copyright=2026, WolfTech Innovations
License=GPLv3
Type=sddm-theme
Version=1.0
Website=https://github.com/WolfTech-Innovations/Kiba
MainScript=Main.qml
Font=Noto Sans
QuickVersion=6
SDDMMETA

cat > "${SDDM_THEME_DIR}/Main.qml" << 'SDDMQML'
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Single shared greeter for both the desktop ISO and KibaOS Mobile --
// this exact file is written byte-for-byte into both images (see the
// mobile copy inside build_kibaos_mobile(), which carries a comment
// pointing back here -- keep the two in sync by hand, they can't
// literally share a bash variable since they run inside two different
// execution contexts: this one at ISO customize time inside a chroot,
// the mobile one directly against the target root while build.sh itself
// runs). Rather than branching into two separate QML files, the layout
// adapts itself at runtime off Screen.width, so a genuinely single
// theme covers a 1920x1080 desktop panel and a ~1080x2400 phone panel
// without drifting out of sync on brand/behavior over time.
Rectangle {
    id: root
    width: Screen.width  > 0 ? Screen.width  : 1920
    height: Screen.height > 0 ? Screen.height : 1080
    color: "#0d1b2a"
    focus: true

    // phoc's own config scales the DSI panel output 2x at the Wayland
    // protocol level (see phoc.ini's [output:DSI-1] scale=2) -- Qt's
    // Wayland QPA backend reads that wl_output scale itself and already
    // renders this file's logical pixels at the right physical density,
    // so nothing extra is needed here for HiDPI; this width/height check
    // is purely about aspect ratio/orientation, not pixel density.
    readonly property bool isPhone: width < 700
    readonly property int touchH: isPhone ? 56 : 44
    readonly property int fieldR: isPhone ? 18 : 14

    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    // ── Background wallpaper, darkened so the glass card pops ──────────────
    Image {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Rectangle {
        anchors.fill: parent
        color: "#0d1b2a"
        opacity: 0.42
    }

    // ── Clock ────────────────────────────────────────────────────────────
    // Desktop: small pill, top-right, matches the KibaOS panel style.
    // Phone: big lockscreen-style clock, top-center, clear of any status
    // bar / camera-cutout safe area -- Android/iOS lockscreen convention,
    // and it doubles as a landmark while your thumb finds the card below.
    Column {
        id: clockCol
        anchors {
            top: parent.top
            topMargin: isPhone ? 64 : 28
        }
        anchors.horizontalCenter: isPhone ? parent.horizontalCenter : undefined
        anchors.right: isPhone ? undefined : parent.right
        anchors.rightMargin: isPhone ? 0 : 28
        spacing: isPhone ? 4 : 0
        Text {
            id: clockTime
            text: Qt.formatTime(new Date(), "h:mm AP")
            color: "#ffffff"
            font.pixelSize: isPhone ? 56 : 18
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: Qt.formatDate(new Date(), "ddd, MMM d")
            color: "#aebccd"
            font.pixelSize: isPhone ? 16 : 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Timer { interval: 1000; running: true; repeat: true; onTriggered: clockTime.text = Qt.formatTime(new Date(), "h:mm AP") }
    }

    // ── Central frosted-glass login card ────────────────────────────────────
    // Desktop: fixed 360px, dead-centered, unchanged from before.
    // Phone: full-width (minus margins), anchored in the lower half
    // rather than dead-center -- that's within comfortable one-handed
    // thumb reach, and critically it leaves the *upper* half of the
    // screen clear for squeekboard to pop up underneath without ever
    // covering the password field it's currently focused on.
    Rectangle {
        id: card
        anchors {
            horizontalCenter: isPhone ? parent.horizontalCenter : undefined
            centerIn: isPhone ? undefined : parent
            bottom: isPhone ? parent.bottom : undefined
            bottomMargin: isPhone ? 96 : 0
        }
        width: isPhone ? parent.width - 48 : 360
        height: cardCol.implicitHeight + (isPhone ? 40 : 56)
        radius: isPhone ? 32 : 26
        color: "#101828"
        opacity: 0.001
        // emulated glass: just a solid translucent fill, no real blur.
        // KWin's own Blur effect is real and available in the actual
        // session, but the SDDM greeter renders on its own standalone
        // Qt Quick surface before any session (or its compositor) is
        // even running — see KWIN CONFIG notes for the full story on
        // why this greeter can't just borrow it — so this fake-glass
        // approach is doing all the work here now, not just backstopping
        // a spot where real blur wouldn't reach anyway.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(0.063, 0.094, 0.157, 0.72)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }

        ColumnLayout {
            id: cardCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: isPhone ? 24 : 28 }
            spacing: isPhone ? 16 : 14

            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "logo.png"
                width: isPhone ? 56 : 64; height: isPhone ? 56 : 64
                fillMode: Image.PreserveAspectFit
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: userModel.count > 0 ? userModel.data(userModel.index(userList.currentIndex, 0), 257) : "User"
                color: "#e8eef5"; font.pixelSize: isPhone ? 19 : 17; font.weight: Font.Medium
            }

            ListView {
                id: userList
                Layout.fillWidth: true
                height: 0; visible: false  // names shown via combo below instead
                model: userModel
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
            }

            ComboBox {
                id: userBox
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                model: userModel
                textRole: "name"
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
                font.pixelSize: isPhone ? 16 : 13
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                contentItem: Text { text: userBox.displayText; color: "#e8eef5"; font: userBox.font; padding: 10; verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: passwordField
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                placeholderText: "Password"
                echoMode: TextInput.Password
                color: "#e8eef5"
                font.pixelSize: isPhone ? 16 : 13
                placeholderTextColor: "#8a99ad"
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                onAccepted: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                Keys.onReturnPressed: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
            }

            Button {
                id: loginButton
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                text: "Sign In"
                onClicked: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                background: Rectangle { radius: fieldR; color: "#0099cc" }
                contentItem: Text { text: loginButton.text; color: "#ffffff"; font.pixelSize: isPhone ? 16 : 13; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
            }

            // Session picker: only worth showing where there's actually
            // more than one to pick from. Desktop offers Budgie/etc
            // session choices; the phone image ships exactly one
            // (kibaos-mobile, Exec=phoc) so this is dead weight there --
            // one less thing to accidentally fat-finger on a small card.
            ComboBox {
                Layout.fillWidth: true
                Layout.preferredHeight: isPhone ? 0 : undefined
                visible: !isPhone
                model: sessionModel
                textRole: "name"
                currentIndex: root.sessionIndex
                onActivated: root.sessionIndex = currentIndex
                background: Rectangle { radius: fieldR; color: "transparent" }
                contentItem: Text { text: parent.displayText; color: "#aebccd"; font.pixelSize: 11; padding: 6; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    // ── Power row ────────────────────────────────────────────────────────
    // Desktop: small 44px pills, bottom-right, unchanged.
    // Phone: bigger 56px targets (comfortable thumb-tap size), moved to
    // top-right instead -- bottom-right on a phone sits right where the
    // login card's bottom edge and any on-screen-keyboard region already
    // are, so it's both more reachable and less likely to be covered.
    Row {
        anchors {
            top: isPhone ? parent.top : undefined
            bottom: isPhone ? undefined : parent.bottom
            right: parent.right
            margins: isPhone ? 24 : 28
        }
        spacing: isPhone ? 14 : 10
        Repeater {
            model: [
                { label: "⏻", visible: sddm.canPowerOff, action: function(){ sddm.powerOff() } },
                { label: "⟲", visible: sddm.canReboot,   action: function(){ sddm.reboot()   } }
            ]
            delegate: Rectangle {
                visible: modelData.visible
                width: touchH; height: touchH; radius: fieldR
                color: "#1c2433"; opacity: 0.78
                Text { anchors.centerIn: parent; text: modelData.label; color: "#e8eef5"; font.pixelSize: isPhone ? 22 : 18 }
                MouseArea { anchors.fill: parent; onClicked: modelData.action() }
            }
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() { passwordField.text = ""; passwordField.placeholderText = "Incorrect password"; }
    }

    Component.onCompleted: passwordField.forceActiveFocus()
}
SDDMQML
DEAD_SDDM_THEME_BLOCK

# ── Wayland session — budgie-desktop-kwinwayland.desktop ────────────────
# budgie-desktop's OWN packaged session file (budgie-desktop.desktop)
# launches labwc -- that's not something a package swap in the pacman
# list can change, since it's baked into the .desktop upstream ships,
# not anything this script writes. Budgie has no supported KWin session
# of its own (their FAQ: KWin is a maybe-someday Budgie 11 item, not
# something 10.10 -- what this image installs -- actually has); the
# only KWin session that exists at all is this one, straight from
# Buddies of Budgie's own (explicitly UNSUPPORTED/experimental,
# "no assistance" per that repo's own README) budgie-wayland-session
# testing repo, verbatim:
#   https://github.com/BuddiesOfBudgie/budgie-wayland-session
#   desktop/budgie-desktop-kwinwayland.desktop
# --exit-with-session is KWin's equivalent of labwc's "-s": start the
# compositor, run this command as the session, exit when it exits.
# Caveat worth knowing: Budgie's gsettings→labwc "bridge" (keyboard
# shortcuts, touchpad, theming sync from Budgie Control Center) has no
# KWin counterpart, so none of that syncs here -- KWin's own config
# has to be set directly instead. See KWIN CONFIG note near the
# top-panel CSS.
mkdir -p /usr/share/wayland-sessions
rm -rf /usr/share/wayland-sessions/budgie-desktop.desktop
cat > /usr/share/wayland-sessions/budgie-desktop.desktop << 'WFSESSION'
[Desktop Entry]
Name=Budgie Desktop on labwc
Comment=This session logs you into the Budgie Desktop
Exec=/usr/bin/labwc --session=/usr/bin/budgie-desktop
Icon=
Type=Application
DesktopNames=Budgie;GNOME
WFSESSION

# labwc IS still installed -- it's a hard `depends=()` of the
# budgie-desktop Arch package itself (confirmed straight from the
# package's own PKGBUILD/dependency list), not something `packages.x86_64`
# not listing it explicitly can prevent pacman from pulling in. It just
# never gets LAUNCHED anymore, since GDM now execs the KWin session
# above instead of budgie-desktop.desktop -- and since nothing ever
# starts the labwc binary, nothing ever parses rc.xml or throws the
# "Invalid action... 'command'" labnag popup from the screenshots
# (that error is labwc's OWN startup log format complaining about its
# own config -- it can only appear if labwc itself is the thing that
# ran).
#
# What budgie-desktop ALSO ships, though, is an autostart entry
# (/etc/xdg/autostart/org.buddiesofbudgie.labwc-bridge.desktop) that
# unconditionally runs usr/lib/budgie-desktop/labwc_bridge.py at every
# login regardless of which compositor is actually active -- it's what
# was regenerating rc.xml (with the "command" vs "Execute" action-name
# bug) fresh on every single login, which is why deleting the file
# alone never stuck. Harmless with labwc never running (nothing reads
# what it writes anymore), but pointless busywork every login, so mask
# it the standard per-user XDG way: a same-filename override in skel's
# own autostart dir with Hidden=true, which takes priority over the
# system-wide copy in /etc/xdg/autostart/ for every new account.
SKEL="/etc/skel"
mkdir -p "${SKEL}/.config/autostart"
cat > "${SKEL}/.config/autostart/org.buddiesofbudgie.labwc-bridge.desktop" << 'NOLABWCBRIDGE'
[Desktop Entry]
Type=Application
Name=Budgie labwc bridge (disabled — KibaOS runs labwc, not labwc)
Exec=/bin/true
Hidden=true
NOLABWCBRIDGE
rm -rf "${SKEL}/.config/budgie-desktop/labwc" 2>/dev/null || true

mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf << 'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=liveuser
WaylandEnable=true
GDMCONF
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/liveuser << 'LIVEUSERACCOUNTS'
[User]
Session=budgie-desktop
XSession=budgie-desktop
SystemAccount=false
LIVEUSERACCOUNTS
mkdir -p /var/lib/gdm /var/log/gdm
chown gdm:gdm /var/lib/gdm /var/log/gdm 2>/dev/null || true
chmod 750 /var/lib/gdm
cat > /usr/local/bin/kibaos-screenshot << 'SCREENSHOT'
#!/bin/bash
# kibaos-screenshot [region] — grabs the full screen by default, or a
# user-selected region if "region" is passed as the first argument.
set -euo pipefail
OUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/Screenshot from $(date '+%Y-%m-%d %H-%M-%S').png"

if [ "${1:-}" = "region" ]; then
  GEOM=$(slurp) || exit 0   # empty selection (Esc) -> exit quietly
  grim -g "$GEOM" "$FILE"
else
  grim "$FILE"
fi

wl-copy < "$FILE"
notify-send -i "$FILE" "Screenshot saved" "Copied to clipboard · $(basename "$FILE")"
SCREENSHOT
chmod +x /usr/local/bin/kibaos-screenshot
cat > /usr/local/bin/kibaos-screenshot-ocr << 'SCREENSHOTOCR'
#!/bin/bash
# kibaos-screenshot-ocr — select a region, extract its text with Tesseract,
# and put the text (not the image) on the clipboard.
set -euo pipefail
GEOM=$(slurp) || exit 0
TMP=$(mktemp --suffix=.png -t kibaos-ocr.XXXXXX)
trap 'rm -f "$TMP"' EXIT
grim -g "$GEOM" "$TMP"

TEXT=$(tesseract "$TMP" - 2>/dev/null | sed -e '$ { /^$/d }')
if [ -z "$TEXT" ]; then
  notify-send "Screenshot OCR" "No text found in that selection."
  exit 0
fi

printf '%s' "$TEXT" | wl-copy
PREVIEW=$(printf '%s' "$TEXT" | head -c 120)
notify-send "Text copied to clipboard" "${PREVIEW}$([ ${#TEXT} -gt 120 ] && echo …)"
SCREENSHOTOCR
chmod +x /usr/local/bin/kibaos-screenshot-ocr
cat > /usr/local/bin/kibaos-apply-output-scale << 'OUTPUTSCALE'
#!/bin/bash
# Give the compositor a moment to enumerate outputs on cold start.
for _ in 1 2 3 4 5; do
    wlr-randr >/tmp/.kiba-outputs 2>/dev/null && [ -s /tmp/.kiba-outputs ] && break
    sleep 1
done
[ -s /tmp/.kiba-outputs ] || exit 0

current_name=""
current_w=""
current_h=""
current_mm_w=""
current_mm_h=""

apply_scale() {
    [ -n "$current_name" ] || return
    scale=1
    if [ -n "$current_mm_w" ] && [ "$current_mm_w" -gt 0 ] 2>/dev/null; then
        # DPI = px / (mm / 25.4); compare against a 168dpi HiDPI threshold.
        dpi=$(( current_w * 254 / (current_mm_w * 10) ))
        if [ "$dpi" -ge 168 ]; then
            scale=2
        fi
    elif [ -n "$current_w" ] && [ "$current_w" -ge 3000 ] 2>/dev/null; then
        # No physical size reported (VM, some externals) -- fall back to a
        # plain resolution heuristic. 4K+ panels are HiDPI in practice.
        scale=2
    fi
    wlr-randr --output "$current_name" --scale "$scale" >/dev/null 2>&1
}

while IFS= read -r line; do
    case "$line" in
        [A-Za-z]*)
            apply_scale
            current_name=$(printf '%s' "$line" | awk '{print $1}')
            current_w=""; current_h=""; current_mm_w=""; current_mm_h=""
            ;;
        *"Physical size:"*)
            # e.g. "  Physical size: 344x194 mm"
            dims=$(printf '%s' "$line" | grep -oE '[0-9]+x[0-9]+')
            current_mm_w=${dims%x*}
            current_mm_h=${dims#*x}
            ;;
        *"current"*)
            # e.g. "  1920x1080 px, 60.000000 Hz (current)"
            dims=$(printf '%s' "$line" | grep -oE '^[[:space:]]*[0-9]+x[0-9]+' | tr -d ' ')
            current_w=${dims%x*}
            current_h=${dims#*x}
            ;;
    esac
done < /tmp/.kiba-outputs
apply_scale
rm -f /tmp/.kiba-outputs
OUTPUTSCALE
chmod +x /usr/local/bin/kibaos-apply-output-scale
OTA_PUBKEY_URL="https://raw.githubusercontent.com/WolfTech-Innovations/Kiba/main/ota/ota-public.asc"
OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
mkdir -p /etc/kibaos /var/lib/kibaos-ota /var/log/kibaos

# ── Import OTA public key into dedicated keyring ───────────────────────────
curl -fsSL --retry 3 "${OTA_PUBKEY_URL}" -o /tmp/ota-public.asc 2>/dev/null && \
  gpg --no-default-keyring --keyring "${OTA_KEYRING}" \
      --import /tmp/ota-public.asc 2>/dev/null || true
rm -f /tmp/ota-public.asc

# ── Patch-level tracking ───────────────────────────────────────────────────
echo "0" > /etc/kibaos/patch-level

# ══════════════════════════════════════════════════════════════════════════
# /usr/local/bin/kibaos-ota — the live patching engine
# ══════════════════════════════════════════════════════════════════════════
cat > /usr/local/bin/kibaos-ota << 'OTASCRIPT'
#!/usr/bin/env bash
# KibaOS OTA Live Patch Engine
# Silently downloads, verifies, and applies file-level patches.
# Handles display manager restarts with a framebuffer freeze trick.
# Runs as root via systemd timer — never visible to the user. Also
# callable directly as `kibaos-ota rollback --reason "..."` (see the
# CLI ROLLBACK section below) to undo the most recent patch.

set -euo pipefail

OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
PATCH_LEVEL_FILE="/etc/kibaos/patch-level"
OTA_WORKDIR="/var/lib/kibaos-ota"
OTA_LOG="/var/log/kibaos/ota.log"
FREEZE_PID_FILE="/tmp/kibaos-fb-freeze.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${OTA_LOG}"; }

# ══════════════════════════════════════════════════════════════════════════
# FRAMEBUFFER FREEZE — makes display restarts invisible to the user
# ══════════════════════════════════════════════════════════════════════════
fb_freeze() {
  log "Freezing display with framebuffer snapshot..."
  # Capture current screen with grim (Wayland screenshot)
  SNAP="/tmp/kibaos-ota-snap.png"
  SNAP_RAW="/tmp/kibaos-ota-snap.raw"
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  XDG_RUNTIME_DIR="/run/user/1000"

  # Take screenshot as liveuser. (This script runs at real boot time on the
  # installed system, not inside the nosuid build chroot, so sudo would
  # actually work here — using runuser anyway for consistency, since this
  # script is also always invoked as root and runuser is the more direct
  # tool for "run as a different user" with no escalation step needed.)
  runuser -u liveuser -- env \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    grim "${SNAP}" 2>/dev/null || true

  if [ -f "${SNAP}" ]; then
    # Convert to raw framebuffer format and write to /dev/fb0
    FB_WIDTH=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d',' -f1 || echo 1920)
    FB_HEIGHT=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d',' -f2 || echo 1080)
    magick "${SNAP}" -resize "${FB_WIDTH}x${FB_HEIGHT}!" \
      -depth 8 bgr:"${SNAP_RAW}" 2>/dev/null || true
    if [ -f "${SNAP_RAW}" ] && [ -w /dev/fb0 ]; then
      cat "${SNAP_RAW}" > /dev/fb0 2>/dev/null || true
    fi
  fi

  # Emulate mouse movement via uinput to keep cursor alive
  python3 - << 'UINPUT_WIGGLE'
import struct, time, os, fcntl

EV_REL, REL_X, REL_Y = 0x02, 0x00, 0x01
EV_SYN, SYN_REPORT    = 0x00, 0x00

def emit(fd, typ, code, val):
    fd.write(struct.pack('llHHi', 0, 0, typ, code, val))

try:
    UI_SET_EVBIT  = 0x40045564
    UI_SET_RELBIT = 0x40045566
    UINPUT_DEV_SZ = 1452 + 4 * (64 + 64 + 48 + 48)
    UI_DEV_CREATE = 0x5501
    UI_DEV_DESTROY= 0x5502

    fd = open('/dev/uinput', 'wb', buffering=0)
    fcntl.ioctl(fd, UI_SET_EVBIT,  EV_REL)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    dev = struct.pack('80sHHIII', b'kibaos-cursor', 0, 0, 0, 0, 0)
    dev = dev.ljust(UINPUT_DEV_SZ, b'\x00')
    fd.write(dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    # Wiggle cursor gently every 500ms for up to 30s
    for _ in range(60):
        emit(fd, EV_REL, REL_X,  1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.25)
        emit(fd, EV_REL, REL_X, -1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.25)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    fd.close()
except Exception:
    pass
UINPUT_WIGGLE
  &
  echo $! > "${FREEZE_PID_FILE}"
  log "Framebuffer freeze active (PID $(cat ${FREEZE_PID_FILE}))."
}

fb_unfreeze() {
  if [ -f "${FREEZE_PID_FILE}" ]; then
    kill "$(cat ${FREEZE_PID_FILE})" 2>/dev/null || true
    rm -f "${FREEZE_PID_FILE}"
  fi
  rm -f /tmp/kibaos-ota-snap.png /tmp/kibaos-ota-snap.raw
  log "Framebuffer freeze released."
}

# ══════════════════════════════════════════════════════════════════════════
# APPLY PATCH — atomic file-by-file replacement
# ══════════════════════════════════════════════════════════════════════════
apply_patch() {
  log "Applying patch ${LATEST}..."
  ROLLBACK_DIR="${OTA_WORKDIR}/rollback-${CURRENT}"
  mkdir -p "${ROLLBACK_DIR}"

  while IFS= read -r line; do
    FILEPATH=$(echo "${line}" | awk '{print $2}' | sed 's|^\./||')
    SRC="${EXTRACT_DIR}/${FILEPATH}"
    DST="/${FILEPATH}"

    [ -f "${SRC}" ] || continue

    # Back up existing file for rollback
    if [ -f "${DST}" ]; then
      BACKUP_PATH="${ROLLBACK_DIR}/${FILEPATH}"
      mkdir -p "$(dirname ${BACKUP_PATH})"
      cp -a "${DST}" "${BACKUP_PATH}"
    fi

    # Atomic replace: write to .ota-tmp then move
    mkdir -p "$(dirname ${DST})"
    cp -a "${SRC}" "${DST}.ota-tmp"
    mv "${DST}.ota-tmp" "${DST}"
    log "  Patched: ${DST}"
  done < "${MANIFEST}"

  log "Patch applied."
}

rollback_patch() {
  ROLLBACK_DIR="${OTA_WORKDIR}/rollback-${CURRENT}"
  log "ROLLING BACK to patch level ${CURRENT}..."
  if [ -d "${ROLLBACK_DIR}" ]; then
    find "${ROLLBACK_DIR}" -type f | while read -r BACKUP; do
      FILEPATH="${BACKUP#${ROLLBACK_DIR}/}"
      DST="/${FILEPATH}"
      mkdir -p "$(dirname ${DST})"
      cp -a "${BACKUP}" "${DST}"
    done
    log "Rollback complete."
  else
    log "No rollback data found. Cannot roll back."
  fi
}

# ── Restart compositor: full session bounce, not in-place reconfigure ─────
# KWin does expose a documented reconfigure signal (`qdbus org.kde.KWin
# /KWin reconfigure`), but it only reloads kwinrc/effects settings, not
# things like a display-server-level renderer swap — so, same call the
# labwc build used to make for the same reason before the switch to KWin,
# this restarts the whole greeter/session rather than gambling on an
# in-place reload inside an unattended OTA patcher. Slower, but it won't
# leave the user stuck on a half-reloaded compositor.
restart_compositor() {
  log "Restarting session..."
  systemctl restart gdm 2>/dev/null || \
  pkill -TERM labwc 2>/dev/null || \
  pkill -TERM labwc 2>/dev/null || true
  sleep 1
  log "Session restarted."
}


# ── Restart display manager silently if needed ────────────────────────────
restart_display_manager() {
  log "Restarting GDM..."
  systemctl restart gdm
  # Wait for Wayland socket to come back
  for i in $(seq 1 20); do
    [ -S "/run/user/1000/${WAYLAND_DISPLAY:-wayland-0}" ] && break
    sleep 0.5
  done
  log "GDM restarted."
}

# ── Post-patch hooks ───────────────────────────────────────────────────────
run_post_hooks() {
  log "Running post-patch hooks..."
  # Re-apply GTK icon cache if icons changed
  grep -q 'usr/share/icons' "${MANIFEST}" && \
    gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true
  # Recompile GLib schemas if any changed
  grep -q 'usr/share/glib-2.0/schemas' "${MANIFEST}" && \
    glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true
  # Update MIME database if mime packages changed
  grep -q 'usr/share/mime' "${MANIFEST}" && \
    update-mime-database /usr/share/mime 2>/dev/null || true
  # Reload systemd units if any changed
  grep -q 'usr/lib/systemd' "${MANIFEST}" && \
    systemctl daemon-reload 2>/dev/null || true
  log "Post-patch hooks complete."
}

# ══════════════════════════════════════════════════════════════════════════
# CLI ROLLBACK — `kibaos-ota rollback --reason "..."`
# ══════════════════════════════════════════════════════════════════════════
# This is the manual entry point for anything that wants to trigger a
# rollback directly. It's independent of the unattended timer flow below: the timer
# always invokes this script bare, with no arguments, and never hits this
# branch. Restores whatever the most recent applied patch overwrote, from
# the backup apply_patch() kept alongside it — there's nothing to undo if
# no patch has landed yet, so that's reported rather than silently no-op'd.
if [ "${1:-}" = "rollback" ]; then
  shift || true
  REASON="cli:unspecified"
  while [ $# -gt 0 ]; do
    case "${1:-}" in
      --reason) REASON="${2:-${REASON}}"; shift 2 || break ;;
      *) shift ;;
    esac
  done
  CURRENT=$(cat "${PATCH_LEVEL_FILE}" 2>/dev/null || echo 0)
  log "Manual rollback requested (reason: ${REASON})"
  if [ -d "${OTA_WORKDIR}/rollback-${CURRENT}" ]; then
    fb_freeze
    rollback_patch
    restart_compositor
    restart_display_manager
    fb_unfreeze
    log "Manual rollback finished."
    exit 0
  else
    log "No rollback data available for patch level ${CURRENT}. Nothing to roll back."
    exit 1
  fi
fi

# ── Check current patch level ──────────────────────────────────────────────
CURRENT=$(cat "${PATCH_LEVEL_FILE}" 2>/dev/null || echo 0)
log "Current patch level: ${CURRENT}"

# ── Fetch latest available patch level ────────────────────────────────────
LATEST=$(curl -fsSL --retry 3 --max-time 10 \
  "${OTA_BASE}/latest-patch-level" 2>/dev/null | tr -d '[:space:]') || {
  log "Could not reach OTA server. Skipping."
  exit 0
}

if ! [[ "${LATEST}" =~ ^[0-9]+$ ]]; then
  log "Invalid patch level received: '${LATEST}'. Skipping."
  exit 0
fi

if [ "${LATEST}" -le "${CURRENT}" ]; then
  log "Already up to date (patch level ${CURRENT})."
  exit 0
fi

log "New patch available: ${CURRENT} → ${LATEST}"

# ── Download patch bundle + signature ─────────────────────────────────────
# patches are tagged per-arch now -- some patched components are compiled
# binaries, not scripts, so an untagged tarball could hand an arm box an
# x86 binary and that's a very bad day. DEV_ARCH comes from uname at download time so
# this stays correct forever, even if a device gets re-imaged later. beep boop
DEV_ARCH="$(uname -m)"
PATCH_TAR="${OTA_WORKDIR}/kibaos-ota-${LATEST}-${DEV_ARCH}.tar.gz"
PATCH_SIG="${PATCH_TAR}.asc"
MANIFEST="${OTA_WORKDIR}/manifest-${LATEST}-${DEV_ARCH}.txt"

mkdir -p "${OTA_WORKDIR}"

log "Downloading patch ${LATEST} (${DEV_ARCH})..."
curl -fsSL --retry 3 --max-time 120 \
  "${OTA_BASE}/kibaos-ota-${LATEST}-${DEV_ARCH}.tar.gz" -o "${PATCH_TAR}" || {
  log "Download failed. Skipping."
  exit 0
}
curl -fsSL --retry 3 --max-time 30 \
  "${OTA_BASE}/kibaos-ota-${LATEST}-${DEV_ARCH}.tar.gz.asc" -o "${PATCH_SIG}" || {
  log "Signature download failed. Aborting for safety."
  rm -f "${PATCH_TAR}"
  exit 1
}
curl -fsSL --retry 3 --max-time 30 \
  "${OTA_BASE}/kibaos-ota-${LATEST}-${DEV_ARCH}-manifest.txt" -o "${MANIFEST}" || {
  log "Manifest download failed. Aborting."
  rm -f "${PATCH_TAR}" "${PATCH_SIG}"
  exit 1
}

# ── Verify GPG signature ───────────────────────────────────────────────────
log "Verifying signature..."
if ! gpg --no-default-keyring --keyring "${OTA_KEYRING}" \
         --verify "${PATCH_SIG}" "${PATCH_TAR}" 2>/dev/null; then
  log "SIGNATURE VERIFICATION FAILED. Patch rejected. Possible tampering."
  rm -f "${PATCH_TAR}" "${PATCH_SIG}" "${MANIFEST}"
  exit 1
fi
log "Signature verified."

# ── Verify SHA256 checksums from manifest ─────────────────────────────────
log "Verifying checksums..."
EXTRACT_DIR="${OTA_WORKDIR}/patch-${LATEST}"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar xzf "${PATCH_TAR}" -C "${EXTRACT_DIR}"

# manifest format: SHA256  ./path/to/file
while IFS= read -r line; do
  EXPECTED_HASH=$(echo "${line}" | awk '{print $1}')
  FILEPATH=$(echo "${line}" | awk '{print $2}' | sed 's|^\./||')
  ACTUAL_HASH=$(sha256sum "${EXTRACT_DIR}/${FILEPATH}" 2>/dev/null | awk '{print $1}')
  if [ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]; then
    log "CHECKSUM MISMATCH for ${FILEPATH}. Aborting."
    rm -rf "${EXTRACT_DIR}" "${PATCH_TAR}" "${PATCH_SIG}" "${MANIFEST}"
    exit 1
  fi
done < "${MANIFEST}"
log "All checksums verified."

# ── Detect whether patch touches display-critical files ───────────────────
NEEDS_DISPLAY_RESTART=false
NEEDS_COMPOSITOR_RESTART=false
while IFS= read -r line; do
  FILEPATH=$(echo "${line}" | awk '{print $2}' | sed 's|^\./||')
  case "${FILEPATH}" in
    etc/gdm*|usr/lib/gdm*|usr/bin/gdm*|usr/share/gdm*|etc/dconf/db/gdm.d*)
      NEEDS_DISPLAY_RESTART=true ;;
    usr/bin/labwc*)
      # kwinrc/autostart/environment all live per-user under
      # ~/.config, seeded from /etc/skel at account creation, same
      # story labwc's rc.xml used to have. An OTA patch to the
      # skel copy only affects NEWLY created users from that point on --
      # it can't retroactively update already-installed users' own
      # configs. Only the kwin binary itself triggers a restart here.
      NEEDS_COMPOSITOR_RESTART=true ;;
  esac
done < "${MANIFEST}"

# ══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ══════════════════════════════════════════════════════════════════════════

# Freeze display if we're going to restart anything visible
if ${NEEDS_DISPLAY_RESTART} || ${NEEDS_COMPOSITOR_RESTART}; then
  fb_freeze
fi

# Apply patch with rollback on failure
if ! apply_patch; then
  log "Patch application failed. Initiating rollback."
  rollback_patch
  fb_unfreeze
  exit 1
fi

# Run post-patch hooks
if ! run_post_hooks; then
  log "Post-patch hooks failed. Initiating rollback."
  rollback_patch
  fb_unfreeze
  exit 1
fi

# Restart services as needed
if ${NEEDS_COMPOSITOR_RESTART}; then
  restart_compositor
fi
if ${NEEDS_DISPLAY_RESTART}; then
  restart_display_manager
fi

# Unfreeze display
if ${NEEDS_DISPLAY_RESTART} || ${NEEDS_COMPOSITOR_RESTART}; then
  fb_unfreeze
fi

# Commit new patch level
echo "${LATEST}" > "${PATCH_LEVEL_FILE}"
log "Successfully updated to patch level ${LATEST}."

# Cleanup
rm -rf "${EXTRACT_DIR}" "${PATCH_TAR}" "${PATCH_SIG}" "${MANIFEST}"
log "Done."
OTASCRIPT
chmod +x /usr/local/bin/kibaos-ota

# ── systemd service + timer for OTA ───────────────────────────────────────
cat > /etc/systemd/system/kibaos-ota.service << 'OTASVC'
[Unit]
Description=KibaOS OTA Live Patch Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-ota
StandardOutput=append:/var/log/kibaos/ota.log
StandardError=append:/var/log/kibaos/ota.log
OTASVC

cat > /etc/systemd/system/kibaos-ota.timer << 'OTATIMER'
[Unit]
Description=KibaOS OTA patch check every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
RandomizedDelaySec=3min
Persistent=true

[Install]
WantedBy=timers.target
OTATIMER

systemctl enable kibaos-ota.timer

# ══════════════════════════════════════════════════════════════════════════
# FIRST-BOOT GROUP CATCHUP
# The installer defers any -G group that doesn't exist yet at install time
# (docker is the known case: its group only shows up once systemd-sysusers
# actually runs against the installed system, not the image-capture
# snapshot) and records it in /etc/kibaos/pending-user-groups as
# "username:group1,group2". This runs after sysusers on first boot, adds
# the user to whatever's now available, and cleans up after itself so it's
# a no-op on every boot after the first.
# ══════════════════════════════════════════════════════════════════════════
cat > /usr/local/bin/kibaos-firstboot-groups << 'FIRSTBOOTGROUPS'
#!/usr/bin/env bash
set -euo pipefail
MARKER="/etc/kibaos/pending-user-groups"
[ -f "$MARKER" ] || exit 0

while IFS=: read -r username groups; do
    [ -n "$username" ] || continue
    IFS=',' read -ra group_arr <<< "$groups"
    add_groups=()
    for g in "${group_arr[@]}"; do
        if getent group "$g" > /dev/null 2>&1; then
            add_groups+=("$g")
        else
            echo "kibaos-firstboot-groups: '$g' still doesn't exist, leaving pending" >&2
        fi
    done
    if [ "${#add_groups[@]}" -gt 0 ]; then
        joined=$(IFS=,; echo "${add_groups[*]}")
        usermod -aG "$joined" "$username" \
            && echo "kibaos-firstboot-groups: added $username to $joined" \
            || echo "kibaos-firstboot-groups: usermod failed for $username" >&2
    fi
done < "$MARKER"

# Only remove the marker once every listed group actually got processed --
# if getent still couldn't find something, leave the file so the next boot
# retries it instead of silently dropping that membership forever.
if ! grep -qE ':.*[a-zA-Z]' "$MARKER" 2>/dev/null || \
   ! awk -F: '{print $2}' "$MARKER" | tr ',' '\n' | while read -r g; do
       [ -n "$g" ] && ! getent group "$g" > /dev/null 2>&1 && exit 1
   done; then
    : # some group still missing -- keep retrying on future boots
else
    rm -f "$MARKER"
fi
FIRSTBOOTGROUPS
chmod +x /usr/local/bin/kibaos-firstboot-groups

cat > /etc/systemd/system/kibaos-firstboot-groups.service << 'FIRSTBOOTSVC'
[Unit]
Description=KibaOS first-boot group catch-up (docker, etc.)
After=systemd-sysusers.service
Wants=systemd-sysusers.service
ConditionPathExists=/etc/kibaos/pending-user-groups

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-firstboot-groups
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
FIRSTBOOTSVC

systemctl enable kibaos-firstboot-groups.service

# ══════════════════════════════════════════════════════════════════════════
# SKELETON
# ══════════════════════════════════════════════════════════════════════════
SKEL="/etc/skel"
mkdir -p \
  "${SKEL}/.config/gtk-3.0" \
  "${SKEL}/.config/gtk-4.0" \
  "${SKEL}/.config/autostart" \
  "${SKEL}/.config/fastfetch"

cat > "${SKEL}/.config/autostart/nemo-desktop.desktop" << 'NEMODESKTOP'
[Desktop Entry]
Type=Application
Name=Nemo Desktop
Exec=nemo-desktop
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
NEMODESKTOP

cat > "${SKEL}/.config/gtk-3.0/settings.ini" << 'GTK3SKEL'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Numix-Circle
gtk-font-name=Noto Sans 11
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
gtk-button-images=1
gtk-menu-images=1
gtk-enable-animations=1
GTK3SKEL

cp /etc/gtk-3.0/gtk.css "${SKEL}/.config/gtk-3.0/gtk.css"
cp /etc/gtk-4.0/gtk.css "${SKEL}/.config/gtk-4.0/gtk.css"

dbus-run-session -- dconf write /com/solus-project/budgie-panel/panels "@as []" || true
cat > /usr/share/glib-2.0/schemas/99-kibaos-budgie.gschema.override << 'EOF'
[com.solus-project.budgie-panel]
panels=@as []
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas/

# ══════════════════════════════════════════════════════════════════════════
# FIRST-LOGIN SCRIPT
# ══════════════════════════════════════════════════════════════════════════
cat > /usr/local/bin/kibaos-first-login << 'FIRSTLOGIN'
#!/usr/bin/env bash
STAMP="${HOME}/.config/.kibaos-configured"
[ -f "${STAMP}" ] && exit 0

gsettings set org.gnome.desktop.interface gtk-theme               'Adwaita-dark'
gsettings set org.gnome.desktop.interface icon-theme              'Numix-Circle'
gsettings set org.gnome.desktop.interface cursor-theme            'Adwaita'
gsettings set org.gnome.desktop.interface cursor-size             24
gsettings set org.gnome.desktop.interface font-name               'Noto Sans 11'
gsettings set org.gnome.desktop.interface document-font-name      'Noto Sans 11'
gsettings set org.gnome.desktop.interface monospace-font-name     'Noto Sans Mono 11'
gsettings set org.gnome.desktop.interface color-scheme            'prefer-dark'
gsettings set org.gnome.desktop.interface enable-animations       true
gsettings set org.gnome.desktop.interface text-scaling-factor     1.0

gsettings set org.gnome.desktop.background picture-uri      'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-uri-dark 'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-options  'zoom'
gsettings set org.gnome.desktop.background primary-color    '#0d1b2a'

gsettings set org.gnome.desktop.wm.preferences button-layout               'close,minimize,maximize:'
gsettings set org.gnome.desktop.wm.preferences titlebar-font               'Noto Sans Medium 10'
gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
gsettings set org.gnome.desktop.wm.preferences num-workspaces               4
gsettings set org.gnome.desktop.wm.preferences focus-mode                  'click'

gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click                true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll               true
gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
gsettings set org.gnome.desktop.peripherals.mouse    natural-scroll               false
gsettings set org.gnome.desktop.peripherals.mouse    accel-profile                'adaptive'

gsettings set org.nemo.desktop show-desktop-icons              true
gsettings set org.nemo.desktop ignored-desktop-handlers        "['budgie-helper']"
gsettings set org.nemo.preferences show-hidden-files           false
gsettings set org.nemo.preferences default-folder-viewer       'icon-view'
gsettings set org.nemo.icon-view default-zoom-level            'standard'
gsettings set org.nemo.preferences show-location-entry         false

touch "${STAMP}"

FIRSTLOGIN
chmod +x /usr/local/bin/kibaos-first-login

# ══════════════════════════════════════════════════════════════════════════
# PANEL GUARD -- runs every login, not just the first
# ══════════════════════════════════════════════════════════════════════════
# The panel setup used to live in kibaos-first-login above, one-shot and
# stamp-guarded like everything else there. That's fine for preferences
# (theme, wallpaper, workspace count) -- if those are wrong, at worst you
# reset them yourself. Panels are different: on more than one report, a
# freshly-configured install came back on the *second* login with a bare
# top panel and no bottom dock at all, i.e. exactly Budgie's own built-in
# fallback layout, not ours.
#
# Root cause, straight from budgie-desktop's own manager.vala
# (BuddiesOfBudgie/budgie-desktop, src/panel/manager.vala): panel startup
# calls load_panels(), and only calls create_default(default_layout) --
# Budgie's own stock single-panel layout -- if that load comes back empty.
# There's also do_live_reset(), a *separate* path that fires on a failed
# load *after* panels were already loaded once: it deletes every panel
# and dconf-resets the whole panels tree before falling back to that same
# default. Budgie's icon-tasklist applet is the documented trigger for
# exactly that (solus-project/budgie-desktop#1480: a pinned-launchers
# entry pointing at a .desktop file that doesn't exist crashes the panel
# on load) -- the find_desktop_id() probe below already guards the .desktop
# IDs actually written into pinned-launchers, but nothing guarantees every
# one of those apps' indexing is settled at the exact moment panel load
# happens on every future boot, only that it was at the moment this script
# last ran. If a crash-and-reset ever fires, dconf keeps whatever default
# layout Budgie fell back to -- and a one-shot, stamp-guarded fix has
# already run and will never touch it again.
#
# So: no stamp here. Cheap check, every login -- if a bottom panel already
# exists, do nothing at all (this is the common case, pure no-op). Only
# if one doesn't -- first login ever, or Budgie wiped it out from under
# us since -- does this actually rebuild anything. Whatever stray
# panel/applet UUIDs Budgie's own fallback left behind just go unreferenced
# in dconf; harmless, and simpler than trying to hunt them down and clean
# them up.
cat > /usr/local/bin/kibaos-panel-guard << 'PANELGUARD'
#!/usr/bin/env bash
PANEL_SCHEMA="com.solus-project.budgie-panel"
PANEL_INSTANCE_SCHEMA="com.solus-project.budgie-panel.panel"
PANEL_BASE="/com/solus-project/budgie-panel/panels/"

EXISTING_UUIDS=$(gsettings get "${PANEL_SCHEMA}" panels 2>/dev/null | tr -d "[]'" | tr ',' ' ')
for uuid in ${EXISTING_UUIDS}; do
  loc=$(gsettings get "${PANEL_INSTANCE_SCHEMA}:${PANEL_BASE}{${uuid}}/" location 2>/dev/null)
  [ "${loc}" = "'bottom'" ] && exit 0
done

# No bottom panel found -- either nothing's been configured yet, or
# Budgie's own load-failure recovery reset things since we last ran.
# Rebuild it from scratch; see the comment above this script for why.
PANEL_UUID=$(uuidgen)
gsettings set "${PANEL_SCHEMA}" panels "['${PANEL_UUID}']"
PANEL_PATH="${PANEL_BASE}{${PANEL_UUID}}/"

gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" location bottom
gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" size 42
gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" transparency none
gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" enable-shadow true

# Budgie's icon-tasklist applet will PERMANENTLY crash the session on
# every future login if pinned-launchers points at a .desktop file that
# doesn't actually exist (solus-project/budgie-desktop#1480 — confirmed
# this happens, not a maybe). so: probe the real filesystem for whichever
# desktop-id variant actually got installed, instead of hardcoding a
# guess and hoping it's right.
find_desktop_id() {
  for candidate in "$@"; do
    [ -f "/usr/share/applications/${candidate}" ] && {
      echo "${candidate}"
      return 0
    }
  done
  return 1
}

DOCK_LAUNCHERS=()
for ids in \
  "kibaos-files.desktop nemo.desktop" \
  "org.gnome.Calendar.desktop gnome-calendar.desktop" \
  "org.gnome.Notes.desktop bijiben.desktop gnome-notes.desktop" \
  "org.gnome.eog.desktop eog.desktop" \
  "org.gnome.Geary.desktop geary.desktop" \
  "org.gnome.Music.desktop gnome-music.desktop" \
  "org.gnome.Todo.desktop gnome-todo.desktop" \
  "gnome-control-center.desktop org.gnome.Settings.desktop"
do
  FOUND=$(find_desktop_id ${ids}) && DOCK_LAUNCHERS+=("${FOUND}")
done

add_applet() {
  local plugin_name="$1"
  local uuid
  uuid=$(uuidgen)
  gsettings set \
    "com.solus-project.budgie-panel.applet:/com/solus-project/budgie-panel/applets/{${uuid}}/" \
    name \
    "${plugin_name}"
  echo "${uuid}"
}

MENU_UUID=$(add_applet "budgie-menu")
TASKLIST_UUID=$(add_applet "icon-tasklist")
CLOCK_UUID=$(add_applet "clock")

gsettings set \
  "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" \
  applets \
  "['${MENU_UUID}', '${TASKLIST_UUID}', '${CLOCK_UUID}']"

if [ "${#DOCK_LAUNCHERS[@]}" -gt 0 ]; then
  LAUNCHERS_GVARIANT=$(printf "'%s', " "${DOCK_LAUNCHERS[@]}")
  gsettings set \
    "com.solus-project.budgie-panel.icon-tasklist:/com/solus-project/budgie-panel/instance/icon-tasklist/{${TASKLIST_UUID}}/" \
    pinned-launchers \
    "[${LAUNCHERS_GVARIANT%, }]"
fi
PANELGUARD
chmod +x /usr/local/bin/kibaos-panel-guard

cat > "${SKEL}/.config/autostart/kibaos-configure.desktop" << 'AUTOCFG'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOCFG

# No Hidden/marker-file gate here on purpose -- unlike kibaos-configure.desktop
# above, this one is meant to run every single login (see the comment on
# kibaos-panel-guard itself for why); it self-limits via the bottom-panel
# check inside the script instead, not via autostart-once semantics.
cat > "${SKEL}/.config/autostart/kibaos-panel-guard.desktop" << 'PANELGUARDDESK'
[Desktop Entry]
Type=Application
Name=KibaOS Panel Guard
Exec=/usr/local/bin/kibaos-panel-guard
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
PANELGUARDDESK

# ── OEM-mode autostart: launches io.kibaos.oobe (which self-detects
# OEM-finish mode via /etc/kibaos/oem-pending, see main.vala) on login to
# the temporary 'oem' autologin account kibaos-oem-prepare sets up. a
# plain Exec= can't conditionally skip launching, so the condition gets
# wrapped in a one-line shell test instead — on a normal (non-OEM)
# install this marker never exists, so the test just fails and nothing
# launches. ───────────────────────────────────────────────────────────
cat > "${SKEL}/.config/autostart/kibaos-oem-finish.desktop" << 'OEMAUTOCFG'
[Desktop Entry]
Type=Application
Name=Finish Setting Up KibaOS
Exec=sh -c 'test -f /etc/kibaos/oem-pending && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
OEMAUTOCFG

# ══════════════════════════════════════════════════════════════════════════
# WINDOWS APP SUPPORT (WinApps) — file-manager integration + first-login
# setup wizard. Package deps (docker, freerdp, dialog, zenity, pciutils,
# etc.) are in packages.x86_64; the winapps-org/winapps repo itself is
# vendored above at ${WINAPPS_SRC}. Both the disk installer
# (kibaos-oobe-backend) and OEM-finish (kibaos-oem-finish.sh) always drop
# /etc/kibaos/winapps-pending on completion — this is a listed, always-on
# feature, not opt-in, so unlike the oem-pending marker it mirrors, nothing
# ever leaves it unset. The marker's what triggers kibaos-winapps-setup on
# first login (see kibaos-winapps-firstrun.desktop below); the user can
# also launch it manually via "Set Up Windows Workspace" in the app menu
# any time, e.g. to retry after a failed first attempt.
# ══════════════════════════════════════════════════════════════════════════

# A KibaOS-branded icon for the exe-runner + app-menu entry, pulled from the
# vendored repo's own installer art instead of drawing something new.
install -Dm644 "${WINAPPS_SRC}/install/windows.svg" \
  /usr/share/icons/hicolor/scalable/apps/kibaos-winapps.svg 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# ── The Windows workspace launcher ──────────────────────────────────────
# Rather than routing individual .exe files through WinApps' RAIL
# integration, this opens the whole Windows environment as one fullscreen
# workspace via its noVNC web console -- simpler mental model for the
# person (one window called "Windows", not per-app RDP plumbing) and
# avoids RAIL edge cases with apps WinApps didn't detect/configure.
cat > /usr/local/bin/kibaos-winapps-workspace << 'WORKSPACE'
#!/bin/bash
# Opens the Windows VM's noVNC console fullscreen. If setup hasn't run
# yet, offers to run it first instead of just opening a browser tab to
# nothing -- same "never dead-end without explanation" rule as before.
CONF_DIR="${HOME}/.config/winapps"
COMPOSE_FILE="${CONF_DIR}/compose.yaml"
KWIN_SCRIPT_NAME="kibaos-winapps-workspace-tempbind"
KWIN_SCRIPT_FILE="/tmp/${KWIN_SCRIPT_NAME}.js"
KWIN_SCRIPT_ID_FILE="/tmp/${KWIN_SCRIPT_NAME}.id"
HINT_MARKER="${HOME}/.config/kibaos/.winapps-workspace-hint-shown"
WIN_URL="http://localhost:8006"

if [ ! -f "${COMPOSE_FILE}" ]; then
  zenity --question --title="Set Up Windows Workspace?" \
    --text="Windows Workspace lets you run Windows programs -- like Word, Excel, or other apps that don't have a Linux version -- right alongside everything else in KibaOS.\n\nWant to set it up now? It takes about 15–20 minutes, and you won't need to do anything but wait." \
    --ok-label="Yes, Let's Do It" --cancel-label="Maybe Later" 2>/dev/null
  if [ "$?" -eq 0 ]; then
    # io.kibaos.winapps-setup, not the raw backend script -- it's the GTK
    # wrapper that actually reads the PROGRESS/FATAL protocol and shows
    # something on screen while kibaos-winapps-setup runs headless behind
    # it (see WINDOWS APP SUPPORT further down for both).
    exec /usr/bin/io.kibaos.winapps-setup --manual-launch
  fi
  exit 1
fi

# ── Single-instance guard ────────────────────────────────────────────────
# Clicking the desktop icon a second time while the workspace is already
# open used to spin up a second chromium --kiosk window and re-run
# `docker compose up` (harmless, but pointless and slow) instead of just
# getting the person back to the window they already have. xdotool is
# already vendored for this workspace launcher's own single-instance
# guard below, so this reuses it rather than adding a new dependency:
# search for a window whose class matches
# chromium's --app= kiosk instance, and if one exists, just raise/focus
# it and exit immediately -- no compose, no pkexec, no wait, no chromium
# relaunch.
EXISTING_WIN="$(xdotool search --class "^chromium.*8006$|^Chromium.*8006$" 2>/dev/null | head -n1)"
if [ -z "${EXISTING_WIN}" ]; then
  # --app= windows aren't always classed by URL depending on chromium
  # version -- fall back to matching by window name instead.
  EXISTING_WIN="$(xdotool search --name "localhost:8006" 2>/dev/null | head -n1)"
fi
if [ -n "${EXISTING_WIN}" ]; then
  xdotool windowactivate "${EXISTING_WIN}" 2>/dev/null
  exit 0
fi

KEYBIND_ADDED=0
add_keybind() {
  # Super+K minimizes the fullscreen Windows window back to the desktop --
  # bound only while this workspace is actually open, not a permanent
  # shortcut. KWin has no rc.xml to patch, so this registers a throwaway
  # KWin script over D-Bus instead: the script calls registerShortcut()
  # for Meta+K and minimizes whatever window is currently active, and
  # gets unloaded again on exit (see cleanup() below) rather than left
  # bound forever.
  if [ ! -f "${KWIN_SCRIPT_ID_FILE}" ]; then
    cat > "${KWIN_SCRIPT_FILE}" << 'KWINTEMPBIND'
registerShortcut("KibaWinAppsWorkspaceMinimize", "Minimize Windows Workspace", "Meta+K", function() {
  if (workspace.activeWindow) {
    workspace.activeWindow.minimized = true;
  }
});
KWINTEMPBIND
    SCRIPT_ID="$(qdbus org.kde.KWin /Scripting loadScript "${KWIN_SCRIPT_FILE}" "${KWIN_SCRIPT_NAME}" 2>/dev/null)"
    if [ -n "${SCRIPT_ID}" ]; then
      qdbus "org.kde.KWin" "/Scripting/Script${SCRIPT_ID}" run 2>/dev/null || \
        qdbus "org.kde.KWin" "/${SCRIPT_ID}" run 2>/dev/null || true
      echo "${SCRIPT_ID}" > "${KWIN_SCRIPT_ID_FILE}"
      KEYBIND_ADDED=1
    fi
  fi
}

# Runs on ANY exit from this point on -- normal chromium close, the user
# killing the window some other way, or this script itself dying. Without
# a trap, only the "chromium closed normally" path unloaded the script,
# so a killed session could permanently leave Super+K bound to minimize.
cleanup() {
  if [ "${KEYBIND_ADDED}" -eq 1 ] && [ -f "${KWIN_SCRIPT_ID_FILE}" ]; then
    SCRIPT_ID="$(cat "${KWIN_SCRIPT_ID_FILE}" 2>/dev/null)"
    if [ -n "${SCRIPT_ID}" ]; then
      qdbus "org.kde.KWin" /Scripting unloadScript "${KWIN_SCRIPT_NAME}" 2>/dev/null || true
    fi
    rm -f "${KWIN_SCRIPT_ID_FILE}" "${KWIN_SCRIPT_FILE}"
  fi
}
trap cleanup EXIT

# ── Skip the auth prompt when it's already running ─────────────────────
# `pkexec docker compose up -d` used to run unconditionally on every
# launch -- idempotent, sure, but that still means a polkit password
# prompt every single time someone reopens the workspace, even when the
# container's been sitting there running the whole time (e.g. they
# minimized with Super+K, closed the window some other way, then clicked
# the icon again a minute later). Checking whether noVNC is already
# answering first means the extremely common "it's already up" case
# skips pkexec, docker compose, and the progress dialog entirely and
# goes straight to reopening chromium.
ALREADY_UP=0
if curl -fsS -o /dev/null --max-time 2 "${WIN_URL}" 2>/dev/null; then
  ALREADY_UP=1
fi

if [ "${ALREADY_UP}" -eq 0 ]; then
  # docker compose up is idempotent -- safe to run even if the container's
  # already up (e.g. the curl check above raced a container that was
  # still finishing its own startup), and covers the case where it's
  # stopped since last boot. Runs in the background so the "starting up"
  # dialog below can show right away instead of the whole launch
  # appearing to hang on the pkexec prompt.
  ( cd "${CONF_DIR}" && pkexec docker compose up -d ) >/dev/null 2>&1 &
  COMPOSE_PID=$!

  # The container can take a few seconds (or longer, first boot after a
  # reboot) before noVNC is actually answering on 8006. Opening chromium
  # immediately used to race that -- landing the person on a browser
  # "connection refused" page with no explanation, which looks broken even
  # though nothing's actually wrong. Wait for a real HTTP response rather
  # than just the TCP port accepting a connection -- noVNC's port can
  # start accepting TCP connections slightly before it's actually serving
  # the console page, which was still enough to show a half-loaded blank
  # page for a moment. A visible, cancellable progress dialog stays on
  # screen the whole time either way, so there's always something on
  # screen that makes sense.
  (
    for i in $(seq 1 60); do
      curl -fsS -o /dev/null --max-time 1 "${WIN_URL}" 2>/dev/null && break
      sleep 1
      echo "$((i * 100 / 60))"
    done
    echo "100"
  ) | zenity --progress --title="Windows Workspace" --text="Just a moment, opening your Windows Workspace…" \
      --pulsate --auto-close --no-cancel --width=360 2>/dev/null

  wait "${COMPOSE_PID}"
  COMPOSE_STATUS=$?

  if ! curl -fsS -o /dev/null --max-time 2 "${WIN_URL}" 2>/dev/null; then
    if [ "${COMPOSE_STATUS}" -ne 0 ]; then
      zenity --error --title="Windows Workspace" --width=420 \
        --text="Hmm, your Windows Workspace didn't start. Give it another try -- if it keeps happening, open 'Set Up Windows Workspace' from the app menu and we'll get it sorted." 2>/dev/null
    else
      zenity --error --title="Windows Workspace" --width=420 \
        --text="Your Windows Workspace is taking a little longer than usual to wake up. Nothing's broken -- just give it another moment, then try 'Open Windows Workspace' again." 2>/dev/null
    fi
    exit 1
  fi
fi

add_keybind

# First time this workspace opens on this account, say what Super+K does
# up front -- it's the only way out of a fullscreen kiosk window, and
# nothing else on screen hints it exists.
if [ "${KEYBIND_ADDED}" -eq 1 ] && [ ! -f "${HINT_MARKER}" ]; then
  mkdir -p "$(dirname "${HINT_MARKER}")"
  touch "${HINT_MARKER}"
  notify-send -i kibaos-winapps "Windows Workspace" \
    "Tip: press Super+K any time to duck back to your KibaOS desktop. Windows Workspace stays right where you left it." 2>/dev/null || \
    zenity --info --title="Windows Workspace" --width=380 \
      --text="Tip: press Super+K any time to duck back to your KibaOS desktop. Windows Workspace stays right where you left it." 2>/dev/null
fi

chromium --kiosk --app="${WIN_URL}" 2>/dev/null
# cleanup() runs automatically via the EXIT trap above.
WORKSPACE
chmod +x /usr/local/bin/kibaos-winapps-workspace

cat > /usr/share/applications/kibaos-winapps-workspace.desktop << 'WORKSPACEDESKTOP'
[Desktop Entry]
Type=Application
Name=Open Windows Workspace
Comment=Run Windows programs like Word and Excel, right alongside KibaOS
Icon=kibaos-winapps
Exec=/usr/local/bin/kibaos-winapps-workspace
Terminal=false
NoDisplay=false
Categories=System;
WORKSPACEDESKTOP

# Also drop it as a desktop icon, not just an app-menu entry -- this is
# meant to be the person's main "open Windows" door, so it should be
# reachable without digging into the menu. Written into skel so it lands
# on every new account's desktop, same as the rest of this section.
mkdir -p "${SKEL}/Desktop"
cp /usr/share/applications/kibaos-winapps-workspace.desktop \
  "${SKEL}/Desktop/kibaos-winapps-workspace.desktop"
chmod +x "${SKEL}/Desktop/kibaos-winapps-workspace.desktop"

# ── The setup wizard itself ─────────────────────────────────────────────
# Written entirely in plain language on purpose — this is the one part of
# KibaOS setup that talks about Docker, RDP ports, and VMs under the
# hood, none of which the person running it should ever need to know.
# Re-runnable: launching it again after a successful setup just re-opens
# the "everything's already working" summary instead of redoing anything.
# ── The setup wizard itself ─────────────────────────────────────────────
# Written entirely in plain language on purpose — this is the one part of
# KibaOS setup that talks about Docker, RDP ports, and VMs under the
# hood, none of which the person running it should ever need to know.
# Re-runnable: launching it again after a successful setup just re-opens
# the "everything's already working" summary instead of redoing anything.
#
# Headless PROGRESS/FATAL backend, not a dialog-driven script. This used
# to talk straight to the person via zenity --info/--question/--error/
# --progress, which meant it could only ever run inside an X session with
# zenity installed, and had no way to hand its status to anything other
# than a zenity window. It now speaks the exact same wire protocol as
# kibaos-oobe-backend and kibaos-oem-finish.sh instead: "PROGRESS <pct>
# <msg>" lines on stdout, "FATAL: <msg>" on stderr, plain exit code for
# success/failure. See launch_backend()/read_backend_output() in the OOBE
# frontend above for the reference reader -- any caller that spawns this
# with stdout piped and stderr merged (GLib.SubprocessLauncher with
# STDOUT_PIPE|STDERR_MERGE, same as the OOBE launcher does) can drive its
# own UI off these two prefixes, or none at all. No zenity calls remain
# anywhere in this script.
cat > /usr/local/bin/kibaos-winapps-setup << 'WINAPPSSETUP'
WINAPPS_SRC="/opt/kibaos/winapps-src"
CONF_DIR="${HOME}/.config/winapps"
COMPOSE_FILE="${CONF_DIR}/compose.yaml"
MARKER="/etc/kibaos/winapps-pending"
MANUAL_LAUNCH="${1:-}"

progress() { echo "PROGRESS $1 $2"; }
fail()     { progress 100 "Setup failed: $1"; echo "FATAL: $1" >&2; exit 1; }

# Group membership in /etc/group only takes effect for *new* login
# sessions, not the one you're already in -- and the OEM-finish flow in
# particular can land someone straight into a desktop session for the
# account that was *just* created, marker and all, with docker group
# membership on disk but not yet in this session's token. Rather than
# make the user log out and back in for what looks like a broken feature,
# re-exec once with the docker group active (see below) if the account
# is a docker-group member on disk but this shell doesn't have it active
# yet. WINAPPS_REGROUPED guards against ever doing this twice.
if [ -z "${WINAPPS_REGROUPED:-}" ] \
   && id -nG "${USER:-$(id -un)}" 2>/dev/null | tr ' ' '\n' | grep -qx docker \
   && ! groups 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  export WINAPPS_REGROUPED=1
  # `sg` (which used to do this in one shot, no TTY required) no longer
  # ships on Arch -- it's gone from both `shadow` and `util-linux` as of
  # current package file lists, `newgrp` is util-linux's now. `newgrp`
  # normally replaces the shell interactively, but feeding it a command
  # over stdin (rather than a TTY) makes it run that command
  # non-interactively in the new group and then exit, which is the
  # standard script idiom for this. `exec` here still replaces this
  # process rather than nesting another layer of shell.
  exec newgrp docker <<NEWGRPCMD
"$0" ${MANUAL_LAUNCH}
NEWGRPCMD
fi

progress 1 "Checking Windows Workspace status..."

# Already fully set up? Report done and clear the marker instead of
# redoing anything -- this is a normal outcome, not a failure.
if command -v winapps >/dev/null 2>&1 && [ -f "${CONF_DIR}/winapps.conf" ]; then
  rm -f "${MARKER}"
  progress 100 "Windows Workspace is already set up and running."
  exit 0
fi

# Docker already installed and the Windows container already created from
# a prior attempt (compose.yaml exists), just not finished (setup.sh
# never completed, or the RDP wait timed out last time)? That means
# someone already went through this once -- resume instead of restarting
# from scratch.
RESUMING=0
if command -v docker >/dev/null 2>&1 && [ -f "${COMPOSE_FILE}" ]; then
  RESUMING=1
fi

# WinApps is a listed, always-on KibaOS feature, not an opt-in add-on
# (see the WINDOWS APP SUPPORT header above), so this proceeds straight
# through rather than gating on a confirmation dialog for something
# that's not actually optional. kibaos-winapps-workspace's own "want to
# set this up now?" question, before it ever launches this backend, is
# the one and only consent point.
if [ "${RESUMING}" -eq 1 ]; then
  progress 5 "Resuming Windows Workspace setup..."
else
  progress 5 "Setting up Windows Workspace..."
fi

progress 10 "Starting Docker..."
mkdir -p "${CONF_DIR}"

# Everything below that actually needs root -- starting docker, reading
# and clearing the root-only password stash under /etc/kibaos, checking
# for the "nvidia" docker runtime, and running `docker compose up`
# against the daemon's root-owned socket -- used to be seven separate
# pkexec calls scattered through this function. Each one is its own
# polkit authentication unless the local agent happens to cache
# auth_admin sessions, which isn't something this script can rely on --
# in practice that meant up to seven password prompts for a single "set
# up Windows Workspace" run. Folded into one script and run through
# exactly one pkexec instead: everything that needs root runs together,
# once; everything that doesn't (compose.yaml templating logic aside --
# see below -- the RDP wait-poll, setup.sh) stays out here, unprivileged,
# same as before.
#
# The compose.yaml templating itself (copying from WINAPPS_SRC, the arm
# image swap, substituting the Windows account password in) doesn't
# strictly need root -- but the password half of it does (the stash
# under /etc/kibaos is 0600 root:root), so rather than split templating
# across the privilege boundary too, the whole thing moved into the
# privileged script and gets chowned back to the real user at the end.
#
# pkexec resets the environment, so nothing in the privileged script can
# rely on $HOME, $USER, or any other variable from out here -- every
# path and identity it needs (CONF_DIR/COMPOSE_FILE, whether NVIDIA
# hardware is even present, which real user to hand the results back to)
# is passed in as a positional argument, already resolved out here
# first. lspci doesn't need root, so the actual hardware check
# (NVIDIA_HW) happens out here rather than adding a reason to elevate.
NVIDIA_HW=0
lspci -nnk 2>/dev/null | grep -qi 'nvidia' && NVIDIA_HW=1
ORIG_USER="$(id -un)"
GPU_FLAG_FILE="$(mktemp)"
PRIV_SCRIPT="$(mktemp)"

cat > "${PRIV_SCRIPT}" << 'PRIVILEGED'
#!/usr/bin/env bash
set -u
CONF_DIR="$1"; COMPOSE_FILE="$2"; NVIDIA_HW="$3"; ORIG_USER="$4"; GPU_FLAG_FILE="$5"
WINAPPS_SRC="/opt/kibaos/winapps-src"

echo "PROGRESS 10 Starting Docker..."
systemctl enable --now docker >/dev/null 2>&1
if ! systemctl is-active --quiet docker; then
  logger -t kibaos-winapps-setup "docker failed to start; see systemctl status docker"
  echo "PROGRESS 100 Setup failed: Docker couldn't be started -- check 'systemctl status docker'."
  echo "FATAL: Docker couldn't be started -- check 'systemctl status docker'." >&2
  exit 1
fi

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "PROGRESS 15 Preparing Windows Workspace configuration..."
  cp "${WINAPPS_SRC}/compose.yaml" "${COMPOSE_FILE}"
  # compose.yaml references "./oem" as a relative bind-mount source (for
  # post-install RDPApps.reg / install.bat execution inside the guest).
  # That path resolves relative to the directory `docker compose` is run
  # from -- CONF_DIR, not WINAPPS_SRC -- so the oem/ folder has to be
  # copied alongside compose.yaml or the bind mount has nothing to point
  # at and `docker compose up -d` fails before the container is created.
  cp -r "${WINAPPS_SRC}/oem" "${CONF_DIR}/oem"
  # arm gets windows-arm instead of windows -- same project, same RDP
  # setup, just a real arm64 windows guest instead of trying to emulate
  # x86 windows on arm hardware (which doesn't work anyway, checked!)
  if [ "$(uname -m)" = "aarch64" ]; then
    sed -i -E 's#image: dockurr/windows(:[^[:space:]]*)?$#image: dockurr/windows-arm\1#' "${COMPOSE_FILE}"
  fi

  # WinApps' docker backend (dockur/windows under the hood) installs
  # Windows completely unattended using whatever USERNAME/PASSWORD is
  # baked into compose.yaml at container creation -- there's no
  # interactive "create your account" step like real Windows Setup, and
  # changing these after the fact means tearing down and recreating the
  # VM. Left at the upstream sample values (MyWindowsUser /
  # MyWindowsPassword), that's a weak, publicly documented password --
  # and per WinApps' own docs, an empty/default password can make Windows
  # auto-login in a way that breaks the RDP handshake WinApps needs.
  echo "PROGRESS 20 Setting your Windows account password..."
  WIN_USER="KibaUser"
  WIN_PASS=""
  # Rather than a random string the person is never shown, reuse the same
  # password they already log into KibaOS with -- one password to
  # remember, not two. kiba_install_create_user() (disk installs) and
  # kibaos-oem-finish.sh (OEM-imaged devices) both stash it root-only and
  # one-time-use, right after account creation, for exactly this. Already
  # running as root in here, so just read it directly (no separate
  # pkexec needed the way the old per-call version needed one) and
  # delete the stash the moment it's read, so it never sits around
  # longer than this single read needs it to.
  STASH="/etc/kibaos/winapps-userpass"
  if [ -f "${STASH}" ]; then
    WIN_PASS="$(cat "${STASH}" 2>/dev/null)"
    rm -f "${STASH}" 2>/dev/null || true
  fi
  # Headless: there's no dialog left to ask for a password interactively
  # if the stash is missing or too short (e.g. this runs long after
  # install, once the KibaOS login password has since changed) -- the
  # old zenity --password loop simply can't happen here, and blocking a
  # backend process on input that can never arrive would just hang it
  # forever. Fall back to a freshly generated password instead, stashed
  # the same root-only, 0600 way as the original -- written back out
  # this time rather than consumed, so it can still be recovered later.
  if [ -z "${WIN_PASS}" ] || [ "${#WIN_PASS}" -lt 8 ]; then
    WIN_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
    NOTE="/etc/kibaos/winapps-password-note"
    ( umask 077; printf '%s\n' "${WIN_PASS}" > "${NOTE}" ) 2>/dev/null || true
    logger -t kibaos-winapps-setup "no reusable KibaOS password found -- generated a new Windows password, stashed root-only at ${NOTE}"
  fi
  # Rewritten line-by-line rather than with sed/awk substitution -- the
  # password can contain characters (/, &, \) that sed and awk both treat
  # as special in a replacement string, which would silently corrupt the
  # line for anyone whose password has one. printf '%s' never
  # reinterprets its argument, so this is the one substitution method
  # that's actually safe for an arbitrary password.
  COMPOSE_TMP="$(mktemp)"
  while IFS= read -r line; do
    if [[ "${line}" =~ ^([[:space:]]*)USERNAME:[[:space:]]* ]]; then
      printf '%sUSERNAME: "%s"\n' "${BASH_REMATCH[1]}" "${WIN_USER}"
    elif [[ "${line}" =~ ^([[:space:]]*)PASSWORD:[[:space:]]* ]]; then
      printf '%sPASSWORD: "%s"\n' "${BASH_REMATCH[1]}" "${WIN_PASS}"
    else
      printf '%s\n' "${line}"
    fi
  done < "${COMPOSE_FILE}" > "${COMPOSE_TMP}"
  mv "${COMPOSE_TMP}" "${COMPOSE_FILE}"
  # Default to Tiny11 rather than stock Windows 11 -- this box's whole
  # audience is "cheap/low-RAM laptop running KibaOS", and stock Win11
  # inside dockur/windows wants noticeably more RAM/disk headroom than
  # this hardware class tends to have to spare on top of the Linux host
  # itself. Only rewrites VERSION if the line exists in upstream's
  # compose.yaml as shipped -- if they ever restructure it, this just
  # quietly no-ops instead of corrupting the file.
  sed -i "s/^\([[:space:]]*VERSION:[[:space:]]*\).*/\1\"tiny11\"/" "${COMPOSE_FILE}"
  chmod 600 "${COMPOSE_FILE}"
fi

# GPU passthrough, auto-detected -- no user prompt for this, it either
# helps or it's a no-op. Only NVIDIA is handled: that's the only vendor
# WinApps' docker/podman backend can pass through today (via the NVIDIA
# Container Toolkit's CDI/legacy runtime), since it needs a driver stack
# installed *inside* the Windows guest anyway, which only NVIDIA ships in
# a form that works headless like this.
#
# Two separate checks, both required:
#   1. NVIDIA_HW (passed in) -- is there NVIDIA hardware at all, per the
#      unprivileged lspci check out in the caller.
#   2. docker info -- is the "nvidia" container runtime actually
#      registered, meaning the NVIDIA Container Toolkit is installed and
#      the proprietary driver is loaded on the host. Already running as
#      root in here, talking straight to the docker socket -- no pkexec
#      needed for this one either now.
# Hardware alone isn't enough: plenty of machines have an NVIDIA card
# sitting there on nouveau with no proprietary driver installed, and
# requesting a device reservation docker can't satisfy makes the whole
# "docker compose up" fail outright rather than just skip GPU passthrough.
echo "PROGRESS 30 Checking for GPU passthrough..."
COMPOSE_ARGS=(--file "${COMPOSE_FILE}")
GPU_DETECTED=0
if [ "${NVIDIA_HW}" -eq 1 ] && docker info 2>/dev/null | grep -qi 'nvidia'; then
  OVERRIDE_FILE="${CONF_DIR}/compose.override.yaml"
  cat > "${OVERRIDE_FILE}" << 'GPUOVERRIDE'
services:
  windows:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: ["gpu"]
GPUOVERRIDE
  COMPOSE_ARGS+=(--file "${OVERRIDE_FILE}")
  GPU_DETECTED=1
fi
# GPU_FLAG_FILE is how this one bit survives back out to the unprivileged
# caller -- it's needed much later (the final "All set!" message, after
# the RDP wait-poll and setup.sh both run unprivileged) and a variable
# set in here doesn't exist anymore once this script exits.
echo "${GPU_DETECTED}" > "${GPU_FLAG_FILE}"

# cd happens before docker compose runs, same reasoning as always: cwd
# is inherited across fork/exec, so this still lands docker compose in
# CONF_DIR (needed for the compose file's relative "./oem" mount).
echo "PROGRESS 35 Starting the Windows virtual machine..."
COMPOSE_LOG="$(mktemp)"
if ! ( cd "${CONF_DIR}" && docker compose "${COMPOSE_ARGS[@]}" up -d ) > "${COMPOSE_LOG}" 2>&1; then
  logger -t kibaos-winapps-setup "docker compose up -d failed: $(cat "${COMPOSE_LOG}")"
  rm -f "${COMPOSE_LOG}"
  echo "PROGRESS 100 Setup failed: Windows Workspace couldn't start -- nothing was changed permanently, retry from the app menu."
  echo "FATAL: Windows Workspace couldn't start -- nothing was changed permanently, retry from the app menu." >&2
  chown -R "${ORIG_USER}:${ORIG_USER}" "${CONF_DIR}" 2>/dev/null || true
  exit 1
fi
rm -f "${COMPOSE_LOG}"

# Everything under CONF_DIR was just written as root -- hand it back to
# the real account before this script exits, or the desktop session that
# reads compose.yaml/winapps.conf right after can't even open its own
# config files. The root-only password note under /etc/kibaos is
# deliberately NOT included in this -- that one's meant to stay root-only.
chown -R "${ORIG_USER}:${ORIG_USER}" "${CONF_DIR}" 2>/dev/null || true
PRIVILEGED
chmod +x "${PRIV_SCRIPT}"

# PROGRESS/FATAL lines the privileged script echoes above reach the
# frontend exactly the way every other line in this file does -- pkexec
# doesn't touch stdout/stderr, so they just flow straight through.
pkexec bash "${PRIV_SCRIPT}" "${CONF_DIR}" "${COMPOSE_FILE}" "${NVIDIA_HW}" "${ORIG_USER}" "${GPU_FLAG_FILE}"
PRIV_STATUS=$?
rm -f "${PRIV_SCRIPT}"
if [ "${PRIV_STATUS}" -eq 126 ] || [ "${PRIV_STATUS}" -eq 127 ]; then
  # pkexec's own failure codes for "authentication wasn't completed" (the
  # dialog was dismissed/cancelled) or "couldn't even run the command" --
  # in both cases the privileged script never got to run, so it never
  # got a chance to print its own FATAL: line. This is the one failure
  # mode that still needs one from out here.
  rm -f "${GPU_FLAG_FILE}"
  fail "Windows Workspace setup needs administrator access to continue -- retry from the app menu when you're ready to authenticate."
elif [ "${PRIV_STATUS}" -ne 0 ]; then
  # Any other nonzero status means the privileged script itself ran and
  # hit a real problem -- it already logged specifics and printed its
  # own PROGRESS 100/FATAL: pair above, so there's nothing left to add;
  # just stop.
  rm -f "${GPU_FLAG_FILE}"
  exit "${PRIV_STATUS}"
fi
GPU_DETECTED="$(cat "${GPU_FLAG_FILE}" 2>/dev/null || echo 0)"
rm -f "${GPU_FLAG_FILE}"

# No chromium launch here on purpose. Opening a browser window is a UI
# concern that belongs to whatever's driving this backend, not something
# a headless process should do on its own -- kibaos-winapps-workspace
# already opens the noVNC console itself once winapps.conf exists below.

# Source of truth for credentials from here on is compose.yaml itself,
# not a fresh random generation -- keeps this idempotent if setup gets
# re-run after a partial failure. The container (and whatever account is
# actually inside it) may already exist from a prior attempt, and
# regenerating a new password here would just desync from it.
progress 40 "Reading Windows account details..."
WIN_USER=$(grep -oP '^\s*USERNAME:\s*"\K[^"]+' "${COMPOSE_FILE}")
WIN_PASS=$(grep -oP '^\s*PASSWORD:\s*"\K[^"]+' "${COMPOSE_FILE}")

if [ -z "${WIN_USER}" ] || [ -z "${WIN_PASS}" ]; then
  fail "Couldn't read the Windows account details back out of compose.yaml."
fi

progress 45 "Writing Windows Workspace configuration..."
cat > "${CONF_DIR}/winapps.conf" << CONF
RDP_USER="${WIN_USER}"
RDP_PASS="${WIN_PASS}"
RDP_IP="127.0.0.1"
RDP_PORT="3389"
WAFLAVOR="docker"
DEBUG="true"
# /gfx:AVC444 switches FreeRDP onto the H.264 graphics pipeline instead of
# the legacy bitmap codec -- this is the single biggest lag fix, especially
# for anything Photoshop/video-editing-shaped. /network:lan tells FreeRDP
# this is a fast local link (it is: loopback to a container) rather than
# throttling itself as if it were a WAN connection. Baked in here rather
# than left as a README tweak, since there's no real reason for a user to
# ever want the slower defaults on a local install.
RDP_FLAGS="/gfx:AVC444 /network:lan"
CONF
chmod 600 "${CONF_DIR}/winapps.conf"

# Wait for the unattended install to actually finish -- this is a real
# Windows install (download + setup), not a quick boot, so budget up to
# ~35 minutes rather than the couple of minutes an already-installed VM
# would need to just bring RDP up after a restart. An open RDP port is
# used as the "Windows is ready" signal since there's no other clean
# hook into dockur/windows' unattended install process from out here.
# Progress ticks every ~30s (every 6th 5s poll) rather than on every
# single poll -- PROGRESS lines are meant to mark real movement for
# whatever's reading them, not flood the pipe with 420 near-identical
# updates over up to 35 minutes.
progress 50 "Waiting for Windows to finish installing (this can take up to 35 minutes)..."
RDP_UP=0
for i in $(seq 1 420); do
  nc -z 127.0.0.1 3389 >/dev/null 2>&1 && { RDP_UP=1; break; }
  sleep 5
  if [ $((i % 6)) -eq 0 ]; then
    progress "$((50 + i * 35 / 420))" "Still waiting for Windows to finish installing..."
  fi
done

if [ "${RDP_UP}" -ne 1 ]; then
  fail "Windows is taking longer than expected to finish installing -- nothing's broken, just re-run this to pick up where it left off."
fi

# Runs setup.sh synchronously -- with nowhere to render a progress dialog
# anyway, there's no reason left to background it behind one. Full output
# is still captured to SETUP_LOG and, on failure, forwarded to the system
# log via logger for anyone who does need to dig in.
progress 85 "Setting up your Windows app shortcuts..."
SETUP_LOG="$(mktemp)"
if ! "${WINAPPS_SRC}/setup.sh" --user --setupAllOfficiallySupportedApps > "${SETUP_LOG}" 2>&1; then
  logger -t kibaos-winapps-setup "app shortcut setup failed: $(cat "${SETUP_LOG}")"
  rm -f "${SETUP_LOG}"
  fail "Windows itself is all set up and ready to go, but hooking up the individual app shortcuts hit a snag -- re-run this to retry just that step."
fi
rm -f "${SETUP_LOG}"

rm -f "${MARKER}"
if [ "${GPU_DETECTED}" -eq 1 ]; then
  progress 100 "All set! An NVIDIA GPU was detected and passed through to Windows for faster, hardware-accelerated apps."
else
  progress 100 "All set!"
fi
exit 0
WINAPPSSETUP
chmod +x /usr/local/bin/kibaos-winapps-setup

# Menu entry so this is re-runnable any time, not just at first login
# (e.g. if someone skips it initially, or wants to fix a broken setup).
# Points at io.kibaos.winapps-setup (built above alongside the OOBE app)
# rather than the raw backend script directly -- running the headless
# script straight from a .desktop entry would mean PROGRESS/FATAL lines
# with nowhere to go and no visible feedback at all.
cat > /usr/share/applications/kibaos-winapps-setup.desktop << 'SETUPDESKTOP'
[Desktop Entry]
Type=Application
Name=Set Up Windows Workspace
Comment=Set up Windows so you can run Windows programs, like Office, right from KibaOS
Icon=kibaos-winapps
Exec=/usr/bin/io.kibaos.winapps-setup
Terminal=false
Categories=System;Settings;
SETUPDESKTOP

# First-login autostart: only actually shows anything if the marker from
# kibaos-oobe-backend / kibaos-oem-finish.sh is present, which it always
# is now (WinApps is a mandatory feature, not opt-in). Same gating style
# as the OEM-finish entry above -- also updated to launch the GUI wrapper
# rather than the headless backend directly, same reasoning as the menu
# entry above.
cat > "${SKEL}/.config/autostart/kibaos-winapps-firstrun.desktop" << 'WINAPPSAUTOCFG'
[Desktop Entry]
Type=Application
Name=Windows Workspace Setup
Exec=sh -c 'test -f /etc/kibaos/winapps-pending && exec /usr/bin/io.kibaos.winapps-setup'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
WINAPPSAUTOCFG

# ── Live-session autostart: launches the OOBE installer automatically on
# the regular live boot (the 'liveuser' autologin session), so the person
# lands straight in the installer instead of staring at an empty desktop.
# gated to liveuser specifically (via `whoami`) so this never fires after
# a real install, on the OEM-finish account (which has its own autostart
# entry above), or on any other account this .config/autostart skeleton
# ends up getting copied into down the line. ────────────────────────────
cat > "${SKEL}/.config/autostart/kibaos-install-launch.desktop" << 'LIVELAUNCH'
[Desktop Entry]
Type=Application
Name=KibaOS Installer
Exec=sh -c '[ "$(whoami)" = "liveuser" ] && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
LIVELAUNCH

mkdir -p /etc/systemd/zram-generator.conf.d
cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

mkdir -p "${SKEL}/.config"

mkdir -p "${SKEL}/.config/fontconfig"
cat > "${SKEL}/.config/fontconfig/fonts.conf" << 'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>
  <alias>
    <family>sans-serif</family>
    <prefer><family>Noto Sans</family></prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer><family>Noto Sans Mono</family></prefer>
  </alias>
</fontconfig>
FONTCONF

cat > "${SKEL}/.config/electron-flags.conf" << 'ELECTRONFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
--enable-wayland-ime
ELECTRONFLAGS

cat > "${SKEL}/.config/chrome-flags.conf" << 'CHROMEFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHROMEFLAGS

cat > "${SKEL}/.config/autostart/polkit-agent.desktop" << 'POLKIT'
[Desktop Entry]
Type=Application
Name=Polkit Authentication Agent
Exec=/usr/lib/polkit-kde-authentication-agent-1
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
POLKIT

cat > "${SKEL}/.bashrc" << 'BASHRC'
[[ $- != *i* ]] && return
PS1='\[\e[1;36m\][KibaOS]\[\e[0m\] \[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias grep='grep --color=auto'
alias install='io.kibaos.oobe'
alias update='sudo kiba update'
fastfetch 2>/dev/null || true
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export HISTFILE="$XDG_STATE_HOME/bash/history"
BASHRC

mkdir -p "${SKEL}/.config/fastfetch"
cat > "${SKEL}/.config/fastfetch/config.jsonc" << 'FFCONF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "source": "kibaos",
    "color": { "1": "cyan", "2": "white" },
    "padding": { "top": 1 }
  },
  "display": { "separator": "  ", "color": { "keys": "cyan" } },
  "modules": [
    { "type": "title",  "format": "{user-name-colored}@{host-name-colored}" },
    "separator",
    { "type": "os",     "key": "OS" },
    { "type": "kernel", "key": "Kernel" },
    { "type": "de",     "key": "Desktop" },
    { "type": "wm",     "key": "WM" },
    { "type": "shell",  "key": "Shell" },
    { "type": "cpu",    "key": "CPU" },
    { "type": "gpu",    "key": "GPU" },
    { "type": "memory", "key": "Memory" },
    { "type": "disk",   "key": "Disk" },
    "break",
    { "type": "colors", "paddingLeft": 0 }
  ]
}
FFCONF

cp -aT "${SKEL}/" /home/liveuser/
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser

# ── No firewall package on KibaOS ──────────────────────────────────────────
# ufw used to be in here, but its packaging hooks just don't behave
# inside this chroot build container, and it goes beyond just the
# `ufw enable` CLI call (confirmed — removing that one call wasn't even
# enough, something in ufw's own systemd-enable-time hooks still tries a
# /proc-dependent SSH-detection check and fails the same way, since
# there's no real /proc in this build environment). rather than keep
# fighting a third-party tool's chroot incompatibility for a
# build-time-only step that was never going to filter live traffic
# anyway, ufw's just gone entirely now. so KibaOS currently ships with no
# firewall configured by default — worth coming back to eventually (maybe
# straight nftables, or a different frontend) if network-facing hardening
# ever becomes a priority, but it's not a build-blocking concern for a
# desktop live/install image the way it'd be for a server image.

# ══════════════════════════════════════════════════════════════════════════
# WELCOME APP - Install KibaOS welcome application
mkdir -p /usr/local/bin
mkdir -p /usr/share/kibaos-welcome

# Update GTK_THEME in environment to use KibaOS
sed -i 's/GTK_THEME=Adwaita-dark/GTK_THEME=KibaOS/' /etc/environment

# DESKTOP SHORTCUTS
# ══════════════════════════════════════════════════════════════════════════
mkdir -p /usr/share/applications /etc/skel/Desktop /etc/skel/Documents \
         /etc/skel/Downloads /etc/skel/Pictures /etc/skel/Music /etc/skel/Videos
cat > /etc/skel/.config/user-dirs.dirs << 'USERDIRS'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_MUSIC_DIR="$HOME/Music"
XDG_VIDEOS_DIR="$HOME/Videos"
USERDIRS

# ── "Files" launcher: opens Nemo straight into $HOME ────────────────────
# Nemo's own .desktop entry can't be edited in place without fighting
# future package updates, so this ships a separate launcher that's used
# everywhere a "Files" icon is needed instead (pinned dock slot, app
# menu) -- Exec= field codes don't expand $HOME, so it's a one-line
# wrapper script rather than a raw Exec= path.
cat > /usr/local/bin/kibaos-files << 'FILESWRAP'
#!/bin/bash
exec nemo "$HOME"
FILESWRAP
chmod +x /usr/local/bin/kibaos-files

cat > /usr/share/applications/kibaos-files.desktop << 'FILESDESK'
[Desktop Entry]
Type=Application
Name=Files
Comment=Browse your documents, downloads, and other files
Icon=nemo
Exec=/usr/local/bin/kibaos-files
Terminal=false
NoDisplay=false
Categories=System;FileTools;FileManager;
FILESDESK

# ── Nemo/GTK sidebar bookmarks: a clean "quick access" list ────────────────
# Windows' C:\Users\<name> feels tidy because Explorer's nav pane only
# ever shows Desktop/Documents/Downloads/Pictures/Music/Videos plus the
# user's own Home — everything else (our AppData-equivalent: ~/.config,
# ~/.local, ~/.cache) is already hidden by the leading dot, same deal as
# AppData being hidden by its own attribute on Windows. this seeds that
# same short, fixed list into Nemo's sidebar on first login, nothing
# more — no stray "Other Locations"/raw filesystem browsing sitting front
# and center.
#
# heads up: this can't just be a static /etc/skel file — GTK bookmark
# files are plain file:// URIs with zero variable expansion, and skel
# gets copied byte-for-byte at account creation before the real username
# even exists. so instead this runs once per new user via a first-login
# script gated on a marker file, using a real $HOME at the moment it
# actually runs.
mkdir -p /etc/skel/.config/autostart
cat > /usr/local/bin/kibaos-first-login-setup << 'FIRSTLOGIN'
#!/bin/bash
MARKER="$HOME/.config/.kibaos-first-login-done"
[ -f "$MARKER" ] && exit 0
mkdir -p "$HOME/.config/gtk-3.0"
cat > "$HOME/.config/gtk-3.0/bookmarks" << BOOKMARKS
file://$HOME/Desktop Desktop
file://$HOME/Documents Documents
file://$HOME/Downloads Downloads
file://$HOME/Pictures Pictures
file://$HOME/Music Music
file://$HOME/Videos Videos
BOOKMARKS
mkdir -p "$HOME/.config"
touch "$MARKER"
FIRSTLOGIN
chmod +x /usr/local/bin/kibaos-first-login-setup

cat > /etc/skel/.config/autostart/kibaos-first-login-setup.desktop << 'FIRSTLOGINDESK'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login-setup
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
FIRSTLOGINDESK

# ══════════════════════════════════════════════════════════════════════════
# KIBAPKG — friendly libalpm-backed package manager, invoked as `kiba`
# ══════════════════════════════════════════════════════════════════════════
# Talks to libalpm directly via pyalpm (no shelling out to pacman), and
# translates its transaction/event callbacks into plain-language status
# lines instead of pacman's raw resolver/conflict/signature jargon. Reads
# repo names + mirror servers straight from pacman.conf/mirrorlist so it
# stays in sync with whatever the system is actually configured to use.
mkdir -p /usr/share/kibapkg
cat > /usr/share/kibapkg/kibapkg.py << 'KIBAPKG'
#!/usr/bin/env python3
"""kibapkg — a friendly front-end to libalpm (via pyalpm) for KibaOS.
Invoked as `kiba`. Talks to libalpm directly; never shells out to pacman."""
import os
import re
import sys
import pyalpm

ROOT = "/"
DBPATH = "/var/lib/pacman"
PACMAN_CONF = "/etc/pacman.conf"
MIRRORLIST = "/etc/pacman.d/mirrorlist"


def die(msg):
    print(f"kiba: {msg}")
    sys.exit(1)


def need_root():
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable, __file__] + sys.argv[1:])


def active_mirrors(limit=5):
    mirrors = []
    if os.path.exists(MIRRORLIST):
        with open(MIRRORLIST) as f:
            for line in f:
                line = line.strip()
                if line.startswith("Server"):
                    url = line.split("=", 1)[1].strip()
                    mirrors.append(url)
                    if len(mirrors) >= limit:
                        break
    return mirrors


def repo_names():
    repos = []
    if os.path.exists(PACMAN_CONF):
        with open(PACMAN_CONF) as f:
            for line in f:
                m = re.match(r"^\[(\w+)\]$", line.strip())
                if m and m.group(1) != "options":
                    repos.append(m.group(1))
    return repos or ["core", "extra", "multilib"]


def make_handle():
    h = pyalpm.Handle(ROOT, DBPATH)
    mirrors = active_mirrors()
    for repo in repo_names():
        db = h.register_syncdb(repo, pyalpm.SIG_DATABASE_OPTIONAL)
        db.servers = [m.replace("$repo", repo).replace("$arch", os.uname().machine) for m in mirrors]
    return h


def cb_event(*_):
    pass  # kept silent on purpose — kiba prints its own plain-language status


def run_transaction(h, build_trans, verb):
    h.dlcb = lambda name, xfered, total: None
    h.eventcb = cb_event
    t = h.init_transaction()
    try:
        build_trans(h, t)
        t.prepare()
        if not t.to_add and not t.to_remove:
            print(f"kiba: nothing to {verb}.")
            t.release()
            return
        for pkg in t.to_add:
            print(f"  + {pkg.name} {pkg.version}")
        for pkg in t.to_remove:
            print(f"  - {pkg.name} {pkg.version}")
        t.commit()
        print(f"kiba: {verb} complete.")
    except pyalpm.error as e:
        print(f"kiba: couldn't {verb} that — {e}")
        sys.exit(1)
    finally:
        try:
            t.release()
        except Exception:
            pass


def cmd_search(h, terms):
    seen = set()
    for db in h.get_syncdbs():
        for pkg in db.search(terms):
            if pkg.name not in seen:
                seen.add(pkg.name)
                print(f"{pkg.name:<28} {pkg.version:<16} {pkg.desc}")


def cmd_list(h):
    for pkg in h.get_localdb().pkgcache:
        print(f"{pkg.name:<28} {pkg.version}")


def cmd_info(h, name):
    pkg = h.get_localdb().get_pkg(name)
    source = "installed"
    if pkg is None:
        for db in h.get_syncdbs():
            pkg = db.get_pkg(name)
            if pkg:
                source = f"available in {db.name}"
                break
    if pkg is None:
        die(f"no package named '{name}'")
    print(f"{pkg.name}  {pkg.version}  ({source})")
    print(pkg.desc)


def cmd_install(h, names):
    def build(h, t):
        for name in names:
            pkg = None
            for db in h.get_syncdbs():
                pkg = db.get_pkg(name)
                if pkg:
                    break
            if pkg is None:
                die(f"no package named '{name}'")
            t.add_pkg(pkg)
    run_transaction(h, build, "install")


def cmd_remove(h, names):
    def build(h, t):
        for name in names:
            pkg = h.get_localdb().get_pkg(name)
            if pkg is None:
                die(f"'{name}' isn't installed")
            t.remove_pkg(pkg)
    run_transaction(h, build, "remove")


def cmd_update(h):
    def build(h, t):
        for db in h.get_syncdbs():
            db.update(force=False)
        h.sysupgrade(downgrade=False)
    run_transaction(h, build, "update")


HELP = """kiba — the KibaOS package manager

  kiba install <name...>   install one or more apps
  kiba remove  <name...>   remove one or more apps
  kiba update              update everything
  kiba search  <term>      search for an app
  kiba list                list installed apps
  kiba info    <name>      show details about an app
"""


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(HELP)
        return
    cmd, rest = args[0], args[1:]
    if cmd in ("install", "remove", "update"):
        need_root()
    h = make_handle()
    if cmd == "install" and rest:
        cmd_install(h, rest)
    elif cmd == "remove" and rest:
        cmd_remove(h, rest)
    elif cmd == "update":
        cmd_update(h)
    elif cmd == "search" and rest:
        cmd_search(h, rest)
    elif cmd == "list":
        cmd_list(h)
    elif cmd == "info" and rest:
        cmd_info(h, rest[0])
    else:
        print(HELP)


if __name__ == "__main__":
    main()
KIBAPKG
chmod +x /usr/share/kibapkg/kibapkg.py
ln -sf /usr/share/kibapkg/kibapkg.py /usr/local/bin/kiba
ln -sf /usr/share/kibapkg/kibapkg.py /usr/local/bin/kibapkg

# ══════════════════════════════════════════════════════════════════════════
# PACMAN SHIM — `pacman` becomes a thin dispatcher in front of kiba
# ══════════════════════════════════════════════════════════════════════════
# The real pacman binary gets moved aside (NOT removed -- libalpm itself
# isn't touched, and kibapkg already never called the pacman binary
# anyway, it's pyalpm straight to libalpm) and /usr/bin/pacman becomes a
# small dispatcher script instead.
#
# What it does NOT do: try to reimplement pacman's CLI. That's a losing
# game -- makepkg, DKMS's pacman hooks, and any AUR helper all
# shell out to pacman with exact flag combinations and, in some cases,
# parse its stdout for specific fields. Silently rewriting any of that
# output format would break real tooling for a cosmetic win, which isn't
# a trade worth making.
#
# So the dispatcher only intercepts when BOTH are true:
#   1. stdout is a real terminal (a human is sitting at it, not a script
#      capturing output through a pipe or the DKMS/makepkg machinery)
#   2. the arguments exactly match one of a short list of common,
#      simple, interactively-typed invocations (pacman -S foo, -Syu,
#      -Ss term, etc.)
# Anything else -- any flag combo not on the list, any non-interactive
# invocation, `-U` for local package files, `-T` dependency checks,
# `--asdeps`, multiple mixed flags, whatever makepkg/DKMS actually use --
# execs the real binary with the ORIGINAL argv, completely unmodified.
# The net effect: someone typing `pacman -S firefox` out of habit gets
# kiba's plain-language output; every script, hook, and build tool on the
# system keeps talking to the genuine pacman/libalpm exactly as before,
# because from their side nothing changed.
echo "=== Installing pacman shim (real pacman -> /usr/lib/kibaos/pacman-real) ==="
mkdir -p /usr/lib/kibaos
if [ -f /usr/bin/pacman ] && [ ! -f /usr/lib/kibaos/pacman-real ]; then
  mv /usr/bin/pacman /usr/lib/kibaos/pacman-real
fi

cat > /usr/bin/pacman << 'PACMANSHIM'
#!/usr/bin/env bash
# pacman shim -- see the build-script comment above this heredoc for the
# full design rationale (tty check, exact-match allowlist, fallback).
# KIBAOS_REAL_PACMAN=1 is the documented escape hatch: set it to always
# get the genuine binary regardless of how this is invoked.
REAL=/usr/lib/kibaos/pacman-real

if [ -n "${KIBAOS_REAL_PACMAN:-}" ] || [ ! -t 1 ]; then
  exec "${REAL}" "$@"
fi

# Bail to the real binary the instant anything looks like more than a
# bare "flag + plain package names/terms" -- any additional flag anywhere
# (--noconfirm, --asdeps, --needed, whatever) means this came from a
# script, not someone typing at a prompt, so don't touch it.
rest=("$@"); rest=("${rest[@]:1}")
for a in "${rest[@]}"; do
  case "${a}" in -*) exec "${REAL}" "$@" ;; esac
done

case "$1" in
  -S|--sync)
    [ "${#rest[@]}" -ge 1 ] || exec "${REAL}" "$@"
    exec kiba install "${rest[@]}" ;;
  -R|--remove)
    [ "${#rest[@]}" -ge 1 ] || exec "${REAL}" "$@"
    exec kiba remove "${rest[@]}" ;;
  -Syu|-Syyu)
    [ "${#rest[@]}" -eq 0 ] || exec "${REAL}" "$@"
    exec kiba update ;;
  -Ss|--search)
    [ "${#rest[@]}" -ge 1 ] || exec "${REAL}" "$@"
    exec kiba search "${rest[@]}" ;;
  -Qi)
    [ "${#rest[@]}" -eq 1 ] || exec "${REAL}" "$@"
    exec kiba info "${rest[0]}" ;;
  -Q|--query)
    [ "${#rest[@]}" -eq 0 ] || exec "${REAL}" "$@"
    exec kiba list ;;
  *)
    exec "${REAL}" "$@" ;;
esac
PACMANSHIM
chmod +x /usr/bin/pacman
echo "=== pacman shim installed ==="

cat > /usr/share/applications/kibaos-install.desktop << 'INSTDESK'
[Desktop Entry]
Name=Install KibaOS
Comment=Install KibaOS to your hard drive
Exec=/usr/bin/io.kibaos.oobe
Icon=kibaos
Terminal=false
Type=Application
Categories=System;
Keywords=install;setup;kibaos;
INSTDESK

cat > /usr/share/applications/kibaos-about.desktop << 'ABOUTDESK'
[Desktop Entry]
Name=About KibaOS
Comment=Learn more about KibaOS
Exec=xdg-open https://github.com/WolfTech-Innovations/Kiba
Icon=kibaos
Terminal=false
Type=Application
Categories=System;
ABOUTDESK

# ── Hide Avahi network browser (avahi-discover / avahi-ui-tools) ──────────
# avahi drags in a "Network Browser" launcher nobody needs in the app
# grid. override both avahi-discover and bssh/bvnc's desktop files with
# NoDisplay so they stop showing up.
for _avahi_desk in avahi-discover bssh bvnc; do
  if [ -f "/usr/share/applications/${_avahi_desk}.desktop" ]; then
    cp "/usr/share/applications/${_avahi_desk}.desktop" \
       "/usr/share/applications/${_avahi_desk}.desktop.bak" 2>/dev/null || true
    printf '[Desktop Entry]\nNoDisplay=true\n' \
      >> "/usr/share/applications/${_avahi_desk}.desktop"
  fi
done

# ── Hide gnome-terminal from the app launcher / shortcuts ─────────────────
# terminal's still reachable via right-click and other paths, just don't
# want it pinned or sitting visible in the main shortcut list.
if [ -f "/usr/share/applications/org.gnome.Terminal.desktop" ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' \
      "/usr/share/applications/org.gnome.Terminal.desktop" || true
  grep -q '^NoDisplay=' "/usr/share/applications/org.gnome.Terminal.desktop" \
    || echo 'NoDisplay=true' >> "/usr/share/applications/org.gnome.Terminal.desktop"
fi

# ── Hide budgie-control-center from the app launcher ───────────────────────
# gets pulled in transitively as a dependency of the budgie package
# group, so can't just remove it without risking breaking budgie itself
# — but it's superseded by the visible Settings app below, so just keep
# it out of the menu instead. budgie-desktop-settings (the separate
# panel/applet-layout configurator) is the same story — GNOME Settings
# is the one and only settings entry point users should see.
for _bcc_desk in budgie-control-center.desktop \
                 org.buddiesofbudgie.BudgieControlCenter.desktop \
                 budgie-desktop-settings.desktop \
                 org.buddiesofbudgie.BudgieDesktopSettings.desktop; do
  if [ -f "/usr/share/applications/${_bcc_desk}" ]; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/${_bcc_desk}" || true
    grep -q '^NoDisplay=' "/usr/share/applications/${_bcc_desk}" \
      || echo 'NoDisplay=true' >> "/usr/share/applications/${_bcc_desk}"
  fi
done

# ── Hide dev/power-user tooling that has no business in a consumer app menu
# Kvantum Manager (Qt theme engine config, pulled in as a Qt/KDE-lib dep),
# Sysprof (system profiler), GNOME Extensions (Budgie doesn't run
# gnome-shell extensions, this is a stray dep of some GNOME component),
# qv4l2/qvidcap (the v4l-utils Qt test/capture utilities — camera driver
# debugging tools, not something an end user should stumble into),
# tuned-gui (the tuned power-profile daemon's own GUI — tuned itself stays
# enabled as a service, just the standalone control panel is redundant now
# that power profile switching lives in Settings), and lstopo (hwloc's
# hardware-topology visualizer). all several candidate desktop-file names
# are covered since exact IDs drift across distro packaging.
for _hidden_desk in kvantummanager.desktop \
                     org.gnome.Sysprof.desktop \
                     sysprof.desktop \
                     sysprof4.desktop \
                     org.gnome.Extensions.desktop \
                     com.github.hedges.gnome-extensions.desktop \
                     qv4l2.desktop \
                     qvidcap.desktop \
                     tuned-gui.desktop \
                     tuned-adm-gui.desktop \
                     lstopo.desktop \
                     hwloc.desktop; do
  if [ -f "/usr/share/applications/${_hidden_desk}" ]; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/${_hidden_desk}" || true
    grep -q '^NoDisplay=' "/usr/share/applications/${_hidden_desk}" \
      || echo 'NoDisplay=true' >> "/usr/share/applications/${_hidden_desk}"
  fi
done

# ── Rename gnome-control-center to "Settings" ───────────────────────────────
# plain upstream GNOME Settings here, not the Budgie fork -- current
# libadwaita builds use the sidebar+search layout, which reads a lot
# closer to macOS System Settings than budgie-control-center's older
# layout does. upstream's desktop file already calls it "Settings" in
# most locales, but strip the localised Name[xx]= lines anyway so a
# non-English locale can't override the label — matching the other
# rebrands in this block.
for _gcc_desk in gnome-control-center.desktop \
                 org.gnome.Settings.desktop; do
  if [ -f "/usr/share/applications/${_gcc_desk}" ]; then
    sed -i 's/^Name=.*/Name=Settings/' "/usr/share/applications/${_gcc_desk}" || true
    sed -i '/^Name\[/d' "/usr/share/applications/${_gcc_desk}" || true
  fi
done

# gnome-control-center registers each panel as its own (usually
# NoDisplay) .desktop file just for search indexing (e.g.
# "gnome-wifi-panel.desktop" launches `gnome-control-center wifi`). a
# few of those panels are GNOME-Shell-specific and don't mean anything
# under KWin/Budgie, so hide them from search too. this list is a
# best-effort starting point based on current upstream panel naming --
# check `ls /usr/share/applications/gnome-*-panel.desktop` on a built
# image and extend/trim as needed, since the exact panel-desktop-id
# naming does shift between GNOME releases.
for _panel_desk in gnome-multitasking-panel.desktop \
                    gnome-search-panel.desktop \
                    gnome-wwan-panel.desktop \
                    gnome-online-accounts-panel.desktop; do
  if [ -f "/usr/share/applications/${_panel_desk}" ]; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/${_panel_desk}" || true
    grep -q '^NoDisplay=' "/usr/share/applications/${_panel_desk}" \
      || echo 'NoDisplay=true' >> "/usr/share/applications/${_panel_desk}"
  fi
done

# ── Rename GNOME Software so it doesn't expose the "gnome-software"/Flathub
# plumbing in its name; consumers should just see "App Store".
for _sw_desk in org.gnome.Software.desktop; do
  if [ -f "/usr/share/applications/${_sw_desk}" ]; then
    sed -i 's/^Name=.*/Name=App Store/' "/usr/share/applications/${_sw_desk}" || true
    sed -i '/^Name\[/d' "/usr/share/applications/${_sw_desk}" || true
  fi
done

# ── Hide the raw NetworkManager connection editor (nm-connection-editor) —
# advanced tabs (802.1x, bonding, IPv6 routing metrics) are pure plumbing
# for a consumer OS; Wi-Fi/wired toggling stays exposed via the panel applet.
if [ -f "/usr/share/applications/nm-connection-editor.desktop" ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/nm-connection-editor.desktop" || true
  grep -q '^NoDisplay=' "/usr/share/applications/nm-connection-editor.desktop" \
    || echo 'NoDisplay=true' >> "/usr/share/applications/nm-connection-editor.desktop"
fi

# ── Hide cmake-gui from the app launcher ───────────────────────────────────
# leftover safety net: cmake used to get pulled into this chroot to
# compile labwc-plugins-extra from source, and Arch's cmake package
# drags a cmake-gui.desktop entry along with it -- no business showing up
# in a consumer app menu. cmake isn't installed in the image at all
# anymore now that that build's gone (see where labwc IPC used to be),
# so this if-check is realistically dead code today. leaving it in
# anyway in case cmake ever ends up pulled in here again for something
# else later -- costs nothing to keep, and it's a lot cheaper than
# forgetting to add it back.
if [ -f "/usr/share/applications/cmake-gui.desktop" ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/cmake-gui.desktop" || true
  grep -q '^NoDisplay=' "/usr/share/applications/cmake-gui.desktop" \
    || echo 'NoDisplay=true' >> "/usr/share/applications/cmake-gui.desktop"
fi

# ── Disable Magic SysRq — a raw kernel-debugging keyboard backdoor that has
# no business being reachable from a consumer desktop.
echo 'kernel.sysrq = 0' > /etc/sysctl.d/50-kibaos-disable-sysrq.conf

# ── Restrict virtual-terminal switching: Ctrl+Alt+F2 etc. are handled by
# the kernel's VT layer, not the compositor, so this can't be blocked
# from KWin config no matter what. instead, remove what's waiting on
# the other VTs — cap logind to one auto-spawned VT and mask the extra
# getty units, so Ctrl+Alt+F2-F6 land on an empty console with no login
# prompt to even reach.
grep -q '^NAutoVTs' /etc/systemd/logind.conf \
  && sed -i 's/^NAutoVTs=.*/NAutoVTs=1/' /etc/systemd/logind.conf \
  || echo 'NAutoVTs=1' >> /etc/systemd/logind.conf
systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service \
                getty@tty5.service getty@tty6.service

# ── De-brand Chromium: keep the engine (site/extension/DRM compatibility),
# strip the corporate name/icon so it doesn't read as "Google Chromium" in
# the app grid. Icon is swapped for a flat single-color glyph consistent
# with the rest of the KibaOS icon set.
for _chromium_desk in chromium.desktop; do
  if [ -f "/usr/share/applications/${_chromium_desk}" ]; then
    sed -i 's/^Name=.*/Name=Browser/' "/usr/share/applications/${_chromium_desk}" || true
    sed -i '/^Name\[/d' "/usr/share/applications/${_chromium_desk}" || true
    sed -i 's/^Icon=.*/Icon=kibaos-browser/' "/usr/share/applications/${_chromium_desk}" || true
  fi
done

mkdir -p /home/liveuser/Desktop
for src_desktop in kibaos-install kibaos-about; do
  cp "/usr/share/applications/${src_desktop}.desktop" \
     "/home/liveuser/Desktop/${src_desktop}.desktop" 2>/dev/null || true
  chmod +x "/home/liveuser/Desktop/${src_desktop}.desktop" 2>/dev/null || true
done


# ══════════════════════════════════════════════════════════════════════════
# SYSTEM ENVIRONMENT
# ══════════════════════════════════════════════════════════════════════════
cat > /etc/environment << 'ENV'
DESKTOP_SESSION=Budgie
XDG_CURRENT_DESKTOP=Budgie
XDG_SESSION_DESKTOP=Budgie
XDG_SESSION_TYPE=wayland
KWIN_FORCE_SW_CURSOR=1
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
CLUTTER_BACKEND=wayland
SDL_VIDEODRIVER=wayland
KIBAOS_VERSION=rolling
KIBAOS_VENDOR="Kiba Labs, LLC"
ENV

cat > /etc/issue << 'ISSUE'

  ██╗  ██╗██╗██████╗  █████╗  ██████╗ ███████╗
  ██║ ██╔╝██║██╔══██╗██╔══██╗██╔═══██╗██╔════╝
  █████╔╝ ██║██████╔╝███████║██║   ██║███████╗
  ██╔═██╗ ██║██╔══██╗██╔══██║██║   ██║╚════██║
  ██║  ██╗██║██████╔╝██║  ██║╚██████╔╝███████║
  ╚═╝  ╚═╝╚═╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝

  KibaOS by Kiba Labs
  Live session: user=liveuser  password=live
  Install: click the desktop icon or run  install

ISSUE

cat > /etc/motd << 'MOTD'
Welcome to KibaOS
MOTD

# ── Time sync ──────────────────────────────────────────────────────────────
# Configure timesyncd with fast NTP pools so the RTC gets corrected
# immediately on first boot rather than slewing for minutes/hours.
mkdir -p /etc/systemd/
cat > /etc/systemd/timesyncd.conf << 'TIMESYNCD'
[Time]
NTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org time.cloudflare.com time.google.com
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=1024
TIMESYNCD

# Force RTC to UTC (matches hwclock.conf) and enable sync
timedatectl set-local-rtc 0 2>/dev/null || true
systemctl enable systemd-timesyncd
# NOT systemd-time-wait-sync: that unit exists to BLOCK boot until the
# first NTP sync completes -- built for servers that need a guaranteed
# clock before continuing, not a consumer desktop. timesyncd above already
# syncs the clock in the background with zero boot-time cost; wait-sync
# would instead add a real (sometimes multi-second, sometimes a full
# timeout on a flaky/offline network) delay to every single boot for no
# benefit a desktop actually needs.

systemctl enable gdm

# ── Network stack: NetworkManager ───────────────────────────────────────
# Back on NetworkManager (handles Wi-Fi/wired/DNS itself, no separate
# systemd-networkd/resolved wiring needed). Budgie's built-in network
# indicator and nm-applet both talk to NM natively, so no custom panel
# applet is needed either.
systemctl enable NetworkManager

# ── DNS: hardcode Cloudflare (1.1.1.1 / 1.0.0.1) ─────────────────────────
# NetworkManager manages /etc/resolv.conf itself by default and will
# happily overwrite it with whatever DNS servers the DHCP lease hands
# out — flaky router/ISP resolvers are what caused the resolve errors.
# Tell NM to keep its hands off resolv.conf, then write it ourselves so
# DNS always points straight at Cloudflare.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/dns.conf << 'NMDNS'
[main]
dns=none
NMDNS

# ── Boot-time DNS pin ─────────────────────────────────────────────────────
# Runs every boot, live or installed, and forces /etc/resolv.conf back to
# a single "nameserver 1.1.1.1" line before anything else comes up.
cat > /usr/local/bin/kibaos-boot-dns << 'BOOTDNS'
#!/bin/bash
echo "nameserver 1.1.1.1" > /etc/resolv.conf
BOOTDNS
chmod +x /usr/local/bin/kibaos-boot-dns

cat > /etc/systemd/system/kibaos-boot-dns.service << 'BOOTDNSSVC'
[Unit]
Description=Pin /etc/resolv.conf to nameserver 1.1.1.1
DefaultDependencies=no
Before=sysinit.target network-pre.target NetworkManager.service
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-boot-dns
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
BOOTDNSSVC
systemctl enable kibaos-boot-dns.service

# ── kiba-tcpmask: outbound TCP/IP fingerprint mask ───────────────────────
# Rewrites the two heaviest-weighted fields in classic active/passive OS
# fingerprinting (nmap -O, p0f) on every locally-generated SYN and
# SYN-ACK before it leaves the box: IP TTL and initial TCP window size.
# Stock Linux defaults (TTL 64, window ~64240-ish depending on MTU/scale)
# are exactly what nmap/p0f signature databases key "Linux" off of.
# Rewriting them to Windows 10/11's classic defaults (TTL 128, window
# 65535) flips the top-line guess on both tools without touching
# anything user-visible -- no GUI, no config anyone opens, nothing in
# /etc/os-release, no libc-level uname() shim.
#
# Deliberately NOT touching TCP option order/presence (MSS/WScale/SACK/
# Timestamp ordering, also fingerprinted) -- doing that means rewriting
# option bytes in place without changing total header length, and
# getting it wrong risks silently breaking window scaling or SACK on
# real connections. TTL + window alone already move both tools off
# "Linux" as the top guess; that's the safe subset to ship.
#
# NFQUEUE + a tiny userspace daemon rather than a kernel patch (the old
# IP Personality approach) -- IP Personality only ever supported 2.4-era
# kernels and never got a modern port, so a netfilter-queue callback is
# the current equivalent that actually works against `linux` today.
mkdir -p /usr/lib/kibaos/src
cat > /usr/lib/kibaos/src/kiba_tcpmask.c << 'TCPMASKC'
/* kiba-tcpmask: rewrite TTL + TCP window on outbound SYN/SYN-ACK packets
 * to mask the stock Linux TCP/IP fingerprint. See build.sh for the full
 * rationale on what's touched and what's deliberately left alone. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <linux/netfilter.h>
#include <libnetfilter_queue/libnetfilter_queue.h>

/* Windows 10/11's classic nmap/p0f-visible defaults. */
#define TARGET_TTL    128
#define TARGET_WINDOW 65535

static uint16_t in_cksum(const uint16_t *ptr, int nbytes) {
    long sum = 0;
    while (nbytes > 1) {
        sum += *ptr++;
        nbytes -= 2;
    }
    if (nbytes == 1) {
        uint16_t odd = 0;
        *((uint8_t *)&odd) = *(const uint8_t *)ptr;
        sum += odd;
    }
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    return (uint16_t)(~sum);
}

static uint16_t tcp_cksum(const struct iphdr *iph, const struct tcphdr *tcph, int tcp_len) {
    struct {
        uint32_t src;
        uint32_t dst;
        uint8_t  zero;
        uint8_t  proto;
        uint16_t len;
    } __attribute__((packed)) ps;

    ps.src   = iph->saddr;
    ps.dst   = iph->daddr;
    ps.zero  = 0;
    ps.proto = IPPROTO_TCP;
    ps.len   = htons((uint16_t)tcp_len);

    int total = (int)sizeof(ps) + tcp_len;
    uint8_t *buf = malloc((size_t)total);
    if (!buf) return 0;
    memcpy(buf, &ps, sizeof(ps));
    memcpy(buf + sizeof(ps), tcph, (size_t)tcp_len);
    uint16_t sum = in_cksum((const uint16_t *)buf, total);
    free(buf);
    return sum;
}

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
              struct nfq_data *nfa, void *data) {
    (void)nfmsg; (void)data;
    struct nfqnl_msg_packet_hdr *ph = nfq_get_msg_packet_hdr(nfa);
    uint32_t id = ph ? ntohl(ph->packet_id) : 0;

    unsigned char *pkt = NULL;
    int len = nfq_get_payload(nfa, &pkt);
    if (len < (int)sizeof(struct iphdr) || !pkt) {
        return nfq_set_verdict(qh, id, NF_ACCEPT, 0, NULL);
    }

    struct iphdr *iph = (struct iphdr *)pkt;
    int ip_hlen = iph->ihl * 4;

    if (iph->protocol == IPPROTO_TCP && len >= ip_hlen + (int)sizeof(struct tcphdr)) {
        struct tcphdr *tcph = (struct tcphdr *)(pkt + ip_hlen);
        int tcp_len = len - ip_hlen;

        if (tcph->syn) {
            iph->ttl    = TARGET_TTL;
            tcph->window = htons(TARGET_WINDOW);

            iph->check = 0;
            iph->check = in_cksum((const uint16_t *)iph, ip_hlen);

            tcph->check = 0;
            tcph->check = tcp_cksum(iph, tcph, tcp_len);
        }
    }

    return nfq_set_verdict(qh, id, NF_ACCEPT, (uint32_t)len, pkt);
}

int main(void) {
    struct nfq_handle *h = nfq_open();
    if (!h) { perror("nfq_open"); return 1; }

    nfq_unbind_pf(h, AF_INET);
    if (nfq_bind_pf(h, AF_INET) < 0) { perror("nfq_bind_pf"); return 1; }

    struct nfq_q_handle *qh = nfq_create_queue(h, 100, &cb, NULL);
    if (!qh) { perror("nfq_create_queue"); return 1; }

    if (nfq_set_mode(qh, NFQNL_COPY_PACKET, 0xffff) < 0) {
        perror("nfq_set_mode"); return 1;
    }

    int fd = nfq_fd(h);
    char buf[65536];
    int rv;
    while ((rv = (int)recv(fd, buf, sizeof(buf), 0)) >= 0) {
        nfq_handle_packet(h, buf, rv);
    }

    nfq_destroy_queue(qh);
    nfq_close(h);
    return 0;
}
TCPMASKC

gcc -O2 -Wall $(pkg-config --cflags libnetfilter_queue) \
    -o /usr/local/bin/kiba-tcpmask /usr/lib/kibaos/src/kiba_tcpmask.c \
    $(pkg-config --libs libnetfilter_queue) \
  || { echo "FATAL: kiba_tcpmask.c failed to compile" >&2; exit 1; }

# nftables ruleset: queue every locally-generated SYN/SYN-ACK to kiba-
# tcpmask. 'bypass' is load-bearing -- if the daemon isn't running for
# any reason, packets fall through and get accepted normally instead of
# being dropped, so a crashed/masked daemon degrades to "looks like
# Linux again" instead of "no network at all".
mkdir -p /etc/nftables-kiba
cat > /etc/nftables-kiba/tcpmask.conf << 'TCPMASKNFT'
table inet kiba_tcpmask {
  chain output {
    type filter hook output priority mangle; policy accept;
    tcp flags syn queue num 100 bypass
  }
}
TCPMASKNFT

cat > /etc/systemd/system/kiba-tcpmask.service << 'TCPMASKSVC'
[Unit]
Description=KibaOS outbound TCP/IP fingerprint mask
After=network-pre.target
Before=network.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=simple
ExecStartPre=/usr/bin/nft -f /etc/nftables-kiba/tcpmask.conf
ExecStart=/usr/local/bin/kiba-tcpmask
ExecStopPost=-/usr/bin/nft delete table inet kiba_tcpmask
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
TCPMASKSVC
systemctl enable kiba-tcpmask.service

chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser

# ══════════════════════════════════════════════════════════════════════════
# SYSTEM SERVICES — irqbalance, tuned, systemd-sysext, fstrim, tmpfiles
# ══════════════════════════════════════════════════════════════════════════
# irqbalance: was already in packages.x86_64 but never actually enabled --
# distributes IRQ load across cores instead of pinning everything to CPU0,
# which matters more on the low-core-count H616 SBC target than on a
# desktop x86_64 box, but costs nothing either way.
# systemd-oomd: requires PSI + full cgroups-v2 delegation to even start;
# fails to launch in this boot environment regardless of available RAM,
# and its startup failure was cluttering the boot log alongside real
# early-boot failures. Masked (not just disabled) so no dependency chain
# can pull it back in. earlyoom (already in packages.x86_64) replaces it
# as the actual OOM responder.
systemctl mask systemd-oomd.service systemd-oomd.socket
systemctl enable earlyoom

systemctl enable irqbalance

# tuned: ships a "balanced" profile out of the box that's a reasonable
# default for a consumer desktop (dynamic between throughput and power
# saving) without needing power-profiles-daemon and tuned fighting over
# the same knobs -- power-profiles-daemon is already installed for the
# GNOME-side battery/performance toggle in Budgie's quick settings, so
# tuned is set to a profile that doesn't try to override CPU governor
# decisions PPD already owns. tuned-adm needs a running D-Bus session to
# select a profile the normal way, which doesn't exist in this chroot, so
# the active_profile file (what tuned-adm actually writes under the hood)
# is dropped directly instead.
mkdir -p /etc/tuned
echo "balanced" > /etc/tuned/active_profile
systemctl enable tuned

# systemd-sysext: ships inside systemd itself, no separate package. Not
# populated with any extension images at build time -- this just enables
# the mechanism and creates the directories it reads from, so a .raw/
# squashfs extension image (e.g. a driver bundle or dev toolchain for the
# H616 SBC work) can be dropped into /var/lib/extensions and merged into
# /usr at boot with `systemctl restart systemd-sysext`, with no rebuild
# of the base image required. Empty directories are a no-op until
# something's actually placed in them.
mkdir -p /var/lib/extensions /etc/extensions
systemctl enable systemd-sysext

# fstrim.timer: ships inside systemd itself. Weekly TRIM for SSD/NVMe --
# continuous online discard (mount option) is deliberately NOT used
# instead, since batched weekly TRIM avoids the write-amplification and
# latency spikes continuous discard is known for.
systemctl enable fstrim.timer

# systemd-tmpfiles-clean.timer: periodic sweep of tmpfiles.d Age= rules.
# adding one real rule on top of the stock ones: kibaos-screenshot-ocr
# drops its OCR scratch PNG in /tmp via mktemp
# (now with a "kibaos-ocr." prefix specifically so this rule can target
# just those files) and already cleans up after itself on exit, but a
# killed/crashed OCR run would leak it -- age those out after a day as a
# backstop. scoped to just that prefix instead of touching /tmp's own age
# own age (already handled by systemd's stock tmpfiles.d/tmp.conf) so
# this doesn't shadow or conflict with that default.
cat > /etc/tmpfiles.d/kibaos.conf << 'TMPFILES'
e /tmp/kibaos-ocr.* - - - 1d
TMPFILES
systemctl enable systemd-tmpfiles-clean.timer

# ══════════════════════════════════════════════════════════════════════════
# SECURITY — AppArmor, Firejail
# ══════════════════════════════════════════════════════════════════════════
# AppArmor: the LSM itself is only live if apparmor is in the kernel's
# lsm= boot param (baked into /etc/kernel/cmdline and bundled into the
# UKI for installed systems; see kiba_install_finish.c's
# kiba_install_finalize()).
# Enabling the service here
# just makes it load whatever profiles ship in /etc/apparmor.d/ at boot
# once that param is active -- profile enforcement (aa-enforce/aa-complain
# for individual apps) is left to Remi/the end user, since KibaOS doesn't
# curate its own profile set.


# Firejail: firecfg symlinks /usr/local/bin/<app> -> /usr/bin/firejail for
# every desktop app it recognizes a sandbox profile for (found by scanning
# /usr/share/applications), so e.g. the browser launches sandboxed by
# default without anyone having to type `firejail chromium` by hand.
# NOTE: firejail's own namespace/seccomp sandboxing and AppArmor's
# path-based enforcement have been reported to step on each other for
# some apps (an app both jailed AND under a restrictive profile can get
# denied in confusing ways) -- if something sandboxed misbehaves, check
# `aa-status`/`journalctl` for AppArmor DENIED lines before assuming it's
# just a firejail bug.

# ── Size reduction ─────────────────────────────────────────────────────────
rm -rf /var/cache/pacman/pkg/*
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/doc/*
find /usr/share/locale -mindepth 1 -maxdepth 1 \
  ! -name 'en_US' ! -name 'en_GB' ! -name 'locale.alias' \
  -exec rm -rf {} + 2>/dev/null || true
find /usr/lib/firmware -mindepth 1 -maxdepth 1 \
  ! -name 'i915'    ! -name 'amdgpu'   ! -name 'radeon'  \
  ! -name 'nouveau' ! -name 'iwlwifi*' ! -name 'ath*'    \
  ! -name 'ath10k'  ! -name 'ath11k'   ! -name 'rtl_nic' \
  ! -name 'rtlwifi' ! -name 'rtw88'    ! -name 'rtw89'   \
  ! -name 'sof'     ! -name 'sof-tplg' ! -name 'intel'   \
  -exec rm -rf {} + 2>/dev/null || true
find /usr -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find /usr -name '*.pyc' -delete 2>/dev/null || true
find /usr/lib -name '*.a' -delete 2>/dev/null || true
rm -rf /usr/include/* 2>/dev/null || true
find /usr/share/icons -name 'icon-theme.cache' -delete 2>/dev/null || true
rm -rf /var/lib/pacman/sync/* /tmp/* /var/tmp/* 2>/dev/null || true

chown -R 1000:1000 /home/liveuser

# Same labwc-bridge mask as the installed-system skel path above (see
# "labwc IS still installed") -- this is a plain file write, no D-Bus
# involved, so it's fine as a direct chroot write.
mkdir -p /home/liveuser/.config/autostart
cat > /home/liveuser/.config/autostart/org.buddiesofbudgie.labwc-bridge.desktop << 'NOLABWCBRIDGE'
[Desktop Entry]
Type=Application
Name=Budgie labwc bridge (disabled — KibaOS runs labwc, not labwc)
Exec=/bin/true
Hidden=true
NOLABWCBRIDGE

install -d -m 755 -o 1000 -g 1000 /home/liveuser/.config/dconf
chown -R 1000:1000 /home/liveuser/.config

# ══════════════════════════════════════════════════════════════════════════
# HIDE UPSTREAM-BRANDED LAUNCHER ENTRIES
# ══════════════════════════════════════════════════════════════════════════
# Scoped to /usr/share/applications ONLY -- deliberately not touching
# /usr/share/wayland-sessions or /usr/share/xsessions, since those are
# session definitions GDM reads directly for the login screen's session
# picker, not app-menu entries; hiding budgie-desktop.desktop there would
# break login rather than just tidy the menu.
#
# Uses NoDisplay=true (the standard XDG way to hide a launcher without
# deleting the file) rather than removing the .desktop outright -- keeps
# the actual application and anything that might Exec= it intact, just
# not menu-visible. Runs as one of the last steps here specifically so it
# catches every .desktop pacstrap/AUR ended up installing by this point,
# not just the ones known about when this block was written -- matches
# on both filename and the Name= field, since a package can ship e.g.
# budgie-screenshot.desktop with Name=Screenshot (filename gives it away
# even if the display name wouldn't), or the reverse (a generically-named
# file whose Name= field says "Budgie" something).
for _desktop_file in /usr/share/applications/*.desktop; do
  [ -f "${_desktop_file}" ] || continue
  _basename=$(basename "${_desktop_file}")
  _name_line=$(grep -m1 '^Name=' "${_desktop_file}" 2>/dev/null || true)
  if echo "${_basename}" | grep -qi 'budgie' || echo "${_name_line}" | grep -qi 'budgie'; then
    if grep -q '^NoDisplay=' "${_desktop_file}"; then
      sed -i 's/^NoDisplay=.*/NoDisplay=true/' "${_desktop_file}"
    else
      echo 'NoDisplay=true' >> "${_desktop_file}"
    fi
    echo "=== Hid launcher entry: ${_basename} (matched 'budgie') ==="
  fi
done

# ── DNS: hardcode Cloudflare (1.1.1.1 / 1.0.0.1) ─────────────────────────
# Written as the LAST thing this script does, right before mkarchiso packs
# the airootfs into the squashfs -- NetworkManager (or anything else touched
# above) won't get a chance to reset /etc/resolv.conf after this point, so
# what ships in the live ISO is guaranteed to still be this file.
cat > /etc/resolv.conf << 'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF

# ── ARM: generate the live-medium initramfs by hand ─────────────────────
# ALARM's linux-aarch64 package (unlike x86_64's `linux`) doesn't carry
# the 90-mkinitcpio-install.hook trigger path that would otherwise
# regenerate the initramfs automatically on install, so nothing else in
# this chroot ever runs mkinitcpio for us -- do it explicitly.
#
# No vmlinuz-* manufacturing needed here anymore: this build boots
# aarch64 via systemd-boot (see the boot menu section and
# install_archiso's note on why GRUB's arm64-efi target doesn't work),
# and the fork's _make_boot_on_fat_aarch64 copies /boot/Image* onto the
# live medium directly -- ALARM already ships that file, no renaming or
# repackaging required. Called with an explicit -k/-g instead of -p
# linux specifically to sidestep ALL_kver resolution: mkinitcpio's normal
# path-based kernel-version detection wants to inspect a vmlinuz file
# that plain ALARM installs never produce (only /boot/Image[.gz], which
# aren't in a format mkinitcpio's version-sniffing understands), so
# an explicit -k is required rather than hoping ALL_kver resolves
# against a file that was never there in the first place. That -k
# value has to come from the chroot's own /usr/lib/modules though,
# not ambient uname -r -- see the note just below.
if [ "$(uname -m)" = "aarch64" ]; then
  # NOTE: uname -r here is the GH Actions RUNNER's kernel (e.g.
  # 6.17.0-1020-azure) -- chroot only changes the filesystem root, it
  # doesn't change what uname() reports, so ambient uname -r never
  # matches whatever version linux-aarch64 actually dropped into this
  # chroot's own /usr/lib/modules. Same class of bug already fixed in
  # kibaos_oobe_backend (see kiba_install_finalize) -- read the real
  # installed version off disk instead of trusting uname -r.
  _kver="$(ls -1 /usr/lib/modules | head -n1)"
  if [ -z "${_kver}" ]; then
    echo "ERROR: no kernel module directory found under /usr/lib/modules" >&2
    exit 1
  fi
  mkinitcpio -k "${_kver}" -c /etc/mkinitcpio.conf.d/archiso.conf -g /boot/initramfs-linux.img
fi

# ── blank the machine-id back out for shipping ───────────────────────────
# Re-clear the temporary real ID set near the top of this script (needed
# only so dbus-run-session/dconf calls above had a working session bus
# during the build) -- a live/installer image should ship with an empty
# machine-id so systemd generates a fresh, genuinely unique one on each
# install's first boot instead of every install sharing this build's ID.
rm -f /etc/machine-id
touch /etc/machine-id

echo "=== customize_airootfs.sh complete ==="
CUSTOMIZE
chmod +x "${AIROOTFS}/root/customize_airootfs.sh"

# ══════════════════════════════════════════════════════════════════════════
# BUILD ISO
# ══════════════════════════════════════════════════════════════════════════
cd "${WORKDIR}"
rm -rf "${WORKDIR}/work"

# mkarchiso's own _make_pacman_conf points pacstrap at an isolated GPGDir
# under here (work/pacman-gnupg/), and pacstrap itself is invoked with -G
# (never copies the host's /etc/pacman.d/gnupg in) -- mkarchiso's
# _make_packages also never calls pacman-key on its own, so that GPGDir
# starts out completely empty. On x86_64 this is invisible because
# archlinux-keyring is a dependency of base and its own post-install
# scriptlet populates the archlinux keys as part of pacstrap installing
# it. ALARM packages are signed by a different key ("Arch Linux ARM
# Build System <builder@archlinuxarm.org>") that the archlinux keyring
# doesn't carry at all, and there's no archlinuxarm-keyring package on
# this host's own x86_64 repos to pull it in the same way -- so on
# aarch64 that GPGDir needs the ALARM key seeded by hand, before mkarchiso
# ever touches this directory. Fingerprint per archlinuxarm.org's own
# install docs and independently confirmed across several ALARM forum
# threads: 68B3 537F 39A3 13B3 E574 D067 7719 3F15 2BDB E6A6.
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  mkdir -p "${WORKDIR}/work/pacman-gnupg"
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --init
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --populate archlinux
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --recv-keys \
    68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --lsign-key \
    68B3537F39A313B3E574D06777193F152BDBE6A6
fi

mkarchiso -v -w work -o out "${PROFILE}/"

if ls out/*.iso 1>/dev/null 2>&1; then
  mv out/*.iso "${ISO}.iso"
  sha256sum "${ISO}.iso" > "${ISO}.iso.sha256"
  echo "╔══════════════════════════════════════╗"
  echo "║  KibaOS build complete!       ║"
  echo "║  ${ISO}.iso            ║"
  echo "╚══════════════════════════════════════╝"
else
  echo "ERROR: ISO file not found after mkarchiso!"
  exit 1
fi
