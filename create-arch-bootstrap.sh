#!/usr/bin/env bash

# Dependencies: curl tar gzip grep coreutils zstd sed
# Root rights are required
# Select a build profile with PROFILE=<name> (profiles/<name>.sh).
# Empty/unset keeps the legacy default: settings.sh (full).
script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
settings_file="${script_dir}/settings.sh"
if [ -n "${PROFILE:-}" ]; then
	settings_file="${script_dir}/profiles/${PROFILE}.sh"
	if [ ! -f "${settings_file}" ]; then
		echo "Unknown profile '${PROFILE}': ${settings_file} not found"
		echo "Available: $(ls "${script_dir}"/profiles/*.sh 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')"
		exit 1
	fi
fi
# shellcheck source=settings.sh
source "${settings_file}"

if [ "${PROFILE_STATUS:-stable}" = "planned" ]; then
	echo "Profile '${PROFILE}' is planned but not implemented yet (bootstrap support missing)."
	exit 1
fi

check_command_available() {
	for cmd in "$@"; do
		if ! command -v "$cmd" >&-; then
			echo "$cmd is required!"
			exit 1
		fi
	done
}
check_command_available curl gzip grep sha256sum tar zstd sed awk

if [ $EUID != 0 ]; then
	echo "Root rights are required!"
	exit 1
fi

bootstrap="${script_dir}"/root.x86_64

mount_chroot () {
	mount -o bind "${bootstrap}" "${bootstrap}"
	mount -t proc /proc "${bootstrap}"/proc
	mount -t sysfs sys "${bootstrap}"/sys
	mount -o bind /dev "${bootstrap}"/dev
	mount -o bind /dev/pts "${bootstrap}"/dev/pts
	mount -o bind /dev/shm "${bootstrap}"/dev/shm

	rm -f "${bootstrap}"/etc/resolv.conf
	cp /etc/resolv.conf "${bootstrap}"/etc/resolv.conf
	cp "${settings_file}" "${bootstrap}"/conty_settings.sh

	mkdir -p "${bootstrap}"/run/shm
}

unmount_chroot () {
	umount -l "${bootstrap}"
	for fs in proc sys dev/pts dev/shm dev; do
		umount "${bootstrap}"/"${fs}"
	done
}

run_in_chroot () {
	if [ -n "${CHROOT_AUR}" ]; then
		chroot --userspec=aur:aur "${bootstrap}" /usr/bin/env LANG=en_US.UTF-8 TERM=xterm PATH="/bin:/sbin:/usr/bin:/usr/sbin" "$@"
	else
		chroot "${bootstrap}" /usr/bin/env LANG=en_US.UTF-8 TERM=xterm PATH="/bin:/sbin:/usr/bin:/usr/sbin" "$@"
	fi
}

install_packages () {
	source /conty_settings.sh
	echo "Checking if packages are present in the repos, please wait..."

	declare -a bad_pkglist
	mapfile -t bad_pkglist < <(comm -23 \
									<(printf '%s\n' "${PACKAGES[@]}" | sort -u) \
									<(pacman -Slq | sort -u))
	if [ "${#bad_pkglist[@]}" -gt 0 ]; then
		echo "These packages are not available in arch repositories: " "${bad_pkglist[@]}"
		exit 1
	fi

	for i in {1..10}; do
		if pacman --noconfirm --needed -S "${PACKAGES[@]}" || [ "$?" -gt 127 ]; then
			break
		fi
	done

}

install_aur_packages () {
	cd /home/aur

	echo "Checking if packages are present in the AUR, please wait..."
	for p in ${aur_pkgs}; do
		if ! paru --clonedir /home/aur -a -G "${p}" &>/dev/null; then
			bad_aur_pkglist="${bad_aur_pkglist} ${p}"
		else
			good_aur_pkglist="${good_aur_pkglist} ${p}"
		fi
	done

	if [ -n "${bad_aur_pkglist}" ]; then
		echo ${bad_aur_pkglist} > /home/aur/bad_aur_pkglist.txt
	fi

	for i in {1..10}; do
		if paru --noconfirm --sync --removemake --skipreview --useask --clonedir /home/aur --builddir /home/aur -a ${good_aur_pkglist}; then
			break
		fi
	done
}

generate_pkg_licenses_file () {
	pacman -Qi | grep -E '^Name|Licenses' |  cut -d ":" -f 2 | paste -d ' ' - - > /pkglicenses.txt
}

