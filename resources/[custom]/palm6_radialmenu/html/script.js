/*
  palm6_radialmenu — html/script.js

  Single IIFE, vanilla JS, no framework, no bundler — palm6_ui idiom. Real trigonometry
  for wedge layout (see buildWedgePath), CSS-driven easing/stagger, breadcrumb state
  machine over `stack`.

  NUI message contract (exact names, final):
    Lua -> JS   SendNUIMessage({ action: 'open',  tree, accent })
    Lua -> JS   SendNUIMessage({ action: 'close' })                  -- forced close
    JS  -> Lua  fetch https://${RESOURCE_NAME}/select  { key, id, event }
                  key   = node.nodeKey, the tree path Lua stamped on when it built the
                          tree. The ONLY field Lua dispatches from.
                  event = cross-check only; Lua compares it to its own stored node.
                  eventType/args are deliberately NOT sent - Lua reads them off its own
                  tree so a forged POST cannot choose them.
    JS  -> Lua  fetch https://${RESOURCE_NAME}/close   {}
    Lua callbacks RegisterNUICallback('select', ...) / ('close', ...) must cb('ok') or
    CEF's fetch hangs.
*/
(() => {
  "use strict";

  const RESOURCE_NAME = window.GetParentResourceName ? GetParentResourceName() : "palm6_radialmenu";
  const CLOSE_ANIMATION_MS = 180;   // must equal --radial-close-ms
  const STAGGER_MS = 22;            // must equal --radial-stagger-ms
  const SELECT_PULSE_MS = 80;

  // Fixed allowlist of <symbol id="icon-*"> defined in html/index.html's <defs>. Any
  // item.icon not in this set falls back to "dot" — icon names are never string-
  // concatenated into innerHTML, only used to build a validated href for <use>.
  const ICON_ALLOWLIST = new Set([
    "car", "user", "lock", "wrench", "emote", "badge", "grid", "back", "dot",
  ]);

  const SVG_NS = "http://www.w3.org/2000/svg";

  const wedgeLayerEl = document.getElementById("wedge-layer");
  const hubTitleEl = document.getElementById("radial-hub-title");
  const hubBreadcrumbEl = document.getElementById("radial-hub-breadcrumb");

  let stack = [];          // breadcrumb: stack[0] = root, stack[last] = level on screen
  let currentTree = null;
  let currentWedges = [];  // [{ el, item, isBack }] for the level currently on screen, in
                            // sector order — drives keyboard nav
  let hoverIndex = -1;
  let isTransitioning = false;

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || typeof data.action !== "string") return;
    if (data.action === "open") openMenu(data);
    else if (data.action === "close") forceClose();
  });

  document.addEventListener("keydown", (e) => {
    if (!document.body.classList.contains("is-open")) return;

    if (e.key === "Escape") {
      requestClose();
    } else if (e.key === "Backspace") {
      onBack();
    } else if (e.key === "Enter" || e.key === " ") {
      if (hoverIndex >= 0 && currentWedges[hoverIndex]) {
        activateWedge(currentWedges[hoverIndex]);
      }
    } else if (e.key === "ArrowRight" || e.key === "ArrowDown") {
      moveHover(1);
    } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
      moveHover(-1);
    }
  });

  // ---------------------------------------------------------------------------------
  // Open / close
  // ---------------------------------------------------------------------------------

  function openMenu(data) {
    currentTree = data.tree;
    const accent = data.accent || "#d6a950";
    document.documentElement.style.setProperty("--accent", accent);
    const rgb = hexToRgb(accent);
    if (rgb) document.documentElement.style.setProperty("--accent-rgb", rgb);

    stack = [currentTree];
    document.body.classList.add("is-open");
    renderLevel(stack[stack.length - 1]);
  }

  function closeMenu() {
    document.body.classList.remove("is-open");
    clearWedges();
    stack = [];
    currentTree = null;
  }

  // Forced close from Lua (e.g. player got cuffed mid-menu) — no fetch back, Lua already
  // knows.
  function forceClose() {
    closeMenu();
  }

  // ---------------------------------------------------------------------------------
  // Trigonometry / rendering — angleStep derives generically from sectorCount; the
  // wedge-gap is subtracted symmetrically inside buildWedgePath, never baked into a
  // fixed per-item constant.
  // ---------------------------------------------------------------------------------

  const INNER_R = 92;   // must match --radial-inner
  const OUTER_R = 220;  // radial-root viewBox half-extent minus a small margin
  const GAP_DEG = 3;    // must match --radial-wedge-gap

  function clearWedges() {
    while (wedgeLayerEl.firstChild) wedgeLayerEl.removeChild(wedgeLayerEl.firstChild);
    currentWedges = [];
    hoverIndex = -1;
  }

  function renderLevel(node) {
    clearWedges();

    const items = Array.isArray(node.items) ? node.items : [];
    const hasBack = stack.length > 1;
    const sectorCount = items.length + (hasBack ? 1 : 0);

    hubTitleEl.textContent = node.title || "";

    // The breadcrumb is the path TO here, not including here. It used to be
    // `stack.map(title)`, which at the root level is a one-element stack - so
    // the hub printed the same word twice, stacked ("Interactions" over
    // "INTERACTIONS"). At the root there is no path yet, so it shows the way
    // out instead, which is the one thing a player on a radial menu needs to
    // know and nothing on screen was saying.
    const ancestors = stack.slice(0, -1).map((n) => n.title || "").filter(Boolean);
    hubBreadcrumbEl.textContent = ancestors.length ? ancestors.join(" / ") : "Esc to close";
    hubBreadcrumbEl.classList.toggle("is-hint", ancestors.length === 0);

    if (sectorCount === 0) {
      return;
    }

    const angleStep = 360 / sectorCount;

    items.forEach((item, i) => {
      const start = i * angleStep;
      const end = start + angleStep;
      const wedge = buildWedge(item, start, end, i, false);
      currentWedges.push(wedge);
    });

    if (hasBack) {
      const start = items.length * angleStep;
      const end = start + angleStep;
      const wedge = buildBackWedge(start, end, items.length);
      currentWedges.push(wedge);
    }
  }

  // Returns false when it refused because another transition is already in
  // flight — the caller must then undo whatever it did in anticipation (see
  // onSelect's stack push).
  function transitionToLevel(node) {
    if (isTransitioning) return false;
    isTransitioning = true;

    const outgoing = Array.from(wedgeLayerEl.children);
    if (outgoing.length === 0) {
      renderLevel(node);
      isTransitioning = false;
      return true;
    }

    let remaining = outgoing.length;
    outgoing.forEach((el) => {
      el.classList.add("is-leaving");
      el.style.animationDelay = "0ms";
    });

    const onDone = () => {
      remaining -= 1;
      if (remaining > 0) return;
      renderLevel(node);
      isTransitioning = false;
    };

    // transitionend doesn't fire on CSS animations — use animationend, with a timeout
    // fallback in case an element is removed mid-flight and never fires it.
    outgoing.forEach((el) => {
      el.addEventListener("animationend", onDone, { once: true });
    });
    setTimeout(() => {
      if (remaining > 0) {
        remaining = 0;
        renderLevel(node);
        isTransitioning = false;
      }
    }, CLOSE_ANIMATION_MS + 40);

    return true;
  }

  function resolveIconId(name) {
    return ICON_ALLOWLIST.has(name) ? name : "dot";
  }

  function buildWedgePath(startDeg, endDeg, innerR, outerR, gapDeg) {
    const s = startDeg + gapDeg / 2;
    const e = endDeg - gapDeg / 2;
    const toRad = (deg) => (deg - 90) * (Math.PI / 180); // 0deg = 12 o'clock
    const p = (r, deg) => [r * Math.cos(toRad(deg)), r * Math.sin(toRad(deg))];
    const [x1, y1] = p(outerR, s);
    const [x2, y2] = p(outerR, e);
    const [x3, y3] = p(innerR, e);
    const [x4, y4] = p(innerR, s);
    const largeArc = (e - s) > 180 ? 1 : 0;
    return `M ${x1} ${y1} A ${outerR} ${outerR} 0 ${largeArc} 1 ${x2} ${y2} `
         + `L ${x3} ${y3} A ${innerR} ${innerR} 0 ${largeArc} 0 ${x4} ${y4} Z`;
  }

  function midpoint(startDeg, endDeg, radius) {
    const midDeg = (startDeg + endDeg) / 2;
    const rad = (midDeg - 90) * (Math.PI / 180);
    return [radius * Math.cos(rad), radius * Math.sin(rad)];
  }

  function makeWedgeGroup(startDeg, endDeg, index, extraClass) {
    const g = document.createElementNS(SVG_NS, "g");
    g.setAttribute("class", `radial-wedge${extraClass ? " " + extraClass : ""}`);
    g.style.animationDelay = `${index * STAGGER_MS}ms`;

    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("class", "radial-wedge-path");
    path.setAttribute("d", buildWedgePath(startDeg, endDeg, INNER_R, OUTER_R, GAP_DEG));
    g.appendChild(path);

    const iconSize = 26;
    const [iconX, iconY] = midpoint(startDeg, endDeg, (INNER_R + OUTER_R) / 2 - 14);
    const use = document.createElementNS(SVG_NS, "use");
    use.setAttribute("class", "radial-wedge-icon");
    use.setAttribute("width", String(iconSize));
    use.setAttribute("height", String(iconSize));
    use.setAttribute("x", String(iconX - iconSize / 2));
    use.setAttribute("y", String(iconY - iconSize / 2));
    g.appendChild(use);

    const [labelX, labelY] = midpoint(startDeg, endDeg, (INNER_R + OUTER_R) / 2 + 26);
    const label = document.createElementNS(SVG_NS, "text");
    label.setAttribute("class", "radial-wedge-label");
    label.setAttribute("x", String(labelX));
    label.setAttribute("y", String(labelY));
    g.appendChild(label);

    return { g, use, label };
  }

  function buildWedge(item, startDeg, endDeg, index, disabled) {
    const { g, use, label } = makeWedgeGroup(startDeg, endDeg, index, disabled ? "is-disabled" : "");
    use.setAttribute("href", `#icon-${resolveIconId(item.icon)}`);
    // textContent only, never innerHTML
    label.textContent = item.title || "";

    const wedge = { el: g, item, isBack: false };

    g.addEventListener("mouseenter", () => setHoverByEl(g));
    g.addEventListener("mouseleave", () => clearHoverIfMatches(g));
    g.addEventListener("click", () => activateWedge(wedge));

    wedgeLayerEl.appendChild(g);
    return wedge;
  }

  function buildBackWedge(startDeg, endDeg, index) {
    const { g, use, label } = makeWedgeGroup(startDeg, endDeg, index, "is-back");
    use.setAttribute("href", "#icon-back");
    label.textContent = "Back";

    const wedge = { el: g, item: null, isBack: true };

    g.addEventListener("mouseenter", () => setHoverByEl(g));
    g.addEventListener("mouseleave", () => clearHoverIfMatches(g));
    g.addEventListener("click", () => activateWedge(wedge));

    wedgeLayerEl.appendChild(g);
    return wedge;
  }

  // ---------------------------------------------------------------------------------
  // Selection / navigation
  // ---------------------------------------------------------------------------------

  function setHoverByEl(el) {
    const idx = currentWedges.findIndex((w) => w.el === el);
    setHoverIndex(idx);
  }

  function clearHoverIfMatches(el) {
    const idx = currentWedges.findIndex((w) => w.el === el);
    if (idx === hoverIndex) setHoverIndex(-1);
  }

  function setHoverIndex(idx) {
    if (hoverIndex >= 0 && currentWedges[hoverIndex]) {
      currentWedges[hoverIndex].el.classList.remove("is-hover");
    }
    hoverIndex = idx;
    if (hoverIndex >= 0 && currentWedges[hoverIndex]) {
      currentWedges[hoverIndex].el.classList.add("is-hover");
    }
  }

  function moveHover(delta) {
    if (currentWedges.length === 0) return;
    const next = hoverIndex < 0
      ? 0
      : (hoverIndex + delta + currentWedges.length) % currentWedges.length;
    setHoverIndex(next);
  }

  // THE OUTGOING LEVEL IS NOT CLICKABLE.
  //
  // For the ~180ms of p6-wedge-out, the leaving wedges were still live: the
  // `.is-leaving` rule overrode only `animation`, the animation fades opacity
  // (not visibility) and ends at scale(0.85), so a second click on the same
  // pixel re-hit a wedge that was on its way out. `.is-leaving` now also sets
  // pointer-events: none in style.css, and every activation path re-checks the
  // flag here so the keyboard route (Enter over currentWedges) is closed too.
  //
  // Three separate symptoms came from this one window: the breadcrumb read
  // "Interactions / Vehicle" with Vehicle as its own ancestor (onSelect pushed
  // to `stack` BEFORE calling transitionToLevel, whose own guard then bailed
  // and left the push behind), Back therefore needed two presses, and clicking
  // a stale LEAF fired its event for a level that was already closing - which
  // the AllowedEvents allowlist cannot stop, because the event is legitimate.
  function activateWedge(wedge) {
    if (isTransitioning) return;
    if (wedge.isBack) {
      onBack();
      return;
    }
    onSelect(wedge.item);
  }

  function onSelect(item) {
    if (isTransitioning) return;
    if (item.items && item.items.length) {
      stack.push(item);
      // Undo the push if the transition refused it. Belt and braces behind the
      // guard above: a push that outlives its transition is exactly the
      // corrupted breadcrumb described above, and it is invisible until a
      // player presses Back and nothing happens.
      if (!transitionToLevel(item)) stack.pop();
      return;
    }
    fireSelect(item);
  }

  function onBack() {
    if (isTransitioning) return;
    if (stack.length <= 1) return;
    const popped = stack.pop();
    if (!transitionToLevel(stack[stack.length - 1])) stack.push(popped);
  }

  function pulseSelecting(item) {
    const wedge = currentWedges.find((w) => w.item === item);
    if (wedge) wedge.el.classList.add("is-selecting");
  }

  // ---------------------------------------------------------------------------------
  // Lua <-> JS transport
  // ---------------------------------------------------------------------------------

  function fireSelect(item) {
    pulseSelecting(item); // .is-selecting, ~80ms
    setTimeout(async () => {
      try {
        await fetch(`https://${RESOURCE_NAME}/select`, {
          method: "POST",
          headers: { "Content-Type": "application/json; charset=UTF-8" },
          // `key` is the node's path in the tree Lua just sent us, stamped on
          // by collectEvents. It is the ONLY field Lua dispatches from; `event`
          // rides along purely as a cross-check it verifies against its own
          // stored node. Sending the event name as the identifier is what let
          // sibling leaves that share one event name (the qb idiom, one event
          // + different args) dispatch each other's arguments.
          body: JSON.stringify({
            key: item.nodeKey,
            id: item.id,
            event: item.event,
          }),
        });
      } catch (e) {
        console.debug("[palm6_radialmenu] select post failed (expected outside NUI)", e);
      }
      closeMenu();
    }, SELECT_PULSE_MS);
  }

  function requestClose() {
    document.body.classList.remove("is-open");
    setTimeout(async () => {
      try {
        await fetch(`https://${RESOURCE_NAME}/close`, {
          method: "POST",
          headers: { "Content-Type": "application/json; charset=UTF-8" },
          body: JSON.stringify({}),
        });
      } catch (e) {
        console.debug("[palm6_radialmenu] close post failed (expected outside NUI)", e);
      }
      clearWedges();
      stack = [];
      currentTree = null;
    }, CLOSE_ANIMATION_MS);
  }

  // ---------------------------------------------------------------------------------
  // Utils
  // ---------------------------------------------------------------------------------

  function hexToRgb(hex) {
    const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
    if (!m) return null;
    const r = parseInt(m[1], 16);
    const g = parseInt(m[2], 16);
    const b = parseInt(m[3], 16);
    return `${r}, ${g}, ${b}`;
  }

  // ---------------------------------------------------------------------------------
  // Browser-preview stub, per dossier convention — only runs with ?preview=1, never
  // fires inside the real NUI browser.
  // ---------------------------------------------------------------------------------

  // EVERY LEAF CARRIES `nodeKey`, BECAUSE THE REAL TREE DOES.
  //
  // Lua's collectEvents stamps each leaf with its path ('root/<i>:<id>/...')
  // on the way down, and that key is the only thing the select callback
  // dispatches from. A stub that omitted it would preview a menu whose clicks
  // post `key: undefined` — and, worse, would look correct while doing it.
  // A stub that agrees with the code instead of with the contract is how the
  // charselect preview kept three non-existent qbx_core fields alive through a
  // build and two adversarial reviews.
  const SAMPLE_TREE = {
    id: "root",
    title: "Interactions",
    icon: "grid",
    items: [
      {
        id: "vehicle", title: "Vehicle", icon: "car",
        items: [
          { id: "vehicle_lock", nodeKey: "root/1:vehicle/1:vehicle_lock", title: "Lock/Unlock", icon: "lock", event: "palm6_radialmenu:vehicleLock", eventType: "client" },
          { id: "vehicle_hood", nodeKey: "root/1:vehicle/2:vehicle_hood", title: "Hood", icon: "wrench", event: "palm6_radialmenu:vehicleHood", eventType: "client" },
        ],
      },
      {
        id: "player", title: "Player", icon: "user",
        items: [
          { id: "player_emotes", nodeKey: "root/2:player/1:player_emotes", title: "Emotes", icon: "emote", event: "palm6_radialmenu:openEmoteMenu", eventType: "client" },
          { id: "player_id", nodeKey: "root/2:player/2:player_id", title: "Show ID", icon: "badge", event: "palm6_radialmenu:showId", eventType: "client" },
        ],
      },
    ],
  };

  if (new URLSearchParams(location.search).get("preview") === "1") {
    openMenu({ action: "open", accent: "#d6a950", tree: SAMPLE_TREE });
  }
})();
