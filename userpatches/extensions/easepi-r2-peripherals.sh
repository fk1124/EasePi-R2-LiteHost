# EasePi-R2 Peripherals Extension: IR + AP6255 Bluetooth + LiteHost runtime base
# This extension intentionally keeps the classic userpatches/extensions/*.sh path
# for broad Armbian compatibility, while reading overlay files from the kit's
# userpatches/overlay/easepi-r2-peripherals directory.

: "${EASEPI_R2_VENDOR_GPU_STACK:=libmali}"
: "${EASEPI_R2_LIBMALI_DEB_URL:=https://github.com/tsukumijima/libmali-rockchip/releases/download/v1.9-1-20260312-bd33ee2/libmali-valhall-g610-g24p0-gbm_1.9-1_arm64.deb}"
: "${EASEPI_R2_LIBMALI_DEB_SHA256:=32ffe853e8d56295284637252f1da15dd868a8f7c6b8da6b9f77616ba285eb1a}"
: "${EASEPI_R2_VENDOR_HDMI_DEBUG:=no}"
: "${EASEPI_R2_LITEHOST_PRUNE_PACKAGES:=yes}"
: "${EASEPI_R2_LITEHOST_ENABLE_REDROID_PREP:=yes}"

function extension_prepare_config__easepi_r2_peripherals() {
	display_alert "Extension: EasePi-R2 Peripherals" "IR + Bluetooth + networkd router base" "info"
}

function easepi_r2_write_gpu_profile() {
	mkdir -p "${SDCARD}/etc/modules-load.d" "${SDCARD}/etc/modprobe.d"

	if [[ "${BRANCH:-current}" == "vendor" ]]; then
		cat > "${SDCARD}/etc/modules-load.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODULES_VENDOR'
# Rockchip vendor 6.1 uses the in-tree Mali kbase driver. Do not force-load panthor.
EOF_GPU_MODULES_VENDOR
		cat > "${SDCARD}/etc/modprobe.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODPROBE_VENDOR'
# Vendor kernel uses ARM/Rockchip Mali kbase for RK3588 Mali-G610.
blacklist panfrost
blacklist panthor
EOF_GPU_MODPROBE_VENDOR
	else
		cat > "${SDCARD}/etc/modules-load.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODULES_MAINLINE'
# Load RK3588 Mali-G610's mainline DRM driver early.
panthor
EOF_GPU_MODULES_MAINLINE
		cat > "${SDCARD}/etc/modprobe.d/easepi-r2-gpu.conf" <<'EOF_GPU_MODPROBE_MAINLINE'
# panfrost is for older Mali generations and should not bind this GPU.
blacklist panfrost
EOF_GPU_MODPROBE_MAINLINE
	fi
}

function easepi_r2_write_build_time_seed() {
	local build_epoch build_utc build_local

	build_epoch="${EASEPI_R2_BUILD_EPOCH:-$(date -u +%s)}"
	build_utc="$(date -u -d "@${build_epoch}" '+%Y-%m-%d %H:%M:%S UTC')"
	build_local="$(TZ="${EASEPI_R2_BUILD_TZ:-Asia/Shanghai}" date -d "@${build_epoch}" '+%Y-%m-%d %H:%M:%S %Z')"

	mkdir -p \
		"${SDCARD}/etc" \
		"${SDCARD}/usr/local/sbin" \
		"${SDCARD}/etc/systemd/system/sysinit.target.wants" \
		"${SDCARD}/var/lib/systemd/timesync"

	cat > "${SDCARD}/etc/easepi-r2-build-time" <<EOF_BUILD_TIME
BUILD_EPOCH_UTC=${build_epoch}
BUILD_TIME_UTC=${build_utc}
BUILD_TIME_LOCAL=${build_local}
EOF_BUILD_TIME

	cat > "${SDCARD}/etc/fake-hwclock.data" <<EOF_FAKE_HWCLOCK
$(date -u -d "@${build_epoch}" '+%Y-%m-%d %H:%M:%S')
EOF_FAKE_HWCLOCK

	touch -d "@${build_epoch}" "${SDCARD}/var/lib/systemd/timesync/clock" 2>/dev/null || true

	cat > "${SDCARD}/usr/local/sbin/easepi-r2-seed-clock" <<'EOF_SEED_CLOCK'
#!/usr/bin/env bash
set -euo pipefail

seed_file="/etc/easepi-r2-build-time"
[ -f "${seed_file}" ] || exit 0

build_epoch="$(awk -F= '$1 == "BUILD_EPOCH_UTC" { print $2 }' "${seed_file}" | tr -cd '0-9' | head -c 16)"
[ -n "${build_epoch}" ] || exit 0

now_epoch="$(date -u +%s 2>/dev/null || printf '0')"
case "${now_epoch}" in
	''|*[!0-9]*) now_epoch=0 ;;
