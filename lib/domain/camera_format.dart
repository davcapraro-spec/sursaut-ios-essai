/// Lecture et affichage des réglages de l'appareil (Sony A7 IV, protocole PTP 3).
///
/// Codes et codages VÉRIFIÉS sur l'appareil (banc des 19-20/11) : ISO, ouverture, vitesse.
/// Les autres propriétés (balance des blancs, compensation, mise au point, destination)
/// sont affichées en valeur brute tant que leur sens n'est pas confirmé.
library;

const int kPropIso = 0xD21E;
const int kPropAperture = 0x5007;
const int kPropShutter = 0xD20D;
const int kPropWhiteBalance = 0x5005;
const int kPropExposureMode = 0x500E;
const int kPropExposureComp = 0x5010;
const int kPropFocusMode = 0x500A;
const int kPropDrive = 0x5013;
const int kPropDestination = 0xD222;
const int kPropBattery = 0xD218;
const int kPropKelvin = 0xD20F;

/// ISO : 0xFFFFFF = AUTO ; l'octet de poids fort porte un drapeau (réduction de bruit multi-images), ignoré ici.
String formatIso(int cur) {
  final int v = cur & 0xFFFFFF;
  if (v == 0xFFFFFF) return 'AUTO';
  return '$v';
}

/// Ouverture : ƒ × 100 (0x276 = 630 → ƒ/6,3).
String formatAperture(int cur) {
  final double f = cur / 100.0;
  final String t = (f - f.roundToDouble()).abs() < 0.005 ? f.toStringAsFixed(0) : f.toStringAsFixed(1);
  return 'ƒ/${t.replaceAll('.', ',')}';
}

/// Vitesse : numérateur dans les 16 bits de poids fort, dénominateur dans les 16 bits de poids faible
/// (0x10064 = 1/100 s, 0x1007D = 1/125 s). Au-delà de 0,3 s : affichage en secondes.
String formatShutterCode(int cur) {
  final int top = (cur >> 16) & 0xFFFF;
  final int den = cur & 0xFFFF;
  if (den == 0 || top == 0) return '—';
  if (top == 1) return '1/$den';
  final double sec = top / den;
  if (sec >= 0.3) {
    final String t = (sec - sec.roundToDouble()).abs() < 0.005 ? sec.toStringAsFixed(0) : sec.toStringAsFixed(1);
    return '${t.replaceAll('.', ',')}"';
  }
  return '$top/$den';
}

/// Mode d'exposition : codes RELEVÉS sur l'A7 IV (molette tournée cran par cran, 26/11) :
/// M = 0x1, P = 0x10002, A = 0x20003, S = 0x30004, Auto intelligent = 0x48000.
/// Les mémoires de la molette (MR 1, 2, 3) n'ont pas encore été relevées : valeur brute affichée.
String formatExposureMode(int cur) {
  switch (cur & 0xFFFFFFFF) {
    case 0x1:
      return 'M';
    case 0x10002:
      return 'P';
    case 0x20003:
      return 'A';
    case 0x30004:
      return 'S';
    case 0x48000:
      return 'Auto';
    default:
      return formatRaw(cur);
  }
}

/// Batterie : octet signé en pourcentage (hypothèse confirmée seulement par une lecture).
int batteryPercent(int cur) {
  final int b = cur & 0xFF;
  return b > 127 ? b - 256 : b;
}

/// Valeur brute en hexadécimal, pour les propriétés dont le sens n'est pas encore confirmé.
String formatRaw(int cur) => '0x${(cur & 0xFFFFFFFF).toRadixString(16).toUpperCase()}';

/// Choix voisin dans la liste proposée par l'appareil (`dir` = +1 ou −1). Renvoie null s'il n'y en a pas.
/// Les listes de l'appareil ne sont pas toujours triées : on suit l'ordre de [sorted].
int? neighborChoice(List<int> sorted, int cur, int dir) {
  if (sorted.isEmpty) return null;
  final int i = sorted.indexOf(cur);
  if (i < 0) return null;
  final int j = i + dir;
  if (j < 0 || j >= sorted.length) return null;
  return sorted[j];
}

/// Trie les choix d'une propriété : « + » va toujours vers la valeur la plus haute.
/// ISO : AUTO en tête puis croissant. Ouverture : ƒ croissant (plus fermé). Vitesse : durée croissante (plus lent).
List<int> sortedChoices(int code, List<int> choices) {
  final List<int> c = List<int>.of(choices.toSet());
  switch (code) {
    case kPropIso:
      c.sort((int a, int b) {
        int k(int x) => (x & 0xFFFFFF) == 0xFFFFFF ? 0 : (x & 0xFFFFFF);
        return k(a).compareTo(k(b));
      });
    case kPropAperture:
      c.sort();
    case kPropShutter:
      double d(int x) {
        final int den = x & 0xFFFF;
        return den == 0 ? 0 : ((x >> 16) & 0xFFFF) / den;
      }
      c.sort((int a, int b) => d(a).compareTo(d(b)));
    default:
      c.sort();
  }
  return c;
}