generate_localegen () {
	printf '%s\n' "${LOCALES[@]}" > locale.gen
}

generate_mirrorlist () {
	printf '%s\n' "$MIRRORLIST" > mirrorlist
}

unset proxy
if [ -n "${DOWNLOAD_PROXY}" ]; then
	proxy=(-x "${DOWNLOAD_PROXY}")

	export http_proxy="${DOWNLOAD_PROXY}"
	export https_proxy="${DOWNLOAD_PROXY}"
	export HTTP_PROXY="${DOWNLOAD_PROXY}"
	export HTTPS_PROXY="${DOWNLOAD_PROXY}"
fi

cd "${script_dir}" || exit 1

if [ ! -f sha256sums.txt ] || [ ! -f archlinux-bootstrap-x86_64.tar.zst ]; then
	curl ${proxy[@]} -#LO "$BOOTSTRAP_SHA256SUM_FILE_URL" || (echo "Failed to download sha256sums.txt file"; exit 1)

	grep archlinux-bootstrap-x86_64.tar.zst sha256sums.txt > _
	mv -f _ sha256sums.txt

	for link in "${BOOTSTRAP_DOWNLOAD_URLS[@]}"; do
		echo "Downloading Arch Linux bootstrap from $link"
		curl ${proxy[@]} -#LO "$link"

		echo "Verifying the integrity of the bootstrap"
		if sha256sum -c sha256sums.txt &>/dev/null; then
			bootstrap_is_good=1
			break
		fi
		echo "Download failed, trying again with different mirror"
	done

	if [ -z "${bootstrap_is_good}" ]; then
		echo "Bootstrap download failed or its checksum is incorrect"
		rm -f archlinux-bootstrap-x86_64.tar.zst sha256sums.txt
		exit 1
	fi
fi

# Unmount first just in case
unmount_chroot

rm -rf "${bootstrap}"
zstd -dc archlinux-bootstrap-x86_64.tar.zst | tar -xf -

mount_chroot

generate_localegen

if command -v reflector 1>/dev/null; then
	echo "Generating mirrorlist..."
	reflector --connection-timeout 10 --download-timeout 10 --protocol https --score 10 --sort rate --save mirrorlist
	reflector_used=1
else
	generate_mirrorlist
fi

rm "${bootstrap}"/etc/locale.gen
mv locale.gen "${bootstrap}"/etc/locale.gen

if [ ! -f mirrorlist ]; then
	generate_mirrorlist
	reflector_used=0
fi

if [ -f mirrorlist ]; then
	rm "${bootstrap}"/etc/pacman.d/mirrorlist
	mv mirrorlist "${bootstrap}"/etc/pacman.d/mirrorlist
fi

#if [ -n "${DOWNLOAD_PROXY}" ]; then
#	sed "s,#XferCommand = /usr/bin/curl -L -C - -f -o %o %u,XferCommand = /usr/bin/curl ${proxy[0]} ${proxy[1]} -L -C - -f -o %o %u," "${bootstrap}"/etc/pacman.conf > _
#	mv -f _ "${bootstrap}"/etc/pacman.conf
#fi

sed 's/#DisableSandboxSyscalls/#DisableSandboxSyscalls\nDisableSandbox/' "${bootstrap}"/etc/pacman.conf > _
mv -f _ "${bootstrap}"/etc/pacman.conf

if [ -n "${ENABLE_MULTILIB-1}" ]; then
# Descomentar la estanza stock (no añadir: duplicaria el registro).
sed -i -E '/^#\[multilib\]/,/^#?Include/s/^#//' "${bootstrap}"/etc/pacman.conf
fi

run_in_chroot pacman-key --init
run_in_chroot pacman-key --populate archlinux

# Chaotic-AUR repo (opt-out por perfil: arxy usa solo repos oficiales).
if [ "${ENABLE_CHAOTIC_REPO-1}" = "1" ]; then
# Add Chaotic-AUR repo
if ! run_in_chroot pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com; then
	chaotic_keyring_extract_dir="${bootstrap}/tmp/chaotic-keyring"
	mkdir -p "${chaotic_keyring_extract_dir}"
	curl -L --retry 3 -o "${chaotic_keyring_extract_dir}/chaotic-keyring.pkg.tar.zst" "https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst"
	tar -xf "${chaotic_keyring_extract_dir}/chaotic-keyring.pkg.tar.zst" -C "${chaotic_keyring_extract_dir}"
	run_in_chroot pacman-key --add /tmp/chaotic-keyring/usr/share/pacman/keyrings/chaotic.gpg
	rm -rf "${chaotic_keyring_extract_dir}"
