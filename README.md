# mk_inventory

Inventario completo (tecla F2) + barra rápida de armas/items (tecla Tab,
antes era el resource aparte `mk_weaponwheel`, absorbido aquí) — NUI
propia, sustituye al inventario por defecto de ESX (`esx_inventory`). Toda
la lógica real de dar/tirar/usar corre en `es_extended`, este resource solo
pone la interfaz encima de los eventos ya probados del framework.

## Instalación

Copia la carpeta a `resources/`, `ensure mk_inventory`, reinicia. No
necesita `server/main.lua` propio.

## Depende de

- es_extended
- mk_hud (notificaciones)
