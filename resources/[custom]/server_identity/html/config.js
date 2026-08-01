/* Palm6 loading screen config — edit links, staff, and music here.
   Disabled socials are hidden. Music stays off until you drop an mp3
   and set enabled: true. */
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

  music: {
    enabled: false,
    file: "assets/music/track.mp3",
    title: "Palm6 Bay",
    volume: 0.35,
  },
};
