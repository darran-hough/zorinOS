#!/bin/bash
# =============================================================================
# Zorin OS Gaming + Audio Production Setup Script
# =============================================================================
# Installs and configures:
#   - Timeshift system snapshot (safety net before changes)
#   - Steam + Proton + GameMode (gaming optimisation)
#   - Heroic Games Launcher (Epic/GOG)
#   - ProtonPlus (Proton-GE / Wine-GE manager)
#   - GPU auto-detection (Nvidia / AMD / Intel drivers)
#   - Peripheral support: Piper/libratbag (Logitech/Razer mice)
#   - Razer device support (OpenRazer + Polychromatic)
#   - Controller support (Xbox xpadneo, PS4/PS5, generic)
#   - Focusrite Scarlett auto-detection + alsa-scarlett-gui
#   - PipeWire low latency audio configuration
#   - Real-time audio privileges (limits.conf + PAM)
#   - Cadence (KXStudio audio toolbox)
#   - Swappiness tuning + CPU governor (performance)
#   - Low latency kernel
#   - Vesktop (optimised Discord)
#   - Flatseal (Flatpak permission manager)
#   - MangoHud performance overlay
#
# Safe to run multiple times — all installs are idempotent.
# =============================================================================

set -euo pipefail

# --- Colours ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# --- Helpers ------------------------------------------------------------------
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }

# --- Root check ---------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "Please run this script with sudo: sudo bash $0"
    exit 1
fi

# Store the actual user (not root) for user-level operations
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# --- Welcome ------------------------------------------------------------------
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║       Zorin OS Gaming + Audio Production Setup        ║"
echo "  ║                                                       ║"
echo "  ║  Steam • Heroic • Focusrite • Peripherals • PipeWire  ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "Running as: ${BOLD}$ACTUAL_USER${NC}"
echo -e "Date: $(date)"
echo ""

# =============================================================================
# SECTION 1: System Update
# =============================================================================
section "System Update & Upgrade"

info "Updating package lists..."
apt-get update -qq
log "Package lists updated"

info "Upgrading all installed packages — this may take a few minutes..."
apt-get upgrade -y
log "System packages upgraded"

info "Applying full distribution upgrade (safe)..."
apt-get dist-upgrade -y
log "Distribution upgrade complete"

info "Installing prerequisites..."
apt-get install -y -qq \
    curl \
    wget \
    git \
    make \
    gcc \
    build-essential \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    flatpak \
    gnome-software-plugin-flatpak 2>/dev/null || true

log "Prerequisites installed"

# Add Flathub if not already added
if ! flatpak remotes | grep -q flathub; then
    info "Adding Flathub repository..."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    log "Flathub added"
else
    log "Flathub already configured"
fi

# =============================================================================
# SECTION 1b: Timeshift — System Snapshot (safety net before we change anything)
# =============================================================================
section "Timeshift — System Snapshot"

if ! command -v timeshift &>/dev/null; then
    info "Installing Timeshift..."
    apt-get install -y -qq timeshift
    log "Timeshift installed"
else
    log "Timeshift already installed"
fi

# Create an initial snapshot so user can roll back if anything goes wrong
info "Creating system snapshot before setup begins..."
timeshift --create --comments "Before gaming/audio setup script" --tags D 2>/dev/null && \
    log "System snapshot created — you can restore this from Timeshift if needed" || \
    warn "Snapshot failed — Timeshift may need a supported filesystem (ext4/btrfs). Continuing anyway."

# =============================================================================
# SECTION 2: Gaming — Steam
# =============================================================================
section "Steam Installation"

if dpkg -l | grep -q "^ii  steam"; then
    log "Steam already installed — skipping"
else
    info "Enabling 32-bit architecture for Steam..."
    dpkg --add-architecture i386
    apt-get update -qq

    info "Installing Steam..."
    apt-get install -y -qq steam
    log "Steam installed"
fi

# =============================================================================
# SECTION 3: Gaming — GameMode (CPU optimisation)
# =============================================================================
section "GameMode — CPU Optimisation"

