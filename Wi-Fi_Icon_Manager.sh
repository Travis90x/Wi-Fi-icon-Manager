#!/bin/bash

# ==============================================================================
# Wi-Fi Icon Manager for EmulationStation themes on ArkOS
# ==============================================================================

# --- Root Privilege Check ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

set -euo pipefail

# --- DEBUG ---
DEBUG_LOG="/tmp/wifi_icon_manager.debug"

debug() {
    echo "[DEBUG] $(date '+%H:%M:%S') - $*" | tee -a "$DEBUG_LOG" > "$CURR_TTY"
}

trap 'debug "ERRORE alla linea $LINENO | comando: $BASH_COMMAND"' ERR

# --- Global Variables ---
THEMES_DIR="/roms/themes"
CURR_TTY="/dev/tty1"
PATCH_MARKER=".wifi_icon_patched"
MAINXML_MARKER=".wifi_icon_patched_mainxml"

WIFI_ICON_POS_X="0.16"
WIFI_ICON_POS_Y="0.025"
WIFI_ICON_SIZE="0.07"

UPDATER_PATH="/usr/local/bin/wifi_icon_state_updater.sh"
SERVICE_PATH="/etc/systemd/system/wifi-icon-updater.service"

UPDATE_INTERVAL=5

printf "\033c" > "$CURR_TTY"
printf "\e[?25l" > "$CURR_TTY"
dialog --clear

export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

debug "Script avviato"
debug "UID=$(id -u)"
debug "THEMES_DIR=$THEMES_DIR"

if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
    debug "Font grande"
    setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz
else
    debug "Font piccolo"
    setfont /usr/share/consolefonts/Lat7-Terminus16.psf.gz
fi

pkill -9 -f gptokeyb || true
pkill -9 -f osk.py || true

printf "\033c" > "$CURR_TTY"
printf "Starting Wi-Fi Icon Manager. Please wait..." > "$CURR_TTY"
sleep 1

# --- UI + Cleanup ---
exit_script() {
    debug "exit_script"
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY"
    pkill -f "gptokeyb -1 Wifi_icon_manager.sh" || true
    exit 0
}

restart_es_and_exit() {
    debug "Restarting EmulationStation"
    dialog --title "Restarting" --infobox "\nEmulationStation will now restart..." 4 55 > "$CURR_TTY"
    sleep 2
    systemctl restart emulationstation &
    exit_script
}

check_dependencies() {
    debug "check_dependencies START"
    local missing_pkgs=()

    for pkg in dialog nmcli awk; do
        debug "Checking dependency: $pkg"
        command -v "$pkg" &>/dev/null || missing_pkgs+=("$pkg")
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        debug "Missing deps: ${missing_pkgs[*]}"
        dialog --msgbox "Missing packages: ${missing_pkgs[*]}" 6 60 > "$CURR_TTY"
        exit_script
    fi

    debug "check_dependencies OK"
}

create_updater_script() {
    debug "Creating updater script"
    cat > "$UPDATER_PATH" << 'EOF'
#!/bin/bash
THEMES_DIR="/roms/themes"
UPDATE_INTERVAL=5
prev_wifi_enabled=""

while true; do
    wifi_enabled=$(nmcli radio wifi)

    if [[ "$wifi_enabled" != "$prev_wifi_enabled" ]]; then
        for theme_path in "$THEMES_DIR"/*; do
            [ -d "$theme_path" ] || continue
            art_dir="$theme_path/_art"
            [ -d "$art_dir" ] || art_dir="$theme_path/art"
            [ -d "$art_dir" ] || continue

            icon="$art_dir/wifi.svg"
            [[ "$wifi_enabled" == enabled* ]] && cp -f "$art_dir/wifi_on.bak.svg" "$icon" 2>/dev/null
            [[ "$wifi_enabled" != enabled* ]] && cp -f "$art_dir/wifi_off.bak.svg" "$icon" 2>/dev/null
        done
        systemctl restart emulationstation
        prev_wifi_enabled="$wifi_enabled"
    fi
    sleep "$UPDATE_INTERVAL"
done
EOF
    chmod +x "$UPDATER_PATH"
    debug "Updater script created"
}

create_systemd_service() {
    debug "Creating systemd service"
    cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Wi-Fi Icon State Updater
After=network.target

[Service]
ExecStart=$UPDATER_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now wifi-icon-updater.service
    debug "Service enabled"
}

themes_already_patched() {
    debug "themes_already_patched START"
    local all_patched=true

    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        [ -f "$theme_path/theme.xml" ] || continue
        [ -f "$theme_path/$PATCH_MARKER" ] || all_patched=false
    done

    debug "themes_already_patched result=$all_patched"
    $all_patched
}

install_icons() {
    debug "install_icons START"

    dialog --infobox "Installing Wi-Fi icons..." 4 50 > "$CURR_TTY"
    sleep 1

    if themes_already_patched; then
        debug "Themes already patched"
        dialog --msgbox "Themes already patched" 5 40 > "$CURR_TTY"
        return
    fi

    for theme_path in "$THEMES_DIR"/*; do
        debug "Theme: $theme_path"
        [ -d "$theme_path" ] || continue

        xml="$theme_path/theme.xml"
        [ -f "$xml" ] || continue
        [ -f "$theme_path/$PATCH_MARKER" ] && continue

        debug "Backing up XML"
        cp "$xml" "$xml.bak"

        art_dir="$theme_path/_art"
        [ -d "$art_dir" ] || art_dir="$theme_path/art"
        mkdir -p "$art_dir"

        debug "Resolving relative path"
        icon_path_prefix=$(realpath --relative-to="$theme_path" "$art_dir")
        debug "icon_path_prefix=$icon_path_prefix"

        cp "$art_dir/wifi_on.bak.svg" "$art_dir/wifi.svg" 2>/dev/null || true

        debug "Patching XML"
        awk '/<view /{print;print "    <image name=\"wifi_icon\" extra=\"true\"><path>./'"$icon_path_prefix"'/wifi.svg</path></image>";next}1' \
            "$xml" > "$xml.tmp" && mv "$xml.tmp" "$xml"

        touch "$theme_path/$PATCH_MARKER"
    done

    create_updater_script
    create_systemd_service
    restart_es_and_exit
}

uninstall_icons() {
    debug "uninstall_icons START"
    dialog --infobox "Restoring themes..." 4 45 > "$CURR_TTY"
    sleep 1

    for theme_path in "$THEMES_DIR"/*; do
        debug "Restoring $theme_path"
        [ -d "$theme_path" ] || continue

        [ -f "$theme_path/theme.xml.bak" ] && mv "$theme_path/theme.xml.bak" "$theme_path/theme.xml"
        rm -f "$theme_path/$PATCH_MARKER"
        rm -f "$theme_path"/{art,_art}/wifi*.svg
    done

    rm -f "$UPDATER_PATH" "$SERVICE_PATH"
    systemctl daemon-reload
    restart_es_and_exit
}

ExitMenu() {
    debug "ExitMenu"
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY"
    exit 0
}

main_menu() {
    debug "main_menu"
    while true; do
        CHOICE=$(dialog --menu "Choose:" 12 40 2 \
            1 "Install" \
            2 "Uninstall" \
            2>"$CURR_TTY")

        debug "Choice=$CHOICE"

        case $CHOICE in
            1) install_icons ;;
            2) uninstall_icons ;;
            *) ExitMenu ;;
        esac
    done
}

trap ExitMenu EXIT SIGINT SIGTERM

check_dependencies
main_menu
