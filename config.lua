Config = {}

-- Temporalmente activado: aún se está confirmando en el juego que el fix
-- del umbral de arrastre (18px) del hotbar ya funciona bien del todo.
Config.Debug = true

-- Tecla que abre el panel completo. RegisterKeyMapping (no ESX.RegisterInput,
-- que no está verificado en este proyecto) — mismo patrón que ya usaba
-- mk_weaponwheel para Tab.
Config.OpenKey = 'F2'

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