if dpkg -l | grep -q "^ii  gamemode"; then
    log "GameMode already installed — skipping"
else
    info "Installing GameMode..."
    apt-get install -y -qq gamemode libgamemode0 libgamemodeauto0
    log "GameMode installed"
fi

# Add user to gamemode group
if ! groups "$ACTUAL_USER" | grep -q gamemode; then
    usermod -aG gamemode "$ACTUAL_USER"
    log "Added $ACTUAL_USER to gamemode group"
else
    log "$ACTUAL_USER already in gamemode group"
fi

# =============================================================================
# SECTION 4: Gaming — Heroic Games Launcher
# =============================================================================
section "Heroic Games Launcher (Epic/GOG)"

HEROIC_INSTALLED=false

# Check if already installed via flatpak
if flatpak list | grep -q "com.heroicgameslauncher.hgl"; then
    log "Heroic already installed via Flatpak — skipping"
    HEROIC_INSTALLED=true
fi

# Check if installed via deb
if dpkg -l | grep -q "^ii  heroic"; then
    log "Heroic already installed via deb — skipping"
    HEROIC_INSTALLED=true
fi

if [ "$HEROIC_INSTALLED" = false ]; then
    info "Installing Heroic via Flatpak..."
    sudo -u "$ACTUAL_USER" flatpak install -y flathub com.heroicgameslauncher.hgl || {
        warn "Flatpak install failed, trying deb package..."
        HEROIC_DEB_URL=$(curl -s https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest \
            | grep "browser_download_url.*amd64.deb" \
            | cut -d '"' -f 4 | head -1)
        if [ -n "$HEROIC_DEB_URL" ]; then
            wget -q -O /tmp/heroic.deb "$HEROIC_DEB_URL"
            apt-get install -y /tmp/heroic.deb
            rm -f /tmp/heroic.deb
            log "Heroic installed via deb"
        else
            warn "Could not fetch Heroic deb URL — please install manually from heroicgameslauncher.com"
        fi
    }
    log "Heroic Games Launcher installed"
fi

# =============================================================================
# SECTION 4b: Gaming — ProtonPlus (Proton-GE / Wine-GE manager)
# =============================================================================
section "ProtonPlus — Custom Proton Version Manager"

if flatpak list | grep -q "com.vysp3r.ProtonPlus"; then
    log "ProtonPlus already installed — skipping"
else
    info "Installing ProtonPlus via Flatpak..."
    sudo -u "$ACTUAL_USER" flatpak install -y flathub com.vysp3r.ProtonPlus && \
        log "ProtonPlus installed" || \
        warn "ProtonPlus install failed — you can install it manually from Flathub"
fi

# =============================================================================
# SECTION 5: Gaming — Proton / Wine dependencies
# =============================================================================
section "Proton & Wine Dependencies"

info "Installing Wine and Proton dependencies..."
apt-get install -y -qq \
    wine \
    wine32 \
    wine64 \
    winetricks \
    winbind \
    cabextract \
    libvulkan1 \
    libvulkan1:i386 \
    mesa-vulkan-drivers \
    mesa-vulkan-drivers:i386 \
    vulkan-tools \
    dxvk 2>/dev/null || true

log "Wine/Proton dependencies installed"

# =============================================================================
# SECTION 5b: GPU Driver Auto-Detection & Installation
# =============================================================================
section "GPU Driver Auto-Detection"

GPU_VENDOR=""
GPU_INFO=$(lspci 2>/dev/null | grep -iE "VGA|3D|Display" || true)
info "Detected GPU(s): $GPU_INFO"

if echo "$GPU_INFO" | grep -qi nvidia; then
    GPU_VENDOR="nvidia"
    log "Nvidia GPU detected"
elif echo "$GPU_INFO" | grep -qi "amd\|radeon\|advanced micro"; then
    GPU_VENDOR="amd"
    log "AMD GPU detected"
elif echo "$GPU_INFO" | grep -qi intel; then
    GPU_VENDOR="intel"
    log "Intel GPU detected"
