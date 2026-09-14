# tests/ — puerta de publicacion de la imagen

`matrix.sh` corre 29–34 checks según nivel y flags (rama libc,
autodetección L2 y chroot `MATRIX_WRITE2=1` son condicionales) y falla
el build si algo rompe. El CI la ejecuta en cada build (Arch privilegiado, `MATRIX_WRITE2=1`);
a mano se corre en 5 distros antes de un release.

## Que asserta cada check (y que bug cazaria)

| Check | Que prueba | Bug que cazaria |
|---|---|---|
| doctor reporta nivel | bwrap/userns detectados | entorno roto silencioso |
| setup file:// | descarga+verifica+extrae+`-Sy` atomicos | tarball corrupto publicado |
| run/bash/pacman --version | runtime L1 basico (libalpm, glib) | imagen sin dependencias |
| libc del subsistema | el binario usa la libc de la imagen, no la del host | contaminacion host (musl/glibc) |
| which/info/list/search **con contenido** | lecturas con `Include` resueltos al rootfs | bug Includes L2 (Fase 4: `mirrorlist could not be read`) |
| L2 forzado (run/info/AUR) | mismo path sin bwrap | regresion de nivel 2 |
| export/unexport sintetico | lanzadores `.desktop` + `update-desktop-database` | regresion de export |
| L2: export --all + contenido | export forzado sin bwrap (`Exec` reescrito, `X-Arxy-Pkg`) | regresion de export en nivel 2 (6.5.5 era manual) |
| L2: export tras install chroot | export en L2 sobre rootfs mutado vía chroot | export ciego tras escritura L2 |
| limpia residuo en REAL_APPS | borra lanzadores nuevos vs foto inicial, falla listando resto | acumulación de lanzadores en host real |
| install/run/remove tree | escrituras pacman + scriptlets | imagen sin keyring, hooks rotos |
| fc-list con contenido | fontconfig + fuentes | GUI sin texto |
| clean/quickstart/doctor --fix | CLI nuevo del repo `arxy` contra imagen nueva | deriva CLI-imagen |
| doctor --json format | `format: 1` en stdout limpio | regresión de superficie machine-readable |

La matriz exige el CLI nuevo del repo `arxy` (en docker/CI se copia a
`/usr/local/bin/arxy`): con un `arxy` instalado obsoleto (sin `--json`),
solo ese check falla. No es regresión de la imagen.
| rollback sin .old | el negativo falla limpio | `die` con traceback |
| rollback restaura anterior | `.old` es el setup inmediato anterior (el swap destruye el primero) + el version file vuelve a describir el activo | rotacion que rescata al ancestro equivocado; `version` mintiendo tras rollback |
| clean --apply borra rollback | `clean` recupera el espacio de `.old` | `root.old` huerfano de 1GB+ |
| L2 autodetectado (solo L1) | sin bwrap cae a nivel 2 | deteccion rota |
| L2 install/remove (solo `MATRIX_WRITE2`) | pacman via chroot con mounts | regresion de chroot |

## Manual 5 distros (pre-release)

Por contenedor (alpine, chimera-linux, void, ubuntu, ubuntu+privilegiado):

1. CLI `arxy` (del repo `arxy`) en `/usr/local/bin`.
2. Tarball a validar en `/image.tar.zst`.
3. `tests/matrix.sh` en `/matrix.sh`.
4. `docker exec <contenedor> /matrix.sh` como root.

```bash
docker cp arxy-rootfs-x86_64.tar.zst <c>:/image.tar.zst
docker cp <repo-arxy>/src/arxy <c>:/usr/local/bin/arxy
docker cp tests/matrix.sh <c>:/matrix.sh
docker exec <c> /matrix.sh
```

## Variables

| Variable | Defecto | Uso |
|---|---|---|
| `MATRIX_IMAGE` | `/image.tar.zst` | tarball a validar |
| `ARXY_IMAGE_URL` | `file://$MATRIX_IMAGE` | URL explicita (manda) |
| `ARXY_ROOT` | `/var/lib/arxy/root` | rootfs aislado para no tocar el del host |
| `MATRIX_WRITE2` | vacio (=omitir) | escrituras en nivel 2 (chroot) |

## Convención

Cambios de tamaño con número medido (antes/después en el commit).

## Limite

Los containers son siempre limpios (sin sys-conf ni user-conf): esto no
caza bugs de precedencia `env > user > sys`. Esos se prueban en host real
con conf presente (ver AGENTS.md del repo `arxy`).
