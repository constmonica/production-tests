#!/bin/bash
set -e

#----------------------------------#
# Global definitions section       #
#----------------------------------#

SCRIPT_DIR="$(readlink -f $(dirname $0))"

source $SCRIPT_DIR/lib/utils.sh
#source $SCRIPT_DIR/lib/update_release.sh

SUPPORTED_BOARDS="m2k_addon"

#----------------------------------#
# Functions section                #
#----------------------------------#

sudo_required() {
	type sudo &> /dev/null || {
		echo_red "'sudo' utility required"
		exit 1
	}
}

setup_apt_install_prereqs() {
	type apt-get &> /dev/null || {
		echo "No 'apt-get' found; cannot install dependencies"
		return 0
	}
	sudo_required
	sudo -s <<-EOF
	apt-get -y update
	apt-get -y install swig libftdi-dev bc \
		cmake build-essential git libxml2-dev \
		usbutils wget unzip curl xfce4 \
		libusb-dev libusb-1.0-0-dev htpdate xfce4-terminal \
		openssh-server gpg thunar-volman python3-pandas python3-scipy \
		python3-colorlog
	python3 -m pip install setuptools numpy matplotlib \
		pdoc3 logging
	/etc/init.d/htpdate restart
	EOF
}

check_udev_on_system() {
	[ -d "/etc/udev/rules.d" ] || {
		echo "Your system does not have a '/etc/udev/rules.d'"
		exit 1
	}

	type udevadm &> /dev/null || {
		echo "No 'udevadm' found on system"
		exit 1
	}

	return 0
}

# sync udev rules file
setup_sync_udev_rules_file() {
	sudo_required
	check_udev_on_system || exit 1
	sudo -s <<-EOF
		udevadm control --reload-rules
		udevadm trigger
	EOF
	return $?
}

__common_build_tool() {
	local c_files
	mkdir -p work

	for c_file in $tool_c ; do
		cp -f "src/$c_file" "work/$c_file"
		c_files="$c_files work/$c_file"
	done
	gcc $c_files -o "work/$tool" $cflags $ldflags
}

__download_github_common() {
	local gh_prj="$1"
	mkdir -p work

	local ver=$(get_latest_release analogdevicesinc/$gh_prj)
	[ -d work/$gh_prj ] || {
		if [ -z "$ver" ] ; then
			echo_red "Could not get $gh_prj release tag; cloning repo"
			git clone https://github.com/analogdevicesinc/$gh_prj work/$gh_prj
		else
			echo_green "Using latest released version '$ver' of '$gh_prj'"
			download_and_unzip_to "https://github.com/analogdevicesinc/$gh_prj/archive/${ver}.zip" "work" || {
				echo_red "Could not download $gh_prj..."
				exit 1
			}
			mv -f work/${gh_prj}* work/$gh_prj
		fi
	}
}

setup_libiio() {
	[ ! -d "work/libiio" ] || return 0

	#__download_github_common libiio
	git clone https://github.com/analogdevicesinc/libiio work/libiio

	pushd work/libiio
	mkdir -p build
	pushd build

	cmake -DHAVE_DNS_SD=OFF -DHAVE_AVAHI=OFF ..
	make -j3

	# TEMP: the install is needed to replace the iiod
	# the system iiod uses DNS SD; the new installed version will disable the DNS SD
	sudo make install
	
	popd
	popd
}

setup_libm2k() {
	[ ! -d "work/libm2k" ] || return 0

	#__download_github_common libm2k
	git clone https://github.com/analogdevicesinc/libm2k work/libm2k

	pushd work/libm2k
	mkdir -p build
	pushd build

	cmake -DENABLE_TOOLS=ON -DENABLE_PYTHON=ON -DENABLE_CSHARP=OFF -DIIO_INCLUDE_DIRS=../../libiio/ -DIIO_LIBRARIES=../../libiio/build/libiio.so ..
	make -j3

	# TEMP: the install is needed to replace the broken m2kcli
	sudo make install
	
	popd
	popd
}

