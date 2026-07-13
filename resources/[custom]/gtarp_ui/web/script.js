(() => {
  "use strict";

  const RESOURCE_NAME = "gtarp_ui";
  const CLOSE_ANIMATION_MS = 180;

  const overlay = document.getElementById("overlay");
  const panel = document.getElementById("panel");
  const tagElement = document.getElementById("panel-tag");
  const titleElement = document.getElementById("panel-title");
  const rowsElement = document.getElementById("rows");
  const closeButton = document.getElementById("close-button");

  let isOpen = false;
  let isClosing = false;
  let closeTimer = null;

  function clampByte(value) {
    return Math.max(0, Math.min(255, value));
  }

  function normalizeHexColor(value) {
    if (typeof value !== "string") {
      return "#D6A950";
    }

    let hex = value.trim();

    if (!hex.startsWith("#")) {
      hex = `#${hex}`;
    }

    if (/^#[0-9a-fA-F]{3}$/.test(hex)) {
      const r = hex[1];
      const g = hex[2];
      const b = hex[3];
      return `#${r}${r}${g}${g}${b}${b}`.toUpperCase();
    }

    if (/^#[0-9a-fA-F]{6}$/.test(hex)) {
      return hex.toUpperCase();
    }

    return "#D6A950";
  }

  function hexToRgb(hex) {
    const normalized = normalizeHexColor(hex);
    const numeric = Number.parseInt(normalized.slice(1), 16);

    return {
      r: clampByte((numeric >> 16) & 255),
      g: clampByte((numeric >> 8) & 255),
      b: clampByte(numeric & 255)
    };
  }

  function applyAccent(accent) {
    const safeAccent = normalizeHexColor(accent);
    const rgb = hexToRgb(safeAccent);

    document.documentElement.style.setProperty("--accent", safeAccent);
    document.documentElement.style.setProperty(
      "--accent-rgb",
      `${rgb.r}, ${rgb.g}, ${rgb.b}`
    );
  }

  function isSectionHeader(row) {
    const trimmed = row.trim();

    if (!trimmed) {
      return false;
    }

    if (
      trimmed.endsWith(":") &&
      trimmed.length <= 48 &&
      !trimmed.match(/^\d/)
    ) {
      return true;
    }

    if (
      trimmed.length <= 42 &&
      trimmed === trimmed.toUpperCase() &&
      /[A-Z]/.test(trimmed)
    ) {
      return true;
    }

    if (/^\[[^\]]+\]$/.test(trimmed)) {
      return true;
    }

    return false;
  }

  function renderRows(rows) {
    rowsElement.replaceChildren();

    const safeRows = Array.isArray(rows)
      ? rows.map((row) => String(row ?? ""))
      : [];

    safeRows.forEach((rowText) => {
      const row = document.createElement("div");
      row.className = "panel-row";

      if (!rowText.trim()) {
        row.classList.add("is-empty");
      } else if (isSectionHeader(rowText)) {
        row.classList.add("is-section");
      } else if (/^\s+/.test(rowText)) {
        row.classList.add("is-indented");
      }

      /*
       * textContent is intentional.
       * It prevents rows supplied by the game from injecting HTML.
       * CSS white-space: pre-wrap preserves leading spaces.
       */
      row.textContent = rowText;

      rowsElement.appendChild(row);
    });

    if (safeRows.length === 0) {
      const emptyRow = document.createElement("div");
      emptyRow.className = "panel-row";
      emptyRow.textContent = "No information available.";
      rowsElement.appendChild(emptyRow);
    }

    rowsElement.scrollTop = 0;
  }

  function showPanel(payload) {
    const tag = String(payload.tag ?? "CITY").trim() || "CITY";
    const title =
      String(payload.title ?? "Palm6 Information").trim() ||
      "Palm6 Information";

    const rows = Array.isArray(payload.rows)
      ? payload.rows
      : [];

    const isSingle = payload.single === true;

    clearTimeout(closeTimer);

    isClosing = false;
    isOpen = true;

    applyAccent(payload.accent);

    tagElement.textContent = tag;
    titleElement.textContent = title;

    panel.classList.toggle("is-single", isSingle);
    renderRows(rows);

    overlay.classList.remove("is-closing");
    overlay.classList.add("is-mounted");
    overlay.setAttribute("aria-hidden", "false");

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        overlay.classList.add("is-visible");
        panel.focus({ preventScroll: true });
      });
    });
  }

  function hidePanelImmediately() {
    clearTimeout(closeTimer);

    isOpen = false;
    isClosing = false;

    overlay.classList.remove(
      "is-visible",
      "is-closing",
      "is-mounted"
    );

    overlay.setAttribute("aria-hidden", "true");
  }

  async function postCloseCallback() {
    try {
      await fetch(`https://${RESOURCE_NAME}/close`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=UTF-8"
        },
        body: JSON.stringify({})
      });
    } catch (error) {
      /*
       * This can fail in a normal browser preview because the FiveM
       * callback endpoint only exists inside NUI.
       */
      console.debug("Palm6 close callback unavailable:", error);
    }
  }

  function requestClose() {
    if (!isOpen || isClosing) {
      return;
    }

    isClosing = true;

    overlay.classList.remove("is-visible");
    overlay.classList.add("is-closing");

    postCloseCallback();

    closeTimer = window.setTimeout(() => {
      hidePanelImmediately();
    }, CLOSE_ANIMATION_MS);
  }

  closeButton.addEventListener("click", requestClose);

  window.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !isOpen) {
      return;
    }

    event.preventDefault();
    requestClose();
  });

  window.addEventListener("message", (event) => {
    const data = event.data;

    if (!data || typeof data !== "object") {
      return;
    }

    if (data.action === "show") {
      showPanel(data);
      return;
    }

    /*
     * Optional internal hide support.
     * The required game contract only needs action: "show".
     */
    if (data.action === "hide" || data.action === "close") {
      hidePanelImmediately();
    }
  });

  /*
   * Useful for Chromium browser previews.
   * It does not display anything unless ?preview=1 is present.
   */
  const previewEnabled =
    new URLSearchParams(window.location.search).get("preview") === "1";

  if (previewEnabled) {
    showPanel({
      action: "show",
      tag: "Wanted",
      accent: "#D6A950",
      title: "Verano Most Wanted",
      rows: [
        "ACTIVE WARRANTS",
        "1. JDoe  -  Armed robbery x3",
        "   Bounty: $85,000",
        "   Last seen: Bayside Marina",
        "",
        "2. CStone  -  Vehicle theft",
        "   Bounty: $42,500",
        "   Last seen: Sundown Boulevard",
        "",
        "PUBLIC ADVISORY:",
        "Do not approach. Contact law enforcement."
      ],
      single: false
    });
  }
})();