esac

if [ "${now_epoch}" -lt "${build_epoch}" ]; then
	date -u -s "@${build_epoch}" >/dev/null 2>&1 || exit 0
	logger -t easepi-r2-seed-clock "system clock seeded from image build time: ${build_epoch}" 2>/dev/null || true
fi

mkdir -p /var/lib/systemd/timesync
touch -d "@${build_epoch}" /var/lib/systemd/timesync/clock 2>/dev/null || true
EOF_SEED_CLOCK

	chmod 0755 "${SDCARD}/usr/local/sbin/easepi-r2-seed-clock"

	cat > "${SDCARD}/etc/systemd/system/easepi-r2-seed-clock.service" <<'EOF_SEED_CLOCK_SERVICE'
[Unit]
Description=Seed system clock from EasePi-R2 image build time
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target time-set.target time-sync.target systemd-timesyncd.service chrony.service chronyd.service ntp.service
ConditionPathExists=/etc/easepi-r2-build-time

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-seed-clock

[Install]
WantedBy=sysinit.target
EOF_SEED_CLOCK_SERVICE

	ln -sfn ../easepi-r2-seed-clock.service \
		"${SDCARD}/etc/systemd/system/sysinit.target.wants/easepi-r2-seed-clock.service"
}

function easepi_r2_stage_vendor_libmali() {
	[[ "${BRANCH:-current}" == "vendor" ]] || return 0
	[[ "${EASEPI_R2_VENDOR_GPU_STACK}" == "libmali" ]] || return 0

	local cache_root="${SRC:-/tmp}/cache/easepi-r2-libmali"
	local deb_name deb_path tmp_path

	deb_name="$(basename "${EASEPI_R2_LIBMALI_DEB_URL}")"
	deb_path="${cache_root}/${deb_name}"
	tmp_path="${deb_path}.tmp"

	mkdir -p "${cache_root}" "${SDCARD}/tmp"
	if [[ ! -f "${deb_path}" ]]; then
		curl -fL --retry 3 --connect-timeout 15 -o "${tmp_path}" "${EASEPI_R2_LIBMALI_DEB_URL}"
		mv -f "${tmp_path}" "${deb_path}"
	fi
	printf '%s  %s\n' "${EASEPI_R2_LIBMALI_DEB_SHA256}" "${deb_path}" | sha256sum -c -
	cp -f "${deb_path}" "${SDCARD}/tmp/easepi-r2-libmali.deb"
}

function easepi_r2_apt_install_best_effort() {
	local apt_opts=(
		-y --no-install-recommends
		-o Dpkg::Use-Pty=0
		-o Dpkg::Options::=--force-confdef
		-o Dpkg::Options::=--force-confold
	)
	local pkg

	[[ "$#" -gt 0 ]] || return 0

	if chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get install "${apt_opts[@]}" "$@"; then
		return 0
	fi

	display_alert "EasePi-R2 LiteHost" "Retrying packages one by one" "wrn"
	for pkg in "$@"; do
		chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true apt-get install "${apt_opts[@]}" "${pkg}" || \
			display_alert "EasePi-R2 LiteHost" "Optional package skipped: ${pkg}" "wrn"
	done

	return 0
}

function easepi_r2_preseed_litehost_debconf() {
	local preseeds="${SDCARD}/tmp/easepi-r2-litehost-debconf-selections"

	mkdir -p "${SDCARD}/tmp"
	cat > "${preseeds}" <<'EOF_DEBCONF'
iperf3 iperf3/start_daemon boolean false
EOF_DEBCONF

	chroot_sdcard debconf-set-selections /tmp/easepi-r2-litehost-debconf-selections || true
	rm -f "${preseeds}"
}