setup_write_autostart_config() {
	local autostart_path="$HOME/.config/autostart"
	local configs_disable="blueman light-locker polkit-gnome-authentication-agent-1"

	configs_disable="$configs_disable print-applet pulseaudio snap-userd-autostart"
	configs_disable="$configs_disable spice-vdagent update-notifier user-dirs-update-gtk xdg-user-dirs"

	mkdir -p $autostart_path

	for cfg in $configs_disable ; do
		cat > $autostart_path/$cfg.desktop <<-EOF
[Desktop Entry]
Hidden=true
		EOF
	done

	local font_size="16"
	if [ "$BOARD" == "pluto" ] ; then
		font_size=14
	fi

	# FIXME: see about generalizing this to other desktops [Gnome, MATE, LXDE, etc]
	cat > $autostart_path/test-jig-tool.desktop <<-EOF
[Desktop Entry]
Encoding=UTF-8
Version=0.9.4
Type=Application
Name=test-jig-tool
Comment=test-jig-tool
Exec=sudo xfce4-terminal --font="DejaVu Sans Mono $font_size" --fullscreen --hide-borders --hide-scrollbar --hide-menubar -x $SCRIPT_DIR/production_${BOARD}.sh
OnlyShowIn=XFCE;LXDE
StartupNotify=false
Terminal=false
Hidden=false
	EOF

	if type ufw &> /dev/null ; then
		sudo ufw enable
		sudo ufw allow ssh
	fi

	cat > $autostart_path/auto-save-logs.desktop <<-EOF
[Desktop Entry]
Encoding=UTF-8
Version=0.9.4
Type=Application
Name=auto-save-logs
Comment=auto-save-logs
Exec=sudo /bin/bash $SCRIPT_DIR/autosave_logs.sh
StartupNotify=false
Terminal=false
Hidden=false
	EOF
}

xfconf_has_cap() {
	type xfconf-query &> /dev/null || return 1
	if xfconf-query -l | grep -q xfce4-power-manager ; then
		return 0
	fi
	return 1
}

setup_xfce4_power_manager_settings() {
	local pm_sett="/xfce4-power-manager/blank-on-ac=0
		/xfce4-power-manager/blank-on-battery=0
		/xfce4-power-manager/brightness-switch=0
		/xfce4-power-manager/brightness-switch-restore-on-exit=1
		/xfce4-power-manager/dpms-enabled=false
		/xfce4-power-manager/dpms-on-ac-off=60
		/xfce4-power-manager/dpms-on-ac-sleep=20
		/xfce4-power-manager/dpms-on-battery-off=30
		/xfce4-power-manager/dpms-on-battery-sleep=15
		/xfce4-power-manager/lock-screen-suspend-hibernate=true
		/xfce4-power-manager/logind-handle-lid-switch=false
		/xfce4-power-manager/power-button-action=4
		/xfce4-power-manager/show-panel-label=0"
	xfconf_has_cap xfce4-power-manager || return 0
	prop_list=`xfconf-query -c xfce4-power-manager -l`
	for sett in $pm_sett ; do
		local key="$(echo $sett | cut -d'=' -f1)"
		local val="$(echo $sett | cut -d'=' -f2)"
		if [[ $prop_list == *$key* ]]; then
			xfconf-query -c xfce4-power-manager -p $key -s $val
		fi
	done
}

setup_disable_sudo_passwd() {
	sudo_required
	sudo -s <<-EOF
		if ! grep -q $USER /etc/sudoers ; then
			echo "$USER	ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
		fi
	EOF
}

setup_thunar_volman() {
	local configs="/autobrowse/enabled=false
		/autoburn/enabled=false
		/autoipod/enabled=false
		/autokeyboard/enabled=false
		/automount-drives/enabled=true
		/automount-media/enabled=true
		/automouse/enabled=false
		/autoopen/enabled=false
		/autophoto/enabled=false
		/autoplay-audio-cds/enabled=false
		/autoplay-video-cds/enabled=false
		/autoprinter/enabled=false
		/autorun/enabled=false
		/autotablet/enabled=false"
	xfconf_has_cap thunar-volman || return 0
	prop_list=`xfconf-query -c thunar-volman -l`
	for sett in $configs ; do
		local key="$(echo $sett | cut -d'=' -f1)"
		local val="$(echo $sett | cut -d'=' -f2)"
		if [[ $prop_list == *$key* ]]; then
			xfconf-query -c thunar-volman -p $key -s $val
		fi
	done
}

