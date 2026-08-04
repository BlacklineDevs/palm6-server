# Animated P6 logo (Higgsfield)

Export a transparent logo loop if possible:
- Prefer `logo-anim.webm` (VP9 + alpha) or MP4 with dark/black bg that matches the plate
- Square, ~512–1024px
- Soft motion only (glow / orbit / breathe) — keep the mark readable
- Drop as `assets/logo-anim.webm`

Then in `html/config.js`:

```js
logoVideo: "assets/logo-anim.webm",
```

Static `assets/logo.png` remains the fallback.
