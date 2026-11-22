/// Identifiant stable d'une photo, calculé sur son contenu (et non sur son nom :
/// iPadOS donne un nom temporaire différent à chaque import depuis la bibliothèque).
/// Empreinte FNV-1a 64 bits sur les dimensions et un échantillon régulier des pixels.
String photoKey(List<int> rgba, int w, int h) {
  const int prime = 0x100000001b3;
  int hash = 0xcbf29ce484222325;
  void mix(int v) {
    hash = (hash ^ (v & 0xFF)) * prime;
  }

  for (final int v in <int>[w, h, w >> 8, h >> 8]) {
    mix(v);
  }
  const int step = 97;
  for (int i = 0; i < rgba.length; i += step) {
    mix(rgba[i]);
  }
  return 'photo_${hash.toUnsigned(64).toRadixString(16).padLeft(16, '0')}';
}
