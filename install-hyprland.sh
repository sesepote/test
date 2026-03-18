#!/usr/bin/env bash
# =============================================================================
#  install-hyprland-nvidia-debian13.sh
#  Instalación automatizada de Hyprland + drivers NVIDIA oficiales
#  para Debian 13 "Trixie" (servidor sin entorno gráfico)
#
#  Ejecutar como root o con sudo desde una sesión TTY.
#  Uso: sudo bash install-hyprland-nvidia-debian13.sh
# =============================================================================

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"; }

# ─── Comprobaciones previas ───────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && error "Este script debe ejecutarse como root (sudo bash $0)"

# Verificar que es Debian 13 Trixie
if ! grep -q "trixie\|13" /etc/os-release 2>/dev/null; then
    warn "No se detectó Debian 13 Trixie. Continúa bajo tu responsabilidad."
    read -rp "¿Continuar de todos modos? [s/N] " RESP
    [[ "${RESP,,}" != "s" ]] && exit 1
fi

# Detectar usuario no-root que ejecutará el entorno gráfico
if [[ -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="$SUDO_USER"
else
    read -rp "¿Nombre del usuario que usará Hyprland? " TARGET_USER
    id "$TARGET_USER" &>/dev/null || error "El usuario '$TARGET_USER' no existe."
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
info "Usuario objetivo: ${BOLD}$TARGET_USER${RESET} (home: $TARGET_HOME)"

# Detectar GPU NVIDIA
if ! lspci | grep -qi "nvidia"; then
    warn "No se detectó ninguna GPU NVIDIA con lspci."
    read -rp "¿Continuar con la instalación de drivers NVIDIA igualmente? [s/N] " RESP
    [[ "${RESP,,}" != "s" ]] && SKIP_NVIDIA=true || SKIP_NVIDIA=false
else
    ok "GPU NVIDIA detectada."
    SKIP_NVIDIA=false
fi

# =============================================================================
# PASO 1 – Configurar repositorios APT (non-free, deb-src, unstable pinning)
# =============================================================================
section "PASO 1 · Configurar repositorios APT"

# Reescribir sources.list con todas las secciones necesarias
cat > /etc/apt/sources.list << 'EOF'
# Debian 13 Trixie – repositorios oficiales (main + contrib + non-free)
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
EOF

# Añadir repositorio Unstable (SID) con pin de baja prioridad
# Solo para dependencias de Hyprland que aún no están en Trixie
cat > /etc/apt/sources.list.d/unstable.list << 'EOF'
# Debian Unstable (SID) – solo para dependencias de Hyprland
deb http://deb.debian.org/debian/ unstable main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ unstable main contrib non-free non-free-firmware
EOF

# Pinning: Trixie tiene máxima prioridad; unstable solo se usa si se pide explícitamente
cat > /etc/apt/preferences.d/99-trixie-priority << 'EOF'
Package: *
Pin: release n=trixie
Pin-Priority: 900

Package: *
Pin: release n=unstable
Pin-Priority: 100
EOF

apt-get update -qq
ok "Repositorios configurados."

# =============================================================================
# PASO 2 – Actualización del sistema y herramientas base
# =============================================================================
section "PASO 2 · Actualización del sistema y herramientas base"

apt-get upgrade -y
apt-get install -y --no-install-recommends \
    curl wget gpg ca-certificates apt-transport-https \
    git build-essential cmake ninja-build meson pkg-config \
    python3 python3-pip \
    software-properties-common \
    lsb-release \
    pciutils usbutils \
    htop fastfetch \
    unzip tar xz-utils
ok "Sistema actualizado y herramientas base instaladas."

# =============================================================================
# PASO 3 – Drivers NVIDIA oficiales (repositorio NVIDIA)
# =============================================================================
if [[ "$SKIP_NVIDIA" == "false" ]]; then
    section "PASO 3 · Drivers NVIDIA – repositorio oficial de NVIDIA"

    DISTRO="debian13"
    ARCH="x86_64"
    KEYRING_PKG="cuda-keyring_1.1-1_all.deb"
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/${ARCH}/${KEYRING_PKG}"

    info "Descargando cuda-keyring desde NVIDIA..."
    wget -q -O "/tmp/${KEYRING_PKG}" "${KEYRING_URL}" \
        || error "No se pudo descargar el keyring de NVIDIA. Verifica conectividad."

    dpkg -i "/tmp/${KEYRING_PKG}"
    rm -f "/tmp/${KEYRING_PKG}"

    # Añadir repo NVIDIA al sources.list.d (ya lo hace el keyring, pero aseguramos)
    apt-get update -qq

    # Instalar headers del kernel (obligatorio en Debian 13 con kernel 6.12)
    KERNEL_VERSION=$(uname -r)
    info "Instalando headers para kernel: ${KERNEL_VERSION}"
    apt-get install -y linux-headers-"${KERNEL_VERSION}" linux-headers-amd64 dkms

    # Blacklist Nouveau antes de instalar el driver propietario
    info "Deshabilitando driver Nouveau..."
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u

    # Instalar driver NVIDIA propietario + utilidades
    info "Instalando nvidia-driver y utilidades NVIDIA..."
    apt-get install -y \
        nvidia-driver \
        nvidia-kernel-dkms \
        nvidia-settings \
        nvidia-smi \
        libcuda1 \
        libnvidia-egl-wayland1

    # Habilitar nvidia-drm.modeset para Wayland (necesario para Hyprland)
    info "Configurando nvidia-drm.modeset=1 en GRUB para Wayland..."
    GRUB_NVIDIA_CONF="/etc/default/grub.d/nvidia-modeset.cfg"
    mkdir -p "$(dirname "$GRUB_NVIDIA_CONF")"
    echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX nvidia-drm.modeset=1"' \
        > "$GRUB_NVIDIA_CONF"

    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg
    fi

    # Servicios de suspensión de NVIDIA
    apt-get install -y nvidia-suspend-common || true
    for svc in nvidia-suspend nvidia-hibernate nvidia-resume; do
        systemctl enable "${svc}.service" 2>/dev/null || true
    done

    ok "Drivers NVIDIA instalados correctamente."
else
    section "PASO 3 · Drivers NVIDIA [OMITIDO]"
    warn "Se omitió la instalación de drivers NVIDIA."
fi

# =============================================================================
# PASO 4 – Dependencias de Wayland y Hyprland
# =============================================================================
section "PASO 4 · Dependencias de Wayland y Hyprland"

# Dependencias disponibles en Trixie
apt-get install -y \
    wayland-protocols \
    libwayland-dev \
    libwayland-client0 \
    libwayland-server0 \
    libwayland-egl1 \
    libwlroots-dev \
    xwayland \
    libxcb1-dev \
    libxcb-util-dev \
    libxcb-keysyms1-dev \
    libxcb-icccm4-dev \
    libxcb-xfixes0-dev \
    libxcb-render-util0-dev \
    libxcb-ewmh-dev \
    libxcb-errors-dev \
    libx11-dev \
    libx11-xcb-dev \
    libxfixes-dev \
    libxcomposite-dev \
    libxrender-dev \
    libxcursor-dev \
    libxkbcommon-dev \
    libxkbcommon-x11-dev \
    libinput-dev \
    libpixman-1-dev \
    libcairo2-dev \
    libpango1.0-dev \
    libglib2.0-dev \
    libegl1-mesa-dev \
    libgles2-mesa-dev \
    libgl1-mesa-dev \
    libdrm-dev \
    libgbm-dev \
    libseat-dev \
    libudev-dev \
    libdisplay-info-dev \
    libliftoff-dev \
    libvulkan-dev \
    libvulkan1 \
    mesa-vulkan-drivers \
    vulkan-tools \
    glslang-tools \
    libtomlplusplus-dev \
    libmuparser-dev \
    libcurl4-openssl-dev \
    liblz4-dev \
    libzip-dev \
    libffi-dev \
    libre2-dev \
    libsystemd-dev \
    libpipewire-0.3-dev \
    pipewire \
    wireplumber \
    gir1.2-pipewire-0.3 \
    gcc-14 g++-14 \
    clang-19 \
    ninja-build \
    cmake \
    meson \
    libcogl-pango-dev || true

ok "Dependencias base de Wayland instaladas."

# Dependencias de Hyprland disponibles parcialmente en unstable
info "Instalando dependencias hypr* desde repositorios (unstable donde sea necesario)..."
apt-get install -y -t unstable \
    libhyprlang-dev \
    libhyprutils-dev \
    libhyprcursor-dev \
    libhyprgraphics-dev \
    libhyprwire-dev \
    libaquamarine-dev \
    hyprwayland-scanner \
    libglaze-dev \
    libtomlplusplus-dev 2>/dev/null || \
    warn "Algunas dependencias hypr* no estaban en unstable; se compilarán desde fuente si es necesario."

ok "Dependencias de Hyprland procesadas."

# =============================================================================
# PASO 5 – Compilar e instalar Hyprland desde fuente
# =============================================================================
section "PASO 5 · Compilar e instalar Hyprland desde fuente"

BUILD_DIR="/opt/hyprland-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Usar GCC 14 (necesario para C++26) o Clang 19
export CC=gcc-14
export CXX=g++-14

# Clonar Hyprland
if [[ -d "$BUILD_DIR/Hyprland" ]]; then
    info "Directorio Hyprland ya existe, actualizando..."
    cd "$BUILD_DIR/Hyprland"
    git pull
else
    info "Clonando Hyprland..."
    git clone --recursive --depth=1 https://github.com/hyprwm/Hyprland.git "$BUILD_DIR/Hyprland"
    cd "$BUILD_DIR/Hyprland"
fi

info "Compilando Hyprland (esto puede tardar varios minutos)..."
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DNO_XWAYLAND=OFF \
    -G Ninja

cmake --build build -j"$(nproc)"
cmake --install build

# Instalar archivo de sesión Wayland para los gestores de login
install -Dm644 example/hyprland.desktop \
    /usr/share/wayland-sessions/hyprland.desktop 2>/dev/null || \
    cat > /usr/share/wayland-sessions/hyprland.desktop << 'EOF'
[Desktop Entry]
Name=Hyprland
Comment=An intelligent dynamic tiling Wayland compositor
Exec=Hyprland
Type=Application
EOF

ok "Hyprland compilado e instalado en /usr/bin/Hyprland."

# =============================================================================
# PASO 6 – Herramientas esenciales del ecosistema Hyprland
# =============================================================================
section "PASO 6 · Herramientas esenciales del ecosistema Hyprland"

# ── Hyprpaper (fondo de pantalla) ─────────────────────────────────────────────
info "Instalando hyprpaper..."
cd "$BUILD_DIR"
if [[ ! -d hyprpaper ]]; then
    git clone --recursive --depth=1 https://github.com/hyprwm/hyprpaper.git
fi
cd hyprpaper
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -G Ninja
cmake --build build -j"$(nproc)"
cmake --install build
ok "hyprpaper instalado."

# ── Hypridle (gestión de inactividad) ────────────────────────────────────────
info "Instalando hypridle..."
cd "$BUILD_DIR"
if [[ ! -d hypridle ]]; then
    git clone --recursive --depth=1 https://github.com/hyprwm/hypridle.git
fi
cd hypridle
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -G Ninja
cmake --build build -j"$(nproc)"
cmake --install build
ok "hypridle instalado."

# ── Hyprlock (bloqueo de pantalla) ────────────────────────────────────────────
info "Instalando hyprlock..."
cd "$BUILD_DIR"
if [[ ! -d hyprlock ]]; then
    git clone --recursive --depth=1 https://github.com/hyprwm/hyprlock.git
fi
cd hyprlock
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -G Ninja
cmake --build build -j"$(nproc)"
cmake --install build
ok "hyprlock instalado."

# ── xdg-desktop-portal-hyprland ───────────────────────────────────────────────
info "Instalando xdg-desktop-portal-hyprland..."
apt-get install -y xdg-desktop-portal xdg-desktop-portal-gtk \
    xdg-utils libpipewire-0.3-dev || true
cd "$BUILD_DIR"
if [[ ! -d xdph ]]; then
    git clone --recursive --depth=1 \
        https://github.com/hyprwm/xdg-desktop-portal-hyprland.git xdph
fi
cd xdph
cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -G Ninja
cmake --build build -j"$(nproc)"
cmake --install build
ok "xdg-desktop-portal-hyprland instalado."

# =============================================================================
# PASO 7 – Software de entorno (barra, lanzador, terminal, notificaciones)
# =============================================================================
section "PASO 7 · Software de entorno Wayland"

apt-get install -y \
    foot \
    wofi \
    dunst \
    brightnessctl \
    grim \
    slurp \
    wl-clipboard \
    wf-recorder \
    network-manager \
    network-manager-gnome \
    pulseaudio \
    pamixer \
    pavucontrol \
    qt6-wayland \
    qt5-wayland \
    nemo \
    thunar || true

# Waybar (barra de estado)
if ! command -v waybar &>/dev/null; then
    info "Instalando Waybar..."
    apt-get install -y waybar || {
        cd "$BUILD_DIR"
        apt-get install -y libgtk-3-dev libgtkmm-3.0-dev \
            libjsoncpp-dev libfmt-dev libspdlog-dev libpulse-dev \
            libnl-3-dev libnl-genl-3-dev libdbusmenu-gtk3-dev \
            libmpdclient-dev libupower-glib-dev libpam0g-dev || true
        git clone --depth=1 --recursive https://github.com/Alexays/Waybar.git
        cd Waybar
        meson setup build --prefix=/usr -Dbuildtype=release
        ninja -C build
        ninja -C build install
    }
    ok "Waybar instalado."
fi

# =============================================================================
# PASO 8 – Gestor de inicio de sesión SDDM
# =============================================================================
section "PASO 8 · Gestor de inicio de sesión (SDDM)"

apt-get install -y sddm sddm-theme-debian-breeze || \
    apt-get install -y sddm

# Configurar SDDM para usar Wayland
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/hyprland.conf << 'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=Hyprland
EOF

systemctl enable sddm.service
ok "SDDM instalado y habilitado como gestor de login."

# =============================================================================
# PASO 9 – Configuración base de Hyprland para el usuario
# =============================================================================
section "PASO 9 · Configuración inicial de Hyprland"

HYPR_CONF_DIR="$TARGET_HOME/.config/hypr"
mkdir -p "$HYPR_CONF_DIR"

# Solo crear si no existe configuración previa
if [[ ! -f "$HYPR_CONF_DIR/hyprland.conf" ]]; then
    info "Creando configuración base de Hyprland en $HYPR_CONF_DIR/hyprland.conf"
    cat > "$HYPR_CONF_DIR/hyprland.conf" << 'HYPRCONF'
# ================================================================
# Hyprland – Configuración inicial para Debian 13 con NVIDIA
# ================================================================

# Variables de entorno esenciales para NVIDIA + Wayland
env = LIBVA_DRIVER_NAME,nvidia
env = XDG_SESSION_TYPE,wayland
env = GBM_BACKEND,nvidia-drm
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
env = ELECTRON_OZONE_PLATFORM_HINT,auto
env = MOZ_ENABLE_WAYLAND,1
env = QT_QPA_PLATFORM,wayland
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1
env = SDL_VIDEODRIVER,wayland
env = CLUTTER_BACKEND,wayland

# Monitor – ajusta según tu configuración
# monitor = nombre,resolución@hz,posición,escala
monitor = ,preferred,auto,1

# Iniciar aplicaciones al arrancar
exec-once = waybar
exec-once = dunst
exec-once = hypridle
exec-once = hyprpaper
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# Fuente de entrada
input {
    kb_layout = es
    follow_mouse = 1
    touchpad {
        natural_scroll = no
    }
    sensitivity = 0
}

# Apariencia general
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
    allow_tearing = false
}

# Decoraciones de ventana
decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    shadow {
        enabled = true
        range = 4
        render_power = 3
        color = rgba(1a1a1aee)
    }
}