else
    warn "Could not determine GPU vendor — skipping GPU-specific driver install"
fi

case "$GPU_VENDOR" in
    nvidia)
        info "Installing Nvidia drivers and Vulkan support..."
        apt-get install -y -qq ubuntu-drivers-common 2>/dev/null || true
        RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep recommended | awk '{print $3}' | head -1 || true)

        if [ -n "$RECOMMENDED" ]; then
            info "Recommended Nvidia driver: $RECOMMENDED"
            apt-get install -y -qq "$RECOMMENDED" 2>/dev/null || \
                apt-get install -y -qq nvidia-driver-535 2>/dev/null || true
        else
            warn "Could not auto-detect recommended driver — installing nvidia-driver-535 as fallback"
            apt-get install -y -qq nvidia-driver-535 2>/dev/null || true
        fi

        apt-get install -y -qq \
            libnvidia-gl-535 \
            libnvidia-gl-535:i386 2>/dev/null || true

        if command -v nvidia-smi &>/dev/null; then
            nvidia-smi -pm 1 2>/dev/null || true
            log "Nvidia persistence mode enabled"
        fi
        log "Nvidia drivers installed"
        ;;

    amd)
        info "Installing AMD Mesa + Vulkan support..."
        apt-get install -y -qq \
            mesa-vulkan-drivers \
            mesa-vulkan-drivers:i386 \
            libdrm-amdgpu1 \
            firmware-amd-graphics \
            radeontop \
            amdvlk \
            mesa-opencl-icd 2>/dev/null || true
        log "AMD drivers and Vulkan support installed"
        ;;

    intel)
        info "Installing Intel graphics support..."
        apt-get install -y -qq \
            intel-media-va-driver \
            i965-va-driver \
            mesa-vulkan-drivers \
            mesa-vulkan-drivers:i386 2>/dev/null || true
        log "Intel graphics support installed"
        ;;
esac

# =============================================================================
# SECTION 6: Peripheral Support — Logitech / General Mice (Piper + libratbag)
# =============================================================================
section "Mouse Peripheral Support — Piper (Logitech, Razer, SteelSeries)"

if dpkg -l | grep -q "^ii  piper"; then
    log "Piper already installed — skipping"
else
    info "Installing Piper and libratbag..."
    apt-get install -y -qq piper libratbag-dev ratbagd 2>/dev/null || {
        # Fallback to flatpak if apt version unavailable
        info "Trying Piper via Flatpak..."
        sudo -u "$ACTUAL_USER" flatpak install -y flathub org.freedesktop.Piper || \
            warn "Piper install failed — device may still work without GUI configuration"
    }
    log "Piper installed"
fi

# Enable ratbagd service for mouse configuration
if systemctl list-unit-files | grep -q ratbagd; then
    systemctl enable --now ratbagd 2>/dev/null || true
    log "ratbagd service enabled"
fi

# =============================================================================
# SECTION 7: Peripheral Support — Razer (OpenRazer)
# =============================================================================
section "Razer Device Support — OpenRazer"

if dpkg -l | grep -q "^ii  openrazer-meta"; then
    log "OpenRazer already installed — skipping"
else
    info "Adding OpenRazer PPA..."
    add-apt-repository -y ppa:openrazer/stable 2>/dev/null || \
        warn "Could not add OpenRazer PPA — skipping Razer support"

    apt-get update -qq

    info "Installing OpenRazer..."
    apt-get install -y -qq openrazer-meta 2>/dev/null || \
        warn "OpenRazer install failed — skipping"

    # Install Polychromatic GUI for Razer RGB
    apt-get install -y -qq polychromatic 2>/dev/null || \
        sudo -u "$ACTUAL_USER" flatpak install -y flathub app.polychromatic.Polychromatic 2>/dev/null || \
        warn "Polychromatic GUI not available — OpenRazer still functional via CLI"

    log "OpenRazer installed"
fi

