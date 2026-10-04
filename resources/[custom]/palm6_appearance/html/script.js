(() => {
  "use strict";

  const RESOURCE_NAME = "palm6_appearance";
  const CLOSE_ANIMATION_MS = 180;
  const SENS_YAW = 0.28;
  const SENS_PITCH = 0.22;
  const ZOOM_STEP = 0.12;

  // ---- DOM refs ---------------------------------------------------------

  const overlay = document.getElementById("overlay");
  const hitzone = document.getElementById("viewport-hitzone");
  const regionTabs = document.getElementById("camera-region-tabs");
  const panelTitle = document.getElementById("panel-title");

  const faceFeatureList = document.getElementById("face-feature-list");
  const overlayList = document.getElementById("overlay-list");
  const wardrobeComponents = document.getElementById("wardrobe-components");
  const wardrobeProps = document.getElementById("wardrobe-props");
  const hairColorGrid = document.getElementById("hair-color-grid");
  const hairHighlightGrid = document.getElementById("hair-highlight-grid");
  const eyeColorGrid = document.getElementById("eye-color-grid");

  const panelTabs = document.getElementById("panel-tabs");
  const panelBody = document.getElementById("panel-body");

  const randomizeBtn = document.getElementById("randomize-btn");
  const randomizeAllBtn = document.getElementById("randomize-all-btn");
  const clearTattoosBtn = document.getElementById("clear-tattoos-btn");
  const saveBtn = document.getElementById("save-btn");
  const cancelBtn = document.getElementById("cancel-btn");
  const resetBtn = document.getElementById("reset-btn");

  const blendSliderIds = [
    "shapeFirst", "shapeSecond", "shapeThird",
    "skinFirst", "skinSecond", "skinThird",
    "shapeMix", "skinMix", "thirdMix",
  ];

  // ---- State --------------------------------------------------------------

  let isOpen = false;
  let isClosing = false;
  let isDragging = false;
  let lastX = 0;
  let lastY = 0;
  let dragRafPending = false;
  let pendingDelta = { yaw: 0, pitch: 0 };

  let regions = [];
  let activeRegion = "whole";
  let currentMode = "create";

  // ---- NUI post helper ------------------------------------------------------

  function postNuiCallback(name, body) {
    try {
      fetch(`https://${RESOURCE_NAME}/${name}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(body || {}),
      }).catch((err) => console.debug(`[palm6_appearance] ${name} failed`, err));
    } catch (err) {
      console.debug(`[palm6_appearance] ${name} threw`, err);
    }
  }

  // ---- Build: camera region tabs --------------------------------------------

  function buildRegionTabs(regionList) {
    regionTabs.textContent = "";
    regionList.forEach((region) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "region-tab" + (region === activeRegion ? " active" : "");
      btn.dataset.region = region;

      const underline = document.createElement("span");
      underline.className = "tab-underline";
      btn.appendChild(underline);

      const label = document.createElement("span");
      label.textContent = region.charAt(0).toUpperCase() + region.slice(1);
      btn.appendChild(label);

      btn.addEventListener("click", () => {
        setActiveRegionTab(region);
        postNuiCallback("setCameraFocus", { region });
      });

      regionTabs.appendChild(btn);
    });
  }

  function setActiveRegionTab(region) {
    activeRegion = region;
    Array.from(regionTabs.children).forEach((child) => {
      child.classList.toggle("active", child.dataset.region === region);
    });
  }

  // ---- Panel section tabs ------------------------------------------------------
  //
  // Separate from the CAMERA region tabs above: those move the camera on the
  // ped (whole/head/torso/legs/shoes), these switch which editor section the
  // panel is showing. The panel was previously one flat scroll containing every
  // section at once - measured at 1885px of content in a 945px panel, with the
  // save bar for a MANDATORY step sitting ~940px below the fold.
  //
  // The camera follows the section, because they line up: editing the face
  // while the camera is framing shoes is a pointless extra click. Wardrobe and
  // Colors keep whatever framing the player chose, since both touch the whole
  // body.
  const SECTION_CAMERA = {
    "head-blend-panel": "head",
    "wardrobe-panel": "whole",     // you judge an outfit on the whole body
    "appearance-colors": "head",   // hair and eye colour are head features
    "tattoos-panel": "torso",
  };

  function setActiveSection(sectionId) {
    if (!panelTabs || !panelBody) return;

    Array.from(panelTabs.querySelectorAll(".panel-tab")).forEach((tab) => {
      tab.classList.toggle("is-active", tab.dataset.section === sectionId);
      tab.setAttribute("aria-selected", tab.dataset.section === sectionId ? "true" : "false");
    });

    Array.from(panelBody.querySelectorAll(".panel-section")).forEach((section) => {
      section.hidden = section.id !== sectionId;
    });

    // A section swap should start at the top of that section, not wherever the
    // previous one was scrolled to.
    panelBody.scrollTop = 0;

    const region = SECTION_CAMERA[sectionId];
    if (region) {
      setActiveRegionTab(region);
      postNuiCallback("setCameraFocus", { region });
    }
  }

  if (panelTabs) {
    panelTabs.addEventListener("click", (ev) => {
      const tab = ev.target.closest(".panel-tab");
      if (tab && tab.dataset.section) setActiveSection(tab.dataset.section);
    });
  }

  // ---- Build: face feature sliders -------------------------------------------

  function buildFaceFeatures(faceFeatures, labels) {
    faceFeatureList.textContent = "";
    const count = 20;
    for (let i = 0; i < count; i++) {
      const row = document.createElement("div");
      row.className = "blend-row";

      const label = document.createElement("label");
      label.textContent = (labels && labels[i]) || `Feature ${i + 1}`;
      row.appendChild(label);

      const input = document.createElement("input");
      input.type = "range";
      input.min = "-1";
      input.max = "1";
      input.step = "0.01";
      input.value = (faceFeatures && faceFeatures[i]) || 0;
      input.dataset.index = String(i);
      input.addEventListener("input", () => {
        postNuiCallback("setFaceFeature", { index: i, value: parseFloat(input.value) });
      });
      row.appendChild(input);

      faceFeatureList.appendChild(row);
    }
  }

  // ---- Build: overlays --------------------------------------------------------

  function buildOverlays(overlayDefs, currentOverlays) {
    overlayList.textContent = "";
    (overlayDefs || []).forEach((def) => {
      const state = (currentOverlays && currentOverlays[def.id]) || { index: 0, opacity: 0 };
      // Mutable, shared between the variant arrows and the opacity slider
      // below so an opacity change always sends whichever variant index the
      // player is currently on, not the one the row happened to render with.
      let currentIndex = state.index || 0;
      const variantCount = Math.max(def.count || 1, 1);

      const row = document.createElement("div");
      row.className = "blend-row overlay-row";

      const label = document.createElement("label");
      label.textContent = def.label;
      row.appendChild(label);

      // Variant picker — GetNumHeadOverlayValues-bounded (see client/main.lua),
      // so e.g. facial hair/makeup patterns are actually choosable, not stuck
      // on whatever index the ped happened to load with (opacity-only control
      // was the entire exposed surface before this).
      if (variantCount > 1) {
        const variantRow = document.createElement("div");
        variantRow.className = "cycle-controls overlay-variant";

        const prev = document.createElement("button");
        prev.type = "button";
        prev.className = "cycle-arrow";
        prev.textContent = "‹";
        prev.setAttribute("aria-label", `Previous ${def.label} style`);

        const count = document.createElement("span");
        count.className = "cycle-count";
        count.textContent = `${currentIndex + 1} / ${variantCount}`;

        const next = document.createElement("button");
        next.type = "button";
        next.className = "cycle-arrow";
        next.textContent = "›";
        next.setAttribute("aria-label", `Next ${def.label} style`);

        const stepVariant = (dir) => {
          currentIndex = (currentIndex + dir + variantCount) % variantCount;
          count.textContent = `${currentIndex + 1} / ${variantCount}`;
          postNuiCallback("setHeadOverlay", { overlayId: def.id, index: currentIndex, opacity: parseFloat(input.value) });
        };
        prev.addEventListener("click", () => stepVariant(-1));
        next.addEventListener("click", () => stepVariant(1));

        variantRow.appendChild(prev);
        variantRow.appendChild(count);
        variantRow.appendChild(next);
        row.appendChild(variantRow);
      }

      const input = document.createElement("input");
      input.type = "range";
      input.min = "0";
      input.max = "1";
      input.step = "0.01";
      input.value = state.opacity || 0;
      input.addEventListener("input", () => {
        postNuiCallback("setHeadOverlay", {
          overlayId: def.id,
          index: currentIndex,
          opacity: parseFloat(input.value),
        });
      });
      row.appendChild(input);

      // Color picker — def.hasColor overlays (makeup, lipstick, blush,
      // eyebrows, facial hair) had NO way to set a color at all before this;
      // setHeadOverlayColor existed server-side with zero caller. Reuses the
      // same swatch-grid idiom as hair/eye color for a consistent feel.
      if (def.hasColor) {
        const colorGrid = document.createElement("div");
        colorGrid.className = "swatch-grid overlay-swatch-grid";
        row.appendChild(colorGrid);
        // colorType 1 is the HAIR colour table (this is what the apply call
        // below has always passed), so these swatches are painted from the
        // same live hair palette the Hair Color grid uses - a swatch has to
        // show the colour it applies. Falls back to neutral swatches when the
        // palette is unavailable.
        buildSwatchGrid(colorGrid, {
          total: hairPalette.length || 64,
          selectedId: state.color1 != null ? state.color1 : 0,
          colorFor: hairSwatchColor,
          onSelect: (colorId) => {
            postNuiCallback("setHeadOverlayColor", {
              overlayId: def.id,
              colorType: 1,
              colorIndex: colorId,
              secondColorIndex: colorId,
            });
          },
        });
      }

      overlayList.appendChild(row);
    });
  }

  // ---- Build: wardrobe cycle rows ----------------------------------------------

  function formatCycleCount(state, kind) {
    if (!state) return "0 / 0";
    if (kind === "prop" && !state.active) {
      return state.drawableCount ? `None / ${state.drawableCount}` : "0 / 0";
    }
    const count = Math.max(state.drawableCount || 0, 1);
    return `${(state.drawableId || 0) + 1} / ${count}`;
  }

  function buildCycleRow(kind, id, label, initialState) {
    const row = document.createElement("div");
    row.className = "cycle-row";
    row.dataset.kind = kind;
    row.dataset.id = String(id);

    const labelEl = document.createElement("span");
    labelEl.className = "cycle-label";
    labelEl.textContent = label;
    row.appendChild(labelEl);

    const controls = document.createElement("div");
    controls.className = "cycle-controls";

    const prev = document.createElement("button");
    prev.type = "button";
    prev.className = "cycle-arrow";
    prev.textContent = "‹";
    prev.setAttribute("aria-label", `Previous ${label}`);

    const count = document.createElement("span");
    count.className = "cycle-count";
    count.textContent = formatCycleCount(initialState, kind);

    const next = document.createElement("button");
    next.type = "button";
    next.className = "cycle-arrow";
    next.textContent = "›";
    next.setAttribute("aria-label", `Next ${label}`);

    const callbackName = kind === "prop" ? "cycleProp" : "cycleComponent";
    const idKey = kind === "prop" ? "propId" : "componentId";

    prev.addEventListener("click", () => postNuiCallback(callbackName, { [idKey]: id, direction: -1 }));
    next.addEventListener("click", () => postNuiCallback(callbackName, { [idKey]: id, direction: 1 }));

    controls.appendChild(prev);
    controls.appendChild(count);
    controls.appendChild(next);
    row.appendChild(controls);

    // ---- Texture / colourway row --------------------------------------------
    //
    // THIS IS THE SINGLE LARGEST WARDROBE GAP THIS EDITOR HAD. Base-game
    // clothing is drawable + TEXTURE (the colourways), and only the drawable
    // was reachable: `cycleTexture` was registered in Lua with zero callers and
    // `cyclePropTexture` had no callback at all, while wardrobe.lua resets to
    // texture 0 on every drawable change - so the first arrow press stripped
    // whatever colourway was on the ped and nothing could bring it back. Every
    // wardrobeState message has always carried textureId/textureCount; the UI
    // simply threw both away. The README claimed "cycles drawables/textures".
    //
    // Rendered for every slot and hidden when the current drawable has fewer
    // than two colourways, so it appears exactly when it can do something.
    const texRow = document.createElement("div");
    texRow.className = "cycle-subrow";

    const texLabel = document.createElement("span");
    texLabel.className = "cycle-sublabel";
    texLabel.textContent = "Colour";
    texRow.appendChild(texLabel);

    const texControls = document.createElement("div");
    texControls.className = "cycle-controls";

    const texPrev = document.createElement("button");
    texPrev.type = "button";
    texPrev.className = "cycle-arrow";
    texPrev.textContent = "‹";
    texPrev.setAttribute("aria-label", `Previous ${label} colour`);

    const texCount = document.createElement("span");
    texCount.className = "cycle-count";

    const texNext = document.createElement("button");
    texNext.type = "button";
    texNext.className = "cycle-arrow";
    texNext.textContent = "›";
    texNext.setAttribute("aria-label", `Next ${label} colour`);

    const texCallback = kind === "prop" ? "cyclePropTexture" : "cycleTexture";
    texPrev.addEventListener("click", () => postNuiCallback(texCallback, { [idKey]: id, direction: -1 }));
    texNext.addEventListener("click", () => postNuiCallback(texCallback, { [idKey]: id, direction: 1 }));

    texControls.appendChild(texPrev);
    texControls.appendChild(texCount);
    texControls.appendChild(texNext);
    texRow.appendChild(texControls);
    row.appendChild(texRow);

    updateTextureRow(row, initialState);

    return row;
  }

  // Shows the colourway row only when there is more than one colourway to pick,
  // and keeps its counter in step with the ped.
  function updateTextureRow(row, state) {
    const texRow = row.querySelector(".cycle-subrow");
    if (!texRow) return;
    const total = (state && typeof state.textureCount === "number") ? state.textureCount : 0;
    const current = (state && typeof state.textureId === "number") ? state.textureId : 0;
    texRow.hidden = !(total > 1);
    const counter = texRow.querySelector(".cycle-count");
    if (counter) counter.textContent = `${current + 1} / ${total}`;
  }

  function buildWardrobe(components, props, wardrobeState) {
    wardrobeComponents.textContent = "";
    wardrobeProps.textContent = "";

    const componentStateById = {};
    const propStateById = {};
    ((wardrobeState && wardrobeState.components) || []).forEach((entry) => { componentStateById[entry.id] = entry.state; });
    ((wardrobeState && wardrobeState.props) || []).forEach((entry) => { propStateById[entry.id] = entry.state; });

    (components || []).forEach((def) => {
      wardrobeComponents.appendChild(buildCycleRow("component", def.id, def.label, componentStateById[def.id]));
    });
    (props || []).forEach((def) => {
      wardrobeProps.appendChild(buildCycleRow("prop", def.id, def.label, propStateById[def.id]));
    });
  }

  function updateCycleRowCount(kind, id, index, count) {
    const row = document.querySelector(`.cycle-row[data-kind="${kind}"][data-id="${id}"]`);
    if (!row) return;
    const countEl = row.querySelector(".cycle-count");
    if (!countEl) return;
    countEl.textContent = formatCycleCount(
      { drawableId: index, drawableCount: count, active: index !== -1 },
      kind
    );
  }

  // ---- Build: color swatches -----------------------------------------------------

  // The REAL hair palette, sent by the Lua side from GET_PED_HAIR_RGB_COLOR
  // (client/main.lua buildOpenPayload -> Game.GetHairRgbPalette). Empty until
  // the first `open` message, and empty forever on a build where that native
  // is unavailable - which is why every path below has a neutral fallback.
  let hairPalette = [];

  // Was `hsl(i/total*360, 55%, 45%)` - a generated rainbow. GTA's 64 hair
  // colours are blacks, browns, blondes and reds with a block of unnatural
  // shades at the end, so the rainbow meant swatch 10 rendered lime green
  // while the hair it selects is brown. A player picks a colour by looking at
  // the swatch; the swatch has to be the colour.
  function hairSwatchColor(i) {
    const c = hairPalette[i];
    if (!c) return "rgba(255,255,255,0.12)";
    return `rgb(${c.r}, ${c.g}, ${c.b})`;
  }

  // OPTIONS OBJECT, NOT POSITIONAL ARGS - and that is a bug fix, not a style
  // preference. This used to be buildSwatchGrid(container, total, selectedId,
  // onSelect). Adding a `colorFor` parameter ahead of `onSelect` silently
  // repurposed the overlay call site's callback: `colorFor` became the
  // "apply this colour" function and `onSelect` became undefined. The result
  // was that BUILDING an overlay's colour grid called the apply-colour
  // callback 64 times - 192 spurious setHeadOverlayColor posts on open across
  // the three colour-capable overlays, leaving every one of them set to colour
  // 63 - the swatches rendered blank white (the callback returns nothing), and
  // clicking one threw on `onSelect is not a function`.
  //
  // Named options cannot be silently reordered, so the same mistake cannot
  // happen again. `colorFor` is optional and defaults to no paint.
  function buildSwatchGrid(container, opts) {
    const { total, selectedId, onSelect } = opts;
    const colorFor = typeof opts.colorFor === "function" ? opts.colorFor : () => null;
    if (typeof onSelect !== "function") {
      console.error("buildSwatchGrid: onSelect is required", container && container.className);
      return;
    }

    container.textContent = "";
    for (let i = 0; i < total; i++) {
      const swatch = document.createElement("button");
      swatch.type = "button";
      swatch.className = "swatch" + (i === selectedId ? " selected" : "");
      const paint = colorFor(i);
      if (paint) swatch.style.background = paint;
      swatch.dataset.colorId = String(i);
      swatch.title = `Colour ${i}`;
      swatch.setAttribute("aria-label", `Colour ${i}`);
      swatch.addEventListener("click", () => {
        Array.from(container.children).forEach((c) => c.classList.remove("selected"));
        swatch.classList.add("selected");
        onSelect(i);
      });
      container.appendChild(swatch);
    }
  }

  // LIVE hair colour state, module-scoped on purpose.
  //
  // These used to be the *parameters* of buildColorGrids, which is only called
  // at open - so both swatch grids closed over the values the screen STARTED
  // with. Pick hair 12, then a highlight: the highlight handler posted
  // `{colorId: <the value from open>, highlightColorId: 30}`, and
  // HeadBlend.SetHairColor writes BOTH unconditionally, so the hair snapped
  // back to its opening colour. The DOM kept the selected ring on 12 and the
  // saved payload took the clobbered value, so nothing on screen said so.
  // That is the ordinary create sequence, not an edge case.
  let currentHairColor = 0;
  let currentHairHighlight = 0;

  function buildColorGrids(hairColor, hairHighlight, eyeColor) {
    const hairCount = hairPalette.length || 64;
    currentHairColor = typeof hairColor === "number" ? hairColor : 0;
    currentHairHighlight = typeof hairHighlight === "number" ? hairHighlight : 0;

    buildSwatchGrid(hairColorGrid, {
      total: hairCount,
      selectedId: currentHairColor,
      colorFor: hairSwatchColor,
      onSelect: (colorId) => {
        currentHairColor = colorId;   // update BEFORE posting, so the pair sent is current
        postNuiCallback("setHairColor", { colorId: currentHairColor, highlightColorId: currentHairHighlight });
      },
    });

    buildSwatchGrid(hairHighlightGrid, {
      total: hairCount,
      selectedId: currentHairHighlight,
      colorFor: hairSwatchColor,
      onSelect: (colorId) => {
        currentHairHighlight = colorId;
        postNuiCallback("setHairColor", { colorId: currentHairColor, highlightColorId: currentHairHighlight });
      },
    });

    // EYE COLOUR IS NOT AN RGB VALUE. Eye colours are texture variations on
    // the eye, and the game exposes no getter that turns an index into a
    // colour - so any colour shown here would be invented. These render as
    // numbered chips instead of lying with a swatch (no colorFor).
    buildSwatchGrid(eyeColorGrid, {
      total: 32,
      selectedId: eyeColor,
      onSelect: (colorId) => postNuiCallback("setEyeColor", { colorId }),
    });
    Array.from(eyeColorGrid.children).forEach((chip, i) => {
      chip.classList.add("swatch--index");
      chip.textContent = String(i);
    });
  }

  // ---- Message handling (Lua -> JS) ------------------------------------------------

  window.addEventListener("message", (event) => {
    const data = event.data || {};
    switch (data.action) {
      case "open":
        handleOpen(data.payload);
        break;
      case "refresh":
        handleRefresh(data.payload);
        break;
      case "wardrobeState":
        handleWardrobeState(data.payload);
        break;
      case "tattooTiers":
        // No per-design detail view is scaffolded in this base panel (see
        // README.md "Tattoos: current scope") — this message has no UI
        // consumer yet, on purpose.
        break;

      case "tattoosCleared":
        if (clearTattoosBtn) {
          clearTattoosBtn.classList.add("is-confirmed");
          setTimeout(() => clearTattoosBtn.classList.remove("is-confirmed"), 900);
        }
        break;
      case "regionFocused":
        if (data.payload && data.payload.region) setActiveRegionTab(data.payload.region);
        break;
      case "close":
        closeScreen(false);
        break;
      default:
        break;
    }
  });

  // The control-rebuilding half of an open, split out so a REFRESH can reuse
  // it. Everything here re-seeds a control from the payload; nothing here
  // changes which tab you are on, where you are scrolled, or where the camera
  // is pointing. See handleRefresh.
  function rebuildControls(payload) {
    const ped = payload.ped || {};
    const blend = ped.headBlend || {};
    blendSliderIds.forEach((id) => {
      const el = document.getElementById(id);
      if (el && blend[id] !== undefined) el.value = blend[id];
    });

    // Must be set BEFORE buildColorGrids, which paints from it.
    hairPalette = Array.isArray(ped.hairPalette) ? ped.hairPalette : [];

    buildFaceFeatures(ped.faceFeatures || [], ped.faceFeatureLabels || []);
    buildOverlays(ped.overlayDefs || [], ped.overlays || {});
    buildWardrobe(ped.components || [], ped.props || [], ped.wardrobeState);
    buildColorGrids(ped.hairColor || 0, ped.hairHighlight || 0, ped.eyeColor || 0);
  }

  function handleOpen(payload) {
    if (!payload) return;
    currentMode = payload.mode || "create";
    regions = payload.regions || [];
    activeRegion = "whole";

    panelTitle.textContent = currentMode === "edit" ? "Edit Appearance" : "Create Your Character";
    cancelBtn.classList.toggle("mode-hidden", currentMode !== "edit");
    // Exactly one of Cancel / Reset is ever shown: edit mode can discard and
    // walk away, create mode cannot, so it gets the revert instead.
    resetBtn.classList.toggle("mode-hidden", currentMode !== "create");

    buildRegionTabs(regions);
    rebuildControls(payload);

    // Every open starts on Face with the other sections hidden. Without this
    // the markup's initial state shows ALL sections stacked (only the tab
    // chrome would look right), which is the flat mega-scroll this replaced.
    // Set before openScreen() so the panel never paints in the wrong state.
    setActiveSection("head-blend-panel");

    openScreen();
  }

  // Re-seed every control from a new payload WITHOUT touching where the player
  // is.
  //
  // Randomize, Randomize All and Reset all produce a new ped that the controls
  // have to catch up with, and all three used to do it by re-sending `open` -
  // which the NUI could not tell apart from a first open, so it ran
  // setActiveSection("head-blend-panel"): back to the Face tab, scroll zeroed,
  // and a setCameraFocus post that also reset the orbit distance. Those three
  // buttons live in the pinned save bar and are reachable from every tab, so
  // the actual experience was: randomize your whole outfit, and get zoomed to
  // your face with the outfit controls hidden.
  function handleRefresh(payload) {
    if (!payload) return;
    const scrollTop = panelBody ? panelBody.scrollTop : 0;
    rebuildControls(payload);
    // Rebuilding a section's children can shorten it enough to clamp the
    // scroll position, so it is restored rather than assumed intact.
    if (panelBody) panelBody.scrollTop = scrollTop;
  }

  function handleWardrobeState(payload) {
    if (!payload) return;
    // The colourway row is refreshed from the SAME message as the drawable
    // row - textureId/textureCount were always in this payload and were simply
    // discarded, which is half of why texture selection was unreachable.
    if (payload.componentId !== undefined) {
      updateCycleRowCount("component", payload.componentId, payload.drawableId, payload.drawableCount);
      const row = wardrobeComponents.querySelector(`.cycle-row[data-id="${payload.componentId}"]`);
      if (row) updateTextureRow(row, payload);
    } else if (payload.propId !== undefined) {
      const index = payload.active === false ? -1 : payload.drawableId;
      updateCycleRowCount("prop", payload.propId, index, payload.drawableCount);
      const row = wardrobeProps.querySelector(`.cycle-row[data-id="${payload.propId}"]`);
      // A cleared prop has no colourway to pick.
      if (row) updateTextureRow(row, payload.active === false ? null : payload);
    }
  }

  // ---- Open / close animation -------------------------------------------------------

  function openScreen() {
    isOpen = true;
    isClosing = false;
    overlay.classList.remove("hidden");
    overlay.setAttribute("aria-hidden", "false");
    // Force reflow so the opacity transition actually plays on first open.
    void overlay.offsetWidth;
    overlay.classList.add("visible");
  }

  function closeScreen(notifyLua) {
    if (!isOpen || isClosing) return;
    isClosing = true;
    overlay.classList.remove("visible");

    if (notifyLua) postNuiCallback("close", {});

    setTimeout(() => {
      overlay.classList.add("hidden");
      overlay.setAttribute("aria-hidden", "true");
      isOpen = false;
      isClosing = false;
    }, CLOSE_ANIMATION_MS);
  }

  // ---- Drag / orbit + zoom -------------------------------------------------------------

  hitzone.addEventListener("pointerdown", (event) => {
    isDragging = true;
    lastX = event.clientX;
    lastY = event.clientY;
    hitzone.classList.add("dragging");
    hitzone.setPointerCapture(event.pointerId);
  });

  hitzone.addEventListener("pointermove", (event) => {
    if (!isDragging) return;
    const deltaX = event.clientX - lastX;
    const deltaY = event.clientY - lastY;
    lastX = event.clientX;
    lastY = event.clientY;

    pendingDelta.yaw += deltaX * SENS_YAW;
    pendingDelta.pitch += -deltaY * SENS_PITCH;

    if (!dragRafPending) {
      dragRafPending = true;
      requestAnimationFrame(() => {
        postNuiCallback("rotateCamera", { deltaYaw: pendingDelta.yaw, deltaPitch: pendingDelta.pitch });
        pendingDelta = { yaw: 0, pitch: 0 };
        dragRafPending = false;
      });
    }
  });

  function endDrag(event) {
    if (!isDragging) return;
    isDragging = false;
    hitzone.classList.remove("dragging");
    try { hitzone.releasePointerCapture(event.pointerId); } catch (err) { /* no-op */ }
  }

  hitzone.addEventListener("pointerup", endDrag);
  hitzone.addEventListener("pointercancel", endDrag);

  hitzone.addEventListener("wheel", (event) => {
    event.preventDefault();
    postNuiCallback("zoomCamera", { delta: event.deltaY > 0 ? ZOOM_STEP : -ZOOM_STEP });
  }, { passive: false });

  // ---- Camera control buttons ----------------------------------------------------------
  //
  // Same two callbacks the drag and wheel gestures use, so there is exactly one
  // camera contract on the Lua side. Held buttons repeat, because a single
  // 12-degree nudge per click would make turning the ped a chore.

  const CAM_ACTIONS = {
    "rotate-left":  () => postNuiCallback("rotateCamera", { deltaYaw: -6, deltaPitch: 0 }),
    "rotate-right": () => postNuiCallback("rotateCamera", { deltaYaw: 6, deltaPitch: 0 }),
    "zoom-in":      () => postNuiCallback("zoomCamera", { delta: -ZOOM_STEP }),
    "zoom-out":     () => postNuiCallback("zoomCamera", { delta: ZOOM_STEP }),
  };

  const camControls = document.getElementById("camera-controls");
  if (camControls) {
    let repeatTimer = null;

    const stopRepeat = () => {
      if (repeatTimer) { clearInterval(repeatTimer); repeatTimer = null; }
    };

    camControls.addEventListener("pointerdown", (ev) => {
      const btn = ev.target.closest(".cam-btn");
      if (!btn) return;
      const action = CAM_ACTIONS[btn.dataset.cam];
      if (!action) return;
      action();
      stopRepeat();
      repeatTimer = setInterval(action, 60);
    });

    // Every way a press can end, including the pointer leaving the button
    // mid-hold - otherwise the camera keeps turning after the mouse is up.
    ["pointerup", "pointerleave", "pointercancel"].forEach((evt) => {
      camControls.addEventListener(evt, stopRepeat);
    });
    window.addEventListener("blur", stopRepeat);
  }

  // ---- Blend sliders ------------------------------------------------------------------

  blendSliderIds.forEach((id) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.addEventListener("input", () => {
      if (id === "shapeMix" || id === "skinMix" || id === "thirdMix") {
        postNuiCallback("setHeadBlendMix", { key: id, value: parseFloat(el.value) });
      } else {
        postNuiCallback("setHeadBlendParents", {
          shapeFirst: parseFloat(document.getElementById("shapeFirst").value),
          shapeSecond: parseFloat(document.getElementById("shapeSecond").value),
          shapeThird: parseFloat(document.getElementById("shapeThird").value),
          skinFirst: parseFloat(document.getElementById("skinFirst").value),
          skinSecond: parseFloat(document.getElementById("skinSecond").value),
          skinThird: parseFloat(document.getElementById("skinThird").value),
        });
      }
    });
  });

  // ---- Buttons ------------------------------------------------------------------------

  randomizeBtn.addEventListener("click", () => postNuiCallback("randomizeHeadBlend", {}));
  randomizeAllBtn.addEventListener("click", () => postNuiCallback("randomizeAll", {}));
  if (clearTattoosBtn) clearTattoosBtn.addEventListener("click", () => postNuiCallback("clearTattoos", {}));
  saveBtn.addEventListener("click", () => {
    postNuiCallback("save", {});
    closeScreen(false);
  });
  cancelBtn.addEventListener("click", () => {
    if (currentMode !== "edit") return;
    postNuiCallback("cancel", {});
    closeScreen(false);
  });

  // Reverts the ped to exactly how it looked when this screen opened. Does NOT
  // close the screen - it is an undo, not an exit. The Lua side re-applies the
  // payload it captured at open and re-sends `open`, which rebuilds every
  // control from the reverted ped, so the sliders and swatches match what is
  // actually on the model rather than what the player last dragged.
  resetBtn.addEventListener("click", () => {
    if (currentMode !== "create") return;
    postNuiCallback("reset", {});
  });

  // ---- Escape handling ------------------------------------------------------------------

  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && isOpen && currentMode === "edit") {
      postNuiCallback("cancel", {});
      closeScreen(false);
    }
  });

  // ---- Standalone preview stub (?preview=1) ----------------------------------------------

  if (window.location.search.includes("preview=1")) {
    // PREVIEW ONLY. In game this page is a transparent surface over the live
    // 3D view (the stylesheet forces `background: transparent !important`), so
    // in a browser it renders on white and light-on-light chrome cannot be
    // judged. Stands in for the world behind the UI. Built here, in the
    // ?preview=1 branch, so it can never reach a running server.
    const backdrop = document.createElement("div");
    backdrop.style.cssText = [
      "position:fixed", "inset:0", "z-index:-1", "pointer-events:none",
      "background:radial-gradient(120% 90% at 38% 25%, #23384d 0%, #101c28 45%, #05090e 100%)",
    ].join(";");
    document.body.appendChild(backdrop);

    handleOpen({
      mode: "create",
      accent: "gold",
      regions: ["whole", "head", "torso", "legs", "shoes"],
      ped: {
        gender: "male",
        headBlend: {
          shapeFirst: 0, shapeSecond: 0, shapeThird: 0,
          skinFirst: 0, skinSecond: 0, skinThird: 0,
          shapeMix: 0.5, skinMix: 0.5, thirdMix: 0.0,
        },
        faceFeatures: new Array(20).fill(0),
        // THE STUB MUST MATCH THE REAL PAYLOAD. Everything below mirrors what
        // client/main.lua's buildOpenPayload actually sends: the real trait
        // names from Config.FaceFeatureLabels (this stub used to send none, so
        // the preview rendered "Feature 1".."Feature 20" - the exact label
        // problem an earlier pass had already fixed in the game path, still
        // visible here), the real component slots from
        // Config.WardrobeComponents, and overlayDefs carrying the `count` and
        // `hasColor` fields the variant cycler and colour picker key off. A
        // stub that agrees with the code instead of with the payload is how
        // the palm6_charselect field bug survived two reviews.
        faceFeatureLabels: [
          "Nose Width", "Nose Peak Height", "Nose Peak Length", "Nose Bone Curveness",
          "Nose Peak Lowering", "Nose Bone Twist", "Eyebrow Height", "Eyebrow Depth",
          "Cheekbone Height", "Cheekbone Width", "Cheeks Width", "Eyes Opening",
          "Lips Thickness", "Jaw Bone Width", "Jaw Bone Shape", "Chin Bone Height",
          "Chin Bone Length", "Chin Bone Shape", "Chin Hole", "Neck Thickness",
        ],
        overlays: {
          2: { index: 3, opacity: 0.9, color1: 1, color2: 1 },
          1: { index: 0, opacity: 0.0 },
        },
        overlayDefs: [
          { id: 2, key: "eyebrows", label: "Eyebrows", hasColor: true, count: 34 },
          { id: 1, key: "beard", label: "Facial Hair", hasColor: true, count: 28 },
          { id: 4, key: "makeup", label: "Makeup", hasColor: true, count: 74 },
          { id: 3, key: "ageing", label: "Ageing", hasColor: false, count: 14 },
          { id: 6, key: "blemishes", label: "Blemishes", hasColor: false, count: 11 },
        ],
        components: [
          { id: 2,  key: "hair",       label: "Hairstyle" },
          { id: 1,  key: "mask",       label: "Mask" },
          { id: 3,  key: "torso",      label: "Torso" },
          { id: 4,  key: "legs",       label: "Legs" },
          { id: 6,  key: "shoes",      label: "Shoes" },
          { id: 8,  key: "undershirt", label: "Undershirt" },
          { id: 11, key: "jacket",     label: "Jacket / Top" },
        ],
        props: [
          { id: 0, key: "hat",       label: "Hat" },
          { id: 1, key: "glasses",   label: "Glasses" },
          { id: 2, key: "ears",      label: "Earrings" },
          { id: 6, key: "watch",     label: "Watch" },
          { id: 7, key: "bracelet",  label: "Bracelet" },
        ],
        hairColor: 0,
        hairHighlight: 0,
        eyeColor: 0,
        // Stand-in for what GET_PED_HAIR_RGB_COLOR returns in game: GTA's hair
        // palette is blacks -> browns -> blondes -> greys -> reds, NOT a hue
        // wheel. Approximated here only so the browser preview shows the right
        // SHAPE of palette; the real values come from the game at runtime and
        // are never authored in this repo.
        hairPalette: Array.from({ length: 64 }, (_, i) => {
          if (i < 8)  return { r: 20 + i * 6,  g: 16 + i * 5,  b: 14 + i * 4 };   // blacks
          if (i < 20) return { r: 70 + i * 4,  g: 45 + i * 3,  b: 28 + i * 2 };   // browns
          if (i < 30) return { r: 200 + (i % 6) * 8, g: 175 + (i % 6) * 7, b: 120 + (i % 6) * 6 }; // blondes
          if (i < 40) return { r: 150 + (i % 5) * 9, g: 148 + (i % 5) * 9, b: 145 + (i % 5) * 9 }; // greys
          if (i < 48) return { r: 130 + (i % 6) * 12, g: 45 + (i % 6) * 4, b: 30 };  // reds
          return { r: 90 + (i % 8) * 16, g: 60 + (i % 5) * 20, b: 130 + (i % 7) * 15 }; // unnatural
        }),
      },
    });
  }
})();
