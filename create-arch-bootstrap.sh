#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

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
		echo "Available: $(shopt -s nullglob; for p in "${script_dir}"/profiles/*.sh; do basename "$p" .sh; done 2>/dev/null | tr '\n' ' ')"
		exit 1
	fi
fi
# shellcheck source=settings.sh
source "${settings_file}"

if [ "${PROFILE_STATUS:-stable}" = "planned" ]; then
	echo "Profile '${PROFILE}' is planned but not implemented yet (bootstrap support missing)."
	exit 1
fi

for cmd in curl gzip grep sha256sum tar zstd sed awk; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "$cmd is required!"
		exit 1
	fi
done

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
	cp "${settings_file}" "${bootstrap}"/arxy_settings.sh

	mkdir -p "${bootstrap}"/run/shm
}

unmount_chroot () {
	umount -l "${bootstrap}"
	for fs in proc sys dev/pts dev/shm dev; do
		umount "${bootstrap}"/"${fs}"
	done
}

run_in_chroot () {
	chroot "${bootstrap}" /usr/bin/env LANG=en_US.UTF-8 TERM=xterm PATH="/bin:/sbin:/usr/bin:/usr/sbin" "$@"
}

install_packages () {
	source /arxy_settings.sh
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
	curl "${proxy[@]}" -#LO "$BOOTSTRAP_SHA256SUM_FILE_URL" || (echo "Failed to download sha256sums.txt file"; exit 1)

	grep archlinux-bootstrap-x86_64.tar.zst sha256sums.txt > _
	mv -f _ sha256sums.txt

	for link in "${BOOTSTRAP_DOWNLOAD_URLS[@]}"; do
		echo "Downloading Arch Linux bootstrap from $link"
		curl "${proxy[@]}" -#LO "$link"

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

sed 's/#DisableSandboxSyscalls/#DisableSandboxSyscalls\nDisableSandbox/' "${bootstrap}"/etc/pacman.conf > _
mv -f _ "${bootstrap}"/etc/pacman.conf

if [ -n "${ENABLE_MULTILIB-1}" ]; then
# Descomentar la estanza stock (no añadir: duplicaria el registro).
sed -i -E '/^#\[multilib\]/,/^#?Include/s/^#//' "${bootstrap}"/etc/pacman.conf
fi

run_in_chroot pacman-key --init
run_in_chroot pacman-key --populate archlinux


# Do not install unneeded files (man pages and Nvidia firmwares by
# default; profiles can extend via PACMAN_NOEXTRACT, '|' as sed delimiter).
sed "s|#NoExtract   =|NoExtract   = ${PACMAN_NOEXTRACT-usr/lib/firmware/nvidia/* usr/share/man/*}|" "${bootstrap}"/etc/pacman.conf > _
mv -f _ "${bootstrap}"/etc/pacman.conf

run_in_chroot pacman -Sy archlinux-keyring --noconfirm
run_in_chroot pacman -Su --noconfirm


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
# later by the arxy runtime
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
