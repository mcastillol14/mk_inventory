-- Inventario completo (F2), NUI propia. Toda la lógica real (dar/quitar/usar
-- items, armas, dinero) vive en es_extended/server/main.lua — este resource
-- solo lee ESX.PlayerData (ya mantenido por es_extended) y dispara los
-- mismos eventos que ya usaba esx_inventory. No hay server/main.lua propio:
-- no hace falta reimplementar nada que es_extended ya valida en el servidor.

local inventoryOpen = false

local function dbg(msg)
    if Config.Debug then
        print(("[mk_inventory] %s"):format(msg))
    end
end

-------------------------
-- Construcción de datos --
-------------------------

-- Igual que el esx_inventory original: el peso solo cuenta items normales
-- (item.weight * count), las armas no pesan en este cálculo.
local function buildItems()
    local items, weight = {}, 0

    for _, item in ipairs(ESX.PlayerData.inventory or {}) do
        if item.count > 0 then
            weight = weight + (item.weight * item.count)
            items[#items + 1] = {
                name = item.name,
                label = item.label,
                count = item.count,
                weight = item.weight,
                usable = item.usable and true or false,
                canRemove = item.canRemove and true or false,
            }
        end
    end

    return items, weight
end

-- El ammo mostrado se recalcula fresco con GetAmmoInPedWeapon en vez de
-- fiarse de weapon.ammo del loadout, que puede estar desactualizado (mismo
-- motivo que ya documentó esx_inventory original).
local function buildWeapons()
    local weapons = {}
    local ped = ESX.PlayerData.ped or PlayerPedId()

    for _, weapon in ipairs(ESX.PlayerData.loadout or {}) do
        weapons[#weapons + 1] = {
            name = weapon.name,
            label = weapon.label,
            ammo = GetAmmoInPedWeapon(ped, joaat(weapon.name)),
            canGiveAmmo = weapon.ammo ~= nil,
        }
    end

    return weapons
end

-- Solo cuentas con dinero > 0, igual que el original. El banco no se puede
-- dar/tirar (canRemove=false) — mismo criterio que esx_inventory (canDrop =
-- account.name ~= "bank").
local function buildAccounts()
    local accounts = {}

    for _, account in ipairs(ESX.PlayerData.accounts or {}) do
        if account.money > 0 then
            accounts[#accounts + 1] = {
                name = account.name,
                label = account.label,
                money = account.money,
                canRemove = account.name ~= "bank",
            }
        end
    end

    return accounts
end

local function giveDistance()
    return ESX.GetConfig("DistanceGive") or 4.0
end

-- closestPlayer es un índice LOCAL (no server id) — GetPlayerServerId() lo
-- convierte cuando hace falta mandar el evento al servidor. Se recalcula en
-- cada acción real (no se guarda de la apertura del panel), porque el
-- jugador puede alejarse mientras el inventario sigue abierto.
local function getNearbyTarget()
    local closestPlayer, dist = ESX.Game.GetClosestPlayer()
    if closestPlayer and closestPlayer ~= -1 and dist and dist <= giveDistance() then
        return closestPlayer, GetPlayerName(closestPlayer)
    end
    return nil, nil
end

local function buildPayload()
    local items, weight = buildItems()
    local _, targetName = getNearbyTarget()

    return {
        weight = weight,
        maxWeight = ESX.PlayerData.maxWeight,
        items = items,
        weapons = buildWeapons(),
        accounts = buildAccounts(),
        playerNearby = targetName ~= nil,
        targetName = targetName,
    }
end

----------------------
-- Abrir / cerrar --
----------------------

local function closeInventory()
    if not inventoryOpen then return end

    inventoryOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "close" })
    dbg("cerrado")
end

local function openInventory()
    if inventoryOpen then return end
    if not ESX.PlayerLoaded then return end
    if ESX.PlayerData.dead then return end

    inventoryOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "open", data = buildPayload() })
    dbg("abierto")
end

local function refreshInventory()
    if not inventoryOpen then return end
    SendNUIMessage({ action = "refresh", data = buildPayload() })
end

-- Sin tecla propia (F2 quitada a petición del usuario) — el panel completo
-- solo se abre desde dentro de la barra rápida, ver
-- "mk_inventory:hotbarOpenFull" más abajo, junto a la lógica del hotbar.

