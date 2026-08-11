Config = {}

-- Temporalmente activado: aún se está confirmando en el juego que el fix
-- del umbral de arrastre (18px) del hotbar ya funciona bien del todo.
Config.Debug = true

-- Sin tecla propia para el panel completo (F2 quitada a petición del
-- usuario) — solo se abre desde dentro de la barra rápida (Tab), ver
-- Config.HotbarToggleKey más abajo.

-- La distancia máxima para "dar" (armas/items/dinero) NO se duplica aquí:
-- se relee en vivo de es_extended con ESX.GetConfig("DistanceGive") en
-- client/main.lua, así este panel nunca queda desincronizado si esa config
-- cambia allá.

-- ============================================================
-- Hotbar (antes mk_weaponwheel, absorbido aquí a petición del usuario: un
-- solo resource de inventario en vez de dos separados). Acceso rápido de
-- 9 casillas para armas/items sin tener que abrir el panel completo.
-- ============================================================

Config.HotbarSlots = 9
Config.HotbarToggleKey = 'TAB'
