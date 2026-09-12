# arxy-image — construcción de la imagen mínima de arxy

[![build-image](https://github.com/SrDicov/arxy-image/actions/workflows/build.yml/badge.svg)](https://github.com/SrDicov/arxy-image/actions/workflows/build.yml)
![license](https://img.shields.io/badge/license-MIT-green)

Construye el rootfs Arch mínimo que consume el CLI
[**arxy**](https://github.com/SrDicov/arxy): ~215 paquetes, ~0.9GB
desempaquetado, ~220MB en `arxy-rootfs-x86_64.tar.zst`.

- Repos: `core` + `extra` + `multilib` (habilitado, **sin** paquetes
  `lib32-*` preinstalados; Steam los instala después).
- Sin kernel, sin firmware, sin X server propio, sin toolchain, sin AUR.
- Locales `en_US` + `es_ES`, mirrorlist mundial estática, keyring
  pre-inicializado.

El CI la reconstruye cada viernes + a demanda y publica en el release
**[`latest`](https://github.com/SrDicov/arxy-image/releases/tag/latest)**
(`arxy-rootfs-x86_64.tar.zst` + `.sha256`). `arxy setup` descarga de ahí y
verifica contra el `.sha256` automáticamente.

## Reconstruir a mano (requiere root + ~10GB libres, vale en Void con sudo)

```bash
sudo -n PROFILE=arxy ./create-arch-bootstrap.sh  # paso 1: root.x86_64/
sudo -n PROFILE=arxy ./create-arxy-image.sh      # paso 2: tarball + .sha256
```

> OJO: pasar el perfil como asignación tras `sudo` (`sudo -n PROFILE=arxy
> ./script`); `PROFILE=arxy sudo ...` lo pierde porque sudo limpia el entorno.

`create-arxy-image.sh` avisa (no aborta) si se cuela kernel
(`usr/lib/modules`), firmware o `usr/lib32` con contenido, y solo acepta el
perfil `arxy`.

## Ficheros

| Fichero | Rol |
|---|---|
| `profiles/arxy.sh` | perfil: paquetes, locales, mirrorlist, compresión |
| `create-arch-bootstrap.sh` | paso 1: bootstrap Arch → `root.x86_64/` |
| `create-arxy-image.sh` | paso 2: `root.x86_64/` → tarball + sha256 |
| `.github/workflows/build.yml` | CI: build semanal + publicación en `latest` |

## Licencia

MIT — ver [LICENSE](LICENSE).