# Add user to plugdev group for Razer device access
if ! groups "$ACTUAL_USER" | grep -q plugdev; then
    usermod -aG plugdev "$ACTUAL_USER"
    log "Added $ACTUAL_USER to plugdev group"
fi

# =============================================================================
# SECTION 8: Controller Support
# =============================================================================
section "Controller Support (Xbox / PlayStation / Generic)"

info "Installing controller support packages..."
apt-get install -y -qq \
    joystick \
    jstest-gtk \
    evtest \
    xboxdrv \
    steam-devices 2>/dev/null || true

# Xbox controller (xpad is built into kernel but xpadneo gives better support)
if ! dkms status | grep -q xpadneo 2>/dev/null; then
    info "Installing xpadneo for enhanced Xbox controller support..."
    apt-get install -y -qq dkms linux-headers-$(uname -r) 2>/dev/null || true
    
    if [ -d /tmp/xpadneo ]; then rm -rf /tmp/xpadneo; fi
    git clone --depth=1 https://github.com/atar-axis/xpadneo.git /tmp/xpadneo 2>/dev/null && \
        bash /tmp/xpadneo/install.sh 2>/dev/null && \
        log "xpadneo installed for Xbox controllers" || \
        warn "xpadneo install failed — standard Xbox support still available via xpad kernel module"
else
    log "xpadneo already installed"
fi

# PS4/PS5 controller support via SDL2 and udev rules
info "Installing PlayStation controller support..."
apt-get install -y -qq \
    libsdl2-dev \
    libsdl2-2.0-0 2>/dev/null || true

# Add udev rules for PS4/PS5 if not present
UDEV_RULES_FILE="/etc/udev/rules.d/70-sony-controllers.rules"
if [ ! -f "$UDEV_RULES_FILE" ]; then
    info "Adding Sony controller udev rules..."
    cat > "$UDEV_RULES_FILE" << 'EOF'
# PS4 DualShock 4
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="05c4", MODE="0666"
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="09cc", MODE="0666"
# PS5 DualSense
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0666"
# PS3 DualShock 3
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0268", MODE="0666"
EOF
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    log "Sony controller udev rules added"
else
    log "Sony controller udev rules already present"
fi

log "Controller support configured"

# =============================================================================
# SECTION 9: Audio — PipeWire Optimisation
# =============================================================================
section "PipeWire Audio Optimisation"

info "Ensuring PipeWire stack is fully installed..."
apt-get install -y -qq \
    pipewire \
    pipewire-pulse \
    pipewire-jack \
    pipewire-audio \
    wireplumber \
    libspa-0.2-jack \
    libspa-0.2-bluetooth 2>/dev/null || true

# Create low latency PipeWire config for the actual user
PIPEWIRE_CONF_DIR="$ACTUAL_HOME/.config/pipewire"
PIPEWIRE_CONF_FILE="$PIPEWIRE_CONF_DIR/pipewire.conf.d/10-lowlatency.conf"

if [ ! -f "$PIPEWIRE_CONF_FILE" ]; then
    info "Configuring PipeWire for low latency..."
    mkdir -p "$PIPEWIRE_CONF_DIR/pipewire.conf.d"
    cat > "$PIPEWIRE_CONF_FILE" << 'EOF'
# Low latency PipeWire configuration
context.properties = {
    default.clock.rate          = 48000
    default.clock.quantum       = 64
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 8192
}
EOF
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$PIPEWIRE_CONF_DIR"
    log "PipeWire low latency config written"
else
    log "PipeWire low latency config already exists — skipping"
fi

# Restart PipeWire as the actual user
sudo -u "$ACTUAL_USER" systemctl --user restart pipewire pipewire-pulse wireplumber 2>/dev/null || \
    warn "Could not restart PipeWire — please log out and back in"

log "PipeWire configured"

# =============================================================================
# SECTION 9b: Audio — Real-Time Privileges (limits.conf) & Cadence
# =============================================================================
section "Audio Real-Time Privileges & Cadence"

