#!/usr/bin/env bash

# Empaqueta root.x86_64/ (construido con PROFILE=arxy) en el tarball de la
# imagen arxy + su sha256. Requiere root: el rootfs contiene ficheros 0700
# de root (keyring pacman, gshadow) que deben ir DENTRO de la imagen.
#
#   PROFILE=arxy sudo ./create-arch-bootstrap.sh   # paso 1
#   PROFILE=arxy sudo ./create-arxy-image.sh       # paso 2 (este script)
#
# El tarball lo publica el CI en el release 'latest' de arxy-image
# (ver .github/workflows/build.yml).

export LC_ALL=C

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
settings_file="${script_dir}/profiles/${PROFILE:-arxy}.sh"
if [ ! -f "${settings_file}" ]; then
	echo "Unknown profile '${PROFILE:-arxy}': ${settings_file} not found"
	exit 1
fi
# shellcheck source=profiles/arxy.sh
source "${settings_file}"

if [ "${PROFILE_NAME:-}" != "arxy" ]; then
	echo "Refusing: profile '${PROFILE:-arxy}' is not the arxy profile (got '${PROFILE_NAME:-?}')"
	echo "Run with PROFILE=arxy (needs root.x86_64/ built with PROFILE=arxy too)."
	exit 1
fi

for cmd in tar zstd sha256sum du; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "$cmd is required!"
		exit 1
	fi
done

if [ $EUID != 0 ]; then
	echo "Root rights are required! (the rootfs holds root-only files that ship inside the image)"
	exit 1
fi

bootstrap="${script_dir}/root.x86_64"
tarball="${script_dir}/${ARXY_IMAGE_TARBALL:-arxy-rootfs-x86_64.tar.zst}"

# --- cordura: esto debe ser un rootfs arxy, no un conty
[ -d "${bootstrap}" ] || { echo "Missing ${bootstrap}: run PROFILE=arxy sudo ./create-arch-bootstrap.sh first"; exit 1; }
[ -x "${bootstrap}/usr/bin/bash" ] || { echo "${bootstrap} has no /usr/bin/bash"; exit 1; }
[ -x "${bootstrap}/usr/bin/pacman" ] || { echo "${bootstrap} has no /usr/bin/pacman"; exit 1; }
[ -f "${bootstrap}/etc/arch-release" ] || { echo "${bootstrap} has no /etc/arch-release"; exit 1; }

# Guardias de minimalismo: avisan (no abortan) si se colo peso muerto.
if [ -n "$(ls -A "${bootstrap}/usr/lib/modules" 2>/dev/null)" ]; then
	echo "WARNING: kernel modules present in usr/lib/modules (did 'base' sneak in?)."
fi
if [ -d "${bootstrap}/usr/lib/firmware" ] && [ -n "$(ls -A "${bootstrap}/usr/lib/firmware" 2>/dev/null)" ]; then
	echo "WARNING: firmware files present in usr/lib/firmware."
fi
if [ -n "$(ls -d "${bootstrap}"/usr/lib32 2>/dev/null)" ]; then
	echo "WARNING: usr/lib32 present (32-bit leaked in?)."
fi

echo "Rootfs size unpacked: $(du -sh "${bootstrap}" 2>/dev/null | cut -f1)"
if [ -f "${bootstrap}/pkglist.x86_64.txt" ]; then
	echo "Packages in image: $(wc -l < "${bootstrap}/pkglist.x86_64.txt")"
fi

cd "${script_dir}" || exit 1

# tidy_rootfs: quita peso muerto MEDIDO (deltas sobre 946MB pristine).
# Orden: corre tras todas las instalaciones (los rm van ANTES de empaquetar;
# ver Fase 2). strip: NO, Arch ya distribuye strippeado (2139 ficheros, -0MB).
# dedup en build: NO (2MB en base; el auto-dedup de runtime lo cubre).
tidy_rootfs() { # <bootstrap>
	# docs/man/info: restos del tarball base (NoExtract no filtra lo
	# preexistente) -53MB.
	rm -rf "$1/usr/share/man" "$1/usr/share/doc" "$1/usr/share/info" "$1/usr/share/gtk-doc"
	# estaticos: AUR -bin no compila (reaparecen si glibc se reinstala:
	# por eso esto corre al final, no en el bootstrap) -47MB.
	find "$1/usr/lib" "$1/usr/bin" -name '*.a' -delete
	find "$1/usr/lib" -name '*.la' -delete
	# locales: i18n son fuentes de localedef (locale-gen futuro exigiria
	# reinstalar glibc) -16MB; catalogos != C/en incargables (solo
	# C.UTF-8+en_US generados) -108MB; archive 5.8->3.3MB.
	rm -rf "${1:?}/usr/share/i18n"
	for _l in "${1:?}/usr/share/locale/"*; do
		_b="${_l##*/}"
		case "$_b" in C*|en*|locale.alias) ;; *) rm -rf "$_l" ;; esac
	done
	# firmware ENTERO: lo carga el kernel del host, nunca el rootfs (Mesa no
	# toca firmware). -0MB hoy (NoExtract ya lo excluye); linea como garantia
	# futura (el WARNING de arriba avisa si algo se cuela antes de este punto).
	rm -rf "${1:?}/usr/lib/firmware"
	# restos de build: cache/log/boot (contenido; los dirs los recrea pacman) -11MB.
	rm -rf "${1:?}/var/cache/pacman/pkg"/* "${1:?}/var/log"/* "${1:?}/boot"/*
}
tidy_rootfs "${bootstrap}"

echo "Packing ${tarball}..."
# Nodos /dev estaticos dentro de la imagen: el chroot pelado (sin mounts,
# tipico en nivel 2) los necesita para gpg (pacman -S verifica firmas).
# tar los empaqueta; al extraer sin privilegios se omiten con aviso.
mkdir -p "${bootstrap}/dev"
for _dev in "null c 1 3" "zero c 1 5" "full c 1 7" "random c 1 8" "urandom c 1 9" "tty c 5 0"; do
	read -r _name _type _maj _min <<<"${_dev}"
	# Sin -m (no existe en chimerautils): mknod pelado + chmod.
	if [ ! -e "${bootstrap}/dev/${_name}" ]; then
		mknod "${bootstrap}/dev/${_name}" "${_type}" "${_maj}" "${_min}" && chmod 666 "${bootstrap}/dev/${_name}" || { echo "mknod ${_name} fallo"; exit 1; }
	fi
done
# NOTE: -I takes ONE argument (the whole compressor command), quote it.
# Exclude stale gpg-agent sockets left over from the build chroot.
tar --numeric-owner --xattrs --acls -I "${ARXY_TAR_COMPRESSOR:-zstd -19 -T0}" \
	--exclude='./etc/pacman.d/gnupg/S.*' \
	-cf "${tarball}" -C "${bootstrap}" . || { echo "tar failed"; exit 1; }

sha256sum "${tarball##*/}" > "${tarball}.sha256" || { echo "sha256sum failed"; exit 1; }

echo "Done:"
ls -lh "${tarball}" "${tarball}.sha256"
cat "${tarball}.sha256"
echo
echo "Next: upload ${tarball##*/} (+ .sha256) to the 'latest' release of arxy-image"
echo "('arxy setup' lo descarga de ahi y lo verifica contra el .sha256 solo)."
