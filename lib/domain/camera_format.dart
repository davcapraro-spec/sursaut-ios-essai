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

/// Compensation d'exposition : entier signé sur 16 bits = valeur réelle en EV × 1000 (référence Sony :
/// 0xEC78 = −5,0 EV, 0x1388 = +5,0 EV). Lu dans la référence ; pas encore relevé sur l'A7 IV.
int signed16(int cur) {
  final int v = cur & 0xFFFF;
  return v > 0x7FFF ? v - 0x10000 : v;
}

String formatExposureComp(int cur) {
  final int v = signed16(cur);
  if (v == 0) return '0 EV';
  final double ev = v.abs() / 1000.0;
  final String t = (ev - ev.roundToDouble()).abs() < 0.05 ? ev.roundToDouble().toStringAsFixed(0) : ev.toStringAsFixed(1);
  return '${v < 0 ? '−' : '+'}${t.replaceAll('.', ',')} EV';
}

/// Balance des blancs (0x5005) : table de la référence Sony ; 2 = auto confirmé par la lecture du banc (20/11).
String formatWhiteBalance(int cur) {
  switch (cur & 0xFFFF) {
    case 0x0001:
      return 'Manuelle';
    case 0x0002:
      return 'Auto';
    case 0x0003:
      return 'Une touche';
    case 0x0004:
      return 'Lumière du jour';
    case 0x0005:
      return 'Fluorescent';
    case 0x0006:
      return 'Incandescent';
    case 0x0007:
      return 'Flash';
    case 0x8001:
      return 'Fluo : blanc chaud';
    case 0x8002:
      return 'Fluo : blanc froid';
    case 0x8003:
      return 'Fluo : blanc jour';
    case 0x8004:
      return 'Fluo : lumière du jour';
    case 0x8010:
      return 'Nuageux';
    case 0x8011:
      return 'Ombre';
    case 0x8012:
      return 'Température de couleur';
    case 0x8020:
      return 'Perso 1';
    case 0x8021:
      return 'Perso 2';
    case 0x8022:
      return 'Perso 3';
    case 0x8023:
      return 'Perso';
    case 0x8030:
      return 'Sous l\'eau auto';
    default:
      return formatRaw(cur);
  }
}

/// Mode de mise au point (0x500A) : table de la référence Sony.
String formatFocusMode(int cur) {
  switch (cur & 0xFFFF) {
    case 0x0001:
      return 'MF';
    case 0x0002:
      return 'AF-S';
    case 0x0003:
      return 'Macro auto';
    case 0x8004:
      return 'AF-C';
    case 0x8005:
      return 'AF-A';
    case 0x8006:
      return 'DMF';
    case 0x8007:
      return 'MF inversée';
    case 0x8008:
      return 'AF-D';
    case 0x8009:
      return 'Pré-réglée';
    default:
      return formatRaw(cur);
  }
}

/// Destination de la photo (0xD222) : 0x11 (iPad + carte) mesuré au banc le 20/11 ; les deux autres lus dans la référence.
String formatDestination(int cur) {
  switch (cur & 0xFFFF) {
    case 0x0001:
      return 'iPad';
    case 0x0010:
      return 'Carte';
    case 0x0011:
      return 'iPad + carte';
    default:
      return formatRaw(cur);
  }
}

/// Entraînement (0x5013, 32 bits) : table de la référence Sony ; « vue par vue » (0x1) relevé au banc. Les autres : à confirmer.
String formatDrive(int cur) {
  final int v = cur & 0xFFFFFFFF;
  switch (v) {
    case 0x00000001:
      return 'Vue par vue';
    case 0x00010002:
      return 'Rafale Hi';
    case 0x00018010:
      return 'Rafale Hi+';
    case 0x00018011:
      return 'Rafale Hi (vue directe)';
    case 0x00018012:
      return 'Rafale Lo';
    case 0x00018013:
      return 'Rafale';
    case 0x00018014:
      return 'Rafale, priorité vitesse';
    case 0x00018015:
      return 'Rafale Mid';
    case 0x00018016:
      return 'Rafale Mid (vue directe)';
    case 0x00018017:
      return 'Rafale Lo (vue directe)';
    case 0x00020003:
      return 'Intervallomètre';
    case 0x00038003:
      return 'Retardateur 5 s';
    case 0x00038004:
      return 'Retardateur 10 s';
    case 0x00038005:
      return 'Retardateur 2 s';
    case 0x00068018:
      return 'Bracket balance des blancs −';
    case 0x00068028:
      return 'Bracket balance des blancs +';
    case 0x00078019:
      return 'Bracket DRO −';
    case 0x00078029:
      return 'Bracket DRO +';
    case 0x0007801A:
      return 'Bracket filtre passe-bas';
    case 0x0007800A:
      return 'Télécommande';
    case 0x0007800B:
      return 'Miroir relevé';
    case 0x00078006:
      return 'Autoportrait, 1 personne';
    case 0x00078007:
      return 'Autoportrait, 2 personnes';
    case 0x00088008:
      return 'Retardateur continu, 3 vues';
    case 0x00088009:
      return 'Retardateur continu, 5 vues';
  }
  final String? br = _formatBracket(v);
  return br ?? formatRaw(cur);
}