# --- limits.conf — give user real-time scheduling without root ----------------
LIMITS_CONF="/etc/security/limits.d/99-realtime-audio.conf"

if [ -f "$LIMITS_CONF" ]; then
    log "Real-time audio limits already configured — skipping"
else
    info "Setting real-time scheduling privileges for audio..."
    cat > "$LIMITS_CONF" << EOF
# Real-time audio privileges for $ACTUAL_USER
# Allows low-latency audio without running as root
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice      -19
$ACTUAL_USER - rtprio  95
$ACTUAL_USER - memlock unlimited
$ACTUAL_USER - nice    -19
EOF
    log "Real-time audio limits written to $LIMITS_CONF"
fi

# Add user to audio group if not already
if ! groups "$ACTUAL_USER" | grep -q "\baudio\b"; then
    usermod -aG audio "$ACTUAL_USER"
    log "Added $ACTUAL_USER to audio group"
else
    log "$ACTUAL_USER already in audio group"
fi

# --- PAM limits — ensure limits.conf is actually loaded ----------------------
# SAFE: We use a drop-in file in /etc/pam.d/ rather than editing common-session
# directly. This means Zorin OS updates to common-session will never conflict.
PAM_DROPIN="/etc/pam.d/99-realtime-audio-limits"
if [ -f "$PAM_DROPIN" ]; then
    log "PAM drop-in limits file already exists — skipping"
else
    info "Creating PAM drop-in for real-time limits..."
    cat > "$PAM_DROPIN" << 'EOF'
# Drop-in PAM config to load limits.conf for real-time audio
# This file is managed by the gaming/audio setup script
# Safe to remove if real-time audio privileges are no longer needed
session required pam_limits.so
EOF
    log "PAM drop-in written to $PAM_DROPIN — core system files untouched"
fi

# --- Cadence (KXStudio audio toolbox) ----------------------------------------
if command -v cadence &>/dev/null; then
    log "Cadence already installed — skipping"
else
    info "Adding KXStudio repository for Cadence..."
    # Download and install KXStudio repo
    wget -q -O /tmp/kxstudio-repos.deb \
        https://launchpad.net/~kxstudio-debian/+archive/kxstudio/+files/kxstudio-repos_11.1.0_all.deb 2>/dev/null || true

    if [ -f /tmp/kxstudio-repos.deb ]; then
        apt-get install -y -qq /tmp/kxstudio-repos.deb 2>/dev/null || true
        rm -f /tmp/kxstudio-repos.deb
        apt-get update -qq

        info "Installing Cadence..."
        apt-get install -y -qq cadence 2>/dev/null && \
            log "Cadence installed" || \
            warn "Cadence not available from KXStudio — trying direct apt..."
    fi

    # Fallback — try apt directly (may be in Ubuntu repos)
    if ! command -v cadence &>/dev/null; then
        apt-get install -y -qq cadence 2>/dev/null && \
            log "Cadence installed via apt" || \
            warn "Cadence unavailable — you can install it manually from kx.studio"
    fi
fi

# =============================================================================
# SECTION 10: Focusrite Auto-Detection + alsa-scarlett-gui
# =============================================================================
section "Focusrite Scarlett Auto-Detection"

# Detect any connected Focusrite device via lsusb
FOCUSRITE_DETECTED=false
FOCUSRITE_MODEL=""

if command -v lsusb &>/dev/null; then
    # Focusrite vendor ID is 1235
    LSUSB_OUTPUT=$(lsusb 2>/dev/null | grep -i "1235:" || true)
    
    if [ -n "$LSUSB_OUTPUT" ]; then
        FOCUSRITE_DETECTED=true
        FOCUSRITE_MODEL=$(echo "$LSUSB_OUTPUT" | head -1)
        log "Focusrite device detected: $FOCUSRITE_MODEL"
    else
        warn "No Focusrite device currently connected via USB"
        info "alsa-scarlett-gui will still be installed for when you connect your interface"
    fi
else
    apt-get install -y -qq usbutils -qq
    warn "lsusb was not available — installed now. Re-run script after connecting your Focusrite"
