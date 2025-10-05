# -*- coding: utf-8 -*-
"""
Patcht ComfyUI-Workflows für controlnet_aux (OpenPose/DWPose):
- Liest die tatsächlich installierten Klassen aus node_wrappers.py
- Remappt veraltete/abweichend geschriebene class_type-Namen
- Legt .bak-Backups an
"""
import sys, json, pathlib, importlib, importlib.util

# Kandidaten für ComfyUI-Root und Workflows
CN_ROOTS = [
    "/workspace/ComfyUI/custom_nodes",
    "/ComfyUI/custom_nodes",
    "/content/ComfyUI/custom_nodes",
]
WF_DIRS = [
    "/workspace/ComfyUI/workflows",
    "/workspace/workflows",
    "/ComfyUI/workflows",
    "/content/ComfyUI/workflows",
]

def import_wrappers():
    # 1) normal importierbar?
    for name in ("comfyui_controlnet_aux.node_wrappers",
                 "custom_nodes.comfyui_controlnet_aux.node_wrappers"):
        try:
            m = importlib.import_module(name)
            if hasattr(m, "NODE_CLASS_MAPPINGS"):
                return m, name
        except Exception:
            pass
    # 2) direkte Datei
    for root in CN_ROOTS:
        p = pathlib.Path(root)/"comfyui_controlnet_aux"/"node_wrappers.py"
        if p.exists():
            spec = importlib.util.spec_from_file_location("cn_aux_wrappers", str(p))
            m = importlib.util.module_from_spec(spec)  # type: ignore
            spec.loader.exec_module(m)                 # type: ignore
            if hasattr(m, "NODE_CLASS_MAPPINGS"):
                return m, f"file://{p}"
    raise RuntimeError("controlnet_aux.node_wrappers nicht gefunden")

mod, origin = import_wrappers()
NODE_MAP = dict(getattr(mod, "NODE_CLASS_MAPPINGS", {}))
keys = list(NODE_MAP.keys())
print(f"[cn_aux_patch] controlnet_aux aus: {origin}")
print("[cn_aux_patch] Knoten (Auszug):", [k for k in keys if k.lower().startswith("controlnet_aux.")][:6], "…")

def pick_canonical(suffix: str):
    target = ("controlnet_aux."+suffix).lower()
    for k in keys:
        if k.lower() == target:
            return k
    for k in keys:
        if k.lower().endswith(suffix.lower()):
            return k
    return None

canon_openpose = pick_canonical("openposepreprocessor")
canon_dwpose   = pick_canonical("dwposepreprocessor")
print("[cn_aux_patch] OpenPose →", canon_openpose or "❌", " | DWPose →", canon_dwpose or "❌")

if not (canon_openpose or canon_dwpose):
    print("[cn_aux_patch] ❌ Keine passenden Klassen gefunden – skip")
    sys.exit(0)

REMAP = {}
if canon_openpose:
    for old in [
        "controlnet_aux.OpenposePreprocessor",   # häufige Variante (kleines p)
        "controlnet_aux.OpenPosePreprocessor",   # Variante (großes P)
        "controlnet_aux.openposepreprocessor",   # ganz klein
        "controlnet_aux.Openposepreprocessor",
        "controlnet_aux.OpenposePreProcessor",
    ]:
        REMAP[old.lower()] = canon_openpose
if canon_dwpose:
    for old in [
        "controlnet_aux.DWposePreprocessor",
        "controlnet_aux.DWPosePreprocessor",
        "controlnet_aux.dwposepreprocessor",
        "controlnet_aux.DwposePreprocessor",
        "controlnet_aux.DwPosePreprocessor",
    ]:
        REMAP[old.lower()] = canon_dwpose

def patch_one(fp: pathlib.Path) -> bool:
    try:
        data = json.loads(fp.read_text(encoding="utf-8"))
    except Exception:
        return False
    nodes = data.get("nodes")
    if not isinstance(nodes, list):
        return False
    touched = False
    for n in nodes:
        if not isinstance(n, dict): continue
        t = n.get("class_type")
        if not isinstance(t, str):  continue
        new = REMAP.get(t.lower())
        if new and new != t:
            n["class_type"] = new
            touched = True
    if touched:
        bak = fp.with_suffix(fp.suffix + ".bak")
        try:
            bak.write_text(fp.read_text(encoding="utf-8"), encoding="utf-8")
        except Exception:
            pass
        fp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return touched

scanned = changed = 0
for d in WF_DIRS:
    base = pathlib.Path(d)
    if not base.exists(): 
        continue
    for fp in base.rglob("*.json"):
        scanned += 1
        if patch_one(fp):
            print("[cn_aux_patch] ✔ gepatcht:", fp)
            changed += 1

print(f"[cn_aux_patch] Fertig. gescannt={scanned}, geändert={changed}")
