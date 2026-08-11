(() => {
  "use strict";

  const el = (id) => document.getElementById(id);
  const root = el("root");
  const hotbarGrid = el("hotbar-grid");
  const itemList = el("item-list");
  const emptyHint = el("empty-hint");
  const weightLabel = el("weight-label");
  const weightFill = el("weight-fill");
  const toastEl = el("toast");

  const screens = {
    list: el("screen-list"),
    qty: el("screen-qty"),
  };

  const tabs = {
    items: el("tab-items"),
    weapons: el("tab-weapons"),
    accounts: el("tab-accounts"),
  };

  let currentData = null;
  let currentSlots = [];
  let activeTab = "items";
  let pendingAction = null; // { kind: "give"|"remove"|"giveAmmo", type, name, cap }
  let toastTimer = null;

  // Arrastre de las 9 casillas rápidas (mousedown/mousemove/mouseup manual —
  // el drag-and-drop nativo de HTML5 no es fiable en el CEF de FiveM).
  let dragFrom = null;
  let pointerDragging = false;
  let dragStartX = 0;
  let dragStartY = 0;
  // 18px: con 6px (el primer valor) los clics normales de un jugador real
  // medían 6-7px de temblor y ya contaban como arrastre, así que el clic
  // nunca sacaba el arma (ver SKILL.md, lección 2026-08-11).
  const DRAG_THRESHOLD_PX = 18;

  function post(endpoint, payload) {
    return fetch(`https://${GetParentResourceName()}/${endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(payload || {}),
    }).then((res) => res.json()).catch(() => null);
  }

  function debugLog(msg) {
    post("mk_inventory:debug", { msg });
  }

  function escapeHtml(str) {
    return String(str).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function showScreen(name) {
    for (const key in screens) {
      screens[key].classList.toggle("hidden", key !== name);
    }
  }

  function showToast(msg) {
    toastEl.textContent = msg;
    toastEl.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.add("hidden"), 2500);
  }

  function setActiveTab(name) {
    activeTab = name;
    for (const key in tabs) {
      tabs[key].classList.toggle("active", key === name);
    }
    renderList();
  }

  for (const key in tabs) {
    tabs[key].addEventListener("click", () => setActiveTab(key));
  }

  function renderWeight() {
    if (!currentData) return;
    const weight = Math.round(currentData.weight || 0);
    const max = Math.round(currentData.maxWeight || 0);
    weightLabel.textContent = `${weight} / ${max} kg`;

    const pct = max > 0 ? Math.min(100, (weight / max) * 100) : 0;
    weightFill.style.width = `${pct}%`;
    weightFill.classList.toggle("full", pct >= 90);
  }

  function actionButton(cls, action, label, ctx) {
    return `<span class="act-btn ${cls}" data-action="${action}" data-ctx='${escapeHtml(JSON.stringify(ctx))}'>${label}</span>`;
  }

  function renderItems() {
    const items = (currentData.items || []);
    if (items.length === 0) return "";

    return items.map((item) => {
      const actions = [];
      if (item.usable) {
        actions.push(actionButton("act-use", "use", "Usar", { name: item.name }));
      }
      if (item.canRemove) {
        if (currentData.playerNearby) {
          actions.push(actionButton("act-give", "give", "Dar", { type: "item_standard", name: item.name, cap: item.count }));
        }
        actions.push(actionButton("act-remove", "remove", "Tirar", { type: "item_standard", name: item.name, cap: item.count }));
      }

      return `
        <div class="item-row">
          <div class="item-info">
            <span class="item-name">${escapeHtml(item.label)} x${item.count}</span>
            <span class="item-meta">${(item.weight * item.count).toFixed(1)} kg</span>
          </div>
          <div class="item-actions">${actions.join("")}</div>
        </div>
      `;
    }).join("");
  }

  function renderWeapons() {
    const weapons = (currentData.weapons || []);
    if (weapons.length === 0) return "";

    return weapons.map((w) => {
      const actions = [];
      if (currentData.playerNearby) {
        actions.push(actionButton("act-give", "give", "Dar", { type: "item_weapon", name: w.name, cap: 1 }));
      }
      actions.push(actionButton("act-remove", "remove", "Tirar", { type: "item_weapon", name: w.name, cap: 1 }));
      if (w.canGiveAmmo && w.ammo > 0 && currentData.playerNearby) {
        actions.push(actionButton("act-ammo", "giveAmmo", "Munición", { name: w.name, cap: w.ammo }));
      }

      const meta = w.canGiveAmmo ? `${w.ammo} balas` : "Sin munición";

      return `
        <div class="item-row">
          <div class="item-info">
            <span class="item-name">${escapeHtml(w.label)}</span>
            <span class="item-meta">${meta}</span>
          </div>
          <div class="item-actions">${actions.join("")}</div>
        </div>
      `;
    }).join("");
  }

  function renderAccounts() {
    const accounts = (currentData.accounts || []);
    if (accounts.length === 0) return "";

    return accounts.map((acc) => {
      const actions = [];
      if (acc.canRemove) {
        if (currentData.playerNearby) {
          actions.push(actionButton("act-give", "give", "Dar", { type: "item_account", name: acc.name, cap: acc.money }));
        }
        actions.push(actionButton("act-remove", "remove", "Tirar", { type: "item_account", name: acc.name, cap: acc.money }));
      }

      return `
        <div class="item-row">
          <div class="item-info">
            <span class="item-name">${escapeHtml(acc.label)}</span>
            <span class="item-meta">$${acc.money}</span>
          </div>
          <div class="item-actions">${actions.join("")}</div>
        </div>
      `;
    }).join("");
  }

  function renderList() {
    if (!currentData) return;

    let html = "";
    if (activeTab === "items") html = renderItems();
    else if (activeTab === "weapons") html = renderWeapons();
    else if (activeTab === "accounts") html = renderAccounts();

    itemList.innerHTML = html;
    emptyHint.classList.toggle("hidden", html.length > 0);

    itemList.querySelectorAll(".act-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        const action = btn.dataset.action;
        const ctx = JSON.parse(btn.dataset.ctx || "{}");
        handleAction(action, ctx);
      });
    });
  }

  function handleAction(action, ctx) {
    debugLog(`accion=${action} ctx=${JSON.stringify(ctx)}`);

    if (action === "use") {
      post("mk_inventory:use", { name: ctx.name });
      return;
    }

    if (action === "remove") {
      openQtyScreen("remove", ctx, `Tirar`);
      return;
    }

    if (action === "give" || action === "giveAmmo") {
      // El estado "playerNearby" que ya tenemos pudo quedar desactualizado
      // si el jugador se alejó mientras el panel seguía abierto — se
      // reconfirma justo antes de pedir la cantidad, en vez de fiarnos del
      // último render.
      post("mk_inventory:checkTarget", {}).then((res) => {
        if (!res || !res.ok) {
          showToast("No hay nadie lo bastante cerca.");
          return;
        }
        openQtyScreen(action, ctx, `Dar a ${res.targetName}`);
      });
    }
  }

  function openQtyScreen(kind, ctx, verb) {
    pendingAction = { kind, ...ctx };

    const cap = Math.max(1, Math.floor(ctx.cap || 1));
    const input = el("qty-input");
    input.value = "1";
    input.min = "1";
    input.max = String(cap);

    el("qty-title").textContent = verb;
    el("qty-hint").textContent = `Cantidad (1-${cap})`;

    showScreen("qty");
    input.focus();
    input.select();
  }

  el("btn-qty-cancel").addEventListener("click", () => {
    pendingAction = null;
    showScreen("list");
  });

  el("btn-qty-confirm").addEventListener("click", () => {
    if (!pendingAction) return;

    const qty = parseInt(el("qty-input").value, 10);
    const cap = Math.floor(pendingAction.cap || 1);

    if (!Number.isFinite(qty) || qty < 1 || qty > cap) {
      showToast(`Cantidad inválida (1-${cap}).`);
      return;
    }

    const kind = pendingAction.kind;
    let promise;

    if (kind === "give") {
      promise = post("mk_inventory:give", { type: pendingAction.type, name: pendingAction.name, qty });
    } else if (kind === "remove") {
      promise = post("mk_inventory:remove", { type: pendingAction.type, name: pendingAction.name, qty });
    } else if (kind === "giveAmmo") {
      promise = post("mk_inventory:giveAmmo", { name: pendingAction.name, qty });
    }

    pendingAction = null;
    showScreen("list");

    if (promise) {
      promise.then((res) => {
        if (!res || !res.ok) {
          debugLog(`accion rechazada por el cliente (kind=${kind})`);
          showToast("No se pudo completar la acción.");
        }
      });
    }
  });

  // ============================================================
  // Barra rápida — las 9 casillas de arriba del panel
  // ============================================================

  function drawHotbarSlot(slot) {
    if (!currentSlots[slot - 1]) {
      debugLog(`draw(${slot}) abortado: currentSlots[${slot - 1}] esta vacio en la copia local de la NUI`);
      return;
    }
    debugLog(`draw(${slot}) -> POST mk_inventory:hotbarDraw`);
    post("mk_inventory:hotbarDraw", { slot }).then((res) => {
      if (!res || !res.ok) debugLog(`draw(${slot}): la respuesta no fue ok`);
    });
  }

  function renderHotbar() {
    hotbarGrid.innerHTML = currentSlots.map((slot, i) => {
      const n = i + 1;
      if (!slot) {
        return `<div class="cell" data-slot="${n}"><span class="cell-num">${n}</span></div>`;
      }

      const isWeapon = slot.kind === "weapon";
      const icon = isWeapon
        ? `<img class="cell-icon" src="weapons/${slot.icon}" onerror="this.style.display='none'" />`
        : `<span class="cell-icon cell-icon-text">${escapeHtml(slot.label)}</span>`;
      const badge = isWeapon ? slot.ammo : `x${slot.count}`;

      return `
        <div class="cell filled ${isWeapon ? "" : "item"}" data-slot="${n}">
          <span class="cell-num">${n}</span>
          ${icon}
          ${isWeapon ? `<span class="cell-label">${escapeHtml(slot.label)}</span>` : ""}
          <span class="cell-ammo">${badge}</span>
        </div>
      `;
    }).join("");

    hotbarGrid.querySelectorAll(".cell").forEach((cell) => {
      const slot = Number(cell.dataset.slot);

      cell.addEventListener("click", () => {
        debugLog(`click en casilla ${slot} (pointerDragging=${pointerDragging})`);
        if (pointerDragging) return;
        drawHotbarSlot(slot);
      });

      cell.addEventListener("mousedown", (e) => {
        if (!cell.classList.contains("filled")) return;
        e.preventDefault();
        dragFrom = slot;
        dragStartX = e.clientX;
        dragStartY = e.clientY;
        pointerDragging = false;
        cell.classList.add("dragging");
      });
    });
  }

  document.addEventListener("mousemove", (e) => {
    if (dragFrom === null) return;

    if (!pointerDragging) {
      const dx = e.clientX - dragStartX;
      const dy = e.clientY - dragStartY;
      if (Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return;
      pointerDragging = true;
      debugLog(`arrastre real detectado desde casilla ${dragFrom} (dist=${Math.hypot(dx, dy).toFixed(1)}px)`);
    }

    hotbarGrid.querySelectorAll(".cell").forEach((c) => c.classList.remove("dragover"));
    const under = document.elementFromPoint(e.clientX, e.clientY);
    const targetCell = under && under.closest(".cell");
    if (targetCell && Number(targetCell.dataset.slot) !== dragFrom) {
      targetCell.classList.add("dragover");
    }
  });

  document.addEventListener("mouseup", (e) => {
    if (dragFrom === null) return;

    const from = dragFrom;
    debugLog(`mouseup: soltado desde casilla ${from} (pointerDragging=${pointerDragging})`);
    dragFrom = null;
    hotbarGrid.querySelectorAll(".cell").forEach((c) => c.classList.remove("dragging", "dragover"));

    const under = document.elementFromPoint(e.clientX, e.clientY);
    const targetCell = under && under.closest(".cell");
    const to = targetCell && Number(targetCell.dataset.slot);

    if (to && to !== from) {
      const tmp = currentSlots[from - 1];
      currentSlots[from - 1] = currentSlots[to - 1];
      currentSlots[to - 1] = tmp;
      renderHotbar();
      post("mk_inventory:hotbarReorder", { from, to });
    }

    // Deja pointerDragging=true un instante más para que el "click" que el
    // navegador dispara justo después de este mouseup no se cuele.
    setTimeout(() => { pointerDragging = false; }, 0);
  });

  // ============================================================
  // Teclado: ESC cierra, 1-9 sacan/usan la casilla correspondiente
  // ============================================================

  document.addEventListener("keydown", (e) => {
    if (root.classList.contains("hidden")) return;

    if (e.key === "Escape") {
      e.preventDefault();

      if (!screens.qty.classList.contains("hidden")) {
        pendingAction = null;
        showScreen("list");
      } else {
        post("mk_inventory:close", {});
      }
      return;
    }

    if (e.key === "Enter" && !screens.qty.classList.contains("hidden")) {
      e.preventDefault();
      el("btn-qty-confirm").click();
      return;
    }

    // 1-9 para sacar arma/usar item de la casilla correspondiente. Antes
    // esto se detectaba SOLO en Lua con IsDisabledControlJustPressed, pero
    // seguía sin funcionar (reportado varias veces) — se añade también aquí
    // como camino independiente: con la NUI enfocada, el teclado SÍ llega
    // de forma fiable a este listener (ya confirmado con Escape/Tab), así
    // que no depende de esa detección a nivel de control del juego. Solo
    // funciona en la pantalla de lista, no mientras se pide una cantidad
    // (ahí 1-9 son dígitos normales del input).
    if (!screens.qty.classList.contains("hidden")) return;
    if (e.repeat) return;
    const slot = Number(e.key);
    if (Number.isInteger(slot) && slot >= 1 && slot <= 9) {
      e.preventDefault();
      debugLog(`tecla ${slot} detectada en JS -> drawHotbarSlot`);
      drawHotbarSlot(slot);
    }
  });

  window.addEventListener("message", (event) => {
    const data = event.data || {};

    if (data.action === "open") {
      currentData = data.data;
      currentSlots = data.slots || [];
      activeTab = "items";
      setActiveTab("items");
      renderWeight();
      renderHotbar();
      showScreen("list");
      root.classList.remove("hidden");
    }

    if (data.action === "refresh") {
      currentData = data.data;
      currentSlots = data.slots || [];
      renderHotbar();
      // Si estaba en medio de pedir una cantidad, no lo interrumpimos con
      // un re-render de la lista — solo se actualizan los datos de fondo.
      if (screens.list.classList.contains("hidden")) return;
      renderList();
      renderWeight();
    }

    if (data.action === "close") {
      root.classList.add("hidden");
      pendingAction = null;
      showScreen("list");
    }
  });
})();