fi

run_in_chroot pacman-key --lsign-key 3056513887B78AEB

if ! run_in_chroot pacman --noconfirm -U \
	 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
	 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'; then
	echo "Seems like Chaotic-AUR keyring or mirrorlist is currently unavailable"
	echo "Please try again later"
	exit 1
fi

{
	echo
	echo "[chaotic-aur]"
	echo "Include = /etc/pacman.d/chaotic-mirrorlist"
} >> "${bootstrap}"/etc/pacman.conf
fi # ENABLE_CHAOTIC_REPO

# Do not install unneeded files (man pages and Nvidia firmwares by
# default; profiles can extend via PACMAN_NOEXTRACT, '|' as sed delimiter).
sed "s|#NoExtract   =|NoExtract   = ${PACMAN_NOEXTRACT-usr/lib/firmware/nvidia/* usr/share/man/*}|" "${bootstrap}"/etc/pacman.conf > _
mv -f _ "${bootstrap}"/etc/pacman.conf

run_in_chroot pacman -Sy archlinux-keyring --noconfirm
run_in_chroot pacman -Su --noconfirm

if [ -n "$ENABLE_ALHP_REPO" ]; then
	run_in_chroot pacman --noconfirm --needed -S alhp-keyring alhp-mirrorlist
	sed "s/#\[multilib\]/#/" "${bootstrap}"/etc/pacman.conf > _
	mv -f _ "${bootstrap}"/etc/pacman.conf
	sed "s/\[core\]/\[core-x86-64-v${ALHP_FEATURE_LEVEL}\]\nInclude = \/etc\/pacman.d\/alhp-mirrorlist\n\n\[extra-x86-64-v${ALHP_FEATURE_LEVEL}\]\nInclude = \/etc\/pacman.d\/alhp-mirrorlist\n\n\[core\]/" "${bootstrap}"/etc/pacman.conf > _
	mv -f _ "${bootstrap}"/etc/pacman.conf
	sed "s/\[multilib\]/\[multilib-x86-64-v${ALHP_FEATURE_LEVEL}\]\nInclude = \/etc\/pacman.d\/alhp-mirrorlist\n\n\[multilib\]/" "${bootstrap}"/etc/pacman.conf > _
	mv -f _ "${bootstrap}"/etc/pacman.conf
	run_in_chroot pacman -Syu --noconfirm
fi