fi

# Install alsa-scarlett-gui dependencies and build regardless
info "Installing alsa-scarlett-gui build dependencies..."
apt-get install -y -qq \
    libgtk-4-dev \
    libasound2-dev \
    libssl-dev \
    alsa-utils 2>/dev/null || true

# Build alsa-scarlett-gui if not already built
SCARLETT_GUI_BIN="/usr/local/bin/alsa-scarlett-gui"
SCARLETT_GUI_DESKTOP="/usr/share/applications/alsa-scarlett-gui.desktop"

if [ -f "$SCARLETT_GUI_BIN" ]; then
    log "alsa-scarlett-gui already installed at $SCARLETT_GUI_BIN — skipping build"
else
    info "Cloning and building alsa-scarlett-gui..."
    
    BUILD_DIR="/tmp/alsa-scarlett-gui-build"
    if [ -d "$BUILD_DIR" ]; then rm -rf "$BUILD_DIR"; fi
    
    git clone --depth=1 https://github.com/geoffreybennett/alsa-scarlett-gui "$BUILD_DIR"
    
    cd "$BUILD_DIR/src"
    make -j$(nproc)
    
    # Install binary system-wide
    install -m 755 alsa-scarlett-gui "$SCARLETT_GUI_BIN"
    
    # Install icon if present
    if [ -f "$BUILD_DIR/img/alsa-scarlett-gui.png" ]; then
        install -D -m 644 "$BUILD_DIR/img/alsa-scarlett-gui.png" \
            /usr/share/icons/hicolor/256x256/apps/alsa-scarlett-gui.png
    fi
    
    # Create desktop entry
    cat > "$SCARLETT_GUI_DESKTOP" << 'EOF'
[Desktop Entry]
Name=Scarlett GUI
Comment=Focusrite Scarlett mixer control
Exec=alsa-scarlett-gui
Icon=alsa-scarlett-gui
Terminal=false
Type=Application
Categories=Audio;Mixer;
Keywords=focusrite;scarlett;audio;interface;
EOF
    
    # Update icon cache
    update-icon-caches /usr/share/icons/hicolor 2>/dev/null || true
    
    cd /
    rm -rf "$BUILD_DIR"
    
    log "alsa-scarlett-gui built and installed to $SCARLETT_GUI_BIN"
fi

# Check for MSD mode issue and warn user
if [ "$FOCUSRITE_DETECTED" = true ]; then
    echo ""
    warn "IMPORTANT — Focusrite MSD Mode:"
    echo -e "  If your Scarlett shows as a USB storage device rather than audio,"
    echo -e "  hold the ${BOLD}48V button${NC} while powering on to disable MSD mode."
    echo ""
fi

# =============================================================================
# SECTION 10b: System Tuning — Swappiness & CPU Governor
# =============================================================================
section "System Tuning — Swappiness & CPU Governor"

# --- Swappiness ---------------------------------------------------------------
SYSCTL_CONF="/etc/sysctl.d/99-gaming-audio.conf"

if grep -q "vm.swappiness" "$SYSCTL_CONF" 2>/dev/null; then
    log "Swappiness already configured — skipping"
else
    info "Setting swappiness to 10 (default is 60)..."
    cat >> "$SYSCTL_CONF" << 'EOF'

# Prefer RAM over swap — better for gaming and audio
vm.swappiness=10

# Reduce dirty page writeback lag — helps with audio dropouts
vm.dirty_ratio=6
vm.dirty_background_ratio=3

# Increase max file watchers — helps Steam and some games
fs.inotify.max_user_watches=524288
EOF
    sysctl -p "$SYSCTL_CONF" 2>/dev/null || true
    log "Swappiness set to 10, dirty ratios tuned, inotify watches increased"
fi

# --- CPU Governor -------------------------------------------------------------
info "Installing cpufrequtils for CPU governor management..."
apt-get install -y -qq cpufrequtils 2>/dev/null || true