-- ESC le quita el foco a la NUI a nivel de motor sin avisar a nuestro
-- callback "close" — mismo patrón ya usado en mk_admin/mk_weaponwheel.
-- También cierra si el jugador muere con el inventario abierto.
CreateThread(function()
    while true do
        if inventoryOpen and (IsPauseMenuActive() or ESX.PlayerData.dead) then
            closeInventory()
        end

        Wait(inventoryOpen and 0 or 500)
    end
end)

--------------------------------
-- Refresco reactivo --
--------------------------------

-- esx:addInventoryItem también se dispara con count=false para el aviso de
-- "recibiste X" al dar arma/componente/tinte (ver lección de mk_weaponwheel
-- en fivem-lecciones) — no pasa nada si igualmente refrescamos aquí, porque
-- buildPayload() siempre recalcula desde ESX.PlayerData entero, no usa esos
-- parámetros del evento para nada.
RegisterNetEvent("esx:addInventoryItem", refreshInventory)
RegisterNetEvent("esx:removeInventoryItem", refreshInventory)
RegisterNetEvent("esx:addLoadoutItem", refreshInventory)
RegisterNetEvent("esx:removeLoadoutItem", refreshInventory)

--------------------------------
-- Callbacks NUI --
--------------------------------

RegisterNUICallback("mk_inventory:close", function(_, cb)
    closeInventory()
    cb({ ok = true })
end)

-- Se llama justo antes de mostrar la pantalla de cantidad de "dar" (item,
-- arma o munición) para confirmar que sigue habiendo alguien cerca — el
-- estado que se mandó al abrir el panel puede haber quedado desactualizado
-- si el jugador se alejó mientras tenía el inventario abierto.
RegisterNUICallback("mk_inventory:checkTarget", function(_, cb)
    local _, targetName = getNearbyTarget()
    cb({ ok = targetName ~= nil, targetName = targetName })
end)

RegisterNUICallback("mk_inventory:use", function(data, cb)
    local itemName = data and data.name
    local item = nil

    for _, it in ipairs(ESX.PlayerData.inventory or {}) do
        if it.name == itemName then
            item = it
            break
        end
    end

    if item and item.usable and item.count > 0 then
        TriggerServerEvent("esx:useItem", itemName)
    end

    cb({ ok = true })
end)

local VALID_GIVE_REMOVE_TYPES = {
    item_standard = true,
    item_account = true,
    item_weapon = true,
}

-- itemType llega de la NUI: whitelist antes de usarlo para nada, igual que
-- ya se hace en mk_anticheat/mk_admin con cualquier valor que venga de
-- cliente y determine una rama de ejecución.
local function sanitizeGiveRemove(data)
    if not data or not VALID_GIVE_REMOVE_TYPES[data.type] or type(data.name) ~= "string" then
        return nil
    end

    return data.type, data.name
end

-- Cap real de cantidad: se relee SIEMPRE de ESX.PlayerData en el momento de
-- la acción (no de lo que mandó la NUI), para no fiarse de un valor que
-- pudo quedar desactualizado en el HTML mientras el panel estaba abierto.
-- La autoridad final sigue siendo el servidor (es_extended ya la aplica),
-- esto es solo para no mandar una acción con un tope evidentemente erróneo.
local function currentCap(itemType, itemName)
    if itemType == "item_standard" then
        for _, it in ipairs(ESX.PlayerData.inventory or {}) do
            if it.name == itemName then return it.count, it.canRemove end
        end
    elseif itemType == "item_account" then
        for _, acc in ipairs(ESX.PlayerData.accounts or {}) do
            if acc.name == itemName then return acc.money, acc.name ~= "bank" end
        end
    elseif itemType == "item_weapon" then
        for _, w in ipairs(ESX.PlayerData.loadout or {}) do
            if w.name == itemName then return 1, true end
        end
    end

    return 0, false
end

RegisterNUICallback("mk_inventory:give", function(data, cb)
    local itemType, itemName = sanitizeGiveRemove(data)
    if not itemType then
        cb({ ok = false })
        return
    end

    local cap, canRemove = currentCap(itemType, itemName)
    local qty = tonumber(data.qty)
    qty = qty and math.floor(qty) or nil

    if not canRemove or not qty or qty < 1 or qty > cap then
        cb({ ok = false })
        return
    end

    local closestPlayer = getNearbyTarget()
    if not closestPlayer then
        exports.mk_hud:Notify("No hay nadie lo bastante cerca para darle esto.", "error")
        cb({ ok = false })
        return
    end

    TriggerServerEvent("esx:giveInventoryItem", GetPlayerServerId(closestPlayer), itemType, itemName, qty)
    dbg(("dar: tipo=%s nombre=%s cantidad=%d"):format(itemType, itemName, qty))
    cb({ ok = true })
end)

