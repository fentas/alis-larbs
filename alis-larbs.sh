#!/usr/bin/env bash
set -eu

# Arch Linux Install Script Packages (alis-packages) installs software
# packages.
# Copyright (C) 2022 picodotdev

# Luke's Auto Rice Boostrapping Script (LARBS)
# by Luke Smith <luke@lukesmith.xyz>
# License: GNU GPLv3

# Modifications by fentas (github.com/fentas)

PACKAGES_STANDALONE="false"

function init_config() {
    local COMMONS_FILE="alis-commons.sh"

    source "$COMMONS_FILE"
    if [ "$PACKAGES_STANDALONE" == "true" ]; then
        source "$COMMONS_CONF_FILE"
    fi
}

function sanitize_variables() {
    PACKAGES_AUR_COMMAND=$(sanitize_variable "$PACKAGES_AUR_COMMAND")
}

function check_variables() {
    check_variables_list "PACKAGES_AUR_COMMAND" "$PACKAGES_AUR_COMMAND" "paru-bin yay-bin paru yay aurman" "true" "false"
}

function init() {
    if [ "$PACKAGES_STANDALONE" == "true" ]; then
        init_log_trace "$LOG_TRACE"
        init_log_file "$LOG_FILE" "$PACKAGES_LOG_FILE"
    fi
}

function facts() {
    print_step "facts()"

    facts_commons

    if [ -z "$USER_NAME" ]; then
        USER_NAME="$(whoami)"
    fi
}

function checks() {
    print_step "checks()"

    check_variables_value "USER_NAME" "$USER_NAME"

    if [ "$SYSTEM_INSTALLATION" == "false" ]; then
        ask_sudo
    fi
}

function ask_sudo() {
    sudo pwd >> /dev/null
}

function prepare() {
    print_step "prepare()"

    # Install bare minimum
    execute_sudo "pacman -Syi curl ca-certificates base-devel git ntp zsh"

    # Synchronizing system time to ensure successful and secure installation of software
    execute_sudo ntpdate 0.us.pool.ntp.org

    # Allow user to run sudo without password. Since AUR programs must be installed
    # in a fakeroot environment, this is required for all builds with AUR.
    trap 'rm -f /etc/sudoers.d/larbs-temp' HUP INT QUIT TERM PWR EXIT
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/larbs-temp

    # Make pacman colorful, concurrent downloads and Pacman eye-candy.
    grep -q "ILoveCandy" /etc/pacman.conf || 
        sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
    sed -Ei "s/^#(ParallelDownloads).*/\1 = 5/;/^#Color$/s/#//" /etc/pacman.conf

    # Use all cores for compilation.
    sed -i "s/-j2/-j$(nproc)/;/^#MAKEFLAGS/s/^#//" /etc/makepkg.conf

    export repodir="/home/$USER_NAME/.local/src"
	mkdir -p "$repodir"
}

function installpkg() {
	execute_sudo pacman --noconfirm --needed -S "${@}"
}

function gitmakeinstall() {
	progname="${1##*/}"
	progname="${progname%.git}"
	dir="$repodir/$progname"

	execute_user "$USER_NAME" git -C "$repodir" clone --depth 1 --single-branch --no-tags -q "$1" "$dir" || {
        cd "$dir" || return 1
        execute_user "$USER_NAME" git pull --force origin master
    }

	cd "$dir" || return 1
	make
	execute_sudo make install
	cd /tmp
}

function aurinstall() {
	! echo "$aurinstalled" | grep -q "^$1$" ||
        return 1
    
	execute_user "$USER_NAME" "$PACKAGES_AUR_COMMAND" -S --noconfirm "$1"
}

function pipinstall() {
	[ -x "$(command -v "pip")" ] || installpkg python-pip
	yes | pip install "$1"
}

