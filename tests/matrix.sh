#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
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
# LIMITE firma: file:// omite minisign por diseno
# (sig_should_verify solo verifica http(s) sin pin). Esta puerta pinea
# presencia+formato de los hermanos .sha256/.minisig cuando existen
# (CI pre-publish); el e2e https+minisign no tiene puerta automatica:
# la logica de verificacion vive en test-signature.sh del repo arxy.
set -uo pipefail

export ARXY_IMAGE_URL="${ARXY_IMAGE_URL:-file://${MATRIX_IMAGE:-/image.tar.zst}}"
if [[ -z "${ARXY_ROOT+set}" ]]; then
    export ARXY_ROOT=/var/lib/arxy/root
    _MATRIX_DEFAULT_ROOT=1
fi
# El default es el rootfs PRODUCTIVO; fuera de contenedor, correr
# sin ARXY_ROOT aislado haria setup/rollback/clean --apply contra el
# sistema real. Misma guarda que test-atomic-crash.sh del CLI.
if [[ -n "${_MATRIX_DEFAULT_ROOT:-}" && ! -e /.dockerenv && ! -e /run/.containerenv ]]; then
    echo "FAIL: ARXY_ROOT real sin aislar fuera de contenedor (pasa ARXY_ROOT=/var/lib/arxy-mxt ...)" >&2
    exit 1
fi
R="$ARXY_ROOT"
# Lanzadores aislados: XDG_DATA_HOME manda sobre REAL_HOME en el CLI, asi el
# export escribe aqui venga de donde venga SUDO_USER (cierra el gotcha de los
# FAILs en falso en host: antes miraba $HOME y escribia en /home/$SUDO_USER).
XDG_DATA_HOME="$(mktemp -d)" || exit 99
export XDG_DATA_HOME
chmod 777 "$XDG_DATA_HOME" # el usuario real puede no ser root (sudo -E)
APPS="$XDG_DATA_HOME/applications"
FAIL=0

