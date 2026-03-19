#!/usr/bin/env bash
# =============================================================================
#  install-awww-debian13.sh
#  Instala awww — "An Answer to your Wayland Wallpaper Woes"
#  Sucesor de swww, del mismo autor (LGFae), para Hyprland en Debian 13
#
#  Fuente: https://codeberg.org/LGFae/awww
#
#  Estrategia:
#   - awww NO está en ningún repo de Debian → se compila desde fuente
#   - rustc en trixie = 1.85.0 < MSRV requerido (1.87.0)
#   - rustc en forky  = 1.91.x ✅ → se instala desde forky con -t
#   - Deps de sistema (lz4, wayland) están en trixie ✅
#   - forky ya debe estar configurado (script principal)
#
#  Uso: sudo bash install-awww-debian13.sh
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERR ]${RESET}  $*"; exit 1; }
section() {
    echo ""
    echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────┐${RESET}"
    printf "${BOLD}${CYAN}│  %-56s│${RESET}\n" "$*"
    echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# ─── Comprobaciones previas ───────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && error "Ejecuta como root: sudo bash $0"

# Detectar usuario objetivo
if [[ -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER=$(awk -F: '$3 >= 1000 && $7 !~ /nologin|false/ {print $1; exit}' /etc/passwd)
    [[ -z "$TARGET_USER" ]] && read -rp "Usuario que usará awww: " TARGET_USER
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
info "Usuario objetivo: ${BOLD}$TARGET_USER${RESET} (home: $TARGET_HOME)"

AWWW_MSRV="1.87.0"
BUILD_DIR="/opt/awww-build"

# =============================================================================
# PASO 1 – Verificar que forky está disponible
# =============================================================================
section "PASO 1 · Verificar repositorio Forky"

if ! grep -rqsE "^deb .*forky" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    error "El repositorio Forky no está configurado.\nEjecuta primero el script principal: install-hyprland-debian13.sh"
fi
ok "Repositorio Forky detectado."

apt-get update -qq

# =============================================================================
# PASO 2 – Dependencias de sistema (todas en trixie ✅)
# =============================================================================
section "PASO 2 · Dependencias de sistema"

# liblz4: compresión de frames de animación (única dep de sistema de awww)
# libwayland-dev + wayland-protocols: headers y .xml para compilar
apt-get install -y \
    liblz4-1 \
    liblz4-dev \
    libwayland-dev \
    wayland-protocols \
    pkg-config \
    git \
    ca-certificates \
    build-essential

ok "Dependencias de sistema instaladas."

# =============================================================================
# PASO 3 – Rust toolchain ≥ 1.87.0 desde Forky
# =============================================================================
section "PASO 3 · Rust toolchain (rustc + cargo desde Forky)"

AWWW_MSRV_PARTS=(${AWWW_MSRV//./ })
NEED_RUST=true

if command -v rustc &>/dev/null; then
    CURRENT_RUSTC=$(rustc --version | awk '{print $2}')
    info "rustc encontrado: $CURRENT_RUSTC"
    CUR=(${CURRENT_RUSTC//./ })
    # Comparar major.minor.patch
    if [[ "${CUR[0]}" -gt "${AWWW_MSRV_PARTS[0]}" ]] || \
       { [[ "${CUR[0]}" -eq "${AWWW_MSRV_PARTS[0]}" ]] && \
         [[ "${CUR[1]}" -gt "${AWWW_MSRV_PARTS[1]}" ]]; } || \
       { [[ "${CUR[0]}" -eq "${AWWW_MSRV_PARTS[0]}" ]] && \
         [[ "${CUR[1]}" -eq "${AWWW_MSRV_PARTS[1]}" ]] && \
         [[ "${CUR[2]:-0}" -ge "${AWWW_MSRV_PARTS[2]}" ]]; }; then
        ok "rustc $CURRENT_RUSTC ≥ $AWWW_MSRV → suficiente, no se reinstala."
        NEED_RUST=false
    else
        warn "rustc $CURRENT_RUSTC < $AWWW_MSRV requerido. Instalando desde Forky..."
    fi
fi

if [[ "$NEED_RUST" == "true" ]]; then
    apt-get install -y -t forky rustc cargo
    ok "rustc $(rustc --version | awk '{print $2}') instalado desde Forky."
fi

# Directorio de cargo para la compilación (aislado, no toca el home del usuario)
export CARGO_HOME="$BUILD_DIR/.cargo"
mkdir -p "$CARGO_HOME"

# =============================================================================
# PASO 4 – Clonar y compilar awww desde Codeberg
# =============================================================================
section "PASO 4 · Compilar awww desde fuente (Codeberg)"

mkdir -p "$BUILD_DIR"

if [[ -d "$BUILD_DIR/awww" ]]; then
    info "Directorio awww ya existe, actualizando..."
    cd "$BUILD_DIR/awww"
    git pull
else
    info "Clonando awww desde Codeberg..."
    git clone --depth=1 https://codeberg.org/LGFae/awww.git "$BUILD_DIR/awww"
    cd "$BUILD_DIR/awww"
fi

info "Compilando awww en modo release (puede tardar unos minutos)..."
cargo build --release

# =============================================================================
# PASO 5 – Instalar binarios
# =============================================================================
section "PASO 5 · Instalar binarios"

# awww necesita DOS binarios: el cliente (awww) y el demonio (awww-daemon)
install -Dm755 "$BUILD_DIR/awww/target/release/awww"        /usr/local/bin/awww
install -Dm755 "$BUILD_DIR/awww/target/release/awww-daemon"  /usr/local/bin/awww-daemon

ok "awww instalado en /usr/local/bin/awww"
ok "awww-daemon instalado en /usr/local/bin/awww-daemon"

# Man pages opcionales (requiere scdoc)
if apt-get install -y scdoc 2>/dev/null; then
    info "Generando man pages de awww..."
    cd "$BUILD_DIR/awww"
    bash doc/gen.sh 2>/dev/null && {
        MAN_DEST=$(manpath 2>/dev/null | cut -d: -f1 || echo "/usr/local/share/man")
        mkdir -p "$MAN_DEST/man1"
        cp doc/generated/*.1 "$MAN_DEST/man1/" 2>/dev/null || true
        mandb -q 2>/dev/null || true
        ok "Man pages instaladas. Usa: man awww"
    } || warn "No se pudieron generar las man pages (opcional, no es crítico)."
fi

# Autocompletado en bash (opcional)
BASH_COMP_DIR="/usr/share/bash-completion/completions"
if [[ -d "$BUILD_DIR/awww/completions" ]]; then
    install -Dm644 "$BUILD_DIR/awww/completions/awww.bash" \
        "$BASH_COMP_DIR/awww" 2>/dev/null || true
    ok "Autocompletado bash instalado."
fi

# =============================================================================
# PASO 6 – Configurar awww en Hyprland para todos los usuarios existentes
# =============================================================================
section "PASO 6 · Integrar awww en la configuración de Hyprland"

while IFS=: read -r uname _ uid _ _ uhome ushell; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ "$ushell" == */false || "$ushell" == */nologin ]] && continue
    [[ ! -d "$uhome" ]] && continue

    HYPR_CONF="$uhome/.config/hypr/hyprland.conf"
    [[ ! -f "$HYPR_CONF" ]] && continue

    info "Configurando awww para: $uname"

    # Crear directorio de fondos si no existe
    WALLPAPER_DIR="$uhome/Imágenes/Fondos"
    mkdir -p "$WALLPAPER_DIR"

    # Script de slideshow automático
    AWWW_SCRIPT="$uhome/.config/hypr/awww-slideshow.sh"
    if [[ ! -f "$AWWW_SCRIPT" ]]; then
        cat > "$AWWW_SCRIPT" << SLIDESHOW
#!/usr/bin/env bash
# awww-slideshow.sh
# Cambia el fondo de pantalla automáticamente cada N segundos
# con transiciones animadas usando awww
#
# Uso: bash awww-slideshow.sh [directorio] [intervalo_segundos]
#
# Ejemplo: bash awww-slideshow.sh ~/Imágenes/Fondos 300

WALLPAPER_DIR="\${1:-\$HOME/Imágenes/Fondos}"
INTERVAL="\${2:-300}"   # segundos entre cambios (300 = 5 minutos)

# Tipos de transición disponibles:
# simple, fade, left, right, top, bottom, center, outer, wipe, grow, any, random
TRANSITION="random"
TRANSITION_FPS="30"
TRANSITION_STEP="90"

# Formatos soportados por awww
SUPPORTED="jpg jpeg png gif webp bmp tga tiff pnm"

# Esperar a que el demonio esté listo
sleep 1

# Si el directorio está vacío o no existe, salir sin error
shopt -s nullglob
FILES=()
for EXT in \$SUPPORTED; do
    FILES+=("\$WALLPAPER_DIR"/*.\$EXT "\$WALLPAPER_DIR"/*.\${EXT^^})
done
shopt -u nullglob

if [[ \${#FILES[@]} -eq 0 ]]; then
    echo "awww-slideshow: No se encontraron imágenes en \$WALLPAPER_DIR"
    echo "Añade imágenes a \$WALLPAPER_DIR y reinicia Hyprland."
    exit 0
fi

# Barajar y ciclar indefinidamente
while true; do
    # Recargar lista en cada ciclo (por si añades fondos en caliente)
    FILES=()
    for EXT in \$SUPPORTED; do
        FILES+=("\$WALLPAPER_DIR"/*.\$EXT "\$WALLPAPER_DIR"/*.\${EXT^^})
    done
    [[ \${#FILES[@]} -eq 0 ]] && sleep "\$INTERVAL" && continue

    # Orden aleatorio
    mapfile -t SHUFFLED < <(printf '%s\n' "\${FILES[@]}" | shuf)

    for IMG in "\${SHUFFLED[@]}"; do
        [[ -f "\$IMG" ]] || continue
        awww img "\$IMG" \
            --transition-type "\$TRANSITION" \
            --transition-fps "\$TRANSITION_FPS" \
            --transition-step "\$TRANSITION_STEP"
        sleep "\$INTERVAL"
    done
done
SLIDESHOW
        chmod +x "$AWWW_SCRIPT"
        chown "$uname:$uname" "$AWWW_SCRIPT"
        ok "Script de slideshow creado: $AWWW_SCRIPT"
    fi

    # Integrar en hyprland.conf si no está ya
    if ! grep -q "awww-daemon" "$HYPR_CONF"; then
        cat >> "$HYPR_CONF" << HYPRBLOCK

# ================================================================
# ── awww: gestor de fondos animados ─────────────────────────────
# ================================================================
# Iniciar el demonio de awww al arrancar Hyprland
exec-once = awww-daemon

# Iniciar slideshow automático (edita el script para ajustar
# directorio e intervalo de cambio):
exec-once = bash \$HOME/.config/hypr/awww-slideshow.sh

# Atajo: SUPER+W → cambiar fondo manualmente con transición aleatoria
# (apunta a un archivo concreto o ajusta la ruta a tu directorio)
bind = \$mainMod, W, exec, awww img \$(find \$HOME/Imágenes/Fondos -type f \\
    \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \\
       -o -iname "*.gif" -o -iname "*.webp" \\) 2>/dev/null | shuf -n1) \\
    --transition-type random \\
    --transition-fps 30
HYPRBLOCK
        ok "awww añadido al hyprland.conf de $uname"
    else
        ok "awww ya estaba en hyprland.conf de $uname (no se duplica)."
    fi

    chown -R "$uname:$uname" "$WALLPAPER_DIR" "$uhome/.config/hypr"

done < /etc/passwd

# =============================================================================
# RESUMEN
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║       awww INSTALADO CORRECTAMENTE                          ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${CYAN}Binarios instalados:${RESET}"
echo -e "  • /usr/local/bin/awww          → cliente (cambia fondos)"
echo -e "  • /usr/local/bin/awww-daemon   → demonio (debe estar activo)"
echo ""
echo -e "  ${CYAN}Cómo funciona:${RESET}"
echo -e "  1. Al iniciar Hyprland, ${BOLD}awww-daemon${RESET} arranca automáticamente"
echo -e "  2. El slideshow cambia el fondo cada 5 min desde:"
echo -e "     ${BOLD}~/Imágenes/Fondos/${RESET}"
echo -e "  3. Añade imágenes (jpg, png, gif, webp...) a esa carpeta"
echo ""
echo -e "  ${CYAN}Controles:${RESET}"
echo -e "  • ${BOLD}SUPER+W${RESET}  → cambiar fondo manualmente (transición aleatoria)"
echo -e "  • awww img /ruta/imagen.gif  → poner fondo concreto desde terminal"
echo -e "  • awww query                 → ver estado actual"
echo -e "  • awww kill                  → parar el demonio"
echo ""
echo -e "  ${CYAN}Personalizar slideshow:${RESET}"
echo -e "  Edita ${BOLD}~/.config/hypr/awww-slideshow.sh${RESET}"
echo -e "  Variables al inicio: WALLPAPER_DIR, INTERVAL, TRANSITION"
echo ""
echo -e "  ${CYAN}Transiciones disponibles:${RESET}"
echo -e "  simple · fade · left · right · top · bottom"
echo -e "  center · outer · wipe · grow · any · random"
echo ""
echo -e "  ${YELLOW}Nota:${RESET} Si tenías hyprpaper configurado en exec-once,"
echo -e "  coméntalo en hyprland.conf para evitar conflictos con awww."
echo ""