# Add CachyOS repos when the active profile sets CACHYOS_ARCH
# (x86-64-v3, x86-64-v4 or znver4; needs a matching CPU, else SIGILL).
# Only the arch-optimized repos are added, NOT the plain [cachyos] repo,
# which carries a forked pacman that warns under stock Arch pacman.
# Sections are inserted BEFORE [core] so optimized packages take
# precedence over stock Arch ones. Runs before the -Sy/-Su below so the
# new repos are synced like the rest.
if [ -n "${CACHYOS_ARCH:-}" ]; then
	case "${CACHYOS_ARCH}" in
		x86-64-v3)
			cachyos_sections="cachyos-v3 cachyos-core-v3 cachyos-extra-v3"
			cachyos_mirrorlist="cachyos-v3-mirrorlist"
			;;
		x86-64-v4)
			cachyos_sections="cachyos-v4 cachyos-core-v4 cachyos-extra-v4"
			cachyos_mirrorlist="cachyos-v4-mirrorlist"
			;;
		znver4)
			cachyos_sections="cachyos-znver4 cachyos-core-znver4 cachyos-extra-znver4"
			cachyos_mirrorlist="cachyos-v4-mirrorlist"
			;;
		*)
			echo "Unknown CACHYOS_ARCH '${CACHYOS_ARCH}' (want x86-64-v3, x86-64-v4 or znver4)"
			exit 1
			;;
	esac

	if ! run_in_chroot pacman-key --recv-key F3B607488DB35A47 --keyserver keyserver.ubuntu.com; then
		cachyos_keyring_extract_dir="${bootstrap}/tmp/cachyos-keyring"
		mkdir -p "${cachyos_keyring_extract_dir}"
		curl -L --retry 3 -o "${cachyos_keyring_extract_dir}/cachyos-keyring.pkg.tar.zst" "https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst"
		tar -xf "${cachyos_keyring_extract_dir}/cachyos-keyring.pkg.tar.zst" -C "${cachyos_keyring_extract_dir}"
		run_in_chroot pacman-key --add /tmp/cachyos-keyring/usr/share/pacman/keyrings/cachyos.gpg
		rm -rf "${cachyos_keyring_extract_dir}"
	fi

	run_in_chroot pacman-key --lsign-key F3B607488DB35A47

	# Keyring + mirrorlists. These URLs are versioned and may rot, so a
	# failure here is not fatal: the key is already trusted above and we
	# fall back to minimal mirrorlists with direct Server lines.
	cachyos_mirror_url="https://mirror.cachyos.org/repo/x86_64/cachyos"
	if ! run_in_chroot pacman --noconfirm -U \
		 "${cachyos_mirror_url}/cachyos-keyring-20240331-1-any.pkg.tar.zst" \
		 "${cachyos_mirror_url}/cachyos-v3-mirrorlist-27-1-any.pkg.tar.zst" \
		 "${cachyos_mirror_url}/cachyos-v4-mirrorlist-27-1-any.pkg.tar.zst"; then
		echo "CachyOS keyring/mirrorlist packages unavailable, using fallback mirrorlists"
	fi
	for ml in cachyos-v3-mirrorlist cachyos-v4-mirrorlist; do
		if [ ! -s "${bootstrap}/etc/pacman.d/${ml}" ]; then
			printf '%s\n' 'Server = https://mirror.cachyos.org/repo/$arch/$repo' > "${bootstrap}/etc/pacman.d/${ml}"
		fi
	done

	{
		echo
		for s in ${cachyos_sections}; do
			echo "[${s}]"
			echo "Include = /etc/pacman.d/${cachyos_mirrorlist}"
			echo
		done
	} > "${bootstrap}"/cachyos-repos.conf
	awk 'BEGIN{done=0} /^\[core\]$/ && !done {while ((getline line < repos) > 0) print line; done=1} {print}' repos="${bootstrap}"/cachyos-repos.conf "${bootstrap}"/etc/pacman.conf > _
	mv -f _ "${bootstrap}"/etc/pacman.conf
	rm -f "${bootstrap}"/cachyos-repos.conf
	run_in_chroot pacman -Syu --noconfirm
fi

date -u +"%d-%m-%Y %H:%M (DMY UTC)" > "${bootstrap}"/version

# Build-time toolset inside the image (default keeps legacy behavior).
# Profiles that do not need it (arxy: no kernel, no squashfs, pacman runs
# as root via host sudo) set BOOTSTRAP_BASE_PACKAGES empty to skip.
if [ -n "${BOOTSTRAP_BASE_PACKAGES-base reflector squashfs-tools fakeroot}" ]; then
run_in_chroot pacman --noconfirm --needed -S ${BOOTSTRAP_BASE_PACKAGES-base reflector squashfs-tools fakeroot}
fi

# Regenerate the mirrorlist with reflector if reflector was not used before
# (and the profile did not opt out via ENABLE_REFLECTOR=).
if [ -z "${reflector_used}" ] && [ -n "${ENABLE_REFLECTOR-1}" ]; then
	echo "Generating mirrorlist..."
	run_in_chroot reflector --connection-timeout 10 --download-timeout 10 --protocol https --score 10 --sort rate --save /etc/pacman.d/mirrorlist
	run_in_chroot pacman -Syu --noconfirm
fi

export -f install_packages
if ! run_in_chroot bash -c install_packages; then
	unmount_chroot
	exit 1
fi

# mesa-mini (archlinux-pkgs-debloated, release 'continuous'): mismo
# pkgname=mesa sin dependencia de llvm-libs. Medido: -169MB (mesa 53.85
# ->39.5MB + llvm-libs 163.7MB fuera, delink verificado con ldd).
# Se elige mini sobre nano: nano compila con -Os y upstream advierte de
# problemas de rendimiento y estabilidad; la imagen corre juegos (steam)
# y emuladores. No es repo pacman: descarga + -U. llvm-libs queda
# huerfano (solo mesa lo pedia) y sale con -Rsn; si un futuro PACKAGES
# lo exige, esto falla en voz alta a proposito.
if [ -n "${DEBLOATED_MESA_URL:-}" ]; then
	curl -fL --retry 3 -o "${bootstrap}/tmp/mesa-mini.pkg.tar.zst" "${DEBLOATED_MESA_URL}" || { echo "mesa-mini download failed"; unmount_chroot; exit 1; }
	run_in_chroot pacman --noconfirm -U /tmp/mesa-mini.pkg.tar.zst || { echo "mesa-mini install failed"; unmount_chroot; exit 1; }
	rm -f "${bootstrap}/tmp/mesa-mini.pkg.tar.zst"
	if run_in_chroot pacman -Qq llvm-libs >/dev/null 2>&1; then
		run_in_chroot pacman --noconfirm -Rsn llvm-libs || { echo "llvm-libs removal failed (alguien lo exige: revisar PACKAGES)"; unmount_chroot; exit 1; }
	fi