RegisterNUICallback("mk_inventory:remove", function(data, cb)
    local itemType, itemName = sanitizeGiveRemove(data)
    if not itemType then
        cb({ ok = false })
        return
    end

    local cap, canRemove = currentCap(itemType, itemName)
    local qty = tonumber(data.qty)
    qty = qty and math.floor(qty) or nil

    if not canRemove or not qty or qty < 1 or qty > cap then
        cb({ ok = false })
        return
    end

    TriggerServerEvent("esx:removeInventoryItem", itemType, itemName, qty)
    dbg(("tirar: tipo=%s nombre=%s cantidad=%d"):format(itemType, itemName, qty))
    cb({ ok = true })
end)

RegisterNUICallback("mk_inventory:giveAmmo", function(data, cb)
    local weaponName = data and data.name
    if type(weaponName) ~= "string" then
        cb({ ok = false })
        return
    end

    local ped = ESX.PlayerData.ped or PlayerPedId()
    local pedAmmo = GetAmmoInPedWeapon(ped, joaat(weaponName))
    local qty = tonumber(data.qty)
    qty = qty and math.floor(qty) or nil

    if not qty or qty < 1 or qty > pedAmmo then
        cb({ ok = false })
        return
    end

    local closestPlayer = getNearbyTarget()
    if not closestPlayer then
        exports.mk_hud:Notify("No hay nadie lo bastante cerca para darle munición.", "error")
        cb({ ok = false })
        return
    end

    TriggerServerEvent("esx:giveInventoryItem", GetPlayerServerId(closestPlayer), "item_ammo", weaponName, qty)
    dbg(("dar municion: arma=%s cantidad=%d"):format(weaponName, qty))
    cb({ ok = true })
end)

-- Relay de logs de la NUI a la consola F8 — un console.log del HTML no
-- aparece ahí (vive en la consola de devtools del CEF), mismo patrón que
-- mk_weaponwheel.
RegisterNUICallback("mk_inventory:debug", function(data, cb)
    dbg("JS: " .. tostring(data and data.msg))
    cb({ ok = true })
end)

-- ============================================================================
-- MARK: Hotbar (Tab) — antes era el resource separado mk_weaponwheel; el
-- usuario pidió consolidar todo en un solo resource de inventario. Lógica
-- portada TAL CUAL (incluidos los fixes ya confirmados esta misma sesión:
-- umbral de arrastre de 18px, e.repeat en Tab, BlockWeaponWheelThisFrame()
-- siempre activo) — reutiliza el dbg() de arriba en vez de redefinirlo.
-- Coexiste con el panel completo (F2) sin chocar: cada uno solo actúa
-- mientras SU PROPIO contenedor está visible, y las dos NUI no comparten
-- nombres de "action" (el panel usa "open"/"refresh"/"close", el hotbar usa
-- "hotbar:open"/"hotbar:close").
-- ============================================================================

local hotbarOpen = false

-- [1..Config.HotbarSlots] = { kind = "weapon"|"item", name = "WEAPON_X"/"bread" } o false (vacia).
local hotbarOrder = {}

local function iconFor(weaponName)
    return weaponName:lower():gsub("^weapon_", "") .. ".png"
end

local function hotbarFindLoadoutWeapon(weaponName)
    for _, w in ipairs(ESX.PlayerData.loadout or {}) do
        if w.name == weaponName then
            return w
        end
    end

    return nil
end

local function hotbarFindInventoryItem(itemName)
    for _, it in ipairs(ESX.PlayerData.inventory or {}) do
        if it.name == itemName then
            return it
        end
    end

    return nil
end

local function hotbarSlotsHold(kind, name)
    for i = 1, Config.HotbarSlots do
        local e = hotbarOrder[i]
        if e and e.kind == kind and e.name == name then
            return true
        end
    end

    return false
end

-- Coloca en la primera casilla libre; si ya esta colocado no hace nada; si
-- no queda hueco y silent=false, avisa por el HUD que no cupo.
local function hotbarTryPlace(kind, name, label, silent)
    if hotbarSlotsHold(kind, name) then return end

    for i = 1, Config.HotbarSlots do
        if not hotbarOrder[i] then
            hotbarOrder[i] = { kind = kind, name = name }
            dbg(("hotbar: colocado en slot=%d kind=%s name=%s"):format(i, kind, name))
            return
        end
    end

    if not silent then
        exports.mk_hud:Notify(("Barra rápida llena (%d/%d): no cabe %s"):format(Config.HotbarSlots, Config.HotbarSlots, label), "error")
        dbg(("hotbar: lleno, no cupo: %s"):format(label))
    end
