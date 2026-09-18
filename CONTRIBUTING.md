# Cómo contribuir a arxy-image

## Reportar un bug

Abre un issue con la plantilla de bug report. Incluye siempre:

- Fecha/sha del tarball que falla (del `.sha256` o del release `latest`).
- Versión del CLI usada en la matrix (`arxy version`).
- Host donde corre la matrix (distro, o job del CI con enlace).
- Salida de la matrix (qué checks fallan, no solo el conteo).

## Proponer un cambio

1. Fork + branch desde `main`.
2. Un commit por tarea, mensaje con el porqué.
3. PR contra `main`. Describe el problema antes que la solución.

Ojo: un push a `main` que toque scripts dispara un build real (~20 min)
y puede republicar `latest`. Los PRs corren la matrix sin publicar.

## Perfiles y tamaños

- Cambios en `profiles/arxy.sh` o `tidy_rootfs` traen número medido
  (antes/después en MB en el mensaje del commit).
- Sin CHANGELOG: decisión consciente, el historial vive en los commits.
  Lo que afecte al CLI se cita en `arxy/CHANGELOG.md`.

## Tests

La puerta es `tests/matrix.sh`: necesita root, el tarball y `arxy` en
PATH. En local, lo normal es correrla en contenedor (ver
`tests/README.md`, sección "Manual 5 distros"). No se publica imagen
con la matrix en rojo.