fi

if [ "${#AUR_PACKAGES[@]}" -ne 0 ]; then
	run_in_chroot pacman --noconfirm --needed -S base-devel paru
	run_in_chroot useradd -m -G wheel aur
	echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> "${bootstrap}"/etc/sudoers

	for p in "${AUR_PACKAGES[@]}"; do
		aur_pkgs="${aur_pkgs} aur/${p}"
	done
	export aur_pkgs

	export -f install_aur_packages
	CHROOT_AUR=1 HOME=/home/aur run_in_chroot bash -c install_aur_packages
	mv "${bootstrap}"/home/aur/bad_aur_pkglist.txt "${bootstrap}"/opt
	rm -rf "${bootstrap}"/home/aur
fi

run_in_chroot locale-gen || { echo "locale-gen FAILED"; unmount_chroot; exit 1; }
# i18n excluido de AQUI en adelante (no antes: locale-gen necesita los
# charmaps). Evita que futuros installs restauren las fuentes (+17MB).
sed -i 's|^NoExtract   = |NoExtract   = usr/share/i18n/* |' "${bootstrap}"/etc/pacman.conf
# mesa-mini congelado: sin esto el primer 'arxy update' lo reemplaza por
# mesa oficial + llvm-libs (+170MB de vuelta). Quitar el hold actualiza.
sed -i 's|^#IgnorePkg   =|IgnorePkg   = mesa|' "${bootstrap}"/etc/pacman.conf
grep -q '^IgnorePkg' "${bootstrap}"/etc/pacman.conf || { echo "IgnorePkg sed no-op (formato pacman.conf cambio)"; unmount_chroot; exit 1; }
grep -q 'usr/share/i18n' "${bootstrap}"/etc/pacman.conf || { echo "i18n NoExtract sed no-op"; unmount_chroot; exit 1; }

echo "Generating package info, please wait..."

# Generate a list of installed packages
run_in_chroot pacman -Q > "${bootstrap}"/pkglist.x86_64.txt

# Generate a list of licenses of installed packages
export -f generate_pkg_licenses_file
run_in_chroot bash -c generate_pkg_licenses_file

sed 's/DownloadUser = alpm/#DownloadUser = alpm/' "${bootstrap}"/etc/pacman.conf > _
mv -f _ "${bootstrap}"/etc/pacman.conf


unmount_chroot

# Clear pacman package cache
rm -f "${bootstrap}"/var/cache/pacman/pkg/*

# Create some empty files and directories
# This is needed for bubblewrap to be able to bind real files/dirs to them
# later in the conty-start.sh script
mkdir "${bootstrap}"/media
# Empty bind targets: /host = real host root, /data = extra host data dir
# (arxy bind-mounts them; bwrap --bind requires the dest to exist).
mkdir -p "${bootstrap}"/host "${bootstrap}"/data
mkdir "${bootstrap}"/initrd
mkdir -p "${bootstrap}"/usr/share/steam/compatibilitytools.d
touch "${bootstrap}"/etc/asound.conf
touch "${bootstrap}"/etc/localtime
chmod 755 "${bootstrap}"/root

# Enable full font hinting
rm -f "${bootstrap}"/etc/fonts/conf.d/10-hinting-slight.conf
ln -s /usr/share/fontconfig/conf.avail/10-hinting-full.conf "${bootstrap}"/etc/fonts/conf.d

clear
echo "Done"

if [ -f "${bootstrap}"/opt/bad_aur_pkglist.txt ]; then
	echo
	echo "These packages are either not in the AUR or yay failed to download their"
	echo "PKGBUILDs:"
	cat "${bootstrap}"/opt/bad_aur_pkglist.txt
	rm "${bootstrap}"/opt/bad_aur_pkglist.txt
fi