function easepi_r2_configure_litehost_defaults() {
	display_alert "EasePi-R2 LiteHost" "Configuring LXC and Redroid host defaults" "info"

	mkdir -p \
		"${SDCARD}/etc/lxc" \
		"${SDCARD}/var/lib/lxc" \
		"${SDCARD}/var/cache/lxc" \
		"${SDCARD}/usr/local/sbin" \
		"${SDCARD}/etc/systemd/system/multi-user.target.wants"

	grep -q '^root:100000:65536$' "${SDCARD}/etc/subuid" 2>/dev/null || \
		echo 'root:100000:65536' >> "${SDCARD}/etc/subuid"
	grep -q '^root:100000:65536$' "${SDCARD}/etc/subgid" 2>/dev/null || \
		echo 'root:100000:65536' >> "${SDCARD}/etc/subgid"

	cat > "${SDCARD}/etc/lxc/default.conf" <<'EOF_LXC_DEFAULT'
lxc.include = /usr/share/lxc/config/common.conf
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
EOF_LXC_DEFAULT

	cat > "${SDCARD}/etc/lxc/lxc-usernet" <<'EOF_LXC_USERNET'
# LiteHost does not create a default LXC bridge. Container networking is
# configured later by EasePi-R2-Script or by the user.
EOF_LXC_USERNET

	cat > "${SDCARD}/etc/default/lxc-net" <<'EOF_LXC_NET'
USE_LXC_BRIDGE="false"
EOF_LXC_NET

	cat > "${SDCARD}/usr/local/sbin/easepi-r2-redroid-host-prep" <<'EOF_REDROID_PREP'
#!/usr/bin/env bash
set -euo pipefail

modprobe binder_linux devices=binder,hwbinder,vndbinder,anbox-binder,anbox-hwbinder,anbox-vndbinder 2>/dev/null || true
modprobe ashmem_linux 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
modprobe overlay 2>/dev/null || true
modprobe veth 2>/dev/null || true
modprobe tun 2>/dev/null || true
modprobe 8021q 2>/dev/null || true

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lte4g.accept_ra=2 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lte4g.autoconf=1 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true

mkdir -p /dev/binderfs
if grep -qw binder /proc/filesystems; then
	mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs 2>/dev/null || true
fi

for dev in \
	/dev/binderfs/binder \
	/dev/binderfs/hwbinder \
	/dev/binderfs/vndbinder \
	/dev/binderfs/anbox-binder \
	/dev/binderfs/anbox-hwbinder \
	/dev/binderfs/anbox-vndbinder \
	/dev/ashmem; do
	[[ -e "${dev}" ]] || continue
	chmod 0666 "${dev}" 2>/dev/null || true
done
EOF_REDROID_PREP
	chmod 0755 "${SDCARD}/usr/local/sbin/easepi-r2-redroid-host-prep"

	cat > "${SDCARD}/etc/systemd/system/easepi-r2-redroid-host-prep.service" <<'EOF_REDROID_SERVICE'
[Unit]
Description=Prepare BinderFS and Ashmem for Redroid containers
After=systemd-modules-load.service local-fs.target
Before=lxc.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easepi-r2-redroid-host-prep
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_REDROID_SERVICE

	if [[ "${EASEPI_R2_LITEHOST_ENABLE_REDROID_PREP}" == "yes" ]]; then
		ln -sfn ../easepi-r2-redroid-host-prep.service \
			"${SDCARD}/etc/systemd/system/multi-user.target.wants/easepi-r2-redroid-host-prep.service"
	fi
}

function easepi_r2_prune_litehost_packages() {
	[[ "${EASEPI_R2_LITEHOST_PRUNE_PACKAGES}" == "yes" ]] || return 0

	display_alert "EasePi-R2 LiteHost" "Removing unused host networking packages" "info"
	chroot_sdcard systemctl disable NetworkManager.service NetworkManager-wait-online.service avahi-daemon.service cloud-init.service 2>/dev/null || true
	chroot_sdcard systemctl mask NetworkManager.service NetworkManager-wait-online.service avahi-daemon.service cloud-init.service 2>/dev/null || true
	chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get purge -y --autoremove \
		network-manager network-manager-gnome netplan.io ifupdown \
		isc-dhcp-client isc-dhcp-common avahi-daemon avahi-autoipd \
		cloud-init unattended-upgrades openresolv resolvconf || true
}

