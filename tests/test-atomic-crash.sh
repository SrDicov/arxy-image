#!/usr/bin/env bash
# test-atomic-crash.sh — setup interrumpido deja estado recuperable.
# Fase 0: red mínima para el ciclo de vida atómico (Fase 3). Solo asserts
# de CONTENIDO (grep), nunca solo rc.
# Requiere: root, ~1GB libre en /tmp, red (el -Sy final del setup bueno).
# Aísla todo en /tmp/arxy-crash: NUNCA toca /var/lib/arxy (guarda explícita).
# La ruta del repo padre tiene espacios: file:// NO sirve desde ahí, por
# eso el tarball se copia a /tmp (sin espacios) antes de empezar.
#
#   sudo -n ./tests/test-atomic-crash.sh
#   MATRIX_IMAGE=/ruta/al.tar.zst sudo -n ./tests/test-atomic-crash.sh
set -uo pipefail
FAIL=0

[[ "$(id -u)" -eq 0 ]] || { echo "FAIL: requiere root (sudo -n $0)"; exit 1; }
export ARXY_ROOT="${ARXY_ROOT:-/tmp/arxy-crash/root}"
[[ "$ARXY_ROOT" == /var/lib/arxy/root ]] && { echo "FAIL: ARXY_ROOT real prohibido en este test"; exit 1; }
D="${ARXY_ROOT%/*}"          # /tmp/arxy-crash (ARXY_DATA deriva de aquí)
R="$ARXY_ROOT"
SPID=""
SRC_IMG="${MATRIX_IMAGE:-/image.tar.zst}"
IMG="$D/image.tar.zst"

t() { # t <nombre> -- <cmd...> : contenido implicito en el rc del pipeline
    local name="$1"; shift; shift
    local out rc
    if out="$("$@" 2>&1)"; then echo "PASS: $name";
    else rc=$?; echo "FAIL($rc): $name"; printf '%s\n' "$out" | head -6 | sed 's/^/  /'; FAIL=$((FAIL+1)); fi
}

trap 'kill ${SPID:-} 2>/dev/null; rm -rf "${D:?}"' EXIT

echo "== fixture sin espacios: $SRC_IMG -> $IMG"
mkdir -p "$D" || { echo "FAIL: sin $D"; exit 1; }
[[ -f "$SRC_IMG" ]] || { echo "FAIL: no existe $SRC_IMG (pasa MATRIX_IMAGE=/ruta/al.tar.zst)"; exit 1; }
cp -f "$SRC_IMG" "$IMG" || { echo "FAIL: no pude copiar fixture"; exit 1; }
[[ -f "$SRC_IMG.sha256" ]] && cp -f "$SRC_IMG.sha256" "$IMG.sha256"
curl -sI --max-time 10 https://github.com >/dev/null 2>&1 || { echo "FAIL: sin red (el setup bueno termina en pacman -Sy)"; exit 1; }
if [[ -f "$D/../../arxy/src/arxy" ]]; then
    cmp -s "$D/../../arxy/src/arxy" "$(command -v arxy)" \
        || echo "INFO: arxy en PATH difiere del repo hermano arxy/src/arxy (se prueba el instalado)"
fi

export ARXY_IMAGE_URL="file://$IMG"
echo "== T0: setup bueno (base para marcar)"
t "T0 setup bueno" -- arxy setup
echo bueno > "$R/.crash-mark"

echo "== T1: sha256 corrupto no pisa el rootfs (muere en verify, sin staging)"
t "T1 setup con sha malo falla" -- sh -c '! ARXY_IMAGE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 arxy setup 2>/dev/null'
t "T1 marcador intacto" -- sh -c "test \"\$(cat '$R/.crash-mark' 2>/dev/null)\" = bueno"
t "T1 rootfs sigue listado contenido" -- sh -c 'arxy list | grep -q "^pacman "'
t "T1 sin staging huerfano" -- sh -c "! ls -d '$R'.new.* >/dev/null 2>&1"

echo "== T2: SIGKILL durante extraccion (ventana: aparece $R.new.PID)"
rm -f "$R/.crash-mark"; echo bueno > "$R/.crash-mark"
arxy setup >"$D/setup-kill.log" 2>&1 &
SPID=$!
seen=""
for _i in $(seq 1 600); do
    if ! kill -0 "$SPID" 2>/dev/null; then break; fi
    if ls -d "$R".new.* >/dev/null 2>&1; then seen=1; break; fi
    sleep 0.2
done
if [[ -z "$seen" ]]; then
    echo "FAIL: T2 sin ventana de staging (setup terminó antes del kill)"; FAIL=$((FAIL+1))
else
    kill -KILL "$SPID" 2>/dev/null
    wait "$SPID" 2>/dev/null
    echo "PASS: T2 kill -9 en staging"
    t "T2 marcador intacto (viejo sigue activo)" -- sh -c "test \"\$(cat '$R/.crash-mark' 2>/dev/null)\" = bueno"
    t "T2 rootfs viejo responde" -- sh -c 'arxy run /usr/bin/true'
    t "T2 rootfs viejo lista contenido" -- sh -c 'arxy list | grep -q "^pacman "'
    if ls -d "$R".new.* >/dev/null 2>&1; then
        echo "INFO: staging huerfano tras kill (gap Fase 3, no falla): $(ls -d "$R".new.* | tr '\n' ' ')"
    fi
fi
SPID=""

echo "== T3: re-setup tras kill queda en verde"
t "T3 setup recupera" -- arxy setup
t "T3 marcador nuevo (rotó, no el viejo)" -- sh -c "! cat '$R/.crash-mark' 2>/dev/null | grep -q bueno"
t "T3 lista contenido" -- sh -c 'arxy list | grep -q "^pacman "'

echo "== resultado: $([[ $FAIL -eq 0 ]] && echo TODO_OK || echo "$FAIL FALLOS")"
exit $FAIL
