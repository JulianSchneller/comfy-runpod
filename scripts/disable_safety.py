import re, sys
from pathlib import Path

def patch_text(txt:str):
    orig = txt
    # Make NSFW gating default permissive in common libs (best-effort, non-fatal if not found)
    txt = re.sub(r'block_nsfw\s*:\s*Optional\[bool\]\s*=\s*None','block_nsfw: Optional[bool] = False', txt)
    txt = re.sub(r'enable_nsfw\s*:\s*Optional\[bool\]\s*=\s*None','enable_nsfw: Optional[bool] = True', txt)
    return txt if txt != orig else None

patched = 0
for p in Path(".").rglob("*.py"):
    try:
        t = p.read_text(encoding="utf-8")
    except Exception:
        continue
    n = patch_text(t)
    if n:
        p.write_text(n, encoding="utf-8")
        print("✅ Patched:", p)
        patched += 1
print(f"Done. Patched files: {patched}")