/// Bracketing d'exposition : 0x0004xxxx = en rafale, 0x0005xxxx = vue par vue. Le haut de la partie basse donne
/// le nombre de vues (0xC2 = 2 vues, 0x83 / 0x85 / 0x87 / 0x89 = 3 / 5 / 7 / 9), l'octet bas l'écart (table de la référence).
String? _formatBracket(int v) {
  final int group = v >> 16;
  if (group != 4 && group != 5) return null;
  final int hi = (v >> 8) & 0xFF;
  int lo = v & 0xFF;
  String sign = '';
  int n;
  if (hi == 0xC2) {
    n = 2;
    if ((lo & 0x08) != 0) {
      sign = ' −';
      lo &= ~0x08;
    } else {
      sign = ' +';
    }
  } else if (hi == 0x83) {
    n = 3;
  } else if (hi == 0x85) {
    n = 5;
  } else if (hi == 0x87) {
    n = 7;
  } else if (hi == 0x89) {
    n = 9;
  } else {
    return null;
  }
  if (group == 5) lo += 1;
  const Map<int, String> steps = <int, String>{
    0x37: '0,3', 0x57: '0,5', 0x77: '0,7', 0x11: '1', 0x41: '1,3', 0x61: '1,5',
    0x81: '1,7', 0x21: '2', 0x51: '2,3', 0x71: '2,5', 0x91: '2,7', 0x31: '3',
  };
  final String? st = steps[lo];
  if (st == null) return null;
  return '${group == 4 ? 'Bracket rafale' : 'Bracket simple'} $st EV, $n vues$sign';
}

/// Batterie : octet signé en pourcentage (VÉRIFIÉ sur l'A7 IV : l'écran de l'iPad affiche le même pourcentage que le boîtier).
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
/// ISO : AUTO en tête puis croissant. Ouverture : ƒ croissant (plus fermé). Vitesse : durée décroissante (« + » = plus rapide, « − » = plus lent).
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
    case kPropExposureComp:
      c.sort((int a, int b) => signed16(a).compareTo(signed16(b)));
    case kPropFocusMode:
      // Ordre logique : manuel, puis AF ponctuel, continu, auto, puis les autres.
      const List<int> order = <int>[0x0001, 0x8006, 0x0002, 0x8004, 0x8005, 0x0003, 0x8007, 0x8008, 0x8009];
      int r(int x) {
        final int i = order.indexOf(x);
        return i < 0 ? 100 + x : i;
      }
      c.sort((int a, int b) => r(a).compareTo(r(b)));
    case kPropWhiteBalance:
      // Auto, puis lumière du jour, nuageux, ombre, incandescent, fluorescents, flash, température de couleur, perso.
      const List<int> order = <int>[
        0x0002, 0x0004, 0x8010, 0x8011, 0x0006, 0x0005, 0x8001, 0x8002, 0x8003, 0x8004, 0x0007, 0x8012, 0x8020, 0x8021, 0x8022, 0x8023, 0x0003, 0x0001, 0x8030
      ];
      int r(int x) {
        final int i = order.indexOf(x);
        return i < 0 ? 100 + x : i;
      }
      c.sort((int a, int b) => r(a).compareTo(r(b)));
    case kPropDrive:
      // Vue par vue, rafales, retardateurs, intervallomètre, puis bracketings et le reste.
      const List<int> group = <int>[0, 1, 3, 2, 4, 5, 6, 7, 8];
      int g(int x) {
        final int i = group.indexOf((x >> 16) & 0xFFFF);
        return i < 0 ? 100 : i;
      }
      int t(int x) => x == 0x00038005 ? 0 : (x == 0x00038003 ? 1 : (x == 0x00038004 ? 2 : x));
      c.sort((int a, int b) {
        final int k = g(a).compareTo(g(b));
        return k != 0 ? k : t(a).compareTo(t(b));
      });
    case kPropShutter:
      double d(int x) {
        final int den = x & 0xFFFF;
        return den == 0 ? 0 : ((x >> 16) & 0xFFFF) / den;
      }
      c.sort((int a, int b) => d(b).compareTo(d(a)));
    default:
      c.sort();
  }
  return c;
}