end

local function hotbarRemove(kind, name)
    for i = 1, Config.HotbarSlots do
        local e = hotbarOrder[i]
        if e and e.kind == kind and e.name == name then
            hotbarOrder[i] = false
            return
        end
    end
end

-- Quita del hotbar lo que ya no se posee y coloca (en silencio, sin avisar)
-- lo que se posee y aun no tiene casilla. Se llama SIEMPRE al abrir, como
-- red de seguridad ademas de los hooks reactivos de abajo.
local function hotbarSync()
    for i = 1, Config.HotbarSlots do
        local e = hotbarOrder[i]
        if e then
            local stillOwned = (e.kind == "weapon" and hotbarFindLoadoutWeapon(e.name))
                or (e.kind == "item" and hotbarFindInventoryItem(e.name) and hotbarFindInventoryItem(e.name).count > 0)

            if not stillOwned then
                hotbarOrder[i] = false
            end
        end
    end

    for _, w in ipairs(ESX.PlayerData.loadout or {}) do
        if w.name ~= "WEAPON_UNARMED" then
            hotbarTryPlace("weapon", w.name, w.label, true)
        end
    end

    for _, it in ipairs(ESX.PlayerData.inventory or {}) do
        if it.count > 0 then
            hotbarTryPlace("item", it.name, it.label, true)
        end
    end
end

-- Resuelve datos frescos (label/icono/cantidad) para una casilla en el
-- momento de mandarla a la NUI — nunca se guardan cacheados en hotbarOrder,
-- para que ammo/count nunca queden desactualizados.
local function hotbarResolveSlot(entry)
    if entry.kind == "weapon" then
        local w = hotbarFindLoadoutWeapon(entry.name)
        if not w then return nil end
        return { kind = "weapon", name = entry.name, label = w.label, icon = iconFor(entry.name), ammo = w.ammo }
    else
        local it = hotbarFindInventoryItem(entry.name)
        if not it or it.count <= 0 then return nil end
        return { kind = "item", name = entry.name, label = it.label, count = it.count }
    end
end

local function hotbarBuildSlotsForNui()
    local slots = {}

    for i = 1, Config.HotbarSlots do
        local e = hotbarOrder[i]
        slots[i] = e and (hotbarResolveSlot(e) or false) or false
    end

    return slots
end

local function closeHotbar()
    if not hotbarOpen then return end

    hotbarOpen = false
    FreezeEntityPosition(PlayerPedId(), false)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "hotbar:close" })
    dbg("hotbar: cerrado")
end

local function openHotbar()
    if hotbarOpen then
        dbg("openHotbar(): abortado, ya estaba abierto")
        return
    end

    -- Sin esto, si se pulsaba la tecla justo tras reconectar (antes de que
    -- ESX.PlayerData.loadout/inventory estuvieran listos) el hotbar se abría
    -- igualmente pero con las 9 casillas vacías.
    if not ESX.PlayerLoaded then
        dbg("openHotbar(): abortado, ESX.PlayerLoaded es false")
        return
    end

    local ped = PlayerPedId()
    if IsEntityDead(ped) then
        dbg("openHotbar(): abortado, IsEntityDead(ped) es true")
        return
    end

    hotbarOpen = true
    dbg("openHotbar(): hotbarOpen puesto a true, abriendo de verdad")

    -- Solo enfunda: sigue siendo dueño del arma, esto NO la borra del loadout
    SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
    FreezeEntityPosition(ped, true)
    SetNuiFocus(true, true)
    hotbarSync()
    SendNUIMessage({ action = "hotbar:open", slots = hotbarBuildSlotsForNui() })
    dbg("hotbar: abierto")
end

-- Pequeño debounce: si se machaca la tecla muy rápido (auto-repeat del
-- teclado incluido), evita abrir/cerrar/abrir en el mismo puñado de ms.
local lastHotbarToggle = 0
local HOTBAR_TOGGLE_DEBOUNCE_MS = 200

RegisterCommand("mk_inventory_hotbar_toggle", function()
    dbg("mk_inventory_hotbar_toggle disparado (tecla " .. tostring(Config.HotbarToggleKey) .. " pulsada) — hotbarOpen actual: " .. tostring(hotbarOpen))

    local now = GetGameTimer()
    if now - lastHotbarToggle < HOTBAR_TOGGLE_DEBOUNCE_MS then
        dbg("mk_inventory_hotbar_toggle: ignorado por debounce")
        return
    end
    lastHotbarToggle = now

    if hotbarOpen then
        closeHotbar()
    else
        openHotbar()
    end
end, false)

