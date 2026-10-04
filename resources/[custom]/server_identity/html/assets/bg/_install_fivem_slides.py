from pathlib import Path
from PIL import Image

src = Path(r"C:/Users/Mgtda/.cursor/projects/c-Users-Mgtda-Projects-Active-palm6-server/assets")
dest = Path(r"C:/Users/Mgtda/Projects/Active/palm6-server/resources/[custom]/server_identity/html/assets/bg/slides")
dest.mkdir(parents=True, exist_ok=True)

files = [
    "wide-01-station.jpg",
    "wide-02-bridge.jpg",
    "wide-03-drift.jpg",
    "wide-04-dusk.jpg",
    "wide-05-club.jpg",
    "wide-06-bay.jpg",
]
target_ar = 16 / 9
out_w, out_h = 2560, 1440

for i, name in enumerate(files, 1):
    path = src / name
    im = Image.open(path).convert("RGB")
    w, h = im.size
    ar = w / h
    if ar > target_ar:
        nw = int(h * target_ar)
        left = (w - nw) // 2
        im = im.crop((left, 0, left + nw, h))
    else:
        nh = int(w / target_ar)
        # Prefer LOWER portion so faces stay below logo safe zone
        top = max(0, h - nh - int((h - nh) * 0.08))
        im = im.crop((0, top, w, top + nh))
    im = im.resize((out_w, out_h), Image.Resampling.LANCZOS)
    out = dest / f"slide-{i:02d}.jpg"
    im.save(out, "JPEG", quality=93, optimize=True, progressive=True)
    print("wrote", out.name, out.stat().st_size // 1024, "KB")

print("done")
