# Background loop (Higgsfield)

Drop your cinematic plate animation here.

Recommended:
- `bay-loop.mp4` (H.264) or `bay-loop.webm`
- 1920×1080 or 2560×1440
- 8–15s seamless loop
- Gentle atmosphere only — no hard camera pans
- Keep file under ~15MB if possible (CEF load speed)

Then in `html/config.js`:

```js
background: {
  poster: "palm6_screen.jpg",
  video: "assets/bg/bay-loop.mp4",
  loop: true,
},
```

Until the video exists, the static `palm6_screen.jpg` poster is used.