function pre_customize_image__copy_easepi_r2_peripheral_files() {
	display_alert "EasePi-R2" "Copying peripheral overlay files" "info"

	local OVERLAY_DIR=""

	# Preferred path inside the active Armbian build tree.
	if [[ -n "${SRC:-}" && -d "${SRC}/userpatches/overlay/easepi-r2-peripherals" ]]; then
		OVERLAY_DIR="${SRC}/userpatches/overlay/easepi-r2-peripherals"
	# Fallback: if EXTENSION_DIR is available and overlay sits next to extension.
	elif [[ -n "${EXTENSION_DIR:-}" && -d "${EXTENSION_DIR}/overlay" ]]; then
		OVERLAY_DIR="${EXTENSION_DIR}/overlay"
	fi

	if [[ -z "${OVERLAY_DIR}" || ! -d "${OVERLAY_DIR}" ]]; then
		display_alert "EasePi-R2" "Peripheral overlay not found; skipping IR/BT files" "wrn"
		return 0
	fi

	mkdir -p "${SDCARD}"
	cp -a "${OVERLAY_DIR}/." "${SDCARD}/"
	# eth0-eth3 are aligned by the early easepi-r2-eth-order service. Remove
	# legacy direct .link renames that cannot safely swap eth1 and eth2.
	rm -f "${SDCARD}"/etc/systemd/network/10-easepi-r2-eth{0,1,2,3}.link
	rm -f "${SDCARD}/etc/modprobe.d/99-easepi-r2-panthor-manual-only.conf"
	rm -f "${SDCARD}/usr/local/sbin/easepi-r2-gpu-check"
	chmod +x "${SDCARD}/usr/local/sbin/easepi-r2-eth-order" 2>/dev/null || true
	easepi_r2_write_gpu_profile
	easepi_r2_write_build_time_seed

	if [[ -f "${SDCARD}/usr/local/sbin/bluetooth-hciattach.sh" ]]; then
		chmod +x "${SDCARD}/usr/local/sbin/bluetooth-hciattach.sh"
	fi


	if [[ -f "${SDCARD}/usr/local/ir/fix_infrared.sh" ]]; then
		chmod +x "${SDCARD}/usr/local/ir/fix_infrared.sh"
	fi
}

