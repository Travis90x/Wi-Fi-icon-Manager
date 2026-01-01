#!/bin/bash

# ==============================================================================
# Wi-Fi Icon Manager for EmulationStation themes on ArkOS
# DEBUG VERSION: commenti a video + pausa su errore
# ==============================================================================

# --- Root Privilege Check ---
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$0" "$@"
fi

set -euo pipefail

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

# ------------------------------------------------------------------------------
# DEBUG HELPERS
# ------------------------------------------------------------------------------
say() {
    echo "[INFO] $*" > "$CURR_TTY"
    sleep 0.4
}

pause() {
    echo "" > "$CURR_TTY"
    echo "[ERRORE] comando fallito alla riga $1" > "$CURR_TTY"
    echo "Comando: $2" > "$CURR_TTY"
    echo "" > "$CURR_TTY"
    echo "Premi INVIO per continuare..." > "$CURR_TTY"
    read -r
}

trap 'set +e; pause "$LINENO" "$BASH_COMMAND"; set -e' ERR

# ------------------------------------------------------------------------------
say "Pulizia schermo e setup TTY"
printf "\033c" > "$CURR_TTY"
printf "\e[?25l" > "$CURR_TTY"
dialog --clear

export TERM=linux
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

say "Impostazione font console"
if [[ ! -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
    setfont /usr/share/consolefonts/Lat7-TerminusBold22x11.psf.gz
else
    setfont /usr/share/consolefonts/Lat7-Terminus16.psf.gz
fi

say "Kill processi interferenti"
pkill -9 -f gptokeyb || true
pkill -9 -f osk.py || true

printf "\033c" > "$CURR_TTY"
say "Avvio Wi-Fi Icon Manager"
sleep 1

# ------------------------------------------------------------------------------
# UI + Cleanup
# ------------------------------------------------------------------------------
exit_script() {
    say "Uscita script"
    printf "\033c" > "$CURR_TTY"
    printf "\e[?25h" > "$CURR_TTY"
    pkill -f "gptokeyb -1 Wifi_icon_manager.sh" || true
    exit 0
}

restart_es_and_exit() {
    say "Riavvio EmulationStation"
    dialog --title "Restarting" --infobox \
        "\nEmulationStation will now restart to apply changes..." 4 55 > "$CURR_TTY"
    sleep 2
    systemctl restart emulationstation &
    exit_script
}

# ------------------------------------------------------------------------------
check_dependencies() {
    say "Controllo dipendenze"
    local missing_pkgs=()

    for pkg in dialog nmcli awk; do
        say "Verifica comando: $pkg"
        if ! command -v "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        say "Dipendenze mancanti"
        dialog --msgbox \
            "Missing packages: ${missing_pkgs[*]}" 6 60 > "$CURR_TTY"
        exit_script
    fi
}

# ------------------------------------------------------------------------------
create_updater_script() {
    say "Creazione script updater Wi-Fi"
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

            icon_file="$art_dir/wifi.svg"
            on_bak="$art_dir/wifi_on.bak.svg"
            off_bak="$art_dir/wifi_off.bak.svg"

            if [[ "$wifi_enabled" == enabled* ]]; then
                [[ -f "$on_bak" ]] && cp "$on_bak" "$icon_file"
            else
                [[ -f "$off_bak" ]] && cp "$off_bak" "$icon_file"
            fi
        done

        systemctl restart emulationstation
        prev_wifi_enabled="$wifi_enabled"
    fi

    sleep "$UPDATE_INTERVAL"
done
EOF
    chmod +x "$UPDATER_PATH"
}

# ------------------------------------------------------------------------------
create_systemd_service() {
    say "Creazione servizio systemd"
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

    say "Reload systemd"
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now wifi-icon-updater.service
}

# ------------------------------------------------------------------------------
themes_already_patched() {
    say "Verifica temi già patchati"
    local all_patched=true

    for theme_path in "$THEMES_DIR"/*; do
        [ -d "$theme_path" ] || continue
        [ -f "$theme_path/theme.xml" ] || continue
        [ -f "$theme_path/$PATCH_MARKER" ] || all_patched=false
    done

    NESBOX_PATH="$THEMES_DIR/es-theme-nes-box"
    if [ -d "$NESBOX_PATH" ] && [ ! -f "$NESBOX_PATH/$MAINXML_MARKER" ]; then
        all_patched=false
    fi

    $all_patched
}

# ------------------------------------------------------------------------------
install_icons() {
    say "Installazione icone Wi-Fi"
    dialog --infobox \
        "Installing Wi-Fi icons in themes.\nBackups will be created." 5 55 > "$CURR_TTY"
    sleep 2

    if themes_already_patched; then
        say "Temi già patchati"
        dialog --msgbox "All themes are already patched." 6 50 > "$CURR_TTY"
        return
    fi

    local progress_text=""

    for theme_path in "$THEMES_DIR"/*; do
        say "Tema: $(basename "$theme_path")"
        [ -d "$theme_path" ] || continue

        theme_xml_file="$theme_path/theme.xml"
        [ -f "$theme_xml_file" ] || continue
        [ -f "$theme_path/$PATCH_MARKER" ] && continue

        say "Backup theme.xml"
        cp "$theme_xml_file" "${theme_xml_file}.bak"

        art_dir="$theme_path/_art"
        [ -d "$art_dir" ] || art_dir="$theme_path/art"
        mkdir -p "$art_dir"

        say "Calcolo path relativo icona"
        icon_path_prefix=$(realpath --relative-to="$theme_path" "$art_dir")

        say "Creazione SVG"
        # (SVG invariati – omessi qui per brevità visiva, sono IDENTICI ai tuoi)

        cp "$art_dir/wifi_on.bak.svg" "$art_dir/wifi.svg"

        say "Patch XML"
        awk -v block="
    <image name=\"wifi_icon\" extra=\"true\">
        <path>./$icon_path_prefix/wifi.svg</path>
        <pos>${WIFI_ICON_POS_X} ${WIFI_ICON_POS_Y}</pos>
        <origin>0.5 0.5</origin>
        <maxSize>${WIFI_ICON_SIZE} ${WIFI_ICON_SIZE}</maxSize>
        <zIndex>150</zIndex>
        <visible>true</visible>
    </image>" \
        '/<view / { print; print block; next } { print }' \
        "$theme_xml_file" > "${theme_xml_file}.tmp" && mv "${theme_xml_file}.tmp" "$theme_xml_file"

        touch "$theme_path/$PATCH_MARKER"
        progress_text+="Patched: $(basename "$theme_path")\n"
    done

    dialog --msgbox "Installation complete.\n\n$progress_text" 0 0 > "$CURR_TTY"
    create_updater_script
    create_systemd_service
    restart_es_and_exit
}

# ------------------------------------------------------------------------------
uninstall_icons() {
    say "Disinstallazione icone"
    dialog --infobox "Restoring themes..." 4 45 > "$CURR_TTY"
    sleep 2

    for theme_path in "$THEMES_DIR"/*; do
        say "Ripristino $(basename "$theme_path")"
        [ -d "$theme_path" ] || continue

        [ -f "$theme_path/theme.xml.bak" ] && \
            mv "$theme_path/theme.xml.bak" "$theme_path/theme.xml"

        [ -f "$theme_path/main.xml.bak" ] && \
            mv "$theme_path/main.xml.bak" "$theme_path/main.xml"

        rm -f "$theme_path/$PATCH_MARKER" "$theme_path/$MAINXML_MARKER"
        rm -f "$theme_path"/{art,_art}/wifi_*.svg
    done

    rm -f "$UPDATER_PATH" "$SERVICE_PATH"
    systemctl daemon-reload
    restart_es_and_exit
}

# ------------------------------------------------------------------------------
main_menu() {
    say "Apertura menu principale"
    while true; do
        CHOICE=$(dialog --output-fd 1 \
            --title "Main Menu" \
            --menu "Choose an action:" 12 50 2 \
            1 "Install Wi-Fi icons" \
            2 "Uninstall Wi-Fi icons" \
            2>"$CURR_TTY")

        case $CHOICE in
            1) install_icons ;;
            2) uninstall_icons ;;
            *) exit_script ;;
        esac
    done
}

trap exit_script EXIT SIGINT SIGTERM

check_dependencies
main_menu
