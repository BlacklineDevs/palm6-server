(() => {
  "use strict";

  const RESOURCE_NAME = "palm6_charselect";
  const CLOSE_ANIMATION_MS = 180;

  // Mirrors shared/config.lua Config.EntranceBaseDelayMs / EntranceStepMs /
  // SelectCameraDurationMs. Kept as consts here (rather than fetched at
  // runtime) because the NUI has no round-trip need for them beyond matching
  // the Lua-side animation timings.
  const ENTRANCE_BASE_DELAY_MS = 90;
  const ENTRANCE_STEP_MS = 55;
  const CINEMATIC_MS = 900;

  const overlay = document.getElementById("overlay");
  const charList = document.getElementById("charList");
  const createBtn = document.getElementById("createBtn");
  const playBtn = document.getElementById("playBtn");
  const deleteBtn = document.getElementById("deleteBtn");
  const slotCount = document.getElementById("slotCount");
  const navHint = document.getElementById("navHint");
  const statList = document.getElementById("statList");
  const nameplate = document.getElementById("nameplate");
  const npName = document.getElementById("npName");
  const npSub = document.getElementById("npSub");
  const pedFallback = document.getElementById("pedFallback");
  const fallbackInitials = document.getElementById("fallbackInitials");
  const loadingState = document.getElementById("loadingState");
  const errorBanner = document.getElementById("errorBanner");
  const errorText = document.getElementById("errorText");
  const createPanel = document.getElementById("createPanel");

  const fFirstname = document.getElementById("fFirstname");
  const fLastname = document.getElementById("fLastname");
  const fNationality = document.getElementById("fNationality");
  const fGender = document.getElementById("fGender");
  const fDob = document.getElementById("fDob");
  const createError = document.getElementById("createError");
  const createSubmit = document.getElementById("createSubmit");
  const createCancel = document.getElementById("createCancel");

  const deletePanel = document.getElementById("deletePanel");
  const deleteTargetName = document.getElementById("deleteTargetName");
  const deleteConfirmWord = document.getElementById("deleteConfirmWord");
  const deleteConfirmInput = document.getElementById("deleteConfirmInput");
  const deleteError = document.getElementById("deleteError");
  const deleteSubmit = document.getElementById("deleteSubmit");
  const deleteCancel = document.getElementById("deleteCancel");
  let deleteTargetCitizenid = null;

  let currentCharacters = [];
  let currentMaxSlots = 2;
  let currentNameRules = null;
  let errorTimer = null;

  const previewableIds = new Set();
  // citizenid -> total seconds played. Tracked by THIS resource in its own
  // table, because qbx_core does not track playtime anywhere (confirmed
  // against its real metadata defaults) - which is why the old hardcoded
  // "playtime" line on every card could never have shown a number.
  let playtimeByCitizenid = {};
  let focusedCitizenid = null;
  // Citizenid of the most recent stage request we SENT. Stage answers are
  // matched against this rather than against focusedCitizenid: the two are the
  // same today, but keying on "what did I ask for" is what makes a late answer
  // for a character the player has already arrowed past provably ignorable.
  let stageRequestId = null;

  document.documentElement.style.setProperty("--cinematic-ms", `${CINEMATIC_MS}ms`);

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  function post(endpoint, body) {
    try {
      return fetch(`https://${RESOURCE_NAME}/${endpoint}`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(body || {}),
      }).catch((e) => console.debug(`${endpoint} callback unavailable:`, e));
    } catch (e) {
      console.debug(`${endpoint} callback unavailable:`, e);
      return Promise.resolve();
    }
  }

  function sound(name) {
    post("uiSound", { name });
  }

  function showError(message) {
    errorText.textContent = message;
    errorBanner.hidden = false;
    // force reflow so the transition re-triggers on repeated errors
    void errorBanner.offsetWidth;
    errorBanner.classList.add("is-visible");
    if (errorTimer) clearTimeout(errorTimer);
    errorTimer = setTimeout(() => {
      errorBanner.classList.remove("is-visible");
      setTimeout(() => { errorBanner.hidden = true; }, CLOSE_ANIMATION_MS);
    }, 4200);
  }

  // ---------------------------------------------------------------------
  // Reading a qbx_core character
  //
  // These accessors exist because this file used to read char.firstname,
  // char.lastname, char.playtime and char.lastPlayed off the top level of the
  // character object, and NONE of those are fields qbx_core returns. Verified
  // against qbx_core's real source (server/storage/players.lua,
  // fetchAllPlayerEntities): the SELECT is
  //   citizenid, charinfo, money, job, gang, position, metadata,
  //   UNIX_TIMESTAMP(last_logged_out) AS lastLoggedOut
  // with charinfo/money/job/gang/metadata JSON-decoded into tables and the
  // timestamp exposed as `lastLoggedOut`. So the name lives at
  // charinfo.firstname, and last-played is a UNIX time in SECONDS, not a date
  // string. Every card rendered "Unnamed / Never played / New character"
  // before this - and the delete panel, which types the first name back to
  // confirm, could never be unlocked at all because the expected word was
  // always empty.
  //
  // charinfo is still read defensively (falling back to the character object
  // itself) so a differently-shaped fork on the live box degrades to the old
  // behaviour instead of rendering nothing.
  // ---------------------------------------------------------------------

  function charinfoOf(char) {
    return (char && typeof char.charinfo === "object" && char.charinfo) || char || {};
  }

  function firstNameOf(char) { return charinfoOf(char).firstname || ""; }
  function lastNameOf(char) { return charinfoOf(char).lastname || ""; }

  function fullNameOf(char) {
    return [firstNameOf(char), lastNameOf(char)].filter(Boolean).join(" ");
  }

  function initials(char) {
    const a = (firstNameOf(char) || "?").charAt(0).toUpperCase();
    const b = (lastNameOf(char) || "").charAt(0).toUpperCase();
    return (a + b).trim() || "?";
  }

  function jobLabelOf(char) {
    const job = char.job || {};
    if (!job.label) return "Unemployed";
    const gradeName = job.grade && job.grade.name;
    return gradeName ? `${job.label} · ${gradeName}` : job.label;
  }

  function gangLabelOf(char) {
    const gang = char.gang || {};
    // qbx_core assigns everyone a sentinel "none" gang.
    if (!gang.label || String(gang.name || "").toLowerCase() === "none") return null;
    return gang.label;
  }

  function formatMoney(value) {
    if (typeof value !== "number" || !isFinite(value)) return null;
    return "$" + Math.round(value).toLocaleString("en-US");
  }

  // qbx_core hands back UNIX SECONDS (UNIX_TIMESTAMP(last_logged_out)).
  // Multiplying is the whole fix: new Date(1754400000) is January 1970.
  function formatLastPlayed(unixSeconds) {
    if (typeof unixSeconds !== "number" || unixSeconds <= 0) return "Never";
    const d = new Date(unixSeconds * 1000);
    if (isNaN(d.getTime())) return "Never";

    const days = Math.floor((Date.now() - d.getTime()) / 86400000);
    if (days <= 0) return "Today";
    if (days === 1) return "Yesterday";
    if (days < 30) return `${days} days ago`;
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  }

  // Seconds -> "12h 40m". Sub-hour reads in minutes so a brand-new character
  // shows "18m" rather than "0h".
  function formatPlaytime(seconds) {
    if (typeof seconds !== "number" || seconds < 60) return null;
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (hours <= 0) return `${minutes}m`;
    return `${hours}h ${minutes}m`;
  }

  function formatBirthdate(value) {
    if (!value) return null;
    const d = new Date(value);
    if (isNaN(d.getTime())) return String(value);
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  }

  function characterById(citizenid) {
    return currentCharacters.find((c) => c.citizenid === citizenid) || null;
  }

  // -----------------------------------------------------------------------
  // Details rail
  // -----------------------------------------------------------------------

  // textContent only, never innerHTML - a character name is player-supplied
  // text that reaches this DOM.
  function statRow(label, value, modifier) {
    const row = document.createElement("div");
    row.className = "stat-row" + (modifier ? ` stat-row--${modifier}` : "");
    const l = document.createElement("span");
    l.className = "stat-row__label";
    l.textContent = label;
    const v = document.createElement("span");
    v.className = "stat-row__value";
    v.textContent = value;
    v.title = value;
    row.appendChild(l);
    row.appendChild(v);
    return row;
  }

  function renderStats(char) {
    statList.innerHTML = "";
    if (!char) {
      const empty = document.createElement("div");
      empty.className = "stat-row stat-row--empty";
      empty.textContent = "No character selected";
      statList.appendChild(empty);
      return;
    }

    const ci = charinfoOf(char);
    const money = char.money || {};
    const rows = [
      ["Job", jobLabelOf(char), null],
      ["Gang", gangLabelOf(char), null],
      ["Cash", formatMoney(money.cash), "money"],
      ["Bank", formatMoney(money.bank), "money"],
      ["Born", formatBirthdate(ci.birthdate), null],
      ["Nationality", ci.nationality || null, null],
      ["Phone", ci.phone || null, null],
      ["Last seen", char.zoneLabel || null, null],
      ["Last played", formatLastPlayed(char.lastLoggedOut), null],
      ["Playtime", formatPlaytime(playtimeByCitizenid[char.citizenid]), null],
    ];

    rows.forEach(([label, value, mod]) => {
      if (value) statList.appendChild(statRow(label, value, mod));
    });
  }

  function renderNameplate(char) {
    if (!char) {
      nameplate.hidden = true;
      return;
    }
    npName.textContent = fullNameOf(char) || "Unnamed";
    const bits = [jobLabelOf(char)];
    const gang = gangLabelOf(char);
    if (gang) bits.push(gang);
    npSub.textContent = bits.join("  ·  ");
    nameplate.hidden = false;
  }

  // -----------------------------------------------------------------------
  // Focus = selection cursor. On a full-screen game menu, focus IS the
  // pointer: it drives the nameplate, the details rail, the Play button and
  // which character is standing on the stage.
  // -----------------------------------------------------------------------

  function focusRow(row, opts) {
    const citizenid = row && row.dataset.citizenid;
    if (!citizenid || citizenid === focusedCitizenid) return;
    focusedCitizenid = citizenid;

    charList.querySelectorAll(".char-row").forEach((el) => {
      el.classList.toggle("is-focused", el === row);
      el.setAttribute("aria-selected", el === row ? "true" : "false");
    });

    const char = characterById(citizenid);
    renderNameplate(char);
    renderStats(char);

    playBtn.disabled = false;
    deleteBtn.hidden = false;
    fallbackInitials.textContent = initials(char);

    if (!opts || !opts.silent) sound("focus");

    // ALWAYS post, even for a character with no saved appearance. Posting only
    // for previewable ids meant moving focus onto a character without one told
    // Lua nothing at all, so the PREVIOUS character's ped stayed lit on the
    // stage while the nameplate and rail switched — one character's body under
    // another's name. Lua answers `live:false` for a character it cannot
    // stage, which is what drops the centre back to the medallion.
    stageRequestId = citizenid;
    post("previewCharacter", { citizenid });
  }

  function moveFocus(delta) {
    const rows = Array.from(charList.querySelectorAll(".char-row"));
    if (!rows.length) return;
    const current = rows.findIndex((r) => r.dataset.citizenid === focusedCitizenid);
    const nextIndex = Math.min(Math.max((current < 0 ? 0 : current) + delta, 0), rows.length - 1);
    const next = rows[nextIndex];
    if (!next || next.dataset.citizenid === focusedCitizenid) return;
    next.focus({ preventScroll: false });
    focusRow(next, { silent: true });
    sound("nav");
  }

  function playFocused() {
    if (playBtn.disabled || !focusedCitizenid) return;
    charList.querySelectorAll(".char-row").forEach((el) => {
      el.classList.toggle("is-selected", el.dataset.citizenid === focusedCitizenid);
    });
    post("selectCharacter", { citizenid: focusedCitizenid });
  }

  document.addEventListener("keydown", (ev) => {
    // A modal panel owns its own keyboard handling (and its inputs need the
    // arrow keys for text editing).
    if (!createPanel.hidden || !deletePanel.hidden) return;
    if (charList.childElementCount === 0) return;

    if (ev.key === "ArrowDown" || ev.key === "ArrowRight") { ev.preventDefault(); moveFocus(1); }
    else if (ev.key === "ArrowUp" || ev.key === "ArrowLeft") { ev.preventDefault(); moveFocus(-1); }
    else if (ev.key === "Enter") { ev.preventDefault(); playFocused(); }
  });

  // -----------------------------------------------------------------------
  // Roster rendering
  // -----------------------------------------------------------------------

  function buildCharacterRow(char, index) {
    const row = document.createElement("div");
    row.className = "char-row";
    row.setAttribute("role", "option");
    row.setAttribute("aria-selected", "false");
    row.setAttribute("tabindex", "0");
    row.dataset.citizenid = char.citizenid || "";
    row.style.setProperty("--enter-delay", `${ENTRANCE_BASE_DELAY_MS + index * ENTRANCE_STEP_MS}ms`);

    const medallion = document.createElement("div");
    medallion.className = "char-row__medallion";
    medallion.textContent = initials(char);
    row.appendChild(medallion);

    const text = document.createElement("div");
    text.className = "char-row__text";

    const name = document.createElement("div");
    name.className = "char-row__name";
    name.textContent = fullNameOf(char) || "Unnamed";
    text.appendChild(name);

    const sub = document.createElement("div");
    sub.className = "char-row__sub";
    sub.textContent = jobLabelOf(char);
    text.appendChild(sub);

    row.appendChild(text);

    // Lit when a live ped preview exists for this character.
    const live = document.createElement("span");
    live.className = "char-row__live";
    live.title = "Live preview available";
    row.appendChild(live);

    row.addEventListener("pointerenter", () => focusRow(row, { silent: false }));
    row.addEventListener("focus", () => focusRow(row, { silent: true }));
    row.addEventListener("click", () => {
      // First click focuses, a click on the already-focused row plays. Keeps a
      // single mis-click from committing a character, which is irreversible
      // from this screen (there is no way back once qbx_core logs you in).
      if (row.dataset.citizenid === focusedCitizenid) playFocused();
      else focusRow(row, { silent: false });
    });
    row.addEventListener("dblclick", playFocused);

    return row;
  }

  function renderCharacters(characters, maxSlots, nameRules, slotInfo) {
    currentCharacters = Array.isArray(characters) ? characters : [];
    currentMaxSlots = typeof maxSlots === "number" ? maxSlots : 2;
    currentNameRules = nameRules || null;

    // A soft-deleted character STILL occupies a qbx_core slot - this resource
    // never issues a real DELETE, and qbx_core counts every row in `players`.
    // So "used" is visible + hidden, not visible. Reporting only the visible
    // count is what let the old arithmetic reach "0 / 0 slots" after deleting
    // everything: create disabled, nothing to play, and no way out.
    const info = slotInfo || {};
    const hiddenCount = typeof info.hiddenCount === "number" ? info.hiddenCount : 0;
    const usedSlots = typeof info.usedSlots === "number"
      ? info.usedSlots
      : currentCharacters.length + hiddenCount;

    loadingState.hidden = true;

    // The stage belongs to whatever was on screen BEFORE this render. Clearing
    // it here is what stops a just-deleted character from staying spotlit in
    // the centre next to "Create your first character" - renderCharacters never
    // touched `has-stage`, and the only other thing that clears it is `hide`.
    // Lua's own ped is destroyed by the previewCharacter post that follows the
    // focus below (or, with an empty roster, by nothing needing to be shown).
    overlay.classList.remove("has-stage");
    pedFallback.hidden = true;
    stageRequestId = null;

    charList.innerHTML = "";
    currentCharacters.forEach((char, i) => {
      charList.appendChild(buildCharacterRow(char, i));
    });

    const slotsFull = usedSlots >= currentMaxSlots;
    createBtn.disabled = slotsFull;
    createBtn.title = slotsFull
      ? (hiddenCount > 0
          // Naming the cause matters: otherwise a player who just deleted a
          // character sees a disabled button and concludes the screen is
          // broken. A deleted character is recoverable by an admin
          // (/palm6charselect_restore), so this is actionable, not a dead end.
          ? `All ${currentMaxSlots} character slots are in use. ${hiddenCount} deleted character${hiddenCount === 1 ? "" : "s"} still occupies a slot — ask an admin to restore or clear it.`
          : "All character slots are in use")
      : "";
    slotCount.textContent = `${usedSlots} / ${currentMaxSlots} slots`;

    overlay.classList.add("is-mounted");

    // "browse / Enter to play" is a lie when there is nothing to browse and
    // nothing to play.
    navHint.hidden = currentCharacters.length === 0;

    if (currentCharacters.length === 0) {
      // First-time player: no roster, no stage, nothing to play. The create
      // button is the only thing on screen that does anything, so say so.
      focusedCitizenid = null;
      playBtn.disabled = true;
      deleteBtn.hidden = true;
      nameplate.hidden = false;
      npName.textContent = "Welcome to Palm6";
      npSub.textContent = "Create your first character";
      renderStats(null);
      pedFallback.hidden = true;
      // Nothing left to focus means nothing will post previewCharacter, so
      // this is the one path that has to ask Lua to clear the ped explicitly.
      post("clearStage", {});
      createBtn.focus({ preventScroll: true });
      return;
    }

    // Open on the first character rather than on nothing.
    const first = charList.querySelector(".char-row");
    if (first) {
      focusedCitizenid = null;   // re-render: force focusRow past its dedupe
      first.focus({ preventScroll: true });
      focusRow(first, { silent: true });
      // Until the Lua side reports a live ped, show the medallion so the
      // centre is never an unexplained empty hole.
      pedFallback.hidden = false;
    }
  }

  // -----------------------------------------------------------------------
  // Create-character panel
  // -----------------------------------------------------------------------

  function openCreatePanel() {
    if (createBtn.disabled) return;
    createError.hidden = true;
    fFirstname.value = "";
    fLastname.value = "";
    fDob.value = "";
    createPanel.hidden = false;
    void createPanel.offsetWidth;
    createPanel.classList.add("is-visible");
    fFirstname.focus();
  }

  function closeCreatePanel() {
    createPanel.classList.remove("is-visible");
    setTimeout(() => { createPanel.hidden = true; }, CLOSE_ANIMATION_MS);
  }

  function validateCreateForm() {
    const rules = currentNameRules || { minLen: 2, maxLen: 24 };
    const first = fFirstname.value.trim();
    const last = fLastname.value.trim();
    // Matches Config.NameRules.regex (shared/config.lua) exactly - `+` not
    // `*`, so this alone (not just the separate minLen check below) already
    // rejects a bare single letter. Previously drifted from the Lua pattern
    // (flagged in review); the minLen check masked it in practice, but two
    // rules expressing the same intent with different literal values is a
    // trap for the next edit.
    const nameOk = /^[A-Za-z][A-Za-z'\- ]+$/;

    if (first.length < rules.minLen || first.length > rules.maxLen || !nameOk.test(first)) {
      return "First name must be letters only, correct length.";
    }
    if (last.length < rules.minLen || last.length > rules.maxLen || !nameOk.test(last)) {
      return "Last name must be letters only, correct length.";
    }
    if (!fDob.value) return "Date of birth is required.";
    const dobYear = new Date(fDob.value).getFullYear();
    if (rules.dobMinYear && dobYear < rules.dobMinYear) return `Birth year must be ${rules.dobMinYear} or later.`;
    if (rules.dobMaxYear && dobYear > rules.dobMaxYear) return `Birth year must be ${rules.dobMaxYear} or earlier.`;
    return null;
  }

  createBtn.addEventListener("click", openCreatePanel);

  createSubmit.addEventListener("click", () => {
    const err = validateCreateForm();
    if (err) {
      createError.textContent = err;
      createError.hidden = false;
      sound("error");
      return;
    }
    createError.hidden = true;
    const form = {
      firstname: fFirstname.value.trim(),
      lastname: fLastname.value.trim(),
      nationality: fNationality.value,
      gender: fGender.value,
      dob: fDob.value,
    };
    post("createCharacter", { form });
  });

  createCancel.addEventListener("click", () => { sound("back"); closeCreatePanel(); });

  playBtn.addEventListener("click", playFocused);

  // -----------------------------------------------------------------------
  // Delete-character panel — type-the-name-to-confirm, matches the weight of
  // an irreversible-feeling action even though the server side is a
  // reversible soft-delete (see bridge/sv_framework.lua).
  // -----------------------------------------------------------------------

  function openDeletePanel(char) {
    if (!char) return;
    deleteTargetCitizenid = char.citizenid;
    // The confirm word HAS to be a real name: the submit button stays disabled
    // until the typed text matches it, so reading the name from a field
    // qbx_core doesn't return (char.firstname) made delete permanently
    // unusable - the expected word was "" and `!(expected && ...)` never
    // unlocked. See the accessors at the top of this file.
    const first = firstNameOf(char) || "this character";
    deleteTargetName.textContent = fullNameOf(char) || "this character";
    deleteConfirmWord.textContent = first;
    deleteConfirmInput.value = "";
    deleteError.hidden = true;
    deleteSubmit.disabled = true;
    deletePanel.hidden = false;
    void deletePanel.offsetWidth;
    deletePanel.classList.add("is-visible");
    deleteConfirmInput.focus();
  }

  function closeDeletePanel() {
    deletePanel.classList.remove("is-visible");
    setTimeout(() => { deletePanel.hidden = true; }, CLOSE_ANIMATION_MS);
    deleteTargetCitizenid = null;
  }

  deleteBtn.addEventListener("click", () => {
    openDeletePanel(characterById(focusedCitizenid));
  });

  deleteConfirmInput.addEventListener("input", () => {
    const expected = deleteConfirmWord.textContent.trim().toLowerCase();
    const typed = deleteConfirmInput.value.trim().toLowerCase();
    deleteSubmit.disabled = !(expected && typed === expected);
  });

  deleteConfirmInput.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter" && !deleteSubmit.disabled) { ev.preventDefault(); deleteSubmit.click(); }
  });

  deleteSubmit.addEventListener("click", () => {
    if (deleteSubmit.disabled || !deleteTargetCitizenid) return;
    post("deleteCharacter", { citizenid: deleteTargetCitizenid });
    closeDeletePanel();
  });

  deleteCancel.addEventListener("click", () => { sound("back"); closeDeletePanel(); });

  // -----------------------------------------------------------------------
  // Inbound message dispatch (Lua -> JS)
  // -----------------------------------------------------------------------

  window.addEventListener("message", (event) => {
    const data = event.data;
    if (!data || typeof data !== "object") return;

    switch (data.action) {
      case "loading":
        overlay.classList.add("is-mounted");
        charList.innerHTML = "";
        nameplate.hidden = true;
        pedFallback.hidden = true;
        renderStats(null);
        loadingState.hidden = false;
        break;

      case "show":
        overlay.classList.remove("is-busy");
        renderCharacters(data.characters, data.maxSlots, data.nameRules, {
          usedSlots: data.usedSlots,
          hiddenCount: data.hiddenCount,
        });
        break;

      // Sent right after a select/create request goes out (client/main.lua's
      // `busy` guard, which blocks a second click from reaching qbx_core's
      // own double-login exploit-drop). is-busy disables pointer-events so a
      // second click can't even register client-side, matching the Lua-side
      // guard instead of relying on it alone - a second click with no visible
      // feedback reads as "the button is broken", not "please wait".
      case "busy":
        overlay.classList.add("is-busy");
        playBtn.disabled = true;
        break;

      // Which characters have a saved appearance the stage can actually show.
      // Arrives after `show`, because the Lua side has to round-trip the
      // server for it (see client/main.lua requestAppearances).
      case "previewable": {
        previewableIds.clear();
        (data.citizenids || []).forEach((id) => previewableIds.add(id));
        charList.querySelectorAll(".char-row").forEach((el) => {
          el.classList.toggle("has-preview", previewableIds.has(el.dataset.citizenid));
        });

        // Playtime rides the same round trip. It arrives AFTER `show`, so the
        // details rail has already rendered without it - re-render the focused
        // character so the line appears instead of waiting for the next
        // selection change.
        playtimeByCitizenid = data.playtime || {};
        if (focusedCitizenid) renderStats(characterById(focusedCitizenid));

        // Now that we know which characters CAN be staged, ask for the one
        // that is actually focused. focusRow already posted once (before this
        // answer existed, when Lua had no appearances loaded yet); re-posting
        // here is what puts the right character on the stage on open. Lua no
        // longer picks one itself - see client/main.lua's appearances handler.
        if (focusedCitizenid) {
          stageRequestId = focusedCitizenid;
          post("previewCharacter", { citizenid: focusedCitizenid });
        }
        break;
      }

      // A ped is (or is not) now standing in the world for this character.
      // `live: false` means the spawn was refused - no ground under the framed
      // point, model never loaded - and the centre keeps the medallion.
      case "stage": {
        // Ignore an answer for anything other than the request we are actually
        // waiting on - a slow spawn for a character the player has already
        // arrowed past must not repaint the centre.
        if (data.citizenid !== stageRequestId) break;
        const live = data.live === true;
        overlay.classList.toggle("has-stage", live);
        pedFallback.hidden = live;
        break;
      }

      case "error":
        overlay.classList.remove("is-busy");
        playBtn.disabled = !focusedCitizenid;
        closeCreatePanel();
        closeDeletePanel();
        sound("error");
        showError(data.message || "Something went wrong.");
        break;

      case "confirmSelect": {
        overlay.classList.remove("is-busy");
        overlay.classList.add("is-committing");
        break;
      }

      case "hide":
        overlay.classList.remove("is-mounted", "is-busy", "has-stage", "is-committing");
        charList.innerHTML = "";
        statList.innerHTML = "";
        nameplate.hidden = true;
        pedFallback.hidden = true;
        loadingState.hidden = true;
        previewableIds.clear();
        focusedCitizenid = null;
        break;

      default:
        break;
    }
  });

  // NUI pages don't receive onResourceStop directly - the client Lua side
  // force-releases SetNuiFocus on its own onResourceStop handler (see
  // client/main.lua). This just clears local DOM state on page teardown
  // (hot-reload hygiene) so a stale roster never survives a restart.
  window.addEventListener("pagehide", () => {
    charList.innerHTML = "";
  });

  // -----------------------------------------------------------------------
  // Standalone Chrome/CEF devtools preview stub
  // -----------------------------------------------------------------------

  const previewEnabled = new URLSearchParams(window.location.search).get("preview") === "1";
  if (previewEnabled) {
    // PREVIEW ONLY. In game this page is a transparent surface over the live
    // 3D view, which is why the stylesheet forces `background: transparent
    // !important` - but that also means opening this file in a browser shows
    // white, and light text on white cannot be judged for contrast, spacing
    // or hierarchy. This stands in for the world behind the UI. It is built
    // here, in the ?preview=1 branch, rather than in the stylesheet, so there
    // is no way for it to reach a running server.
    const backdrop = document.createElement("div");
    backdrop.style.cssText = [
      "position:fixed", "inset:0", "z-index:-1", "pointer-events:none",
      "background:radial-gradient(120% 90% at 50% 20%, #23384d 0%, #101c28 45%, #05090e 100%)",
    ].join(";");
    document.body.appendChild(backdrop);

    // Shaped exactly like a real qbx_core PlayerEntity
    // (server/storage/players.lua fetchAllPlayerEntities): charinfo/money/job/
    // gang decoded into tables, lastLoggedOut a UNIX time in SECONDS. Keeping
    // the stub honest is the point - the previous one invented top-level
    // firstname/lastname/playtime/lastPlayed fields, which is exactly why the
    // real screen rendered "Unnamed / Never played" and nobody noticed.
    renderCharacters(
      [
        {
          citizenid: "ABC12345",
          charinfo: { firstname: "Jordan", lastname: "Vance", birthdate: "1994-03-11", nationality: "American", phone: "3105550142" },
          money: { cash: 1240, bank: 18650 },
          job: { name: "unemployed", label: "Unemployed", grade: { name: "Freelance", level: 0 } },
          gang: { name: "none", label: "No Gang" },
          zoneLabel: "Vinewood Hills",
          lastLoggedOut: Math.floor(Date.now() / 1000) - 86400,
        },
        {
          citizenid: "DEF67890",
          charinfo: { firstname: "Sasha", lastname: "Reyes", birthdate: "1989-11-02", nationality: "Mexican", phone: "3105550188" },
          money: { cash: 87, bank: 240310 },
          job: { name: "police", label: "LSPD", grade: { name: "Sergeant", level: 3 } },
          gang: { name: "none", label: "No Gang" },
          zoneLabel: "Mission Row",
          lastLoggedOut: Math.floor(Date.now() / 1000) - 86400 * 46,
        },
      ],
      3,
      { minLen: 2, maxLen: 24, dobMinYear: 1960, dobMaxYear: 2006 },
      // Matches the real `show` payload: a soft-deleted character still holds
      // a qbx_core slot, so used = visible + hidden.
      { usedSlots: 2, hiddenCount: 0 }
    );
    previewableIds.add("ABC12345");
    charList.querySelectorAll(".char-row").forEach((el) => {
      el.classList.toggle("has-preview", previewableIds.has(el.dataset.citizenid));
    });
    // Matches the real `previewable` payload, playtime included.
    playtimeByCitizenid = { ABC12345: 45720, DEF67890: 1926000 };
    if (focusedCitizenid) renderStats(characterById(focusedCitizenid));
  }
})();
