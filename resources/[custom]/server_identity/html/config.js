/* Palm6 loading screen — clean plate + HTML chrome.
   Local QA: open loading.html#preview (fullscreen preferred).

   Dock panels use keys 1–9 in dock order. [ ] cycle panels, F focuses
   drawer search. Esc closes, H hides chrome. Space music, -/= volume,
   ←/→ gallery when open.

   --- Drop-ins (Higgsfield / your exports) ---
   Background loop: put MP4/WebM at assets/bg/bay-loop.mp4 then set background.video
   Animated logo: put WebM/MP4 at assets/logo-anim.webm then set logoVideo
   Until those files exist, static palm6_screen.jpg + logo.png are used.

   --- What you still need to send / create ---
   Socials: paste profile URLs below (YouTube, TikTok, Instagram, Facebook).
   Music: drop legally obtained .mp3 files into assets/music/
   Staff avatars: drop square PNGs into assets/staff/
*/
window.Palm6Loading = {
  serverName: "Palm6",
  showLogo: true,
  logo: "assets/logo.png",
  /* Higgsfield animated P6 — leave blank until the file exists */
  logoVideo: "",
  /* "assets/logo-anim.webm", */
  background: {
    /* Static fallback always available */
    poster: "palm6_screen.jpg",
    /* Higgsfield cinematic loop — leave blank until the file exists */
    video: "",
    /* "assets/bg/bay-loop.mp4", */
    loop: true,
    /* Full plate pool — Discord captures + prior FiveM/character stills */
    slides: [
      "assets/bg/slides/slide-01.jpg",
      "assets/bg/slides/slide-02.jpg",
      "assets/bg/slides/slide-03.jpg",
      "assets/bg/slides/slide-04.jpg",
      "assets/bg/slides/slide-05.jpg",
      "assets/bg/slides/slide-06.jpg",
      "assets/bg/slides/slide-07.jpg",
      "assets/bg/slides/slide-08.jpg",
      "assets/bg/slides/slide-09.jpg",
      "assets/bg/slides/slide-10.jpg",
      "assets/bg/slides/slide-11.jpg",
      "assets/bg/slides/slide-12.jpg",
      "assets/bg/slides/slide-13.jpg",
      "assets/bg/slides/slide-14.jpg",
      "assets/bg/slides/slide-15.jpg",
      "assets/bg/slides/slide-16.jpg",
      "assets/bg/slides/slide-17.jpg",
      "assets/bg/slides/slide-18.jpg",
      "assets/bg/slides/slide-19.jpg",
    ],
  },
  tagline: "The Next Chapter Starts Here.",
  readyTagline: "City link established — welcome to Verano.",
  chapter: "Chapter Zero — Founding Citizens",
  credits: "Built for the State of Verano",
  badge: "Founding Citizens",
  motd: "Welcome to Palm6 Bay — stay IC, join Discord, claim your story.",
  showClock: true,
  showElapsed: true,
  forceMotion: true,
  ambientMotion: false,
  parallax: false,
  introFade: true,
  spotlight: true,
  liveStatus: true,
  liveStatusText: "City systems online",
  liveStatusReturning: "Return link online",
  versionChip: "Palm6 Load · v0.9.24",
  rememberPanel: true,
  dockMaxVisible: 6,
  syncTipsToChapters: true,
  loreWhisper: true,
  loreIntervalMs: 16000,
  readyToast: "City link established",
  showActivityLog: true,
  allowHideUi: true,
  particles: true,
  typewriterStatus: true,
  loadPhases: true,
  showEta: true,
  commandPalette: true,
  foundingSeal: true,
  signalHud: true,
  constellation: true,
  dataRails: false,
  dataRailText: "PALM6 · VERANO · CHAPTER ZERO · FOUNDING · BAY LINK · STATE SYSTEMS · ",
  welcomeLine: "Welcome, %s — State of Verano",
  welcomeReturning: "Welcome back, %s — Verano remembers.",
  trackVisits: true,
  /* Image slideshow (no video). Uses slides[] or falls back to gallery.items */
  slideshow: {
    enabled: true,
    intervalMs: 14000,
    crossfadeMs: 1600,
    /* Shuffle full order every load; avoid repeating last opener */
    shuffle: true,
    avoidRepeatStart: true,
    /* 0 = pin top (protect heads), 0.5 = center, 1 = bottom */
    biasY: 0.12,
  },
  /* Live boot log from FiveM NUI events */
  resourceLog: {
    enabled: true,
    maxLines: 40,
  },
  /* Soft accent themes — still Palm6 cyan/magenta/gold family */
  themePicker: {
    enabled: true,
    defaultTheme: "bay",
  },
  /* First-visit rules acknowledge (stored locally) */
  rulesGate: {
    enabled: true,
    title: "Enter the State of Verano",
    body: "Stay IC. Respect staff. No RDM / VDM. Discord is home for rules and tickets.",
    acceptLabel: "I understand — enter Palm6",
    storageKey: "palm6_rules_accepted_v1",
  },
  discordCta: {
    enabled: true,
    label: "Join Discord",
    url: "https://discord.gg/BTb4u4fjY9",
    inviteCode: "BTb4u4fjY9",
    showCount: true,
  },
  announceIntervalMs: 9000,
  announcements: [
    { tag: "MOTD", text: "Welcome to Palm6 Bay — stay IC, join Discord, claim your story." },
    { tag: "CITY", text: "Founding Citizens are live — economy, crews, and departments open." },
    { tag: "DISCORD", text: "Rules & support live in Discord first — discord.gg/BTb4u4fjY9" },
    { tag: "TIP", text: "Press ? for help · P theme · rules gate on first visit · 1–9 panels" },
  ],

  loadChapters: {
    enabled: true,
    /* Keep tips readable — chapter beats live under the logo; toasts stay near MOTD */
    toast: false,
    items: [
      { at: 0, label: "Signal 01", title: "Handshake with the Bay" },
      { at: 0.22, label: "Signal 02", title: "Streaming Verano" },
      { at: 0.48, label: "Signal 03", title: "Charting the districts" },
      { at: 0.72, label: "Signal 04", title: "City systems online" },
      { at: 0.92, label: "Signal 05", title: "Almost at the curb" },
      { at: 0.999, label: "Ready", title: "Welcome to Chapter Zero" },
    ],
  },

  startHere: {
    enabled: true,
    items: [
      { id: "discord", title: "Join Discord", body: "Rules, tickets, announcements, and staff live there first.", action: "discord", goLabel: "Join" },
      { id: "rules", title: "Read city rules", body: "RP first. No RDM / VDM. Fear RP. NLR after death.", panel: "rules", goLabel: "Rules" },
      { id: "identity", title: "Pick your lane", body: "Civilian life, crews, or a department — founding citizens set the tone.", panel: "jobs", goLabel: "Jobs" },
      { id: "keys", title: "Learn the keys", body: "F1 help, T chat, M map, /me /do, /report when you need staff.", panel: "keys", goLabel: "Keys" },
      { id: "map", title: "Know the map", body: "Bay, Pier, Neon Corridor, Hills, Port, Boulevard — pick your haunt.", panel: "map", goLabel: "Map" },
      { id: "report", title: "Know /report", body: "Broken RP or grief? Report in-city or open a Discord ticket.", panel: "faq", goLabel: "FAQ" },
      { id: "apply", title: "Apply for jobs", body: "LSPD, EMS, mechanics, and more — applications on the site.", url: "https://palm6rp.com", goLabel: "Site" },
    ],
  },

  lore: [
    "The Bay never sleeps — only changes shifts.",
    "Second chances are the city's oldest currency.",
    "Founding citizens write the first chapter.",
    "Stay IC. The State of Verano is watching — and waiting.",
  ],

  systems: {
    enabled: true,
    items: [
      "Link handshake",
      "Stream assets",
      "Chart districts",
      "Boot systems",
      "World sync",
      "Ready to spawn",
    ],
  },

  /* MMO-style realm / population HUD */
  population: {
    enabled: true,
    realm: "Palm6 Bay",
    enterText: "Entering the State of Verano",
    maxPlayers: 64,
    /* CFX join code from cfx.re/join/XXXX — leave blank until you have one */
    cfxCode: "",
    /* Optional direct endpoints (may be blocked by CORS in browser preview) */
    endpoints: [
      "http://193.31.31.27:30149/dynamic.json",
      "http://193.31.31.27:30149/players.json",
    ],
    refreshMs: 20000,
    fallbackOnline: 12,
    queueIdle: "Instant entry",
    queueBusy: "World traffic elevated",
    queueFull: "Realm near capacity",
  },

  /* Paste real profile URLs and set enabled: true */
  socials: [
    { id: "discord",   label: "Discord",   enabled: true,  url: "https://discord.gg/BTb4u4fjY9" },
    { id: "website",   label: "Website",   enabled: true,  url: "https://palm6rp.com" },
    { id: "youtube",   label: "YouTube",   enabled: false, url: "" },
    { id: "tiktok",    label: "TikTok",    enabled: false, url: "" },
    { id: "instagram", label: "Instagram", enabled: false, url: "" },
    { id: "facebook",  label: "Facebook",  enabled: false, url: "" },
    { id: "x",         label: "X",         enabled: true,  url: "https://x.com/palm6rp" },
    { id: "github",    label: "GitHub",    enabled: false, url: "" },
  ],

  staff: [
    {
      name: "EvThatGuy",
      role: "Owner",
      bio: "Founder of Palm6 Bay — vision, community tone, and the long game for Chapter Zero.",
      focus: "Vision · Community",
      avatar: "assets/staff/evthatguy.jpg",
      url: "https://x.com/evthatguy",
    },
    {
      name: "David",
      role: "Owner",
      bio: "Ops and systems — keeps Verano online, patched, and ready for founding citizens.",
      focus: "Tech · Operations",
      avatar: "assets/staff/moderngrindtech.jpg",
      url: "https://x.com/moderngrindtech",
    },
  ],

  districts: {
    enabled: true,
    items: [
      { name: "Palm6 Bay", zone: "Bay", blurb: "Waterfront core — nightlife, glass towers, and the city's first impression.", vibe: "Premium night" },
      { name: "Verano Pier", zone: "Bay", blurb: "Golden-hour boardwalk and tourist RP. Soft crime, strong vibes.", vibe: "Leisure" },
      { name: "Neon Corridor", zone: "Downtown", blurb: "Dense streets, clubs, and late calls. Bring fear RP.", vibe: "High energy" },
      { name: "Hillside Estates", zone: "Hills", blurb: "Overlook mansions and quiet money. Perfect for long-form civ stories.", vibe: "Quiet wealth" },
      { name: "Port District", zone: "Port", blurb: "Docks, crates, and night logistics. Industrial RP with teeth.", vibe: "Industrial" },
      { name: "Palm Boulevard", zone: "Bay", blurb: "Daytime heat, cruising, and storefronts — the city's daytime pulse.", vibe: "Day cruise" },
    ],
  },

  tips: {
    enabled: true,
    intervalMs: 9500,
    items: [
      "Stay in character. Use /me and /do for actions and details.",
      "Read Rules in the dock — Discord pins have the full book.",
      "Need staff? /report in-city or open a Discord ticket.",
      "Neon Corridor hits different after midnight — bring fear RP.",
      "The State of Verano runs on second chances. New day, new life.",
      "Open Jobs to apply for LSPD, EMS, mechanics, and more.",
      "Verano Pier is soft crime and strong vibes — perfect first haunt.",
      "Check Updates for patch notes — founding citizens move fast.",
      "Palm Boulevard owns the daytime pulse; the Bay owns the night.",
    ],
  },

  rules: {
    enabled: true,
    items: [
      { tag: "RP", severity: "high", title: "Roleplay first", body: "Stay in character. No metagaming, powergaming, or breaking immersion for laughs." },
      { tag: "Combat", severity: "high", title: "Fear for your life", body: "Guns, cuffs, and crashes have weight — play the fear, not the scoreboard." },
      { tag: "Combat", severity: "high", title: "No RDM / VDM", body: "Random or vehicle deathmatch without RP lead-up is a ban." },
      { tag: "NLR", severity: "high", title: "New Life Rule", body: "Death wipes memory of the events that killed you. Fresh start, same city." },
      { tag: "Crime", severity: "med", title: "Value life & loot", body: "Don't rob freshly spawned players. Keep crime grounded in the scene." },
      { tag: "Tech", severity: "med", title: "No exploiting", body: "Bugs are for tickets, not bank accounts. Report and move on." },
      { tag: "Voice", severity: "med", title: "Voice & OOC", body: "Keep OOC out of voice. Use /ooc or Discord when you need out-of-character." },
      { tag: "Staff", severity: "med", title: "Staff calls are final", body: "Obey in the moment. Appeal later via ticket — not in chat." },
    ],
  },

  news: {
    enabled: true,
    items: [
      {
        title: "Founding Citizens are live",
        date: "Chapter Zero",
        body: "Palm6 Bay is open. Economy, crews, and departments are running — claim your story early.",
      },
      {
        title: "Loadscreen 0.9.24",
        date: "Aug 2026",
        body: "19 randomized plates · 14s dwell · unique opener each login.",
      },
      {
        title: "Discord is home base",
        date: "Community",
        body: "Rules, support, and patch notes ship in Discord first. Join before you spawn.",
      },
      {
        title: "Departments hiring",
        date: "Jobs",
        body: "LSPD, EMS / Fire, mechanics, and civilian lanes — apply on palm6rp.com.",
      },
    ],
  },

  jobs: {
    enabled: true,
    applyUrl: "https://palm6rp.com",
    applyLabel: "Apply on palm6rp.com",
    items: [
      { name: "LSPD", tag: "Emergency", body: "Protect and serve Palm6 Bay. Patrol, investigate, hold the line.", url: "https://palm6rp.com" },
      { name: "EMS / Fire", tag: "Emergency", body: "Trauma response and fire rescue across the State of Verano.", url: "https://palm6rp.com" },
      { name: "Mechanics", tag: "Civilian", body: "Customs, repairs, and tow — keep the city rolling.", url: "https://palm6rp.com" },
      { name: "Business", tag: "Civilian", body: "Storefronts, clubs, and services — build the Bay economy.", url: "https://palm6rp.com" },
      { name: "Crews", tag: "Street", body: "Territory, loyalty, and long stories — stay IC and earn the name.", url: "https://palm6rp.com" },
      { name: "Civilians", tag: "Civilian", body: "Drivers, hustlers, artists, and everyday Verano — the city needs you.", url: "https://palm6rp.com" },
    ],
  },

  changelog: {
    enabled: true,
    items: [
      {
        version: "0.9.24",
        date: "Aug 2026",
        title: "Full pool + random shuffle",
        body: "19 plates (Discord + prior stills). Longer interval (14s). Full shuffle each login; never opens on the same first plate twice.",
      },
      {
        version: "0.9.23",
        date: "Aug 2026",
        title: "Your Discord captures",
        body: "Slideshow swapped to 7 stills from your Discord uploads — letterbox extracted, 16:9 crop, no stretch.",
      },
      {
        version: "0.9.22",
        date: "Aug 2026",
        title: "CEF anti-stretch",
        body: "Plates use natural size + transform scale (never dual width/height fill) so CEF cannot stretch.",
      },
      {
        version: "0.9.21",
        date: "Aug 2026",
        title: "Headroom + slide-01 swap",
        body: "Replaced soft poster slide-01 with a real FiveM plate. Crops and cover bias pin the top so character heads stay in frame.",
      },
      {
        version: "0.9.20",
        date: "Aug 2026",
        title: "Crew + real FiveM mix",
        body: "Hybrid set: posted-up crew, twin drift, station portrait, plus real FiveM Doppler/chase stills — less poster, more character.",
      },
      {
        version: "0.9.19",
        date: "Aug 2026",
        title: "Real FiveM plates",
        body: "Dropped AI gens. Slideshow now uses real GTA/FiveM stills from free open loadscreen packs + Unsplash LA night.",
      },
      {
        version: "0.9.18",
        date: "Aug 2026",
        title: "Lifestyle crew plates",
        body: "New set matched to your lifestyle banner refs — pier, convertible, deco street, rooftop, boulevard, marina. Centered, no foreign watermarks.",
      },
      {
        version: "0.9.17",
        date: "Aug 2026",
        title: "Ref-matched plates + center",
        body: "New character-forward plates matched to your Discord refs. Slideshow centered (biasY 0.5); 3:2 gens center-cropped to 16:9 without stretch.",
      },
      {
        version: "0.9.16",
        date: "Aug 2026",
        title: "True aspect plates",
        body: "Slideshow sizes plates in JS from natural aspect (no CEF stretch). Slides/poster re-cropped 16:9 without forcing scale.",
      },
      {
        version: "0.9.15",
        date: "Aug 2026",
        title: "No-stretch plates",
        body: "Slideshow uses background-size cover (CEF-safe) so plates no longer stretch; gallery frame hardened.",
      },
      {
        version: "0.9.14",
        date: "Aug 2026",
        title: "Preview boot harden",
        body: "Local browser auto-preview (no stuck 0%), boot veil cannot stick black, slides only swap poster after a real frame loads.",
      },
      {
        version: "0.9.13",
        date: "Aug 2026",
        title: "Hierarchy + ordered plates",
        body: "Slideshow keeps config order, lighter mattes for brand headroom, MOTD/tip chrome cleaned, gallery lore captions.",
      },
      {
        version: "0.9.12",
        date: "Aug 2026",
        title: "Wide plates + rotate fix",
        body: "Slideshow rotate bug fixed (was stuck on first frame). New wide FiveM plates with logo headroom; crop biased below brand.",
      },
      {
        version: "0.9.11",
        date: "Aug 2026",
        title: "Plates load-safe",
        body: "Slideshow keeps poster until a real plate loads, skips broken frames, CEF-safer cover crop, polished FiveM character/street set.",
      },
      {
        version: "0.9.10",
        date: "Aug 2026",
        title: "FiveM cinematic plates",
        body: "Character/street loading plates in the clean FiveM RP look — gas station, drift, bridge, dusk, club, bayfront.",
      },
      {
        version: "0.9.9",
        date: "Aug 2026",
        title: "Staff · Gallery · Map",
        body: "Richer staff cards, district-tagged gallery captions, and a Map / Districts panel for Verano.",
      },
      {
        version: "0.9.8",
        date: "Aug 2026",
        title: "Clean plates + menu push",
        body: "True 16:9 slide plates, tips clear of chapter toasts, sharper dock/drawer, expanded Start/Rules/News/Jobs/FAQ.",
      },
      {
        version: "0.9.7",
        date: "Aug 2026",
        title: "Bay soundtrack + CEF harden",
        body: "Mixkit free Bay playlist (auto-probe), mute/track memory, CEF string-message parse, stronger name/boot handshake, GTA-style location slides, preview CEF sim.",
      },
      {
        version: "0.9.6",
        date: "Aug 2026",
        title: "Market feature pack",
        body: "Player-name bridge, Discord member count, rules gate, live boot log, image slideshow, visual keys, brand theme picker. Music/video still deferred.",
      },
      {
        version: "0.9.5",
        date: "Aug 2026",
        title: "Layout grid + smooth progress",
        body: "Shared CSS gutters, left/right rail alignment, centered tip stack, optical letter-spacing, and lerped progress bar.",
      },
      {
        version: "0.9.4",
        date: "Aug 2026",
        title: "Ready polish + Start deep-links",
        body: "Toast queue, lore whisper under tips, Start Open buttons, T for tip, version chip → Updates, cleaner ready ceremony.",
      },
      {
        version: "0.9.3",
        date: "Aug 2026",
        title: "Story-synced tips",
        body: "Load chapters gently advance tips. Connect rows flash on copy with labeled toasts. Return welcome toast is once per day.",
      },
      {
        version: "0.9.2",
        date: "Aug 2026",
        title: "Returning citizens",
        body: "Visit memory softens the welcome on return loads, keeps the hero clear, and nudges Start checklist continuity.",
      },
      {
        version: "0.9.1",
        date: "Aug 2026",
        title: "Shortcuts sheet + brand-safe remember",
        body: "? opens keyboard help. Last panel remembered for [ ] without covering the hero. Drawer swap motion; volume on -/=; #preview:panel=rules deep-link.",
      },
      {
        version: "0.9.0",
        date: "Aug 2026",
        title: "Panel navigation system",
        body: "Prev/next drawer nav, dock More overflow, remember last panel, [ ] cycle, F to search, gallery thumbs + position.",
      },
      {
        version: "0.8.9",
        date: "Aug 2026",
        title: "Advanced panels",
        body: "Sticky drawer chrome with search + filters, FAQ accordion, richer staff/jobs/rules cards, checklist progress bar.",
      },
      {
        version: "0.8.8",
        date: "Aug 2026",
        title: "Chapters + command palette",
        body: "Progress story beats, / command jump, Palm6 card panels, and FX that ease off as load climbs.",
      },
      {
        version: "0.8.7",
        date: "Aug 2026",
        title: "Start here + ETA",
        body: "Founding checklist dock panel with saved progress, live load ETA, and click-to-copy Connect rows.",
      },
      {
        version: "0.8.6",
        date: "Aug 2026",
        title: "Media drop-in slots",
        body: "Video background + animated logo paths ready for Higgsfield exports. Quieter chrome; ready-state tagline at 100%.",
      },
      {
        version: "0.8.5",
        date: "Aug 2026",
        title: "Clean brand stack",
        body: "Center is logo + name + tagline only. Announcements moved to a thin top ticker; welcome sits left with uplink.",
      },
      {
        version: "0.8.4",
        date: "Aug 2026",
        title: "Verano Signal",
        body: "Bay constellation map, aurora wash, sonar pulses, founding seal, holographic wordmark, uplink bars, progress tip orb.",
      },
      {
        version: "0.8.3",
        date: "Aug 2026",
        title: "Locked plate + onboard",
        body: "Background art stays still. Announcement ticker, load phases, Discord join+copy, clickable tips.",
      },
      {
        version: "0.8",
        date: "Aug 2026",
        title: "Motion + realm HUD",
        body: "Animated logo orbits with beads, particles, lore crawl, typewriter status, and players-online population card.",
      },
      {
        version: "0.7",
        date: "Aug 2026",
        title: "High-tech loadscreen",
        body: "Boot systems HUD, realm population, hex grid, cursor spotlight, and live city pulse.",
      },
      {
        version: "0.6",
        date: "Aug 2026",
        title: "Premium loadscreen",
        body: "Logo-matched chrome, parallax, shimmer progress, glass dock, and richer panels.",
      },
      {
        version: "Chapter Zero",
        date: "Now",
        title: "Founding Citizens open",
        body: "Economy, crews, and departments are live. Claim your story early in Palm6 Bay.",
      },
      {
        version: "City",
        date: "Ongoing",
        title: "Discord is home base",
        body: "Rules, support tickets, and patch notes ship in Discord first.",
      },
    ],
  },

  faq: {
    enabled: true,
    items: [
      { q: "How do I join?", a: "Add the server in FiveM, join Discord, and read the pinned rules before you spawn." },
      { q: "Where are the rules?", a: "Loadscreen Rules panel, Discord pins, and /rules in-city." },
      { q: "How do I get a job?", a: "Open Jobs in the dock or apply on palm6rp.com — departments review tickets." },
      { q: "Can I start a gang / business?", a: "Yes — open a Discord ticket once you're established in-character." },
      { q: "Something broke — help?", a: "/report in-game or a Discord support ticket. Include what you were doing." },
      { q: "Voice not working?", a: "Check FiveM settings, Windows input device, and Discord push-to-talk if you use it OOC." },
    ],
  },

  connect: {
    enabled: true,
    items: [
      { label: "Discord", value: "discord.gg/BTb4u4fjY9" },
      { label: "Website", value: "palm6rp.com" },
      { label: "X", value: "x.com/palm6rp" },
      { label: "City", value: "State of Verano — Palm6 Bay" },
      { label: "Chapter", value: "Zero — Founding Citizens" },
    ],
  },

  keybinds: {
    enabled: true,
    visualKeyboard: true,
    items: [
      { key: "F1", action: "Help / commands", code: "F1" },
      { key: "T", action: "Chat", code: "KeyT" },
      { key: "M", action: "Map", code: "KeyM" },
      { key: "/me /do", action: "Roleplay actions" },
      { key: "/report", action: "Contact staff" },
      { key: "/rules", action: "Re-read city rules" },
      { key: "H", action: "Hide loadscreen UI", code: "KeyH" },
    ],
  },

  gallery: {
    enabled: true,
    intervalMs: 6200,
    items: [
      { src: "assets/bg/slides/slide-01.jpg", caption: "Supervisor unit", district: "Palm6 Bay", body: "Your Discord capture — LSPD night." },
      { src: "assets/bg/slides/slide-02.jpg", caption: "Dirt bike stunt", district: "Port District", body: "Golden hour wheelie." },
      { src: "assets/bg/slides/slide-03.jpg", caption: "Vinewood curb", district: "Neon Corridor", body: "Character + winged sedan." },
      { src: "assets/bg/slides/slide-04.jpg", caption: "Crew plate", district: "Palm Boulevard", body: "From your Discord set." },
      { src: "assets/bg/slides/slide-05.jpg", caption: "Alley hang", district: "Port District", body: "Posted up · rainy curb." },
      { src: "assets/bg/slides/slide-06.jpg", caption: "Street still", district: "Palm6 Bay", body: "From your Discord set." },
      { src: "assets/bg/slides/slide-07.jpg", caption: "Mansion lineup", district: "Hillside Estates", body: "Posted on the hood · red fleet." },
    ],
  },

  /* Mixkit Stock Music Free License — Bay playlist (legal free stock).
     Drake / ICEMAN cannot be downloaded here — buy/stream legally, then
     replace these files or add your own tracks to music.tracks. */
  music: {
    enabled: "auto",
    volume: 0.28,
    rememberMute: true,
    tracks: [
      { file: "assets/music/01-bay-pulse.mp3", title: "Bay Pulse" },
      { file: "assets/music/02-night-drive.mp3", title: "Night Drive" },
      { file: "assets/music/03-soft-grid.mp3", title: "Soft Grid" },
      { file: "assets/music/04-city-roll.mp3", title: "City Roll" },
      { file: "assets/music/05-after-hours.mp3", title: "After Hours" },
      { file: "assets/music/06-slow-lane.mp3", title: "Slow Lane" },
    ],
  },
};