# The command that does all the installing. Reads the progs.csv file and
# installs each needed program the way required. Be sure to run this only after
# the user has been created and has priviledges to run sudo without a password
# and all build dependencies are installed.
function installationloop() {
    print_step "installationloop()"

    cat "$LARBS_CSV" | sed '/^#/d' > /tmp/progs.csv
	total=$(wc -l </tmp/progs.csv)
	aurinstalled=$(pacman -Qqm)

	while IFS=, read -r tag program comment; do
		n=$((n + 1))
		! echo "$comment" | grep -q "^\".*\"$" ||
			echo "$comment" | sed -E "s/(^\"|\"$)//g"

		case "$tag" in
		"A") aurinstall "$program" ;;
		"G") gitmakeinstall "$program" ;;
		"P") pipinstall "$program" ;;
		*) maininstall "$program" ;;
		esac
	done < /tmp/progs.csv
}

function system() {
    # Finally, installing `libxft-bgra` to enable color emoji in suckless software without crashes.
    pacman -Qs libxft-bgra ||
        aurinstall libxft-bgra-git

    # Most important command! Get rid of the beep!
    rmmod pcspkr
    echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf

    # Make zsh the default shell for the user.
    chsh -s /bin/zsh "$USER_NAME"
    execute_user "$USER_NAME" mkdir -p "/home/$USER_NAME/.cache/zsh/"
    execute_user "$USER_NAME" mkdir -p "/home/$USER_NAME/.config/abook/"
    execute_user "$USER_NAME" mkdir -p "/home/$USER_NAME/.config/mpd/playlists/"

    # dbus UUID must be generated for Artix runit.
    dbus-uuidgen > /var/lib/dbus/machine-id

    # Use system notifications for Brave on Artix
    echo "export \$(dbus-launch)" > /etc/profile.d/dbus.sh

    # Enable tap to click
    [ -f /etc/X11/xorg.conf.d/40-libinput.conf ] ||
        cat <<EOF > /etc/X11/xorg.conf.d/40-libinput.conf
Section "InputClass"
    Identifier "libinput touchpad catchall"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
    # Enable left mouse button by tapping
    Option "Tapping" "on"
EndSection
EOF

    # Allow wheel users to sudo with password and allow several system commands
    # (like `shutdown` to run without password).
    echo "%wheel ALL=(ALL) ALL #LARBS" > \
        /etc/sudoers.d/larbs-wheel-can-sudo
    echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/shutdown,/usr/bin/reboot,/usr/bin/systemctl suspend,/usr/bin/wifi-menu,/usr/bin/mount,/usr/bin/umount,/usr/bin/pacman -Syu,/usr/bin/pacman -Syyu,/usr/bin/pacman -Syyu --noconfirm,/usr/bin/loadkeys,/usr/bin/paru,/usr/bin/pacman -Syyuw --noconfirm" > \
        /etc/sudoers.d/larbs-cmds-without-password
}

function dotfiles() {
    home=/home/$USER_NAME

    git init --bare $home/.voidrice
    voidrice="/usr/bin/git --git-dir=$home/.voidrice/ --work-tree=$home"
    $voidrice config status.showUntrackedFiles no
    $voidrice config core.sparseCheckout true
    cat <<EOF > $home/.voidrice/info/sparse-checkout
!/README.md
!/LICENSE
!/FUNDING
EOF
    $voidrice remote add origin "$LARBS_VOIDRICE"
    $voidrice pull origin master
}

function end() {
    echo ""
    echo -e "${GREEN}LARBS installed successfully"'!'"${NC}"
    echo ""
}

function main() {
    local START_TIMESTAMP=$(date -u +"%F %T")
    set +u
    if [ "$COMMOMS_LOADED" != "true" ]; then
        PACKAGES_STANDALONE="true"
    fi
    set -u

    init_config
    execute_step "sanitize_variables"
    execute_step "check_variables"
    execute_step "init"
    execute_step "facts"
    execute_step "checks"
    execute_step "prepare"
    execute_step "installationloop"
    execute_step "system"
    local END_TIMESTAMP=$(date -u +"%F %T")
    local INSTALLATION_TIME=$(date -u -d @$(($(date -d "$END_TIMESTAMP" '+%s') - $(date -d "$START_TIMESTAMP" '+%s'))) '+%T')
    echo -e "Installation LARBS start ${WHITE}$START_TIMESTAMP${NC}, end ${WHITE}$END_TIMESTAMP${NC}, time ${WHITE}$INSTALLATION_TIME${NC}"
    execute_step "end"
}

main $@

