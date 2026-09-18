# Qué cambia y por qué

Si toca `profiles/arxy.sh` o `tidy_rootfs`: tamaño medido antes/después
en MB (obligatorio, ver `tests/README.md`, "Convención").

## Checklist

- [ ] `bash -n` + `shellcheck` en verde en los scripts tocados
- [ ] Matrix en verde (`tests/matrix.sh`, o job del CI en este PR)
- [ ] Si cambia el perfil: peso medido en el mensaje del commit
- [ ] Un commit con el porqué