t() { # t <nombre> -- <cmd...>
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

echo "== host: $(cat /etc/os-release 2>/dev/null | grep -m1 PRETTY_NAME) / $(uname -m)"
echo "== imagen: $ARXY_IMAGE_URL"
# Sin esto, bajo sudo-host secure_path impone el arxy instalado
# (obsoleto) y LEVEL/checks fallan en falso atribuidos a la imagen.
command -v arxy >/dev/null 2>&1 || { echo "FAIL: sin arxy en PATH (sudo-host: sudo -E env \"PATH=<staging>/bin:...\" ...)" >&2; exit 1; }
arxy version >/dev/null 2>&1 || { echo "FAIL: arxy en PATH no responde (¿instalado obsoleto? usa el CLI fresco)" >&2; exit 1; }
echo "INFO: cli: $(command -v arxy) ($(arxy version 2>/dev/null | head -n 1))"
# El publish exigia el .minisig (presencia) pero nada lo verificaba:
# la matrix corria file:// (ciega a firmas) ANTES de firmar. Si el tarball
# trae hermanos .sha256/.minisig (CI pre-publish), se pinean con contenido;
# si no (docker manual: solo tarball), INFO y se sigue.
_IMG="${MATRIX_IMAGE:-/image.tar.zst}"
if [[ -f "$_IMG" ]]; then
    if [[ -f "$_IMG.sha256" ]]; then
        t "artefacto .sha256 coincide con tarball" -- env IMG="$_IMG" sh -c 'cd "$(dirname "$IMG")" && sha256sum -c "$(basename "$IMG").sha256" 2>&1 | grep -q ": OK$"'
    else
        echo "INFO: sin hermano .sha256 (solo CI pre-publish lo trae)"
    fi
    if [[ -f "$_IMG.minisig" ]]; then
        # Formato real minisign: 2 lineas (untrusted+sig) o 4 (mas bloque
        # trusted timestamp). Pinneado contra salida real del binario.
        t "artefacto .minisig bien formado" -- env IMG="$_IMG" sh -c 'head -n 1 "$IMG.minisig" | grep -q "^untrusted comment: signature" && sed -n "2p" "$IMG.minisig" | grep -qE "^[A-Za-z0-9+/]+={0,2}$" && { test "$(grep -c "" "$IMG.minisig")" -eq 2 || { test "$(grep -c "" "$IMG.minisig")" -eq 4 && sed -n "3p" "$IMG.minisig" | grep -q "^trusted comment:" && sed -n "4p" "$IMG.minisig" | grep -qE "^[A-Za-z0-9+/]+={0,2}$"; }; }'
    else
        echo "INFO: sin hermano .minisig (solo CI pre-publish lo trae)"
    fi
fi
t "doctor reporta nivel" -- sh -c 'arxy doctor | grep -q "nivel [12]"'
LEVEL="$(arxy doctor 2>/dev/null | grep -o 'nivel [12]' | head -1)"
echo "INFO: detectado $LEVEL"
t "setup file://" -- arxy setup
t "setup deja rootfs valido" -- sh -c "test -x '$R/usr/bin/pacman' && test -f '$R/etc/arch-release'"
t "run true" -- arxy run /usr/bin/true
t "bash --version" -- sh -c 'arxy run /usr/bin/bash --version | grep -q "GNU bash"'
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
t "export contenido" -- sh -c "grep -q '^Exec=arxy run /usr/bin/true' '$APPS/arxy-arxy-test.desktop' && grep -q '^X-Arxy-Pkg=' '$APPS/arxy-arxy-test.desktop'"
t "unexport" -- sh -c "arxy unexport arxy-test && test ! -f '$APPS/arxy-arxy-test.desktop'"
# Export en nivel 2 forzado (--all usa find directo sobre el rootfs, sin
# bwrap). Gap histórico sin cobertura (validado a mano): si L2
# regresa, aquí se caza. Verificado que el contenido se reescribe igual.
t "L2: export --all" -- sh -c "ARXY_LEVEL=2 arxy export --all >/dev/null && test -f '$APPS/arxy-arxy-test.desktop'"
t "L2: export contenido" -- sh -c "grep -q '^Exec=arxy run /usr/bin/true' '$APPS/arxy-arxy-test.desktop' && grep -q '^X-Arxy-Pkg=' '$APPS/arxy-arxy-test.desktop'"
t "L2: unexport" -- sh -c "arxy unexport arxy-test && test ! -f '$APPS/arxy-arxy-test.desktop'"
t "install (escritura)" -- arxy install tree
t "run instalado" -- sh -c 'arxy run tree --version | grep -qE "tree v[0-9]"'
t "remove" -- sh -c 'arxy remove tree >/dev/null && ! arxy list 2>/dev/null | grep -q "^tree "'
t "fc-list con contenido" -- sh -c 'arxy run /usr/bin/fc-list | grep -q "\.ttf"'
t "clean dry-run no toca" -- sh -c 'arxy clean | grep -q "dry-run"'
t "quickstart guia" -- sh -c 'arxy quickstart | grep -q "siguiente paso"'
t "doctor --fix informa" -- sh -c 'arxy doctor --fix 2>&1 | grep -q "\[OK\]\|\[FALTA\]"'
t "doctor --json format" -- sh -c 'arxy doctor --json 2>/dev/null | grep -q "\"format\": 1"'
t "gc --json format" -- sh -c 'arxy gc --json 2>/dev/null | grep -q "\"format\": 1" && arxy gc --json 2>/dev/null | grep -q "\"total_bytes\":" && arxy gc --json 2>/dev/null | grep -q "\"applied\": false"'
echo "INFO: bus de sesion: ${DBUS_SESSION_BUS_ADDRESS:-ausente (esperado en contenedor)}"
ls /run/dbus/system_bus_socket 2>/dev/null && echo "INFO: system bus visible" || echo "INFO: sin system bus (esperado en contenedor)"
t "rollback sin .old falla limpio" -- sh -c 'rm -rf "$ARXY_ROOT.old"; arxy rollback 2>&1 | grep -qi "no hay rollback pendiente"'
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
    t "L2: install/remove (chroot)" -- sh -c 'ARXY_LEVEL=2 arxy install tree && ARXY_LEVEL=2 arxy run tree --version | grep -qE "tree v[0-9]" && ARXY_LEVEL=2 arxy remove tree >/dev/null && ! ARXY_LEVEL=2 arxy list 2>/dev/null | grep -q "^tree "'
    # Export en L2 tras escritura vía chroot: el lanzador debe crearse con
    # contenido válido aunque el rootfs se haya mutado sin namespaces.
    # E2E con paquete real (xterm) más abajo: install en chroot + export por
    # nombre + remove que limpia sus lanzadores (remove borra los
    # X-Arxy-Pkg=$pkg; unexport aparte solo cubre el sintetico).
    t "L2: export --all tras install (chroot)" -- sh -c "ARXY_LEVEL=2 arxy export --all >/dev/null && grep -q '^X-Arxy-Pkg=' '$APPS/arxy-arxy-test.desktop'"
    t "L2: unexport tras install (chroot)" -- sh -c "arxy unexport arxy-test && test ! -f '$APPS/arxy-arxy-test.desktop'"
    # E2E: paquete pacman REAL con .desktop instalado en L2 (chroot) y
    # exportado por nombre de paquete (ejercita pkg_desktops con rutas
    # prefijadas por --root, el punto ciego historico).
    # Fixture: xterm (extra, ~1MB+libs X ya casi todas en la mini, sin gtk3;
    # trae xterm.desktop+uxterm.desktop limpios — feh se descarto: su
    # .desktop lleva NoDisplay=true y export lo salta a proposito).
    t "L2: instala paquete con .desktop (chroot)" -- sh -c 'ARXY_LEVEL=2 arxy install xterm && test -f "$ARXY_ROOT/usr/share/applications/xterm.desktop"'
    t "L2: export del .desktop real" -- sh -c "ARXY_LEVEL=2 arxy export xterm >/dev/null && grep -q '^Exec=arxy run /usr/bin/xterm' '$APPS/arxy-xterm.desktop' && grep -q '^X-Arxy-Pkg=xterm' '$APPS/arxy-xterm.desktop' && test -f '$APPS/arxy-uxterm.desktop'"
    t "L2: remove limpia sus lanzadores" -- sh -c 'ARXY_LEVEL=2 arxy remove xterm >/dev/null && test ! -f "$APPS/arxy-xterm.desktop" && test ! -f "$APPS/arxy-uxterm.desktop"'
else
    echo "INFO: escrituras L2 omitidas (MATRIX_WRITE2 vacio; se prueban en CI)"
fi
# Semantica de rollback: .old es siempre el setup INMEDIATO anterior
# (el swap hace rm -rf del .old previo: no hay "primero" que rescatar).
# Se prueba con un marcador DENTRO del rootfs + la fecha del version file
# (vive dentro del root: el swap la rota sola).
t "rollback restaura setup anterior" -- sh -c '
    vf="$ARXY_ROOT/var/lib/arxy/version"
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
rm -rf "$XDG_DATA_HOME"
echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
