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
# Foto de lanzadores previos: export --all crea uno por .desktop del rootfs
# y solo el sintético se limpia; al final se exige cero residuo nuevo.
SNAP_F="$(mktemp)" || exit 99
ls "$APPS"/arxy-*.desktop 2>/dev/null | sort >"$SNAP_F" || true
printf '[Desktop Entry]\nType=Application\nName=Arxy Test\nExec=/usr/bin/true\n' > "$R/usr/share/applications/arxy-test.desktop"
t "export sintetico" -- sh -c "arxy export --all >/dev/null && test -f '$APPS/arxy-arxy-test.desktop'"
t "unexport" -- arxy unexport arxy-test
# Export en nivel 2 forzado (--all usa find directo sobre el rootfs, sin
# bwrap). Gap histórico sin cobertura (validado a mano en 6.5.5): si L2
# regresa, aquí se caza. Verificado que el contenido se reescribe igual.
t "L2: export --all" -- sh -c "ARXY_LEVEL=2 arxy export --all >/dev/null && test -f '$APPS/arxy-arxy-test.desktop'"
t "L2: export contenido" -- sh -c "grep -q '^Exec=arxy run /usr/bin/true' '$APPS/arxy-arxy-test.desktop' && grep -q '^X-Arxy-Pkg=' '$APPS/arxy-arxy-test.desktop'"
t "L2: unexport" -- arxy unexport arxy-test
t "install (escritura)" -- arxy install tree
t "run instalado" -- arxy run tree --version
t "remove" -- arxy remove tree
t "fc-list con contenido" -- sh -c 'arxy run /usr/bin/fc-list | grep -q "\.ttf"'
t "clean dry-run no toca" -- sh -c 'arxy clean | grep -q "dry-run"'
t "quickstart guia" -- sh -c 'arxy quickstart | grep -q "siguiente paso"'
t "doctor --fix informa" -- sh -c 'arxy doctor --fix 2>&1 | grep -q "\[OK\]\|\[FALTA\]"'
t "doctor --json format" -- sh -c 'arxy doctor --json 2>/dev/null | grep -q "\"format\": 1"'
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
    # Export en L2 tras escritura vía chroot: el lanzador debe crearse con
    # contenido válido aunque el rootfs se haya mutado sin namespaces.
    # (End-to-end "paquete pacman que trae .desktop instalado en L2" sigue
    # manual: sin paquete fixture diminuto elegido.)
    t "L2: export --all tras install (chroot)" -- sh -c "ARXY_LEVEL=2 arxy export --all >/dev/null && grep -q '^X-Arxy-Pkg=' '$APPS/arxy-arxy-test.desktop'"
    t "L2: unexport tras install (chroot)" -- arxy unexport arxy-test
else
    echo "INFO: escrituras L2 omitidas (MATRIX_WRITE2 vacio; se prueban en CI)"
fi
# Semantica de rollback: .old es siempre el setup INMEDIATO anterior
# (el swap hace rm -rf del .old previo: no hay "primero" que rescatar).
# Se prueba con un marcador DENTRO del rootfs + la fecha del version file
# (el CLI la restaura desde la copia interna; regla 3 vale tras rollback).
t "rollback restaura setup anterior" -- sh -c '
    vf="${ARXY_ROOT%/*}/version"
    echo uno > "$ARXY_ROOT/.matrix-mark" || exit 2
    d1="$(grep -Eo "\"created_at\": \"[^\"]*\"|^date=.*" "$vf" 2>/dev/null | head -n 1 | sed "s/.*\"created_at\": \"//;s/\"\$//" | cut -d= -f2-)"; test -n "$d1" || exit 3
    arxy setup >/dev/null 2>&1 || exit 4
    test ! -e "$ARXY_ROOT/.matrix-mark" || exit 5
    arxy rollback >/dev/null 2>&1 || exit 6
    test "$(cat "$ARXY_ROOT/.matrix-mark" 2>/dev/null)" = uno || exit 7
    test "$(grep -Eo "\"created_at\": \"[^\"]*\"|^date=.*" "$vf" 2>/dev/null | head -n 1 | sed "s/.*\"created_at\": \"//;s/\"\$//" | cut -d= -f2-)" = "$d1" || exit 8
    rm -f "$ARXY_ROOT/.matrix-mark"'
t "clean --apply borra rollback" -- sh -c 'test -d "$ARXY_ROOT.old" && arxy clean --apply | grep -q "limpieza hecha" && test ! -d "$ARXY_ROOT.old"'

# Limpieza de lo creado por export --all (en host real deja los lanzadores
# de la imagen; en docker es inocuo): borra exactamente lo nuevo vs la foto
# y falla LISTANDO lo que no se pudo borrar (contenido, no solo rc).
t "limpia residuo en REAL_APPS" -- sh -c "ls '$APPS'/arxy-*.desktop 2>/dev/null | sort >'$SNAP_F.cur' || true; extra=\"\$(comm -13 '$SNAP_F' '$SNAP_F.cur')\"; printf '%s\n' \"\$extra\" | while IFS= read -r f; do test -z \"\$f\" || rm -f \"\$f\"; done; ls '$APPS'/arxy-*.desktop 2>/dev/null | sort >'$SNAP_F.cur' || true; rest=\"\$(comm -13 '$SNAP_F' '$SNAP_F.cur')\"; printf '%s\n' \"\$rest\"; test -z \"\$rest\""
rm -f "$SNAP_F" "$SNAP_F.cur"
echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