# Animaciones
animations {
    enabled = yes
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

# Layout
dwindle {
    pseudotile = yes
    preserve_split = yes
}

master {
    new_status = master
}

# Gestos touchpad
gestures {
    workspace_swipe = off
}

# Atajos de teclado (SUPER = tecla Windows)
$mainMod = SUPER
$terminal = foot
$menu = wofi --show drun

bind = $mainMod, Return, exec, $terminal
bind = $mainMod, Q, killactive,
bind = $mainMod SHIFT, E, exit,
bind = $mainMod, V, togglefloating,
bind = $mainMod, D, exec, $menu
bind = $mainMod, P, pseudo,
bind = $mainMod, J, togglesplit,
bind = $mainMod, F, fullscreen,
bind = $mainMod SHIFT, F, fullscreenstate, 0 2

# Mover foco entre ventanas
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d

# Cambiar workspaces
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

# Mover ventana a workspace
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5

# Scroll en workspaces con rueda del ratón
bind = $mainMod, mouse_down, workspace, e+1
bind = $mainMod, mouse_up, workspace, e-1

# Mover/redimensionar ventanas con ratón
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Captura de pantalla
bind = , Print, exec, grim -g "$(slurp)" - | wl-copy
bind = SHIFT, Print, exec, grim ~/Capturas/$(date +%Y%m%d_%H%M%S).png

# Audio
bindel = ,XF86AudioRaiseVolume, exec, pamixer -i 5
bindel = ,XF86AudioLowerVolume, exec, pamixer -d 5
bindel = ,XF86AudioMute, exec, pamixer -t
bindel = ,XF86MonBrightnessUp, exec, brightnessctl s 5%+
bindel = ,XF86MonBrightnessDown, exec, brightnessctl s 5%-

# Bloqueo de pantalla
bind = $mainMod, L, exec, hyprlock
HYPRCONF
fi

# Configuración de hyprpaper
if [[ ! -f "$HYPR_CONF_DIR/hyprpaper.conf" ]]; then
    cat > "$HYPR_CONF_DIR/hyprpaper.conf" << 'EOF'
# hyprpaper.conf – añade una imagen a preload y asígnala
# preload = /ruta/a/fondo.png
# wallpaper = ,/ruta/a/fondo.png
splash = false
EOF
fi

# Crear directorio de capturas
mkdir -p "$TARGET_HOME/Capturas"
chown -R "$TARGET_USER:$TARGET_USER" "$HYPR_CONF_DIR" "$TARGET_HOME/Capturas"
ok "Configuración de Hyprland creada en $HYPR_CONF_DIR"

# =============================================================================
# PASO 10 – Variables de entorno del sistema para NVIDIA + Wayland
# =============================================================================
section "PASO 10 · Variables de entorno del sistema"

cat > /etc/environment << 'EOF'
# Wayland
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=Hyprland

# NVIDIA Wayland
LIBVA_DRIVER_NAME=nvidia
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
NVD_BACKEND=direct

# Qt / Electron
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
ELECTRON_OZONE_PLATFORM_HINT=auto

# Firefox / Mozilla
MOZ_ENABLE_WAYLAND=1

# SDL / Clutter
SDL_VIDEODRIVER=wayland
CLUTTER_BACKEND=wayland
EOF

ok "Variables de entorno del sistema configuradas."

# =============================================================================
# PASO 11 – PipeWire para audio/video en Wayland
# =============================================================================
section "PASO 11 · PipeWire (audio y captura de video)"

apt-get install -y \
    pipewire \
    pipewire-audio-client-libraries \
    pipewire-pulse \
    pipewire-alsa \
    wireplumber \
    libspa-0.2-bluetooth \
    libspa-0.2-jack \
    gstreamer1.0-pipewire || true

# Habilitar PipeWire para el usuario objetivo
sudo -u "$TARGET_USER" systemctl --user enable pipewire.service 2>/dev/null || true
sudo -u "$TARGET_USER" systemctl --user enable pipewire-pulse.service 2>/dev/null || true
sudo -u "$TARGET_USER" systemctl --user enable wireplumber.service 2>/dev/null || true

ok "PipeWire configurado."

# =============================================================================
# PASO 12 – Limpieza final
# =============================================================================
section "PASO 12 · Limpieza"

apt-get autoremove -y
apt-get autoclean -y
ok "Limpieza completada."

# =============================================================================
# RESUMEN FINAL
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║         INSTALACIÓN COMPLETADA EXITOSAMENTE                 ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${CYAN}Componentes instalados:${RESET}"
echo -e "  • Hyprland        → compilado desde fuente (git)"
echo -e "  • hyprpaper       → fondo de pantalla"
echo -e "  • hypridle        → gestión de inactividad"
echo -e "  • hyprlock        → bloqueo de pantalla"
echo -e "  • xdph            → portal escritorio Hyprland"
echo -e "  • Waybar          → barra de estado"
echo -e "  • foot            → emulador de terminal Wayland"
echo -e "  • wofi            → lanzador de aplicaciones"
echo -e "  • dunst           → notificaciones"
echo -e "  • SDDM            → gestor de inicio de sesión"
echo -e "  • PipeWire        → servidor de audio/video"
[[ "$SKIP_NVIDIA" == "false" ]] && \
echo -e "  • NVIDIA drivers  → repositorio oficial NVIDIA (debian13)"
echo ""
echo -e "  ${YELLOW}Próximo paso:${RESET}"
echo -e "  Reinicia el sistema para aplicar los drivers NVIDIA y GRUB:"
echo -e "  ${BOLD}sudo reboot${RESET}"
echo ""
echo -e "  ${YELLOW}Tras el reinicio:${RESET}"
echo -e "  SDDM arrancará automáticamente. Selecciona 'Hyprland'"
echo -e "  en el menú de sesiones e inicia sesión con tu usuario."
echo ""
echo -e "  ${CYAN}Configuración de Hyprland:${RESET}"
echo -e "  $HYPR_CONF_DIR/hyprland.conf"
echo ""
echo -e "  ${RED}IMPORTANTE:${RESET} Si tienes Secure Boot activo, los módulos NVIDIA"
echo -e "  necesitan firmarse con mokutil. Consulta la wiki de Debian."
echo ""
