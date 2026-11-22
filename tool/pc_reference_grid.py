"""Référence PC pour l'étape 3b : développe un RAW avec le code du PC (sursaut/imageio.py, rendu « appareil »)
et sort les moyennes de 8x8 zones x 3 canaux (0..255), identiques à la « GRILLE » du rapport RAW de l'iPad.
Usage : python pc_reference_grid.py <dossier Sursaut> <fichier.ARW> [demi|complet]"""
import json, sys
sys.path.insert(0, sys.argv[1])
import numpy as np
import sursaut.imageio as io

io.set_raw_base("appareil")
rgb = io.load_raw(sys.argv[2], "srgb", half=(len(sys.argv) > 3 and sys.argv[3] == "demi"))
h, w, _ = rgb.shape
ys = np.minimum(np.arange(h) * 8 // h, 7)
xs = np.minimum(np.arange(w) * 8 // w, 7)
cell = (ys[:, None] * 8 + xs[None, :]).ravel()
flat = rgb.reshape(-1, 3).astype(np.float64)
grid = []
cnt = np.bincount(cell, minlength=64)
for c in range(64):
    pass
sums = np.stack([np.bincount(cell, weights=flat[:, k], minlength=64) for k in range(3)], axis=1)
grid = (sums / cnt[:, None] / 257.0).round(1).ravel().tolist()
print(json.dumps({"file": sys.argv[2].split("/")[-1], "w": w, "h": h, "grid": grid}))