RegisterKeyMapping("mk_inventory_hotbar_toggle", "Abrir barra rápida de armas/items", "keyboard", Config.HotbarToggleKey)

-- Igual que con el panel completo: ESC le quita el foco a la NUI a nivel de
-- motor sin avisar a nuestro callback "close" — este hilo resincroniza el
-- estado. También cierra si el jugador muere con el hotbar abierto.
CreateThread(function()
    while true do
        if hotbarOpen and (IsPauseMenuActive() or IsEntityDead(PlayerPedId())) then
            closeHotbar()
        end

        Wait(hotbarOpen and 0 or 500)
    end
end)

-- SetNuiFocus NO desactiva los controles nativos de selección de arma por
-- número (son controles de juego, no de teclado "crudo") — sin esto, con
-- el hotbar abierto, pulsar 1-9 sacaba a la vez el arma correspondiente
-- del menú nativo de GTA por debajo del nuestro. El TAB nativo (control 37,
-- INPUT_SELECT_WEAPON) abre además la ruleta normal del juego por debajo
-- de la nuestra — BlockWeaponWheelThisFrame() la bloquea.
--
-- OJO: DisableControlAction sobre 157-165 solo se aplica MIENTRAS
-- hotbarOpen es true (no todo el rato) — dejarlo activo siempre hacía
-- fallar "sacar arma" de vez en cuando (no hay garantía de orden entre
-- este hilo y el momento exacto en que el callback de la NUI llama a
-- SetCurrentPedWeapon). BlockWeaponWheelThisFrame() es distinto: no toca
-- SetCurrentPedWeapon ni los controles de selección, así que ese sí corre
-- en su propio hilo SIEMPRE activo (ver más abajo), sin ese riesgo.
--
-- Índice = número de tecla física (1-9); valor = control INPUT_SELECT_WEAPON_*
-- que GTA tiene atado a esa tecla por defecto — verificado contra
-- docs.fivem.net/docs/game-references/controls (el orden NO es 157,158,159...
-- correlativo con las teclas: la tecla 6 es el control 159, la 7 es el 161,
-- etc.).
local HOTBAR_KEY_TO_CONTROL = { [1] = 157, [2] = 158, [3] = 160, [4] = 164, [5] = 165, [6] = 159, [7] = 161, [8] = 162, [9] = 163 }
local HOTBAR_WEAPON_SELECT_CONTROLS = { 157, 158, 159, 160, 161, 162, 163, 164, 165 }

local function hotbarDrawSlot(slot)
    local entry = hotbarOrder[slot]
    local resolved = entry and hotbarResolveSlot(entry)
    if not resolved then
        dbg(("hotbarDrawSlot(%s): no hay nada resuelto para esa casilla (entry=%s)"):format(tostring(slot), entry and "existe pero hotbarResolveSlot devolvió nil" or "vacía"))
        return
    end

    if resolved.kind == "weapon" then
        SetCurrentPedWeapon(PlayerPedId(), joaat(resolved.name), true)
        dbg(("hotbar: arma sacada: slot=%s arma=%s"):format(slot, resolved.name))
    else
        TriggerServerEvent("esx:useItem", resolved.name)
        dbg(("hotbar: item usado: slot=%s item=%s"):format(slot, resolved.name))
    end

    closeHotbar()
end

-- BlockWeaponWheelThisFrame() SIEMPRE (no solo con hotbarOpen): solo evita
-- que aparezca la ruleta NATIVA al mantener pulsado Tab — ver nota extensa
-- de por qué esto es seguro dejarlo siempre activo en fivem-lecciones,
-- lección 2026-08-11 sobre mk_weaponwheel.
CreateThread(function()
    while true do
        BlockWeaponWheelThisFrame()
        Wait(0)
    end
end)

CreateThread(function()
    while true do
        if hotbarOpen then
            for _, control in ipairs(HOTBAR_WEAPON_SELECT_CONTROLS) do
                DisableControlAction(0, control, true)
            end

            -- Detectar el número de slot con IsDisabledControlJustPressed —
            -- ver nota extensa en fivem-lecciones sobre por qué esto es más
            -- fiable que el keydown de la NUI en este CEF.
            for slot, control in pairs(HOTBAR_KEY_TO_CONTROL) do
                if IsDisabledControlJustPressed(0, control) then
                    dbg(("hotbar: tecla %s detectada (control %s) -> hotbarDrawSlot(%s)"):format(slot, control, slot))
                    hotbarDrawSlot(slot)
                end
            end

            Wait(0)
        else
            Wait(500)
        end
    end
end)

