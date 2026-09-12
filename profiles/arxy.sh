# shellcheck shell=bash disable=2034
# Conty profile: arxy
#
# Goal: rootfs Arch MINIMO para el subsistema arxy (sin sandbox, sin FUSE).
# Repos oficiales 64-bit + multilib (steam y umu-launcher exigen lib32).
# Sin kernel (usa el del host), sin firmware, sin Chaotic-AUR, sin AUR,
# sin X server propio (usa el del host via sockets), sin toolchain.
# Todo lo demas se instala despues con 'arxy install' dentro del subsistema.
#
# Usage:
#   PROFILE=arxy sudo ./create-arch-bootstrap.sh   # step 1, root, ~10GB libres
#   PROFILE=arxy ./create-arxy-image.sh            # step 2, sin root -> tarball
#
# El tarball resultante lo publica el CI en el release 'latest' de
# arxy-image (URL+`.sha256` que 'arxy setup' consume directamente).

PROFILE_NAME="arxy"
PROFILE_STATUS="stable"

# Artefacto final (create-arxy-image.sh). Sin bundle conty, sin squashfs.
ARXY_IMAGE_TARBALL="arxy-rootfs-x86_64.tar.zst"
ARXY_TAR_COMPRESSOR="zstd -19 -T0"

# --- desactivados: solo repos oficiales ([core]/[extra]+[multilib]).
# --- Multilib ON: steam y umu-launcher exigen lib32 (repo habilitado en
# --- pacman.conf, pero sin paquetes lib32-* preinstalados en la imagen).
ENABLE_CHAOTIC_REPO=
ENABLE_MULTILIB=1
ENABLE_ALHP_REPO=
ALHP_FEATURE_LEVEL=2
CACHYOS_ARCH=

# --- no instalar 'base' (arrastra el kernel linux, inutil aqui),
# --- ni reflector/squashfs-tools/fakeroot (herramientas de build, no runtime).
# --- Vacio = saltar ese paso por completo.
BOOTSTRAP_BASE_PACKAGES=
ENABLE_REFLECTOR=

# --- NoExtract extendido: ademas del firmware nvidia y man (defecto),
# --- fuera docs, gtk-doc e info. Se conservan licenses y locales.
# --- include tambien excluido: evita que un futuro 'arxy update'
# --- (glibc) restaure los headers en silencio (+60MB). Si alguien compila
# --- C dentro, los headers vuelven con 'pacman -S glibc' tras quitarlo.
# --- i18n NO va aqui (romperia el locale-gen del build: los charmaps deben
# --- existir al generar; la exclusion se añade tras locale-gen, ver
# --- create-arch-bootstrap.sh). firmware/* completo: idem persistente.
PACMAN_NOEXTRACT='usr/lib/firmware/* usr/share/man/* usr/share/doc/* usr/share/gtk-doc/* usr/share/info/* usr/include/*'

# Paquete minimo: runtime glibc + shell usable + pacman + baseline
# grafica/sonido/fuentes. 'filesystem' es obligatorio (provee
# /etc/arch-release, que arxy exige para aceptar la imagen).
# Deliberadamente NO: linux, base, lib32-* preinstalados (el repo multilib
# si va habilitado para que 'arxy install steam/umu-launcher' resuelva),
# xorg-server/xwayland (el X server corre en el host), dbus-daemon
# (el socket viene del host), toolchain, editores pesados, utilidades de GPU.
PACKAGES=(
	# base del sistema (sin kernel)
	filesystem glibc bash
	# shell usable
	coreutils findutils grep sed gawk tar gzip xz zstd
	file procps-ng nano curl
	# gestion de paquetes
	pacman archlinux-keyring ca-certificates
	# zona horaria (los navegadores la exigen aunque /etc/localtime se bindee)
	tzdata
	# baseline grafica: mesa + cargador vulkan + libs cliente x11/wayland
	mesa vulkan-icd-loader
	libx11 libxcb libxext libxi libxkbcommon wayland
	# baseline audio (los servidores corren en el host)
	alsa-lib libpulse pipewire pipewire-pulse
	# fuentes minimas (fontconfig viene por dependencias)
	fontconfig ttf-dejavu
)

# mesa-mini en lugar de mesa oficial (el bootstrap lo descarga e instala con
# -U tras PACKAGES, y saca llvm-libs huerfano). No existe repo pacman:
# es un asset del release 'continuous'.
# Decisiones con numero: mini sobre nano (-Os de nano arriesga estabilidad
# en juegos/emuladores por ~11MB mas); icu se queda OFICIAL (no existe
# icu-nano, solo mini -29MB, y recortar datos ICU arriesga corrupcion
# silenciosa en collation de navegadores); gtk3/4-mini N/A (la base no
# lleva gtk); llvm-libs-mini/nano innecesarios (nada lo exige tras el swap).
DEBLOATED_MESA_URL='https://github.com/pkgforge-dev/archlinux-pkgs-debloated/releases/download/continuous/mesa-mini-x86_64.pkg.tar.zst'

# Sin AUR en la imagen: mantiene el bootstrap rapido y evita la etapa
# paru+usuario-aur. AUR llega en arxy fase 2, nunca aqui.
AUR_PACKAGES=()

# Locales minimos: en_US (C.UTF-8 lo genera locale-gen siempre, sin pedirlo).
# es_ES fuera (-5MB): con un solo locale generado, UI en ingles; en_US se
# conserva (no C solo) porque apps clase Steam lo exigen (+1MB de seguro).
LOCALES=(
	'en_US.UTF-8 UTF-8'
)

# Mirrorlist mundial estatica (sin reflector: sus picks solo sirven para
# la maquina que construye, no para el usuario final).
# shellcheck disable=2016
MIRRORLIST='
Server = https://fastly.mirror.pkgbuild.com/$repo/os/$arch
Server = https://de.arch.mirror.kescher.at/$repo/os/$arch
Server = https://at.arch.niranjan.co/$repo/os/$arch
Server = https://mirror.moson.org/arch/$repo/os/$arch
Server = https://arch.jensgutermuth.de/$repo/os/$arch
Server = https://de.arch.niranjan.co/$repo/os/$arch
Server = https://umea.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.osbeck.com/archlinux/$repo/os/$arch
Server = https://ams.nl.mirrors.bjg.at/arch/$repo/os/$arch
Server = https://mirror.lcarilla.de/archlinux/$repo/os/$arch
Server = https://mirror.pseudoform.org/$repo/os/$arch
Server = https://mirror.cyberbits.eu/archlinux/$repo/os/$arch
'

# Sin utils squashfs/dwarfs: la imagen arxy es un tarball extraido, no FUSE.
USE_SYS_UTILS=0
SQUASHFS_COMPRESSOR="zstd"
SQUASHFS_COMPRESSOR_ARGUMENTS=(-b 1M -comp "${SQUASHFS_COMPRESSOR}" -Xcompression-level 19)
USE_DWARFS=
DWARFS_COMPRESSOR_ARGUMENTS=(
	-l7 -C zstd:level=19 --metadata-compression null
	-S 22 -B 1 --order nilsimsa
	-W 12 -w 4 --no-history-timestamps --no-create-timestamp
)

DOWNLOAD_PROXY=

BOOTSTRAP_DOWNLOAD_URLS=(
	'https://umea.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
	'https://de.arch.mirror.kescher.at/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
	'https://de.arch.niranjan.co/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
	'https://mirror.moson.org/arch/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
	'https://fastly.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
)

BOOTSTRAP_SHA256SUM_FILE_URL='https://umea.mirror.pkgbuild.com/iso/latest/sha256sums.txt'

USE_EXISTING_IMAGE=
