# Política de seguridad

## Reportar una vulnerabilidad

No abras un issue público. Escribe a **SrDicov@gmail.com** con:

- Qué componente afecta (build, firma minisign, matrix, perfil).
- Pasos mínimos para reproducir o prueba de concepto.
- Impacto (qué puede hacer un atacante con ello).

## Alcance

Esto es el repo de la imagen, no el del CLI:

- Cuenta aquí: tarball manipulado que pase la verificación,
  `.minisig` que verifique sin la secreta, secreto filtrado en logs
  del CI, perfil que meta software inesperado en la imagen.
- Va al repo `arxy`: bugs del CLI (`setup`, `run`, bridge, `doctor`).
- No es vulnerabilidad: que la imagen no aisle nada (es un rootfs
  plano por diseño, igual que en `arxy`).
