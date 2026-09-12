#!/usr/bin/env bash
# matrix.sh — puerta de publicacion de la imagen arxy.
# Hogar: repo arxy-image, tests/matrix.sh. El CI (build.yml) la corre contra
# el tarball recien construido; a mano se corre en N distros con docker.
# Requiere: arxy en PATH, root, bash.
# v2: assertions de CONTENIDO (grep), no solo rc — los pipes a head
# enmascaraban fallos (info/list vacios pasaban; bug Includes L2).
# No aborta al primer fallo: reporta todo y sale != 0 si algo fallo.
#
#   ./tests/matrix.sh                                # /image.tar.zst (docker)
#   MATRIX_IMAGE=/ruta/al.tar.zst ./tests/matrix.sh  # tarball local
#   ARXY_IMAGE_URL=file://... ./tests/matrix.sh      # URL explicita (manda)
#   ARXY_ROOT=/var/lib/arxy-mxt ./tests/matrix.sh    # rootfs aislado
#   MATRIX_WRITE2=1 ./tests/matrix.sh                # + escrituras en nivel 2
#     (install/remove con chroot; exige privilegios de montaje: CI o host)
#
# Manual 5 distros (pre-release): ver tests/README.md.
#
# LIMITE conocido: los containers son siempre limpios (sin sys-conf ni
# user-conf), asi que esto NO caza bugs de precedencia env>user>sys.
# Esos se prueban en host real con conf presente (ver AGENTS.md del CLI).
set -uo pipefail

export ARXY_IMAGE_URL="${ARXY_IMAGE_URL:-file://${MATRIX_IMAGE:-/image.tar.zst}}"
export ARXY_ROOT="${ARXY_ROOT:-/var/lib/arxy/root}"
R="$ARXY_ROOT"
APPS="$HOME/.local/share/applications"
FAIL=0

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

echo "== host: $(cat /etc/os-release 2>/dev/null | grep -m1 PRETTY_NAME) / $(uname -m)"
echo "== imagen: $ARXY_IMAGE_URL"
t "doctor reporta nivel" -- sh -c 'arxy doctor | grep -q "nivel [12]"'
LEVEL="$(arxy doctor 2>/dev/null | grep -o 'nivel [12]' | head -1)"
echo "INFO: detectado $LEVEL"
t "setup file://" -- arxy setup
t "run true" -- arxy run /usr/bin/true
t "bash --version" -- arxy run /usr/bin/bash --version
t "pacman --version (carga libalpm+glib)" -- sh -c 'arxy run /usr/bin/pacman --version | grep -q Pacman'
if [[ "$LEVEL" == "nivel 1" ]]; then
    # En L1 / es el subsistema: libc debe verse como /usr/lib/...
    t "libc del subsistema (L1)" -- arxy run /usr/bin/bash -c 'while read -r l; do case "$l" in *libc.so*) echo "$l"; break;; esac; done < /proc/self/maps | grep -qv x86_64-linux-gnu'
else
    # En L2 las rutas son del host: libc debe colgar del rootfs arxy.
    t "libc del subsistema (L2)" -- arxy run /usr/bin/bash -c 'while read -r l; do case "$l" in *libc.so*) echo "$l"; break;; esac; done < /proc/self/maps | grep -q arxy'
fi
t "which distingue origen" -- sh -c 'arxy which bash | grep -q subsistema'
t "info con contenido" -- sh -c 'arxy info bash | grep -q "^Name *: bash"'
t "list con contenido" -- sh -c 'arxy list | grep -q "^pacman "'
t "search con contenido" -- sh -c 'arxy search nano | grep -q "extra/nano"'
# Lecturas en nivel 2 forzado (Includes al rootfs; el bug que rompia info/
# list/search en hosts no-Arch). Solo lectura: corre en todas partes.
t "L2: run true" -- sh -c 'ARXY_LEVEL=2 arxy run /usr/bin/true'
t "L2: info con contenido" -- sh -c 'ARXY_LEVEL=2 arxy info bash | grep -q "^Name *: bash"'
t "L2: AUR bloqueado con mensaje" -- sh -c 'ARXY_LEVEL=2 arxy install --aur nano 2>&1 | grep -q "necesita nivel 1"'
printf '[Desktop Entry]\nType=Application\nName=Arxy Test\nExec=/usr/bin/true\n' > "$R/usr/share/applications/arxy-test.desktop"
t "export sintetico" -- sh -c "arxy export --all >/dev/null && test -f '$APPS/arxy-arxy-test.desktop'"
t "unexport" -- arxy unexport arxy-test
t "install (escritura)" -- arxy install tree
t "run instalado" -- arxy run tree --version
t "remove" -- arxy remove tree
t "fc-list con contenido" -- sh -c 'arxy run /usr/bin/fc-list | grep -q "\.ttf"'
t "clean dry-run no toca" -- sh -c 'arxy clean | grep -q "dry-run"'
t "quickstart guia" -- sh -c 'arxy quickstart | grep -q "siguiente paso"'
t "doctor --fix informa" -- sh -c 'arxy doctor --fix 2>&1 | grep -q "\[OK\]\|\[FALTA\]"'
echo "INFO: bus de sesion: ${DBUS_SESSION_BUS_ADDRESS:-ausente (esperado en contenedor)}"
ls /run/dbus/system_bus_socket 2>/dev/null && echo "INFO: system bus visible" || echo "INFO: sin system bus (esperado en contenedor)"
t "rollback sin .old falla limpio" -- sh -c 'rm -rf "$ARXY_ROOT.old"; ! arxy rollback 2>/dev/null'
if [[ "$LEVEL" == "nivel 1" ]]; then
    # Autodeteccion de nivel 2 con bwrap roto (solo lectura).
    mkdir -p /tmp/nobwrap
    printf '#!/bin/sh\nexit 1\n' > /tmp/nobwrap/bwrap
    chmod +x /tmp/nobwrap/bwrap
    t "L2 autodetectado sin bwrap" -- sh -c 'PATH="/tmp/nobwrap:$PATH" arxy doctor | grep -q "nivel 2"'
    t "L2 autodetectado corre" -- sh -c 'PATH="/tmp/nobwrap:$PATH" arxy run /usr/bin/true'
    rm -rf /tmp/nobwrap
else
    echo "INFO: autodeteccion L2 sin objeto (ya en nivel 2)"
fi
if [[ -n "${MATRIX_WRITE2:-}" ]]; then
    # Escrituras en nivel 2 (chroot con mounts): exige privilegios.
    t "L2: install/remove (chroot)" -- sh -c 'ARXY_LEVEL=2 arxy install tree && ARXY_LEVEL=2 arxy run tree --version && ARXY_LEVEL=2 arxy remove tree'
else
    echo "INFO: escrituras L2 omitidas (MATRIX_WRITE2 vacio; se prueban en CI)"
fi

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