function easepi_r2_fix_brcm_firmware_aliases() {
	local FW_DIR="${SDCARD}/lib/firmware/brcm"
	local CY_FW_DIR="${SDCARD}/lib/firmware/cypress"
	local RTL_FW_DIR="${SDCARD}/lib/firmware/rtl_nic"
	local MALI_FW_DIR="${SDCARD}/lib/firmware/arm/mali/arch10.8"
	local zst="" base="" preferred_txt="" preferred_hcd="" hcd_target=""

	[[ -d "${FW_DIR}" ]] || return 0

	if command -v zstd >/dev/null 2>&1; then
		for zst in \
			"${FW_DIR}"/*.zst \
			"${CY_FW_DIR}"/*.zst \
			"${RTL_FW_DIR}"/*.zst \
			"${MALI_FW_DIR}"/*.zst \
			"${SDCARD}/lib/firmware/regulatory.db.zst"; do
			[[ -f "${zst}" ]] || continue
			base="${zst%.zst}"
			[[ -e "${base}" ]] || zstd -d -q -f "${zst}" -o "${base}" || true
		done
	fi

	if [[ ! -f "${FW_DIR}/brcmfmac43455-sdio.txt" ]]; then
		for preferred_txt in \
			"${FW_DIR}/brcmfmac43455-sdio.AW-CM256SM.txt" \
			"${FW_DIR}/brcmfmac43455-sdio.acepc-t8.txt" \
			"${FW_DIR}/brcmfmac43455-sdio.raspberrypi,4-model-b.txt"; do
			if [[ -f "${preferred_txt}" ]]; then
				ln -sfn "$(basename "${preferred_txt}")" "${FW_DIR}/brcmfmac43455-sdio.txt"
				break
			fi
		done
	fi

	if [[ ! -f "${FW_DIR}/brcmfmac43455-sdio.bin" && -f "${CY_FW_DIR}/cyfmac43455-sdio.bin" ]]; then
		ln -sfn "../cypress/cyfmac43455-sdio.bin" "${FW_DIR}/brcmfmac43455-sdio.bin"
	fi

	if [[ ! -f "${FW_DIR}/brcmfmac43455-sdio.clm_blob" && -f "${CY_FW_DIR}/cyfmac43455-sdio.clm_blob" ]]; then
		ln -sfn "../cypress/cyfmac43455-sdio.clm_blob" "${FW_DIR}/brcmfmac43455-sdio.clm_blob"
	fi

	[[ -f "${FW_DIR}/brcmfmac43455-sdio.bin" ]] && \
		ln -sfn "brcmfmac43455-sdio.bin" "${FW_DIR}/brcmfmac43455-sdio.linkease,easepi-r2.bin"
	[[ -f "${FW_DIR}/brcmfmac43455-sdio.txt" ]] && \
		ln -sfn "brcmfmac43455-sdio.txt" "${FW_DIR}/brcmfmac43455-sdio.linkease,easepi-r2.txt"
	[[ -f "${FW_DIR}/brcmfmac43455-sdio.clm_blob" ]] && \
		ln -sfn "brcmfmac43455-sdio.clm_blob" "${FW_DIR}/brcmfmac43455-sdio.linkease,easepi-r2.clm_blob"

	if [[ ! -e "${FW_DIR}/BCM4345C0.hcd" ]]; then
		for preferred_hcd in \
			"${FW_DIR}/BCM4345C0_003.001.025.0162.0000_Generic_UART_37_4MHz_wlbga_ref_iLNA_iTR_eLG.hcd" \
			"${FW_DIR}/BCM4345C0.raspberrypi,4-compute-module.hcd" \
			"${FW_DIR}/BCM4345C0.firefly,rk3566-roc-pc.hcd" \
			"${FW_DIR}/BCM4345C0.radxa,zero2.hcd" \
			"${FW_DIR}/BCM4345C0.amlogic,sm1.hcd" \
			"${SDCARD}/lib/firmware/BCM4345C0.hcd"; do
			[[ -f "${preferred_hcd}" ]] || continue
			case "${preferred_hcd}" in
				"${FW_DIR}"/*) hcd_target="$(basename "${preferred_hcd}")" ;;
				"${SDCARD}/lib/firmware/"*) hcd_target="../$(basename "${preferred_hcd}")" ;;
				*) hcd_target="${preferred_hcd}" ;;
			esac
			ln -sfn "${hcd_target}" "${FW_DIR}/BCM4345C0.hcd"
			break
		done
	fi

	[[ -e "${FW_DIR}/BCM4345C0.hcd" ]] && \
		ln -sfn "BCM4345C0.hcd" "${FW_DIR}/BCM4345C0.linkease,easepi-r2.hcd"
}

function easepi_r2_tune_vendor_bootenv() {
	[[ "${BRANCH:-current}" == "vendor" ]] || return 0

	local env_file="${SDCARD}/boot/armbianEnv.txt"
	local extraargs=""

	[[ -f "${env_file}" ]] || return 0

	extraargs="$(sed -n 's/^extraargs=//p' "${env_file}" | tail -1)"
	case " ${extraargs} " in
		*" cma=256M "*) ;;
		*) extraargs="cma=256M${extraargs:+ ${extraargs}}" ;;
	esac

	sed -i \
		-e '/^overlay_prefix=/d' \
		-e '/^usbstoragequirks=/d' \
		-e '/^extraargs=/d' \
		"${env_file}"

	cat >> "${env_file}" <<EOF_VENDOR_BOOTENV
overlay_prefix=rockchip-rk3588
usbstoragequirks=0x2537:0x1066:u,0x2537:0x1068:u
extraargs=${extraargs}
EOF_VENDOR_BOOTENV
}

function easepi_r2_enable_vendor_hdmi_debug() {
	[[ "${BRANCH:-current}" == "vendor" ]] || return 0
	[[ "${EASEPI_R2_VENDOR_HDMI_DEBUG}" == "yes" ]] || return 0

	local env_file="${SDCARD}/boot/armbianEnv.txt"
	local boot_cmd="${SDCARD}/boot/boot.cmd"
	local boot_scr="${SDCARD}/boot/boot.scr"
	local extraargs=""
	local arg=""

	[[ -f "${env_file}" ]] || return 0
	display_alert "EasePi-R2" "Enabling vendor HDMI debug console" "info"

	extraargs="$(sed -n 's/^extraargs=//p' "${env_file}" | tail -1)"
	for arg in \
		ignore_loglevel \
		no_console_suspend \
		log_buf_len=4M \
		systemd.log_level=debug \
		systemd.log_target=console \
		fbcon=nodefer \
		plymouth.enable=0
	do
		case " ${extraargs} " in
			*" ${arg} "*) ;;
			*) extraargs="${extraargs:+${extraargs} }${arg}" ;;
		esac
	done

	sed -i \
		-e 's/^verbosity=.*/verbosity=7/' \
		-e 's/^console=.*/console=both/' \
		-e 's/^bootlogo=.*/bootlogo=false/' \
		-e '/^stdin=/d' \
		-e '/^stdout=/d' \
		-e '/^stderr=/d' \
		-e '/^extraargs=/d' \
		"${env_file}"

	cat >> "${env_file}" <<EOF_VENDOR_HDMI_DEBUG
stdin=serial,usbkbd
stdout=serial,vidconsole
stderr=serial,vidconsole
extraargs=${extraargs}
EOF_VENDOR_HDMI_DEBUG

	if [[ -f "${boot_cmd}" && -x "$(command -v mkimage)" ]]; then
		sed -i \
			-e 's/setenv consoleargs "splash plymouth.ignore-serial-consoles ${consoleargs}"/setenv consoleargs "${consoleargs}"/' \
			-e 's/setenv consoleargs "splash=verbose ${consoleargs}"/setenv consoleargs "${consoleargs}"/' \
			"${boot_cmd}"
		mkimage -C none -A arm -T script -d "${boot_cmd}" "${boot_scr}" >/dev/null
	fi
}