RegisterNUICallback("mk_inventory:hotbarDraw", function(data, cb)
    local slot = tonumber(data.slot)
    if slot then hotbarDrawSlot(slot) end
    cb({ ok = true })
end)

RegisterNUICallback("mk_inventory:hotbarReorder", function(data, cb)
    local from = tonumber(data.from)
    local to = tonumber(data.to)

    if from and to and from >= 1 and from <= Config.HotbarSlots and to >= 1 and to <= Config.HotbarSlots then
        hotbarOrder[from], hotbarOrder[to] = hotbarOrder[to], hotbarOrder[from]
        dbg(("hotbar: casillas reordenadas: %s<->%s"):format(from, to))
    end

    cb({ ok = true })
end)

RegisterNUICallback("mk_inventory:hotbarClose", function(_, cb)
    closeHotbar()
    cb({ ok = true })
end)

-- Único camino al panel completo (sin tecla F2 propia, quitada a petición
-- del usuario) — pasa de la barra rápida al panel SIN soltar el foco de la
-- NUI (openInventory ya hace su propio SetNuiFocus(true,true), que es
-- idempotente si ya estaba puesto).
RegisterNUICallback("mk_inventory:hotbarOpenFull", function(_, cb)
    if not hotbarOpen then
        cb({ ok = false })
        return
    end

    hotbarOpen = false
    FreezeEntityPosition(PlayerPedId(), false)
    dbg("hotbar: abriendo panel completo")
    openInventory()
    cb({ ok = true })
end)

RegisterNUICallback("mk_inventory:hotbarDebug", function(data, cb)
    dbg("hotbar JS: " .. tostring(data and data.msg))
    cb({ ok = true })
end)

-- ============================================================
-- MARK: Hooks reactivos del hotbar — colocan/quitan casillas al momento en
-- que ganas/pierdes algo, sin esperar a la proxima vez que lo abras.
-- ============================================================

-- Aviso propio al ganar/perder un arma — sustituye al popup nativo de abajo
-- a la derecha, desactivado en es_extended/client/functions.lua
-- (ShowInventoryItemNotification).
RegisterNetEvent("esx:addLoadoutItem", function(weaponName, weaponLabel)
    hotbarTryPlace("weapon", weaponName, weaponLabel, false)
    ESX.ShowNotification(("Has recibido: %s"):format(weaponLabel), "success")
end)

RegisterNetEvent("esx:removeLoadoutItem", function(weaponName, weaponLabel)
    hotbarRemove("weapon", weaponName)
    ESX.ShowNotification(("Has perdido: %s"):format(weaponLabel or weaponName), "error")
end)

-- Ultimo total visto por ESTOS handlers para cada item — se usa solo para
-- calcular el delta (+N/-N) del aviso, independiente de en que orden le
-- lleguen los handlers de es_extended vs los nuestros al mismo evento.
local hotbarLastKnownItemCount = {}

RegisterNetEvent("esx:addInventoryItem", function(itemName, count)
    -- es_extended tambien dispara este evento con count=false solo para el
    -- aviso de "recibiste X" al dar un arma/componente/tinte — no es un item
    -- real, se descarta aqui.
    if type(count) ~= "number" or count <= 0 then return end

    local it = hotbarFindInventoryItem(itemName)
    if it then
        hotbarTryPlace("item", itemName, it.label, false)

        local prev = hotbarLastKnownItemCount[itemName] or 0
        if count > prev then
            exports.mk_hud:Notify(("+%d %s"):format(count - prev, it.label), "success")
        end
    end

    hotbarLastKnownItemCount[itemName] = count
end)

RegisterNetEvent("esx:removeInventoryItem", function(itemName, count)
    if type(count) ~= "number" then return end

    local it = hotbarFindInventoryItem(itemName)
    local prev = hotbarLastKnownItemCount[itemName]
    if prev and prev > count then
        exports.mk_hud:Notify(("-%d %s"):format(prev - count, it and it.label or itemName), "info")
    end
    hotbarLastKnownItemCount[itemName] = count

    if count <= 0 then
        hotbarRemove("item", itemName)
    end
end)
