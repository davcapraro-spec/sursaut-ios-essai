#!/bin/bash
# Étape du CI retirée le 26/11/2026 (serveur download.onnxruntime.ai en panne : certificat refusé). À remettre dans ios.yml
# (après « TensorFlow Lite (contrôle CocoaPods…) ») avec la dépendance onnxruntime-objc du podspec quand le serveur sera réparé.
set -e
V=1.19.2
CURL=/usr/local/opt/curl/bin/curl
[ -x "$CURL" ] || CURL=curl
mkdir -p /tmp/ort
fetch() { # $1 = url, $2 = fichier
  "$CURL" -fsSL --retry 2 -m 600 -o "$2" "$1" && return 0
  echo "Téléchargement normal refusé : on essaie un autre résolveur DNS (la vérification du certificat reste active)."
  for doh in https://cloudflare-dns.com/dns-query https://dns.google/dns-query https://dns.quad9.net/dns-query; do
    "$CURL" -fsSL --retry 1 -m 600 --doh-url "$doh" -o "$2" "$1" && return 0
  done
  # Dernier recours : l'adresse de stockage Microsoft d'origine de ces archives (hypothèse : même fichier ; l'empreinte du podspec le confirmera).
  alt="${1/download.onnxruntime.ai/onnxruntimepackages.z14.web.core.windows.net}"
  if [ "$alt" != "$1" ]; then
    echo "Essai de l'adresse de stockage : $alt"
    "$CURL" -fsSL --retry 1 -m 600 -o "$2" "$alt" && return 0
  fi
  return 1
}
for pod in onnxruntime-c onnxruntime-objc; do
  h=$(md5 -q -s "$pod")
  shard="${h:0:1}/${h:1:1}/${h:2:1}"
  fetch "https://cdn.cocoapods.org/Specs/$shard/$pod/$V/$pod.podspec.json" "/tmp/ort/$pod.orig.json"
  python3 - "$pod" "$V" <<'PY'
import json, sys
pod, v = sys.argv[1], sys.argv[2]
spec = json.load(open(f"/tmp/ort/{pod}.orig.json"))
src = spec["source"]
print(pod, "source :", src)
open(f"/tmp/ort/{pod}.url", "w").write(src["http"])
open(f"/tmp/ort/{pod}.sha1", "w").write(src.get("sha1", ""))
PY
  url=$(cat "/tmp/ort/$pod.url"); sha1=$(cat "/tmp/ort/$pod.sha1")
  fetch "$url" "/tmp/ort/$pod.zip"
  got=$(shasum -a 1 "/tmp/ort/$pod.zip" | cut -d' ' -f1)
  echo "$pod : SHA-1 reçu $got, attendu $sha1"
  [ -z "$sha1" ] || [ "$got" = "$sha1" ] || { echo "Empreinte différente : archive refusée."; exit 1; }
  python3 - "$pod" <<'PY'
import json, sys
pod = sys.argv[1]
spec = json.load(open(f"/tmp/ort/{pod}.orig.json"))
sha1 = open(f"/tmp/ort/{pod}.sha1").read()
spec["source"] = {"http": f"file:///tmp/ort/{pod}.zip"}
if sha1:
    spec["source"]["sha1"] = sha1
json.dump(spec, open(f"/tmp/ort/{pod}.podspec.json", "w"), indent=2)
PY
done
python3 - <<'PY'
p = "ios/Podfile"
t = open(p).read()
line = "target 'Runner' do\n"
assert t.count(line) == 1, "Podfile : « target 'Runner' do » introuvable"
add = "  pod 'onnxruntime-c', :podspec => '/tmp/ort/onnxruntime-c.podspec.json'\n  pod 'onnxruntime-objc', :podspec => '/tmp/ort/onnxruntime-objc.podspec.json'\n"
open(p, "w").write(t.replace(line, line + add))
PY
grep -n "onnxruntime" ios/Podfile