function post_customize_image__enable_easepi_r2_peripheral_services() {
	display_alert "EasePi-R2" "Enabling peripheral services" "info"

	# Armbian's extension path does not consume rootfs/debian/packages-*.txt.
	# Install the LiteHost runtime explicitly so first boot is ready for
	# LXC OpenWrt, LXC Debian, and Redroid workloads.
	# If a base image already has /etc/nftables.conf, move it aside while
	# installing nftables to avoid non-interactive conffile prompts.
	display_alert "EasePi-R2 LiteHost" "Installing host runtime packages" "info"
	local R2_NFT_BACKUP="${SDCARD}/tmp/easepi-r2-nftables.conf.backup"
	mkdir -p "${SDCARD}/tmp"
	easepi_r2_stage_vendor_libmali
	if [[ -f "${SDCARD}/etc/nftables.conf" ]]; then
		mv "${SDCARD}/etc/nftables.conf" "${R2_NFT_BACKUP}"
	fi
	easepi_r2_preseed_litehost_debconf
	local EASEPI_R2_COMMON_RUNTIME=(
		systemd-container dbus-user-session
		systemd-resolved
		lxc lxcfs lxc-templates uidmap libpam-cgfs
		debootstrap mmdebstrap qemu-user-static binfmt-support
		fuse-overlayfs slirp4netns criu
		iproute2 iputils-ping ethtool bridge-utils
		dnsmasq nftables iptables ebtables arptables
		conntrack ipset tcpdump socat iperf3
		ppp pppoe curl ca-certificates rsync zstd xz-utils unzip
		jq htop iotop iftop nload tmux screen vim-tiny nano less lsof strace
		usbutils pciutils kmod
		modemmanager usb-modeswitch
		wpasupplicant hostapd
		rfkill bluetooth bluez bluez-tools
		v4l-utils android-tools-adb android-tools-fastboot
	)
	local EASEPI_R2_GPU_RUNTIME=()
	if [[ "${BRANCH:-current}" == "vendor" ]]; then
		EASEPI_R2_GPU_RUNTIME=(libdrm2 libgbm1 ocl-icd-libopencl1 clinfo)
	else
		EASEPI_R2_GPU_RUNTIME=(
			libdrm2 libegl-mesa0 libgles2 libgl1-mesa-dri
			mesa-vulkan-drivers mesa-utils vulkan-tools
			kmscube glmark2-es2-drm
		)
	fi
	chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || true
	easepi_r2_apt_install_best_effort \
		"${EASEPI_R2_COMMON_RUNTIME[@]}" \
		"${EASEPI_R2_GPU_RUNTIME[@]}"
	easepi_r2_apt_install_best_effort bluez-firmware || true
	if [[ -f "${R2_NFT_BACKUP}" ]]; then
		mv "${R2_NFT_BACKUP}" "${SDCARD}/etc/nftables.conf"
	fi
	if [[ "${BRANCH:-current}" == "vendor" && "${EASEPI_R2_VENDOR_GPU_STACK}" == "libmali" && -f "${SDCARD}/tmp/easepi-r2-libmali.deb" ]]; then
		chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update || true
		easepi_r2_apt_install_best_effort libdrm2 libgbm1 ocl-icd-libopencl1 clinfo v4l-utils ca-certificates
		chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/easepi-r2-libmali.deb || \
			chroot_sdcard /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -f install -y
		rm -f "${SDCARD}/tmp/easepi-r2-libmali.deb"
	fi
	easepi_r2_configure_litehost_defaults
	easepi_r2_prune_litehost_packages
	easepi_r2_fix_brcm_firmware_aliases
	easepi_r2_tune_vendor_bootenv
	easepi_r2_enable_vendor_hdmi_debug

	if [[ -f "${SDCARD}/etc/systemd/system/ir-keymap.service" ]]; then
		chroot_sdcard systemctl enable ir-keymap.service || true
	fi

	if [[ -f "${SDCARD}/etc/systemd/system/bluetooth-hciattach.service" ]]; then
		chroot_sdcard systemctl enable bluetooth-hciattach.service || true
	fi

	# LiteHost is only the container host base. Do not pre-create br-lan,
	# lxcbr0, DHCP, NAT, or LTE data-plane rules in the image; those are owned
	# by EasePi-R2-Script/0.sh, 1.sh, or the user's later configuration.
	mkdir -p "${SDCARD}/etc/easepi-r2-litehost/disabled-netplan-build" "${SDCARD}/etc/easepi-r2-litehost/disabled-networkd-build"
	if [[ -d "${SDCARD}/etc/netplan" ]]; then
		find "${SDCARD}/etc/netplan" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -exec mv -t "${SDCARD}/etc/easepi-r2-litehost/disabled-netplan-build" {} + 2>/dev/null || true
	fi
	if [[ -d "${SDCARD}/etc/systemd/network" ]]; then
		for f in "${SDCARD}"/etc/systemd/network/*.network; do
			[[ -e "$f" ]] || continue
			b="$(basename "$f")"
			case "$b" in
				*easepi-r2*.network) ;;
				*) mv "$f" "${SDCARD}/etc/easepi-r2-litehost/disabled-networkd-build/$b" 2>/dev/null || true ;;
			esac
		done
	fi
	chroot_sdcard systemctl disable NetworkManager.service || true
	# Align RTL8125 interface names before any network manager starts.
	chroot_sdcard systemctl enable easepi-r2-eth-order.service || true
	chroot_sdcard systemctl disable ModemManager.service || true
	chroot_sdcard systemctl enable systemd-networkd.service || true
	chroot_sdcard systemctl enable systemd-resolved.service || true
	chroot_sdcard systemctl disable dnsmasq.service || true
	chroot_sdcard systemctl disable nftables.service || true
	chroot_sdcard systemctl disable lxc-net.service || true
	rm -f "${SDCARD}/etc/resolv.conf"
	ln -sfn /run/systemd/resolve/resolv.conf "${SDCARD}/etc/resolv.conf"
	chroot_sdcard systemctl enable lxcfs.service || true
	if [[ "${EASEPI_R2_LITEHOST_ENABLE_REDROID_PREP}" == "yes" ]]; then
		chroot_sdcard systemctl enable easepi-r2-redroid-host-prep.service || true
	fi
	# This service only waits for network-online and commonly times out on router
	# devices with unplugged LAN/backup-WAN ports. It is not needed for DHCP/NAT.
	chroot_sdcard systemctl disable systemd-networkd-wait-online.service || true
	chroot_sdcard systemctl mask systemd-networkd-wait-online.service || true

	chroot_sdcard systemctl enable bluetooth.service || true
	easepi_r2_write_build_time_seed
}
