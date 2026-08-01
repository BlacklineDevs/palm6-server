/* Palm6 loading screen config — edit links, staff, tips, rules, and music here.
   Disabled socials are hidden. Music stays off until you drop an mp3
   and set enabled: true.

   Local QA: open loading.html#preview in a browser to animate the progress bar. */
window.Palm6Loading = {
  serverName: "Palm6",
  logo: "assets/logo.svg",

  socials: [
    { id: "discord",  label: "Discord",  enabled: true,  url: "https://discord.gg/BTb4u4fjY9" },
    { id: "youtube",  label: "YouTube",  enabled: false, url: "" },
    { id: "tiktok",   label: "TikTok",   enabled: false, url: "" },
    { id: "facebook", label: "Facebook", enabled: false, url: "" },
    { id: "x",        label: "X",        enabled: false, url: "" },
    { id: "github",   label: "GitHub",   enabled: false, url: "" },
  ],

  staff: [
    { name: "EvThatGuy", role: "Owner", avatar: "" },
    { name: "Staff TBD", role: "Admin", avatar: "" },
  ],

  tips: {
    enabled: true,
    intervalMs: 6500,
    items: [
      "Welcome to Palm6 Bay, the heart of the Sunrise State.",
      "Stay in character. Use /me and /do for actions and details.",
      "New here? Read the rules pinned in the Discord before spawning in.",
      "The State of Verano runs on second chances. New day, new life.",
      "Report issues to staff in-game with /report.",
    ],
  },

  rules: {
    enabled: true,
    items: [
      "Stay in character in public channels and in-city.",
      "No RDM, VDM, or random combat without roleplay.",
      "Respect staff and players — use /report for issues.",
      "Read the full rules in Discord before you play.",
    ],
  },

  music: {
    enabled: false,
    file: "assets/music/track.mp3",
    title: "Palm6 Bay",
    volume: 0.35,
  },
};
