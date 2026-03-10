#!/bin/bash
# =============================================================================
#  Zorin OS 18 -- Gaming & Media Beast Setup Script
#  Detects: CPU, GPU, Motherboard, Focusrite Scarlett
#  Covers : Gaming, Video Production, Media Playback, Hardware Acceleration
#  Target : Zorin OS 18 (Ubuntu 24.04 LTS base, Kernel 6.14+)
#
#  DISPLAY:
#    - Wayland-first: no Xorg config written, GDM Wayland stays enabled
#    - AMD/Intel GPU drivers only -- install GPU drivers manually if needed
#
#  RESILIENCE:
#    - Never exits on error; all errors collected and reported at the end
#    - Every install checks if already present and skips if so (idempotent)
#    - Safe to run multiple times without breaking anything
#    - Full error summary with actionable fix hints printed at the end
#    - All operations wrapped in try/catch-style handlers
# =============================================================================

# DO NOT use set -e here -- we handle errors manually and never abort mid-run
set -uo pipefail

# =============================================================================
#  COLOURS & LOGGING
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC} $1"; }
info()    { echo -e "${CYAN}[>>]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
skipped() { echo -e "${BLUE}[--]${NC} $1 -- already installed, skipping"; }
err_msg() { echo -e "${RED}[XX]${NC} $1"; }
media()   { echo -e "${MAGENTA}[AV]${NC} $1"; }
section() {
  echo ""
  echo -e "${BOLD}${BLUE}=================================================${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}=================================================${NC}"
  echo ""
}

# =============================================================================
#  ERROR & SKIP TRACKING
# =============================================================================
ERRORS=()       # Collected errors -- printed in full at the end
SKIPPED=()      # Items that were already installed
INSTALLED=()    # Items successfully installed this run
WARNINGS=()     # Non-fatal warnings worth noting

# Record an error without stopping the script
record_error() {
  local msg="$1"
  local hint="${2:-}"
  err_msg "$msg"
  if [[ -n "$hint" ]]; then
    ERRORS+=("ERROR: $msg || FIX: $hint")
  else
    ERRORS+=("ERROR: $msg")
  fi
}

# Record a warning
record_warning() {
  warn "$1"
  WARNINGS+=("$1")
}

# =============================================================================
#  SAFE OPERATION HELPERS
# =============================================================================

# Safe apt install -- skips packages that are already installed
# Usage: safe_apt "description" pkg1 pkg2 ...
safe_apt() {
  local desc="$1"; shift
  local pkgs=("$@")
  local to_install=()
  local already=()

  for pkg in "${pkgs[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      already+=("$pkg")
    else
      to_install+=("$pkg")
    fi
  done

  if [[ ${#already[@]} -gt 0 ]]; then
    skipped "$desc (packages present: ${already[*]})"
    SKIPPED+=("$desc")
  fi

  if [[ ${#to_install[@]} -eq 0 ]]; then
    return 0
  fi

  info "Installing: ${to_install[*]}"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      "${to_install[@]}" 2>&1; then
    log "$desc installed"
    INSTALLED+=("$desc")
  else
    record_error "APT install failed: $desc (${to_install[*]})" \
      "Run manually: sudo apt install ${to_install[*]}"
  fi
}

# Safe apt install (full recommends -- for GPU drivers and heavier packages)
safe_apt_full() {
  local desc="$1"; shift
  local pkgs=("$@")
  local to_install=()

  for pkg in "${pkgs[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      true  # part already installed, apt will skip it gracefully
    else
      to_install+=("$pkg")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    skipped "$desc"
    SKIPPED+=("$desc")
    return 0
  fi

  info "Installing: ${to_install[*]}"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" 2>&1; then
    log "$desc installed"
    INSTALLED+=("$desc")
  else
    record_error "APT install failed: $desc (${to_install[*]})" \
      "Run manually: sudo apt install ${to_install[*]}"
  fi
}

# Safe flatpak install -- skips if app already installed
# Usage: safe_flatpak "description" "app.id"
safe_flatpak() {
  local desc="$1"
  local app_id="$2"

  if flatpak list --app 2>/dev/null | grep -q "$app_id"; then
    skipped "$desc (Flatpak: $app_id)"
    SKIPPED+=("$desc")
    return 0
  fi

  if flatpak install -y --noninteractive flathub "$app_id" 2>&1; then
    log "$desc installed (Flatpak)"
    INSTALLED+=("$desc")
  else
    record_error "Flatpak install failed: $desc ($app_id)" \
      "Run manually: flatpak install flathub $app_id"
  fi
}

# Safe PPA add -- skips if already present
# Usage: safe_ppa "ppa:name/ppa"
safe_ppa() {
  local ppa="$1"
  local ppa_file
  ppa_file=$(echo "$ppa" | sed 's|ppa:||;s|/|-|' )

  if find /etc/apt/sources.list.d/ -name "*${ppa_file}*" 2>/dev/null | grep -q .; then
    skipped "PPA $ppa"
    return 0
  fi

  if add-apt-repository -y "$ppa" 2>&1; then
    log "PPA added: $ppa"
    apt-get update -y 2>&1 || record_warning "apt update after adding $ppa had warnings"
  else
    record_error "Failed to add PPA: $ppa" "Run manually: sudo add-apt-repository -y $ppa"
  fi
}

# Safe git clone -- skips if directory already exists and is a git repo
# Usage: safe_clone "description" "url" "/dest/path"
safe_clone() {
  local desc="$1"
  local url="$2"
  local dest="$3"

  if [[ -d "$dest/.git" ]]; then
    info "$desc repo exists -- pulling latest..."
    git -C "$dest" pull --ff-only 2>&1 || \
      record_warning "git pull failed for $desc -- using existing version"
    return 0
  fi

  rm -rf "$dest"
  if git clone "$url" "$dest" 2>&1; then
    log "$desc cloned"
  else
    record_error "git clone failed: $desc ($url)" \
      "Check network connectivity and retry"
    return 1
  fi
}

# Safe run -- runs a command, records error if it fails, never stops script
# Usage: safe_run "description" "hint on failure" command args...
safe_run() {
  local desc="$1"
  local hint="$2"
  shift 2
  if "$@" 2>&1; then
    log "$desc"
  else
    record_error "Failed: $desc" "$hint"
  fi
}

# Check if a binary is on PATH
has_cmd() { command -v "$1" &>/dev/null; }

# Check if an apt package is installed
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Write a file only if content has changed (idempotent file writes)
# Usage: safe_write "description" "/path/to/file" <<'EOF' ... EOF
safe_write() {
  local desc="$1"
  local dest="$2"
  local content
  content=$(cat)

  if [[ -f "$dest" ]]; then
    local existing
    existing=$(cat "$dest")
    if [[ "$existing" == "$content" ]]; then
      skipped "Config: $desc (unchanged)"
      SKIPPED+=("Config: $desc")
      return 0
    fi
    # Back up existing config before overwriting
    cp "$dest" "${dest}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi

  mkdir -p "$(dirname "$dest")"
  echo "$content" > "$dest" && log "Config written: $desc" || \
    record_error "Failed to write config: $dest" "Check permissions on $(dirname "$dest")"
}

# Append to a file only if the line isn't already there (idempotent append)
safe_append() {
  local desc="$1"
  local file="$2"
  local content="$3"

  if grep -qF "$content" "$file" 2>/dev/null; then
    skipped "Already present in $file: $desc"
    return 0
  fi
  echo "$content" >> "$file" && log "Appended to $file: $desc" || \
    record_error "Failed to append to $file: $desc"
}

# =============================================================================
#  PREFLIGHT CHECKS
# =============================================================================
section "Preflight Checks"

# Root check
if [[ "$EUID" -ne 0 ]]; then
  echo -e "${RED}This script must be run as root.${NC}"
  echo "Please run: sudo bash zorin18-gaming-setup.sh"
  exit 1
fi

# Identify the real user (not root)
SUDO_USER_NAME="${SUDO_USER:-}"
if [[ -z "$SUDO_USER_NAME" ]] || [[ "$SUDO_USER_NAME" == "root" ]]; then
  # Try to find the first non-root user with a home directory
  SUDO_USER_NAME=$(getent passwd | awk -F: '$3>=1000 && $7!~/nologin|false/ {print $1; exit}')
fi
if [[ -z "$SUDO_USER_NAME" ]]; then
  SUDO_USER_NAME="root"
  record_warning "Could not determine non-root user -- some user configs will target /root"
fi
USER_HOME="/home/$SUDO_USER_NAME"
[[ "$SUDO_USER_NAME" == "root" ]] && USER_HOME="/root"
log "Target user: $SUDO_USER_NAME (home: $USER_HOME)"

# OS check
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_NAME="${NAME:-Unknown}"
  OS_VERSION="${VERSION_ID:-Unknown}"
  info "OS: $OS_NAME $OS_VERSION"
  if ! echo "$OS_NAME $OS_VERSION" | grep -qiE "Zorin|Ubuntu"; then
    record_warning "This script targets Zorin OS 18 / Ubuntu 24.04. Detected: $OS_NAME $OS_VERSION. Proceeding anyway."
  fi
else
  record_warning "Cannot determine OS -- /etc/os-release not found"
fi

# Internet connectivity check
info "Checking internet connectivity..."
if curl -s --max-time 10 https://archive.ubuntu.com > /dev/null 2>&1; then
  log "Internet connectivity: OK"
else
  record_warning "No internet connectivity detected. Installations requiring downloads may fail."
fi

# Disk space check (require at least 10GB free on /)
FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
info "Free disk space: ${FREE_GB}GB"
if [[ "$FREE_GB" -lt 10 ]]; then
  record_warning "Less than 10GB free on /. Some installations may fail. Recommended: 20GB+"
fi

# Log file
LOGFILE="/var/log/zorin-gaming-media-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
log "Logging to: $LOGFILE"

# ── Cleanup leftover repo files from previous script runs ────────────────────
if [[ -f /etc/apt/sources.list.d/amdvlk.list ]]; then
  rm -f /etc/apt/sources.list.d/amdvlk.list
  rm -f /etc/apt/keyrings/amdvlk.gpg 2>/dev/null || true
  log "Removed leftover amdvlk repo (was added by a previous script run with wrong distro codename)"
  apt-get update -y 2>&1 || true
fi

# =============================================================================
#  STEP 1 -- HARDWARE DETECTION
# =============================================================================
section "Hardware Detection"

# ── CPU ───────────────────────────────────────────────────────────────────────
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
CPU_CORES=$(nproc 2>/dev/null || echo "?")
info "CPU: $CPU_MODEL ($CPU_CORES threads)"

CPU_TYPE="generic"
if echo "$CPU_VENDOR" | grep -qi "AuthenticAMD"; then
  CPU_TYPE="amd"; log "CPU vendor: AMD"
elif echo "$CPU_VENDOR" | grep -qi "GenuineIntel"; then
  CPU_TYPE="intel"; log "CPU vendor: Intel"
else
  record_warning "Unknown CPU vendor ($CPU_VENDOR) -- using generic settings"
fi

RYZEN_GEN="zen_generic"
if [[ "$CPU_TYPE" == "amd" ]]; then
  if   echo "$CPU_MODEL" | grep -qiE "9[0-9]{3}0[A-Z]*$|9[0-9]{3}0X"; then RYZEN_GEN="zen5"
  elif echo "$CPU_MODEL" | grep -qiE "7[0-9]{3}X3D|9[0-9]{3}X3D";      then RYZEN_GEN="zen4_x3d"
  elif echo "$CPU_MODEL" | grep -qiE "7[0-9]{3}X|9[0-9]{3}X";           then RYZEN_GEN="zen4"
  elif echo "$CPU_MODEL" | grep -qiE "5[0-9]{3}X3D";                     then RYZEN_GEN="zen3_x3d"
  elif echo "$CPU_MODEL" | grep -qiE "5[0-9]{3}";                        then RYZEN_GEN="zen3"
  fi
  info "Ryzen generation: $RYZEN_GEN"
fi

# ── GPU -- detect active driver ───────────────────────────────────────────────
GPU_INFO=$(lspci 2>/dev/null | grep -iE "VGA|3D|Display" || true)
info "GPU(s): ${GPU_INFO:-none detected}"

# Use /sys/bus/pci/devices as the most reliable source for active driver
# lspci -k can miss the driver line if -A count is too small
ACTIVE_GPU_DRIVER=""

# Method 1: check /sys directly for the GPU PCI device's driver
for pci_dev in /sys/bus/pci/devices/*/; do
  class=$(cat "$pci_dev/class" 2>/dev/null || echo "")
  # PCI class 0x0300 = VGA, 0x0302 = 3D controller, 0x0380 = Display
  if [[ "$class" =~ ^0x03(00|02|80) ]]; then
    if [[ -L "$pci_dev/driver" ]]; then
      ACTIVE_GPU_DRIVER=$(basename "$(readlink "$pci_dev/driver")" 2>/dev/null || true)
      break
    fi
  fi
done

# Method 2: fallback to lspci -k with generous context
if [[ -z "$ACTIVE_GPU_DRIVER" ]]; then
  ACTIVE_GPU_DRIVER=$(lspci -k 2>/dev/null | grep -A5 -iE "VGA compatible|3D controller|Display controller" | grep "Kernel driver in use" | awk '{print $NF}' | head -1 || true)
fi

info "Active GPU driver: ${ACTIVE_GPU_DRIVER:-none detected}"

GPU_DRIVER_TYPE="unknown"
if   [[ "$ACTIVE_GPU_DRIVER" == "nvidia" ]];  then GPU_DRIVER_TYPE="nvidia"
elif [[ "$ACTIVE_GPU_DRIVER" == "amdgpu" ]];  then GPU_DRIVER_TYPE="amdgpu"
elif [[ "$ACTIVE_GPU_DRIVER" == "radeon" ]];  then GPU_DRIVER_TYPE="radeon"
elif [[ "$ACTIVE_GPU_DRIVER" == "i915" ]];    then GPU_DRIVER_TYPE="intel"
elif [[ "$ACTIVE_GPU_DRIVER" == "xe" ]];      then GPU_DRIVER_TYPE="intel"
elif [[ "$ACTIVE_GPU_DRIVER" == "nouveau" ]]; then GPU_DRIVER_TYPE="nouveau"
fi
log "GPU driver type: $GPU_DRIVER_TYPE"

# ── Motherboard ───────────────────────────────────────────────────────────────
MB_MANUFACTURER=$(cat /sys/class/dmi/id/board_vendor  2>/dev/null || echo "Unknown")
MB_MODEL=$(cat        /sys/class/dmi/id/board_name    2>/dev/null || echo "Unknown")
MB_VERSION=$(cat      /sys/class/dmi/id/board_version 2>/dev/null || echo "Unknown")
info "Motherboard: $MB_MANUFACTURER $MB_MODEL ($MB_VERSION)"

MB_TYPE="generic"
if   echo "$MB_MANUFACTURER" | grep -qi "MSI\|Micro-Star"; then MB_TYPE="msi";     log "MSI motherboard confirmed"
elif echo "$MB_MANUFACTURER" | grep -qi "ASUS\|ASUSTeK";   then MB_TYPE="asus";    log "ASUS motherboard detected"
elif echo "$MB_MANUFACTURER" | grep -qi "Gigabyte";         then MB_TYPE="gigabyte";log "Gigabyte motherboard detected"
elif echo "$MB_MANUFACTURER" | grep -qi "ASRock";           then MB_TYPE="asrock";  log "ASRock motherboard detected"
fi

# ── RAM ───────────────────────────────────────────────────────────────────────
RAM_GB=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
[[ "$RAM_GB" -lt 16 ]] && record_warning "Only ${RAM_GB}GB RAM detected -- 16GB+ recommended for video production"
info "RAM: ${RAM_GB}GB"

# ── Storage ───────────────────────────────────────────────────────────────────
DISK_TYPE="hdd"
for dev in /sys/block/nvme* /sys/block/sd*; do
  [[ -f "$dev/queue/rotational" ]] && [[ "$(cat "$dev/queue/rotational" 2>/dev/null)" == "0" ]] && {
    DISK_TYPE="ssd_or_nvme"; break
  }
done
info "Primary storage: $DISK_TYPE"

# ── Focusrite Scarlett USB Detection ──────────────────────────────────────────
SCARLETT_DETECTED=false
SCARLETT_GEN="3rd"
SCARLETT_MODEL="Scarlett 3rd Gen (assumed from build spec)"

if has_cmd lsusb; then
  USB_DEVICES=$(lsusb 2>/dev/null || true)
  if echo "$USB_DEVICES" | grep -q "1235:"; then
    FOCUSRITE_LINE=$(echo "$USB_DEVICES" | grep "1235:" | head -1)
    PRODUCT_ID=$(echo "$FOCUSRITE_LINE" | grep -oP '1235:\K[0-9a-fA-F]+' || echo "")
    SCARLETT_DETECTED=true

    case "${PRODUCT_ID,,}" in
      8210) SCARLETT_GEN="3rd";     SCARLETT_MODEL="Scarlett 2i2 3rd Gen" ;;
      8211) SCARLETT_GEN="3rd";     SCARLETT_MODEL="Scarlett Solo 3rd Gen" ;;
      8212) SCARLETT_GEN="3rd";     SCARLETT_MODEL="Scarlett 4i4 3rd Gen" ;;
      8213) SCARLETT_GEN="3rd";     SCARLETT_MODEL="Scarlett 8i6 3rd Gen" ;;
      8214) SCARLETT_GEN="3rd";     SCARLETT_MODEL="Scarlett 18i8 3rd Gen" ;;
      8215) SCARLETT_GEN="3rd";     SCARLETT_MODEL="Scarlett 18i20 3rd Gen" ;;
      8202) SCARLETT_GEN="2nd";     SCARLETT_MODEL="Scarlett 6i6 2nd Gen" ;;
      8204) SCARLETT_GEN="2nd";     SCARLETT_MODEL="Scarlett 18i8 2nd Gen" ;;
      8206) SCARLETT_GEN="2nd";     SCARLETT_MODEL="Scarlett 18i20 2nd Gen" ;;
      8220) SCARLETT_GEN="4th";     SCARLETT_MODEL="Scarlett Solo 4th Gen" ;;
      8221) SCARLETT_GEN="4th";     SCARLETT_MODEL="Scarlett 2i2 4th Gen" ;;
      8222) SCARLETT_GEN="4th";     SCARLETT_MODEL="Scarlett 4i4 4th Gen" ;;
      8223) SCARLETT_GEN="4th_fcp"; SCARLETT_MODEL="Scarlett 16i16 4th Gen (FCP)" ;;
      8224) SCARLETT_GEN="4th_fcp"; SCARLETT_MODEL="Scarlett 18i16 4th Gen (FCP)" ;;
      8225) SCARLETT_GEN="4th_fcp"; SCARLETT_MODEL="Scarlett 18i20 4th Gen (FCP)" ;;
      820c) SCARLETT_GEN="clarett"; SCARLETT_MODEL="Clarett+ 8Pre" ;;
      820d) SCARLETT_GEN="clarett"; SCARLETT_MODEL="Clarett USB 8Pre" ;;
      "")   SCARLETT_GEN="3rd";     SCARLETT_MODEL="Focusrite device (ID parse failed -- assuming 3rd Gen)" ;;
      *)    SCARLETT_GEN="3rd";     SCARLETT_MODEL="Focusrite device (ID: $PRODUCT_ID -- assuming 3rd Gen)" ;;
    esac
    log "Focusrite detected: $SCARLETT_MODEL (gen: $SCARLETT_GEN)"
  else
    info "Scarlett not detected via USB -- alsa-scarlett-gui will still be installed"
    info "Plug in your Scarlett before running if you want precise model detection"
  fi
else
  record_warning "lsusb not available -- Focusrite USB detection skipped. Will install for assumed 3rd Gen."
fi

# ── Detection Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}--- Detection Summary -----------------------------------------${NC}"
echo -e "  CPU     : $CPU_MODEL ($CPU_TYPE, $CPU_CORES threads)"
echo -e "  GPU     : ${GPU_INFO:-(none detected)}"
echo -e "  DRIVER  : ${ACTIVE_GPU_DRIVER:-none} ($GPU_DRIVER_TYPE)"
echo -e "  MOBO    : $MB_MANUFACTURER $MB_MODEL ($MB_TYPE)"
echo -e "  RAM     : ${RAM_GB}GB"
echo -e "  DISK    : $DISK_TYPE"
echo -e "  SCARLETT: $SCARLETT_MODEL (gen: $SCARLETT_GEN)"
echo -e "${BOLD}--------------------------------------------------------------${NC}"
echo ""

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Pre-flight warnings:${NC}"
  for w in "${WARNINGS[@]}"; do echo -e "  ${YELLOW}!!${NC} $w"; done
  echo ""
fi

read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted by user."; exit 0
fi

# =============================================================================
#  STEP 2 -- SYSTEM PREP
# =============================================================================
section "System Update & Prerequisites"

info "Updating package lists..."
if ! apt-get update -y 2>&1; then
  record_error "apt update failed" "Check internet connection and /etc/apt/sources.list"
fi

info "Upgrading existing packages..."
if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1; then
  record_warning "apt upgrade had issues -- continuing with remaining steps"
fi

safe_apt "Core build tools & utilities" \
  curl wget git software-properties-common \
  build-essential dkms \
  pciutils dmidecode lshw usbutils \
  cpufrequtils htop nvtop \
  flatpak alsa-utils

# Flathub remote -- idempotent, --if-not-exists handles reruns
safe_run "Flathub remote" "Run: flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo" \
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
#  STEP 3 -- GPU SUPPORT LIBRARIES
#  Detects the active GPU driver and installs the matching userspace
#  libraries (Vulkan, VAAPI, VDPAU). Does NOT install or modify any driver.
# =============================================================================
section "GPU Support Libraries"

info "Active GPU driver detected: ${ACTIVE_GPU_DRIVER:-none} ($GPU_DRIVER_TYPE)"

# Vulkan loader -- needed by all GPU types
safe_apt "Vulkan loader + tools" libvulkan1 vulkan-tools

if [[ "$GPU_DRIVER_TYPE" == "nvidia" ]]; then
  # NVIDIA driver already installed and active -- add NVENC/NVDEC support libs
  NVDRIVER=$(dpkg-query -l 'nvidia-driver-*' 2>/dev/null | grep "^ii" | awk '{print $2}' | head -1 || true)
  log "NVIDIA driver active: ${NVDRIVER:-confirmed via /sys}"
  safe_apt "NVIDIA CUDA toolkit (NVENC/NVDEC)" nvidia-cuda-toolkit
  info "NVENC encoder available in OBS: Settings -> Output -> NVENC H.264 / NVENC HEVC"
  info "FFmpeg NVENC usage: -c:v h264_nvenc or -c:v hevc_nvenc"

elif [[ "$GPU_DRIVER_TYPE" =~ ^(amdgpu|radeon)$ ]]; then
  safe_apt "AMD Vulkan + VAAPI libs" \
    mesa-vulkan-drivers mesa-vdpau-drivers \
    libva-dev libva-drm2 libva-x11-2
  info "FFmpeg VAAPI usage: -hwaccel vaapi -c:v h264_vaapi"

elif [[ "$GPU_DRIVER_TYPE" == "intel" ]]; then
  safe_apt "Intel Vulkan + VAAPI + QuickSync libs" \
    mesa-vulkan-drivers \
    intel-media-va-driver i965-va-driver \
    libva-dev libva-drm2 libva-x11-2
  info "FFmpeg VAAPI/QSV usage: -hwaccel vaapi -c:v h264_vaapi"

elif [[ "$GPU_DRIVER_TYPE" == "nouveau" ]]; then
  safe_apt "Nouveau Vulkan + VAAPI libs" \
    mesa-vulkan-drivers mesa-vdpau-drivers \
    libva-dev libva-drm2 libva-x11-2
  record_warning "Nouveau driver active -- limited performance. Install the proprietary NVIDIA driver for full gaming and encoding support."

else
  record_warning "No recognised GPU driver detected (found: ${ACTIVE_GPU_DRIVER:-none}) -- skipping GPU-specific libs. Install your GPU driver first and re-run this script."
fi

# =============================================================================
#  STEP 4 -- CPU OPTIMISATIONS
# =============================================================================
section "CPU Optimisations"

if [[ "$CPU_TYPE" == "amd" ]]; then

  safe_apt "AMD microcode + cpufrequtils" amd64-microcode cpufrequtils

  # AMD P-State -- add to GRUB only if not already present
  GRUB_FILE="/etc/default/grub"
  if grep -q "amd_pstate" "$GRUB_FILE" 2>/dev/null; then
    skipped "AMD P-State GRUB entry (already configured)"
    SKIPPED+=("AMD P-State GRUB")
  else
    cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_pstate=active"/' "$GRUB_FILE" && \
      log "AMD P-State added to GRUB" || \
      record_error "Failed to update GRUB for AMD P-State" "Manually add amd_pstate=active to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
  fi

  # CPU governor
  if [[ -f /etc/default/cpufrequtils ]]; then
    if grep -q 'GOVERNOR="performance"' /etc/default/cpufrequtils; then
      skipped "CPU governor (already set to performance)"
      SKIPPED+=("CPU governor")
    else
      echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils && \
        log "CPU governor set to performance" || \
        record_error "Failed to set CPU governor" "Manually edit /etc/default/cpufrequtils"
    fi
  else
    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils && \
      log "CPU governor set to performance" || \
      record_error "Failed to create /etc/default/cpufrequtils"
  fi
  cpufreq-set -g performance 2>/dev/null || true  # Best-effort live apply

  # Ryzen X3D optimisations
  if echo "$RYZEN_GEN" | grep -q "x3d"; then
    if [[ -f /etc/systemd/system/ryzen-x3d-opt.service ]]; then
      skipped "Ryzen X3D systemd service"
      SKIPPED+=("Ryzen X3D service")
    else
      cat > /etc/systemd/system/ryzen-x3d-opt.service <<'SVCEOF'
[Unit]
Description=Ryzen X3D 3D V-Cache Optimisations
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 0 > /proc/sys/kernel/numa_balancing'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
      safe_run "Ryzen X3D service enable" \
        "Run: sudo systemctl enable ryzen-x3d-opt" \
        systemctl enable ryzen-x3d-opt
    fi
  fi

elif [[ "$CPU_TYPE" == "intel" ]]; then

  safe_apt "Intel microcode + cpufrequtils" intel-microcode cpufrequtils

  if ! grep -q 'GOVERNOR="performance"' /etc/default/cpufrequtils 2>/dev/null; then
    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils && \
      log "CPU governor set to performance" || \
      record_error "Failed to set CPU governor"
  else
    skipped "CPU governor (already set to performance)"
    SKIPPED+=("CPU governor")
  fi

fi

# =============================================================================
#  STEP 5 -- MOTHERBOARD TWEAKS
# =============================================================================
section "Motherboard Configuration"

if [[ "$MB_TYPE" == "msi" ]]; then

  safe_write "MSI USB polling udev rule" /etc/udev/rules.d/60-usb-polling.rules <<'UDEVEOF'
# Disable USB autosuspend for gaming/audio peripherals on MSI boards
SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"
UDEVEOF

  # Scheduler tweaks -- append only if not already present
  safe_append "MSI scheduler tweaks" /etc/sysctl.conf \
    "kernel.sched_min_granularity_ns = 100000"
  safe_append "MSI sched wakeup" /etc/sysctl.conf \
    "kernel.sched_wakeup_granularity_ns = 150000"
  safe_append "MSI sched migration" /etc/sysctl.conf \
    "kernel.sched_migration_cost_ns = 250000"

elif [[ "$MB_TYPE" == "asus" ]]; then
  info "ASUS board: manual BIOS tuning recommended (AI Suite not available on Linux)"
fi

# =============================================================================
#  STEP 6 -- CODECS & MEDIA LIBRARIES
# =============================================================================
section "Codecs & Media Libraries"

media "Installing FFmpeg and codec libraries..."

# Ubuntu restricted extras (MP3, H.264, AAC etc.)
if ! pkg_installed ubuntu-restricted-extras && ! pkg_installed ubuntu-restricted-addons; then
  safe_apt_full "Ubuntu restricted extras (codecs)" ubuntu-restricted-extras
else
  skipped "Ubuntu restricted extras (already installed)"
  SKIPPED+=("Ubuntu restricted extras")
fi

safe_apt "FFmpeg full build" ffmpeg libavcodec-extra

safe_apt "FFmpeg development libraries" \
  libavformat-dev libavutil-dev \
  libswscale-dev libswresample-dev libavfilter-dev

safe_apt "GStreamer core stack" \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-libav \
  gstreamer1.0-pipewire

safe_apt "Image codec libraries" \
  libheif-dev libraw-dev \
  libjpeg-dev libpng-dev libtiff-dev libwebp-dev

safe_apt "GStreamer VAAPI plugin" gstreamer1.0-vaapi

# VAAPI FFmpeg check -- informational only
if ffmpeg -hwaccels 2>/dev/null | grep -q vaapi; then
  log "FFmpeg VAAPI acceleration: READY"
  info "FFmpeg VAAPI usage: -hwaccel vaapi -c:v h264_vaapi"
else
  info "FFmpeg VAAPI will be active once GPU drivers are installed"
fi

# =============================================================================
#  STEP 7 -- AUDIO STACK (PIPEWIRE + JACK)
# =============================================================================
section "Audio Stack -- PipeWire & JACK"

safe_apt "PipeWire full stack" \
  pipewire pipewire-audio \
  pipewire-pulse pipewire-jack \
  wireplumber pavucontrol qpwgraph

safe_apt "JACK pro audio" jackd2 jack-tools qjackctl a2jmidid

# Add user to audio group (idempotent -- groups -G handles existing membership)
if id "$SUDO_USER_NAME" 2>/dev/null | grep -q "audio"; then
  skipped "User $SUDO_USER_NAME already in audio group"
  SKIPPED+=("Audio group membership")
else
  usermod -aG audio "$SUDO_USER_NAME" 2>/dev/null && \
    log "User $SUDO_USER_NAME added to audio group" || \
    record_error "Failed to add $SUDO_USER_NAME to audio group" \
      "Run: sudo usermod -aG audio $SUDO_USER_NAME"
fi

# Realtime audio limits -- only write if not already configured
if [[ -f /etc/security/limits.d/99-realtime-audio.conf ]]; then
  skipped "Realtime audio limits (already configured)"
  SKIPPED+=("Realtime audio limits")
else
  safe_write "Realtime audio limits" /etc/security/limits.d/99-realtime-audio.conf <<'EOF'
# Realtime audio priority for pro audio production
@audio   -  rtprio     99
@audio   -  memlock    unlimited
@audio   -  nice      -19
EOF
fi

# PipeWire low-latency config -- only write if not already configured
if [[ -f /etc/pipewire/pipewire.conf.d/99-gaming-media.conf ]]; then
  skipped "PipeWire low-latency config (already configured)"
  SKIPPED+=("PipeWire config")
else
  mkdir -p /etc/pipewire/pipewire.conf.d
  safe_write "PipeWire low-latency config" \
    /etc/pipewire/pipewire.conf.d/99-gaming-media.conf <<'EOF'
context.properties = {
  default.clock.rate          = 48000
  default.clock.quantum       = 512
  default.clock.min-quantum   = 32
  default.clock.max-quantum   = 2048
}
EOF
fi

# =============================================================================
#  STEP 7.5 -- FOCUSRITE SCARLETT (alsa-scarlett-gui)
#  Follows: https://github.com/geoffreybennett/alsa-scarlett-gui/blob/master/docs/INSTALL.md
# =============================================================================
section "Focusrite Scarlett -- alsa-scarlett-gui"

media "Detected: $SCARLETT_MODEL (Gen: $SCARLETT_GEN)"

# Kernel version check (Scarlett2 driver needs 6.7+; Zorin OS 18 ships 6.14)
KERNEL_VER=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL_VER" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VER" | cut -d. -f2 | cut -d- -f1)
info "Running kernel: $KERNEL_VER"

KERNEL_OK=true
if [[ "$KERNEL_MAJOR" -lt 6 ]] || { [[ "$KERNEL_MAJOR" -eq 6 ]] && [[ "$KERNEL_MINOR" -lt 7 ]]; }; then
  KERNEL_OK=false
  record_error "Kernel $KERNEL_VER is older than 6.7 -- Scarlett2 driver requires 6.7+" \
    "See: https://github.com/geoffreybennett/alsa-scarlett-gui/blob/master/docs/OLDKERNEL.md"
else
  log "Kernel $KERNEL_VER: Scarlett2 driver supported"
fi

if [[ "$SCARLETT_DETECTED" == "true" ]]; then
  if dmesg 2>/dev/null | grep -qi "Focusrite Scarlett.*Mixer Driver enabled"; then
    log "Scarlett2 kernel driver: ACTIVE"
  else
    record_warning "Scarlett Mixer Driver not seen in dmesg yet -- verify after reboot with: dmesg | grep -i focusrite"
  fi
fi

# Install build dependencies (exact Ubuntu deps per INSTALL.md)
safe_apt "alsa-scarlett-gui build dependencies" \
  git make gcc libgtk-4-dev libasound2-dev libssl-dev

# Clone / update alsa-scarlett-gui
BUILD_DIR="/opt/alsa-scarlett-gui"
safe_clone "alsa-scarlett-gui" \
  "https://github.com/geoffreybennett/alsa-scarlett-gui.git" \
  "$BUILD_DIR"

# Build -- only rebuild if binary is missing or source is newer
BINARY="/usr/local/bin/alsa-scarlett-gui"
if [[ -x "$BINARY" ]] && [[ -d "$BUILD_DIR/src" ]]; then
  SOURCE_MOD=$(find "$BUILD_DIR/src" -name "*.c" -newer "$BINARY" 2>/dev/null | wc -l)
  if [[ "$SOURCE_MOD" -eq 0 ]]; then
    skipped "alsa-scarlett-gui binary (already built and up to date)"
    SKIPPED+=("alsa-scarlett-gui build")
  else
    info "Source files newer than binary -- rebuilding..."
    SOURCE_MOD=999  # Force rebuild path below
  fi
else
  SOURCE_MOD=999  # Force build
fi

if [[ "$SOURCE_MOD" -gt 0 ]]; then
  if [[ -d "$BUILD_DIR/src" ]]; then
    info "Building alsa-scarlett-gui..."
    if make -C "$BUILD_DIR/src" 2>&1; then
      log "alsa-scarlett-gui built successfully"
      if make -C "$BUILD_DIR/src" install 2>&1; then
        log "alsa-scarlett-gui installed to /usr/local/bin/"
        INSTALLED+=("alsa-scarlett-gui")
      else
        record_error "alsa-scarlett-gui make install failed" \
          "Run manually: cd $BUILD_DIR/src && sudo make install"
      fi
    else
      record_error "alsa-scarlett-gui build (make) failed" \
        "Check build deps: git make gcc libgtk-4-dev libasound2-dev libssl-dev"
    fi
  else
    record_error "alsa-scarlett-gui source directory not found ($BUILD_DIR/src)" \
      "Clone manually: git clone https://github.com/geoffreybennett/alsa-scarlett-gui.git $BUILD_DIR"
  fi
fi

# Firmware setup
mkdir -p /usr/lib/firmware/scarlett2 /usr/lib/firmware/scarlett4

# scarlett2-firmware: recommended for Gen 2/3, mandatory for Gen 4
if [[ "$SCARLETT_GEN" =~ ^(2nd|3rd|clarett|4th)$ ]]; then
  FIRMWARE_DEST="/usr/lib/firmware/scarlett2"
  if [[ -n "$(ls -A "$FIRMWARE_DEST" 2>/dev/null)" ]]; then
    skipped "scarlett2-firmware (already present in $FIRMWARE_DEST)"
    SKIPPED+=("scarlett2-firmware")
  else
    media "Downloading scarlett2-firmware..."
    FW2_DIR="/tmp/scarlett2-firmware-dl"
    if safe_clone "scarlett2-firmware" \
        "https://github.com/geoffreybennett/scarlett2-firmware.git" "$FW2_DIR"; then
      cp -r "$FW2_DIR"/firmware/* "$FIRMWARE_DEST/" 2>/dev/null && \
        log "scarlett2-firmware installed to $FIRMWARE_DEST" || \
        record_error "Failed to copy scarlett2-firmware files" \
          "Copy manually from $FW2_DIR/firmware/ to $FIRMWARE_DEST/"
    fi
  fi
fi

# scarlett4-firmware: mandatory for 4th Gen
if [[ "$SCARLETT_GEN" =~ ^(4th|4th_fcp)$ ]]; then
  FIRMWARE4_DEST="/usr/lib/firmware/scarlett4"
  if [[ -n "$(ls -A "$FIRMWARE4_DEST" 2>/dev/null)" ]]; then
    skipped "scarlett4-firmware (already present in $FIRMWARE4_DEST)"
    SKIPPED+=("scarlett4-firmware")
  else
    media "Downloading scarlett4-firmware (mandatory for 4th Gen)..."
    FW4_DIR="/tmp/scarlett4-firmware-dl"
    if safe_clone "scarlett4-firmware" \
        "https://github.com/geoffreybennett/scarlett4-firmware.git" "$FW4_DIR"; then
      cp -r "$FW4_DIR"/firmware/* "$FIRMWARE4_DEST/" 2>/dev/null && \
        log "scarlett4-firmware installed to $FIRMWARE4_DEST" || \
        record_error "Failed to copy scarlett4-firmware files (mandatory for 4th Gen!)" \
          "Copy manually from $FW4_DIR/firmware/ to $FIRMWARE4_DEST/"
    fi
  fi
fi

# fcp-server daemon -- required for Scarlett 4th Gen big interfaces
if [[ "$SCARLETT_GEN" == "4th_fcp" ]]; then
  if has_cmd fcp-server; then
    skipped "fcp-server (already installed)"
    SKIPPED+=("fcp-server")
  else
    media "Building fcp-server (required for 4th Gen 16i16/18i16/18i20)..."
    FCP_DIR="/opt/fcp-support"
    if safe_clone "fcp-support" \
        "https://github.com/geoffreybennett/fcp-support.git" "$FCP_DIR"; then
      if make -C "$FCP_DIR" 2>&1 && make -C "$FCP_DIR" install 2>&1; then
        safe_run "fcp-server service enable" \
          "Run: sudo systemctl enable fcp-server" \
          systemctl enable fcp-server
        log "fcp-server installed and enabled"
        INSTALLED+=("fcp-server")
      else
        record_error "fcp-server build failed (required for 4th Gen big interfaces)" \
          "Build manually from: $FCP_DIR"
      fi
    fi
  fi
fi

# MSD mode notice
if [[ "$SCARLETT_GEN" =~ ^(3rd|4th|4th_fcp)$ ]]; then
  echo ""
  warn "ACTION REQUIRED -- MSD (Mass Storage Device) Mode:"
  info "  Scarlett 3rd/4th Gen ships in MSD mode which blocks full driver access."
  info "  To disable:"
  info "    Option 1 (Hardware): Hold the 48V button while powering on the Scarlett"
  info "    Option 2 (Software): Run alsa-scarlett-gui -> Startup window -> Disable MSD Mode -> reboot interface"
  echo ""
fi

# Disable alsa-state / alsa-restore -- they overwrite Scarlett's stored settings on reconnect
for svc in alsa-state alsa-restore; do
  if systemctl is-enabled "$svc" &>/dev/null; then
    systemctl disable "$svc" 2>/dev/null && \
      log "$svc disabled (prevents Scarlett settings overwrite)" || \
      record_error "Failed to disable $svc" "Run: sudo systemctl disable $svc"
    systemctl stop "$svc" 2>/dev/null || true
  else
    skipped "$svc (already disabled or not present)"
    SKIPPED+=("$svc disable")
  fi
done

log "Focusrite Scarlett setup complete"

# =============================================================================
#  STEP 8 -- MEDIA & VIDEO PRODUCTION SOFTWARE
# =============================================================================
section "Media & Video Production Software"

# Video players
safe_apt "VLC + MPV" vlc mpv

# MPV hardware-accelerated config -- write once, don't overwrite user changes
MPV_CONF="$USER_HOME/.config/mpv/mpv.conf"
if [[ -f "$MPV_CONF" ]]; then
  skipped "MPV config (already exists -- not overwriting user config)"
  SKIPPED+=("MPV config")
else
  mkdir -p "$USER_HOME/.config/mpv"
  cat > "$MPV_CONF" <<'MPVEOF'
# MPV -- hardware accelerated via VAAPI, high quality scaling
profile=gpu-hq
scale=lanczos
cscale=spline36
dscale=mitchell
video-sync=display-resample
interpolation=yes
tscale=oversample
hwdec=vaapi
gpu-api=vulkan
MPVEOF
  chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$USER_HOME/.config/mpv" 2>/dev/null || true
  log "MPV config written with VAAPI hardware acceleration"
  INSTALLED+=("MPV config")
fi

# Video editing
safe_flatpak "Kdenlive NLE"  "org.kde.kdenlive"
safe_flatpak "HandBrake"     "fr.handbrake.ghb"

echo ""
media "DaVinci Resolve: manual install required"
info "  -> https://www.blackmagicdesign.com/products/davinciresolve"
info "  -> AMD: free version supported (ROCM support varies by card)"
echo ""

# Streaming
safe_ppa "ppa:obsproject/obs-studio"
safe_apt_full "OBS Studio" obs-studio
info "OBS: Settings -> Output -> Encoder -> VA-API H.264 (once GPU drivers installed)"

# Photo editing
safe_apt "GIMP + plugins" gimp gimp-plugin-registry gimp-gmic
safe_apt "Photo management" rawtherapee darktable

# Audio production
safe_apt "Hydrogen drum machine" hydrogen

# Media inspection
safe_apt "Media management tools" \
  mediainfo mediainfo-gui \
  mkvtoolnix mkvtoolnix-gui \
  ffmpegthumbnailer exiftool

# GameMode + MangoHud
safe_apt "GameMode + MangoHud" gamemode mangohud

# =============================================================================
#  STEP 9 -- SYSTEM-WIDE PERFORMANCE TWEAKS
# =============================================================================
section "System Performance Tweaks"

# vm.max_map_count
safe_append "vm.max_map_count (Proton/Wine games)" /etc/sysctl.conf \
  "vm.max_map_count=2147483642"

# inotify watches
safe_append "inotify watches (video project files)" /etc/sysctl.conf \
  "fs.inotify.max_user_watches=524288"

# Network gaming optimisations -- append individually for idempotency
safe_append "net rmem_max" /etc/sysctl.conf "net.core.rmem_max=134217728"
safe_append "net wmem_max" /etc/sysctl.conf "net.core.wmem_max=134217728"
safe_append "net tcp_fastopen" /etc/sysctl.conf "net.ipv4.tcp_fastopen=3"
safe_append "net netdev_max_backlog" /etc/sysctl.conf "net.core.netdev_max_backlog=5000"

# NMI watchdog off
safe_append "NMI watchdog off" /etc/sysctl.conf "kernel.nmi_watchdog=0"

# Apply sysctl now (best-effort -- some keys may not exist on all kernels)
sysctl -p 2>/dev/null || record_warning "Some sysctl settings could not be applied live -- will apply on reboot"
log "sysctl settings applied"

# I/O scheduler
if [[ ! -f /etc/udev/rules.d/60-ioscheduler.rules ]]; then
  safe_write "I/O scheduler udev rules" /etc/udev/rules.d/60-ioscheduler.rules <<'UDEVEOF'
# NVMe/SSD: no scheduler (max throughput for video files)
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
# HDD: mq-deadline (sequential video reads)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
UDEVEOF
else
  skipped "I/O scheduler udev rules (already configured)"
  SKIPPED+=("I/O scheduler rules")
fi

# THP -- madvise is the right balance: gaming anti-stutter + video editor compat
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

if [[ ! -f /etc/systemd/system/thp-madvise.service ]]; then
  safe_write "THP madvise systemd service" /etc/systemd/system/thp-madvise.service <<'SVCEOF'
[Unit]
Description=Set THP to madvise (gaming anti-stutter + video editor compat)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled && echo madvise > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
  safe_run "THP madvise service enable" \
    "Run: sudo systemctl enable thp-madvise" \
    systemctl enable thp-madvise
else
  skipped "THP madvise service (already configured)"
  SKIPPED+=("THP madvise service")
fi

# =============================================================================
#  STEP 10 -- GAMING SOFTWARE STACK
# =============================================================================
section "Gaming Software Stack"

# 32-bit architecture (idempotent)
if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q i386; then
  safe_run "Enable 32-bit architecture" \
    "Run: sudo dpkg --add-architecture i386 && sudo apt update" \
    dpkg --add-architecture i386
  apt-get update -y 2>&1 || record_warning "apt update after enabling i386 had warnings"
else
  skipped "32-bit (i386) architecture (already enabled)"
  SKIPPED+=("i386 architecture")
fi

safe_apt "Wine 64+32-bit + Winetricks" \
  wine wine32 wine64 winetricks \
  cabextract unzip p7zip-full

# Steam
if has_cmd steam || pkg_installed steam-installer; then
  skipped "Steam (already installed)"
  SKIPPED+=("Steam")
else
  safe_apt_full "Steam" steam-installer
fi

# Lutris
if has_cmd lutris; then
  skipped "Lutris (already installed)"
  SKIPPED+=("Lutris")
else
  safe_ppa "ppa:lutris-team/lutris"
  safe_apt_full "Lutris" lutris
fi

safe_flatpak "ProtonUp-Qt"    "net.davidotek.pupgui2"
safe_flatpak "Heroic Launcher" "com.heroicgameslauncher.hgl"
safe_flatpak "Bottles"         "com.usebottles.bottles"

# =============================================================================
#  STEP 11 -- GAMEMODE & MANGOHUD CONFIG
# =============================================================================
section "GameMode & MangoHud"

# Enable GameMode daemon globally (idempotent)
systemctl --global enable gamemoded 2>/dev/null || \
  record_warning "Could not enable gamemoded globally -- may need to enable per-user"

# GameMode group
if getent group gamemode &>/dev/null; then
  if id "$SUDO_USER_NAME" 2>/dev/null | grep -q "gamemode"; then
    skipped "$SUDO_USER_NAME already in gamemode group"
    SKIPPED+=("gamemode group membership")
  else
    usermod -aG gamemode "$SUDO_USER_NAME" 2>/dev/null && \
      log "$SUDO_USER_NAME added to gamemode group" || \
      record_error "Failed to add $SUDO_USER_NAME to gamemode group" \
        "Run: sudo usermod -aG gamemode $SUDO_USER_NAME"
  fi
fi

# MangoHud config -- only write if not already present
MANGOHUD_CONF="$USER_HOME/.config/MangoHud/MangoHud.conf"
if [[ -f "$MANGOHUD_CONF" ]]; then
  skipped "MangoHud config (already exists -- not overwriting)"
  SKIPPED+=("MangoHud config")
else
  mkdir -p "$USER_HOME/.config/MangoHud"
  cat > "$MANGOHUD_CONF" <<MHEOF
# MangoHud -- Zorin OS 18 Gaming & Media Beast
gpu_stats
gpu_temp
gpu_load_change
gpu_name
cpu_stats
cpu_temp
cpu_mhz
fps
fps_limit=0
frame_timing
vram
ram
io_stats
network
show_fps_limit
toggle_hud=Shift_R+F12
toggle_logging=Shift_L+F2
output_folder=$USER_HOME/.local/share/MangoHud/
MHEOF
  chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$USER_HOME/.config/MangoHud" 2>/dev/null || true
  log "MangoHud configured (toggle: RShift+F12)"
  INSTALLED+=("MangoHud config")
fi

# =============================================================================
#  STEP 12 -- DISPLAY SERVER (WAYLAND)
# =============================================================================
section "Display Server -- Wayland"

log "Zorin OS 18 uses Wayland by default -- no display server configuration needed"
info "GPU driver (AMD/Intel) fully supports Wayland on kernel 6.14"

# Ensure GDM is not locked to X11 from any previous configuration
GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "$GDM_CONF" ]] && grep -q "WaylandEnable=false" "$GDM_CONF"; then
  sed -i 's/WaylandEnable=false/WaylandEnable=true/' "$GDM_CONF" && \
    log "GDM Wayland re-enabled (was previously disabled)" || \
    record_warning "Could not re-enable Wayland in GDM -- check $GDM_CONF"
else
  log "GDM Wayland: enabled (default)"
fi

# Remove any X11-forcing environment overrides
if [[ -f /etc/environment ]] && grep -q "GDK_BACKEND=x11" /etc/environment; then
  sed -i '/GDK_BACKEND=x11/d' /etc/environment && \
    log "Removed GDK_BACKEND=x11 from /etc/environment" || \
    record_warning "Could not remove GDK_BACKEND=x11 from /etc/environment"
fi

# =============================================================================
#  STEP 13 -- GRUB UPDATE & CLEANUP
# =============================================================================
section "GRUB Update & Cleanup"

safe_run "GRUB update" "Run: sudo update-grub" update-grub

apt-get autoremove -y 2>&1 || record_warning "apt autoremove had warnings"
apt-get autoclean  -y 2>&1 || record_warning "apt autoclean had warnings"
log "System cleaned up"

# =============================================================================
#  FINAL REPORT
# =============================================================================
section "Setup Complete -- Final Report"

echo -e "${BOLD}${GREEN}"
echo "  +======================================================+"
echo "  |   Zorin OS 18 -- Gaming & Media Beast Setup Done!   |"
echo "  +======================================================+"
echo -e "${NC}"

echo -e "${BOLD}Detected Hardware:${NC}"
echo "  CPU     : $CPU_MODEL ($CPU_TYPE, $CPU_CORES threads)"
echo "  GPU     : $GPU_INFO"
echo "  DRIVER  : ${ACTIVE_GPU_DRIVER:-none} ($GPU_DRIVER_TYPE)"
echo "  MOBO    : $MB_MANUFACTURER $MB_MODEL ($MB_TYPE)"
echo "  RAM     : ${RAM_GB}GB | DISK: $DISK_TYPE"
echo "  Scarlett: $SCARLETT_MODEL (gen: $SCARLETT_GEN)"
echo ""

# Installed this run
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  echo -e "${BOLD}${GREEN}Installed this run (${#INSTALLED[@]} items):${NC}"
  for item in "${INSTALLED[@]}"; do echo "  [OK] $item"; done
  echo ""
fi

# Skipped (already present)
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo -e "${BOLD}${BLUE}Already installed / skipped (${#SKIPPED[@]} items):${NC}"
  for item in "${SKIPPED[@]}"; do echo "  [--] $item"; done
  echo ""
fi

# Post-reboot steps
echo -e "${BOLD}Post-Reboot Steps:${NC}"
echo "  1. Steam -> Settings -> Compatibility"
echo "     -> Enable Steam Play for all titles"
echo "     -> Install Proton-GE via ProtonUp-Qt"
echo ""
echo "  2. Per-game Steam launch options:"
echo "     DXVK_ASYNC=1 gamemoderun mangohud %command%"
echo ""
echo "  3. OBS Studio -> Settings -> Output -> Encoder -> VA-API H.264"
echo ""
echo "     -> Enable A-XMP/EXPO (RAM rated speed)"
echo "     -> Enable Resizable BAR + Above 4G Decoding"
echo "     -> Set PCIe to Gen 4/5"
echo ""
echo "  5. DaVinci Resolve: https://www.blackmagicdesign.com/products/davinciresolve"
echo ""
echo "  6. Focusrite Scarlett ($SCARLETT_MODEL):"
if [[ "$SCARLETT_GEN" =~ ^(3rd|4th|4th_fcp)$ ]]; then
  echo "     -> Disable MSD mode: hold 48V on power-on OR run alsa-scarlett-gui -> Startup -> Disable MSD"
fi
echo "     -> Run: alsa-scarlett-gui"
echo "     -> Verify driver: dmesg | grep -i focusrite"
echo ""

# ── ERRORS (most important section -- shown last so it's impossible to miss) ──
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo -e "${BOLD}${RED}+----------------------------------------------------+"
  echo -e "| ERRORS ENCOUNTERED (${#ERRORS[@]}) -- ACTION REQUIRED      |"
  echo -e "+----------------------------------------------------+${NC}"
  echo ""
  for i in "${!ERRORS[@]}"; do
    NUM=$((i + 1))
    ENTRY="${ERRORS[$i]}"
    MSG=$(echo "$ENTRY" | sed 's/ || FIX:.*//')
    FIX=$(echo "$ENTRY" | grep -oP '(?<=FIX: ).*' || echo "See log: $LOGFILE")
    echo -e "  ${RED}[$NUM]${NC} ${MSG#ERROR: }"
    echo -e "       ${YELLOW}Fix: $FIX${NC}"
    echo ""
  done
  echo -e "${YELLOW}Full log available at: $LOGFILE${NC}"
  echo ""
  echo -e "${YELLOW}NOTE: The system may still be functional.${NC}"
  echo -e "${YELLOW}      Review each error above and apply the suggested fix.${NC}"
  echo ""
else
  echo -e "${BOLD}${GREEN}No errors encountered. All steps completed successfully.${NC}"
  echo ""
fi

echo -e "${BOLD}${RED}A reboot is required for all changes to take effect.${NC}"
echo ""
read -rp "Reboot now? [Y/n]: " REBOOT_NOW
REBOOT_NOW="${REBOOT_NOW:-Y}"
if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
  info "Rebooting in 5 seconds... Log saved to $LOGFILE"
  sleep 5
  reboot
else
  info "Remember to reboot. Full log: $LOGFILE"
fi
