-- Inventario completo + barra rápida, todo en UNA sola pantalla (Tab) — el
-- usuario pidió quitar la tecla F2 y el botón "ver completo" que separaban
-- las dos cosas, ver lección 2026-08-11 en fivem-lecciones. Toda la lógica
-- real (dar/quitar/usar items, armas, dinero) vive en
-- es_extended/server/main.lua — este resource solo lee ESX.PlayerData (ya
-- mantenido por es_extended) y dispara los mismos eventos que ya usaba
-- esx_inventory/mk_weaponwheel. No hay server/main.lua propio.

local inventoryOpen = false

local function dbg(msg)
    if Config.Debug then
        print(("[mk_inventory] %s"):format(msg))
    end
end

-- ============================================================
-- MARK: Barra rápida — estado y helpers (declarados ANTES de abrir/cerrar
-- porque openInventory/closeInventory ya los necesitan: las 9 casillas y
-- la lista completa comparten la misma apertura/cierre ahora).
-- ============================================================

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
-- red de seguridad ademas de los hooks reactivos de más abajo.
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

-- Volcado completo de las 9 casillas — pedido explícito del usuario para
-- poder ver de un vistazo en F8 qué hay puesto en cada una al abrir.
local function logHotbarState()
    if not Config.Debug then return end

    for i = 1, Config.HotbarSlots do
        local e = hotbarOrder[i]
        if not e then
            dbg(("casilla %d: vacía"):format(i))
        else
            local resolved = hotbarResolveSlot(e)
            if resolved then
                if resolved.kind == "weapon" then
                    dbg(("casilla %d: ARMA %s (%s), municion=%s"):format(i, resolved.name, resolved.label, tostring(resolved.ammo)))
                else
                    dbg(("casilla %d: ITEM %s (%s) x%s"):format(i, resolved.name, resolved.label, tostring(resolved.count)))
                end
            else
                dbg(("casilla %d: guardaba %s/%s pero ya no se resuelve (perdido/gastado)"):format(i, e.kind, e.name))
            end
        end
    end
end

-------------------------
-- Construcción de datos de la lista completa --
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
-- Abrir / cerrar (una sola pantalla: grid + lista completa juntas) --
----------------------

local function closeInventory()
    if not inventoryOpen then return end

    inventoryOpen = false
    FreezeEntityPosition(PlayerPedId(), false)
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "close" })
    dbg("=== INVENTARIO CERRADO ===")
end

local function openInventory()
    if inventoryOpen then return end
    if not ESX.PlayerLoaded then return end
    if ESX.PlayerData.dead then return end

    local ped = PlayerPedId()
    if IsEntityDead(ped) then return end

    inventoryOpen = true

    -- Solo enfunda: sigue siendo dueño del arma, esto NO la borra del loadout.
    SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
    FreezeEntityPosition(ped, true)
    SetNuiFocus(true, true)
    hotbarSync()
    SendNUIMessage({ action = "open", data = buildPayload(), slots = hotbarBuildSlotsForNui() })
    dbg("=== INVENTARIO ABIERTO — contenido de las 9 casillas ===")
    logHotbarState()
end

local function refreshInventory()
    if not inventoryOpen then return end
    SendNUIMessage({ action = "refresh", data = buildPayload(), slots = hotbarBuildSlotsForNui() })
    dbg("=== INVENTARIO REFRESCADO (algo cambió mientras estaba abierto) ===")
    logHotbarState()
end

-- Pequeño debounce: si se machaca la tecla muy rápido (auto-repeat del
-- teclado incluido), evita abrir/cerrar/abrir en el mismo puñado de ms.
local lastToggle = 0
local TOGGLE_DEBOUNCE_MS = 200

RegisterCommand("mk_inventory_toggle", function()
    dbg("mk_inventory_toggle disparado (tecla " .. tostring(Config.HotbarToggleKey) .. " pulsada) — inventoryOpen actual: " .. tostring(inventoryOpen))

    local now = GetGameTimer()
    if now - lastToggle < TOGGLE_DEBOUNCE_MS then
        dbg("mk_inventory_toggle: ignorado por debounce")
        return
    end
    lastToggle = now

    if inventoryOpen then
        closeInventory()
    else
        openInventory()
    end
end, false)

RegisterKeyMapping("mk_inventory_toggle", "Abrir inventario", "keyboard", Config.HotbarToggleKey)

-- ESC le quita el foco a la NUI a nivel de motor sin avisar a nuestro
-- callback "close" — mismo patrón ya usado en mk_admin/mk_shops. También
-- cierra si el jugador muere con el inventario abierto.
CreateThread(function()
    while true do
        if inventoryOpen and (IsPauseMenuActive() or ESX.PlayerData.dead or IsEntityDead(PlayerPedId())) then
            closeInventory()
        end

        Wait(inventoryOpen and 0 or 500)
    end
end)