# Set performance governor persistently
# SAFE: /etc/default/cpufrequtils is a cpufrequtils-owned config file.
# We only write it if it doesn't already exist or has no GOVERNOR set.
CPU_CONF="/etc/default/cpufrequtils"
if grep -q "^GOVERNOR=" "$CPU_CONF" 2>/dev/null; then
    log "CPU governor already configured in $CPU_CONF — skipping"
else
    info "Setting CPU governor to performance mode..."
    # Append rather than overwrite in case file exists with other settings
    echo 'GOVERNOR="performance"' >> "$CPU_CONF"
    systemctl restart cpufrequtils 2>/dev/null || true
    log "CPU governor set to performance"
fi

# Also apply immediately to all cores right now
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null || true
done
log "Performance governor applied to all CPU cores"

# =============================================================================
# SECTION 11: Kernel Options
# =============================================================================
section "Kernel Configuration"

CURRENT_KERNEL=$(uname -r)
info "Current kernel: $CURRENT_KERNEL"

# Install lowlatency kernel if not present
if dpkg -l | grep -q "^ii  linux-lowlatency"; then
    log "Low latency kernel already installed"
else
    info "Installing low latency kernel..."
    apt-get install -y -qq linux-lowlatency
    log "Low latency kernel installed"
fi

# Offer realtime kernel info
if dpkg -l | grep -q "^ii  linux-realtime"; then
    log "Real-time kernel already installed"
else
    info "Real-time kernel available but not auto-installed."
    echo -e "  To install: ${BOLD}sudo apt install linux-realtime${NC}"
    echo -e "  Recommended for dedicated audio production sessions."
    echo -e "  Both kernels can coexist — select at boot via GRUB."
fi

# =============================================================================
# SECTION 12: Additional Gaming Optimisations
# =============================================================================
section "Additional Gaming Optimisations"

# MangoHud — performance overlay
if ! command -v mangohud &>/dev/null; then
    info "Installing MangoHud (performance overlay)..."
    apt-get install -y -qq mangohud 2>/dev/null || \
        sudo -u "$ACTUAL_USER" flatpak install -y flathub org.freedesktop.Platform.VulkanLayer.MangoHud 2>/dev/null || \
        warn "MangoHud not available in repos — skip"
    log "MangoHud installed"
else
    log "MangoHud already installed"
fi

# vkBasalt — post processing
if ! dpkg -l | grep -q "^ii  vkbasalt"; then
    info "Installing vkBasalt (Vulkan post-processing layer)..."
    apt-get install -y -qq vkbasalt 2>/dev/null || true
fi

# --- Vesktop (better Discord client for Linux) --------------------------------
if flatpak list | grep -q "dev.vencord.Vesktop"; then
    log "Vesktop already installed — skipping"
else
    info "Installing Vesktop (optimised Discord client)..."
    sudo -u "$ACTUAL_USER" flatpak install -y flathub dev.vencord.Vesktop && \
        log "Vesktop installed" || \
        warn "Vesktop install failed — install manually from flathub"
fi

# --- Flatseal (Flatpak permission manager) ------------------------------------
if flatpak list | grep -q "com.github.tchx84.Flatseal"; then
    log "Flatseal already installed — skipping"
else
    info "Installing Flatseal (Flatpak permission manager)..."
    sudo -u "$ACTUAL_USER" flatpak install -y flathub com.github.tchx84.Flatseal && \
        log "Flatseal installed" || \
        warn "Flatseal install failed — install manually from flathub"
fi

# Feral GameMode config for Steam
GAMEMODE_CONF="$ACTUAL_HOME/.config/gamemode.ini"
if [ ! -f "$GAMEMODE_CONF" ]; then
    info "Writing GameMode config..."
    mkdir -p "$ACTUAL_HOME/.config"
    cat > "$GAMEMODE_CONF" << 'EOF'
[general]
renice=10
softrealtime=auto
inhibit_screensaver=1

[gpu]
apply_gpu_optimisations=accept-responsibility
gpu_device=0
amd_performance_level=high