setup_disable_lxde_automount() {
	[ -d "$HOME/.config/pcmanfm" ] || return 0

	pushd "$HOME/.config/pcmanfm/"
	for cfg_file in $(find . -name pcmanfm.conf) ; do
		sed 's/autorun=1/autorun=0/g' -i $cfg_file
		sed 's/mount_on_startup=1/mount_on_startup=0/g' -i $cfg_file
		sed 's/mount_removable=1/mount_removable=0/g' -i $cfg_file
	done

	popd
}

setup_disable_pi_screen_blanking() {
	local pi_serial="$(pi_serial)"
	[ -n "$pi_serial" ] || return 0

	local tmp=$(mktemp)
	cat >> $tmp <<-EOF
# --- added by setup_env.sh
[SeatDefaults]
xserver-command=X -s 0 -dpms
# --- end setup_env.sh
	EOF

	sudo -s <<-EOF
		sed -i -e "/^# --- added by setup_env.sh/,/^# --- end setup_env.sh/d" /etc/lightdm/lightdm.conf
		cat $tmp >> /etc/lightdm/lightdm.conf
	EOF
}

setup_raspi_config() {
	sudo -s <<-EOF
		if type raspi-config &> /dev/null ; then
			raspi-config nonint do_ssh 0 # enable SSH
		fi
	EOF
}

setup_misc_profile_cleanup() {
	touch $HOME/.hushlogin # tell login to not print system info
	sudo -s <<-EOF
		# Kind of hacky, but it works ; this will remove the warnings
		# about the SSH password & Wi-Fi on console login
		[ ! -f /etc/profile.d/sshpwd.sh ] || echo -n > /etc/profile.d/sshpwd.sh
		[ ! -f /etc/profile.d/wifi-country.sh ] || echo -n > /etc/profile.d/wifi-country.sh
		[ ! -f /etc/xdg/lxsession/LXDE-pi/sshpwd.sh ] || echo -n > /etc/xdg/lxsession/LXDE-pi/sshpwd.sh
	EOF
}

setup_usbreset_tool() {
	local tool="usbreset"
	local tool_c="${tool}.c"
	local cflags="-I./src -Werror -Wall"
	local ldflags=""

	__common_build_tool
}

setup_zerotier_vpn() {
	curl -s https://install.zerotier.com/ | sudo bash
	sudo zerotier-cli join d3ecf5726dcec114
}

setup_bashrc_update() {
	sed -i -e "/^# --- added by setup_env.sh/,/^# --- end setup_env.sh/d" "$HOME/.bashrc"

	cat >> $HOME/.bashrc <<-EOF
# --- added by setup_env.sh
export SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/vars.sh"
# --- end setup_env.sh
	EOF
}

board_is_supported() {
	local board="$1"
	[ -n "$board" ] || return 1
	for b in $SUPPORTED_BOARDS ; do
		[ "$b" != "$board" ] || return 0
	done
	return 1
}

#----------------------------------#
# Main section                     #
#----------------------------------#

BOARD="$1"
TARGET="$2"

if [ `id -u` == "0" ]
then
	echo_red "This script should not be run as root" 1>&2
	exit 1
fi

board_is_supported "$BOARD" || {
	echo_red "Board '$BOARD' is not supported by this script"
	echo_red "   Supported boards are '$SUPPORTED_BOARDS'"
	exit 1
}

pushd $SCRIPT_DIR

STEPS="bashrc_update disable_sudo_passwd misc_profile_cleanup raspi_config apt_install_prereqs"
STEPS="$STEPS xfce4_power_manager_settings thunar_volman disable_lxde_automount"
STEPS="$STEPS libiio libm2k sync_udev_rules_file write_autostart_config"
STEPS="$STEPS disable_pi_screen_blanking usbreset_tool"
STEPS="$STEPS zerotier_vpn"

RAN_ONCE=0
for step in $STEPS ; do
	if [ "$TARGET" == "$step" ] || [ "$TARGET" == "jig" ] ; then
		setup_$step
		RAN_ONCE=1
	fi
done

if [ "$RAN_ONCE" == "0" ] ; then
	echo_red "Invalid build target '$TARGET'; Valid targets are 'jig' or:"
	for step in $STEPS ; do
		echo_red "    $step"
	done
fi

popd