-- SetNuiFocus NO desactiva los controles nativos de selección de arma por
-- número (son controles de juego, no de teclado "crudo") — sin esto, con
-- el inventario abierto, pulsar 1-9 sacaba a la vez el arma correspondiente
-- del menú nativo de GTA por debajo del nuestro. El TAB nativo (control 37,
-- INPUT_SELECT_WEAPON) abre además la ruleta normal del juego por debajo de
-- la nuestra — BlockWeaponWheelThisFrame() la bloquea (en su propio hilo,
-- más abajo, SIEMPRE activo).
--
-- Índice = número de tecla física (1-9); valor = control INPUT_SELECT_WEAPON_*
-- que GTA tiene atado a esa tecla por defecto — verificado contra
-- docs.fivem.net/docs/game-references/controls (el orden NO es
-- 157,158,159... correlativo con las teclas).
local HOTBAR_KEY_TO_CONTROL = { [1] = 157, [2] = 158, [3] = 160, [4] = 164, [5] = 165, [6] = 159, [7] = 161, [8] = 162, [9] = 163 }
local HOTBAR_WEAPON_SELECT_CONTROLS = { 157, 158, 159, 160, 161, 162, 163, 164, 165 }

-- origin: solo para el log, dice qué camino disparó esto (control nativo de
-- juego vs. NUI/JS) — pedido explícito del usuario para saber si la tecla
-- se detecta y, si se detecta, si de verdad saca el arma o usa el item.
local function hotbarDrawSlot(slot, origin)
    origin = origin or "?"
    local entry = hotbarOrder[slot]
    local resolved = entry and hotbarResolveSlot(entry)

    if not resolved then
        dbg(("[%s] casilla %s pulsada pero NO HACE NADA — %s"):format(
            origin, tostring(slot),
            entry and "tenía algo guardado pero ya no se resuelve (arma/item perdido)" or "está vacía"))
        return
    end

    if resolved.kind == "weapon" then
        SetCurrentPedWeapon(PlayerPedId(), joaat(resolved.name), true)
        dbg(("[%s] casilla %s -> SACA EL ARMA %s (%s)"):format(origin, slot, resolved.name, resolved.label))
    else
        TriggerServerEvent("esx:useItem", resolved.name)
        dbg(("[%s] casilla %s -> CONSUME EL ITEM %s (%s)"):format(origin, slot, resolved.name, resolved.label))
    end

    closeInventory()
end

-- BlockWeaponWheelThisFrame() SIEMPRE (no solo con inventoryOpen): solo
-- evita que aparezca la ruleta NATIVA al mantener pulsado Tab — ver nota
-- extensa de por qué esto es seguro dejarlo siempre activo en
-- fivem-lecciones, lección 2026-08-11 sobre mk_weaponwheel.
CreateThread(function()
    while true do
        BlockWeaponWheelThisFrame()
        Wait(0)
    end
end)

-- Camino Lua (nativo) de detección de 1-9 — se deja activo por si en algún
-- setup SÍ llega de forma fiable, pero el jugador reportó varias veces que
-- esto solo no basta, así que app.js AHORA TAMBIÉN detecta 1-9 por su
-- cuenta con keydown normal (independiente de este camino, ver
-- RegisterNUICallback("mk_inventory:hotbarDraw", ...) más abajo — cualquiera
-- de los dos caminos llega a hotbarDrawSlot igual).
CreateThread(function()
    while true do
        if inventoryOpen then
            for _, control in ipairs(HOTBAR_WEAPON_SELECT_CONTROLS) do
                DisableControlAction(0, control, true)
            end

            for slot, control in pairs(HOTBAR_KEY_TO_CONTROL) do
                if IsDisabledControlJustPressed(0, control) then
                    dbg(("[control-nativo] tecla %s detectada (control %s)"):format(slot, control))
                    hotbarDrawSlot(slot, "control-nativo")
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
    dbg(("[nui] mk_inventory:hotbarDraw recibido, slot=%s"):format(tostring(slot)))
    if slot then hotbarDrawSlot(slot, "nui") end
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

--------------------------------
-- Refresco reactivo de la lista completa --
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
-- Callbacks NUI de la lista completa --
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
-- aparece ahí (vive en la consola de devtools del CEF).
RegisterNUICallback("mk_inventory:debug", function(data, cb)
    dbg("JS: " .. tostring(data and data.msg))
    cb({ ok = true })
end)

-- ============================================================
-- MARK: Hooks reactivos de la barra rápida — colocan/quitan casillas al
-- momento en que ganas/pierdes algo, sin esperar a la proxima vez que
-- abras el inventario.
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