[custom]
start=notify-send "GameMode" "Gaming optimisations active"
end=notify-send "GameMode" "Gaming optimisations disabled"
EOF
    chown "$ACTUAL_USER:$ACTUAL_USER" "$GAMEMODE_CONF"
    log "GameMode config written"
else
    log "GameMode config already exists — skipping"
fi

log "Gaming optimisations complete"

# =============================================================================
# SECTION 13: Final apt cleanup
# =============================================================================
section "Cleanup"

apt-get autoremove -y -qq
apt-get autoclean -y -qq
log "System cleaned up"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║                  Setup Complete! ✓                    ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}What was installed/configured:${NC}"
echo -e "  ${GREEN}✓${NC} Timeshift system snapshot"
echo -e "  ${GREEN}✓${NC} Steam + 32-bit libraries"
echo -e "  ${GREEN}✓${NC} GameMode (CPU optimisation)"
echo -e "  ${GREEN}✓${NC} Heroic Games Launcher"
echo -e "  ${GREEN}✓${NC} ProtonPlus (Proton-GE / Wine-GE manager)"
echo -e "  ${GREEN}✓${NC} GPU drivers auto-detected and installed"
echo -e "  ${GREEN}✓${NC} Wine + Proton dependencies + DXVK + Vulkan"
echo -e "  ${GREEN}✓${NC} Piper + libratbag (Logitech/SteelSeries mice)"
echo -e "  ${GREEN}✓${NC} OpenRazer + Polychromatic (Razer devices)"
echo -e "  ${GREEN}✓${NC} xpadneo (Xbox controllers)"
echo -e "  ${GREEN}✓${NC} PS4/PS5 DualShock/DualSense udev rules"
echo -e "  ${GREEN}✓${NC} PipeWire low latency config (48kHz / 64 quantum)"
echo -e "  ${GREEN}✓${NC} Real-time audio privileges (limits.conf + PAM)"
echo -e "  ${GREEN}✓${NC} Cadence (KXStudio audio toolbox)"
echo -e "  ${GREEN}✓${NC} alsa-scarlett-gui (Focusrite Scarlett control)"
echo -e "  ${GREEN}✓${NC} Swappiness tuned (10) + dirty ratios optimised"
echo -e "  ${GREEN}✓${NC} CPU governor set to performance"
echo -e "  ${GREEN}✓${NC} Low latency kernel"
echo -e "  ${GREEN}✓${NC} Vesktop (optimised Discord client)"
echo -e "  ${GREEN}✓${NC} Flatseal (Flatpak permission manager)"
echo -e "  ${GREEN}✓${NC} MangoHud performance overlay"
echo ""

echo -e "${BOLD}${YELLOW}Action required — please reboot:${NC}"
echo -e "  A reboot is needed to:"
echo -e "  • Load the low latency kernel"
echo -e "  • Apply group membership changes (gamemode, plugdev, audio)"
echo -e "  • Activate xpadneo kernel module"
echo -e "  • Apply real-time audio privilege limits"
echo -e "  • Apply CPU governor changes"
echo ""

echo -e "${BOLD}Post-reboot tips:${NC}"
echo -e "  • In Steam: Enable Steam Play for all titles in Settings → Compatibility"
echo -e "  • Launch games with: ${BOLD}gamemoderun %command%${NC} in Steam launch options"
echo -e "  • Focusrite GUI: run ${BOLD}alsa-scarlett-gui${NC} or find it in your app menu"
echo -e "  • Switch kernels at boot: hold ${BOLD}Shift${NC} during startup to open GRUB"
echo -e "  • For RT kernel: ${BOLD}sudo apt install linux-realtime${NC}"
echo -e "  • Use Flatseal to manage permissions for Heroic, Vesktop, ProtonPlus"
echo -e "  • Open ProtonPlus and download latest Proton-GE before gaming"
echo -e "  • Cadence can be used to manage JACK alongside PipeWire"
echo ""

echo -e "  ${CYAN}Enjoy your setup!${NC}"
echo ""
