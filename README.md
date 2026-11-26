# Sursaut iPad

Application de retouche photo pour iPad (Flutter + plugin Swift + moteur Rust), version d'essai installée sans App Store.
Le dépôt est **public et séparé** : il ne contient aucun code du Sursaut de bureau autre que le moteur copié dans `engine/`.
Sursaut est et reste **gratuit**.

Version courante : voir `pubspec.yaml` (affichée aussi dans l'application).

## Ce que fait l'application

**Développement** (`lib/features/develop`)
- Ouverture d'une photo, y compris les RAW (lecture par LibRaw, couleur RAW, développement RAW).
- Réglages de développement, courbe, HSL, histogramme, recadrage, retouche de taches, masques.
- Annuler / rétablir, historique des recettes, sauvegarde.
- Masques par IA (personnes, visage, parties du corps) : en attente. « Supprimer » par IA (LaMa) : bloqué (voir plus bas).

**Capturer** (`lib/features/capture`), mode connecté Sony A7 IV en USB-C
- Réglages lus sur l'appareil : mode d'exposition, ISO, ouverture, vitesse, compensation, balance des blancs, mise au point, entraînement, destination, batterie.
- ISO, ouverture, vitesse et compensation modifiables avec − / +.
- Vue directe de l'appareil, carré de mise au point déplaçable au toucher, cadre de la zone permise, bouton « Mise au point ».
- Déclenchement, réception de la photo, aperçu, ouverture dans Développement.

**Diagnostics** (bouton discret de l'accueil) : bancs d'essai de l'appareil (vue directe, collimateur, réglages).

Statut des informations de l'appareil :
- Vérifié sur l'A7 IV : vue directe, déplacement du carré de mise au point, ISO, ouverture, vitesse, mode d'exposition, batterie, Auto (balance des blancs), vue par vue, destination « iPad + carte ».
- Lu dans la référence Sony, pas encore relevé sur l'appareil : les autres noms de balance des blancs, de mise au point, d'entraînement et de destination, et le décodage de la compensation.

## Organisation du code

| Dossier | Rôle |
|---|---|
| `lib/app` | coque, accueil, thème |
| `lib/features` | écrans : `develop`, `capture`, `diagnostics` |
| `lib/domain` | logique pure sans écran (courbes, masques, recadrage, formats de l'appareil…) |
| `lib/engine` | accès au moteur Rust |
| `lib/common` | outils communs (version…) |
| `packages/pencil_bridge` | plugin iOS en Swift : Apple Pencil, appareil Sony (ImageCaptureCore / PTP), Core ML, TensorFlow Lite |
| `engine` | moteur Rust (`sursaut-core` copié du PC, pont vers l'iPad) |
| `tools` | scripts de compilation (CocoaPods, synchronisation du moteur) |
| `test` | tests Flutter |

Règle des couches (vérifiée par `test/layers_test.dart`) : les dépendances ne vont que vers le bas (app → features → engine / domain / common) ; un écran n'importe jamais un autre écran. L'accueil fournit les passages d'un écran à l'autre.

Pas de dossier `ios/` dans le dépôt : le workflow le fabrique avec `flutter create`, puis remet nos fichiers.

## Compiler pour l'iPad (GitHub Actions)

1. Pousser les modifications sur `main`.
2. Onglet **Actions** > **ios-essai** > **Run workflow**.
3. Le workflow enchaîne : tests Rust, moteur Rust pour iOS, Flutter, TensorFlow Lite, modèles SAM 2.1, icône, autorisations, analyse, tests Flutter, compilation sans signature, fabrication de l'ipa.
4. **Règle du projet : tout doit être vert**, y compris « Tests Flutter (ne bloque pas) », même si cette étape ne bloque pas techniquement.
5. À la fin, télécharger l'artefact **SursautEssai-ipa** (un zip contenant `SursautEssai-non-signe.ipa`).
6. Si le workflow échoue : ouvrir le journal de l'étape en rouge et copier les dernières lignes d'erreur.

## Installer sur l'iPad (AltServer, compte Apple gratuit)

L'ipa n'est pas signé : la signature se fait à l'installation avec l'identifiant Apple gratuit, **valable 7 jours**.

1. PC : lancer AltServer en administrateur (icône près de l'horloge). iTunes et iCloud doivent être les versions du site d'Apple, pas celles du Microsoft Store.
2. iPad branché en USB (ou sur le même Wi-Fi, avec la synchronisation Wi-Fi activée dans iTunes), déverrouillé.
3. Décompresser le zip téléchargé pour obtenir le `.ipa`.
4. Clic sur l'icône AltServer > **Sideload .ipa…** > choisir l'iPad puis le fichier `.ipa`, saisir l'identifiant Apple si demandé.
5. Sur l'iPad : Réglages > Général > VPN et gestion de l'appareil > faire confiance à l'identifiant Apple ; mode développeur activé (Réglages > Confidentialité et sécurité).
6. Ouvrir Sursaut et vérifier que la version affichée est celle attendue.

**Renouvellement** : le certificat gratuit expire au bout de 7 jours (dernier en date : 26/11/2026). Avant l'expiration, refaire l'étape 4 avec le même ipa (non vérifié : conservation des données de l'application lors de la réinstallation). Une fois expiré, l'application ne s'ouvre plus tant qu'on ne l'a pas réinstallée.

Pour un détail pas à pas, voir la note du projet « premier essai AltServer ».

## Mode connecté (Sony A7 IV)

1. Appareil réglé en connexion USB de contrôle à distance (intitulé exact à relever dans le menu de l'A7 IV), câble USB-C branché à l'iPad.
2. Dans Sursaut : **Capturer** > connexion. L'écran affiche les réglages, puis l'image directe.
3. Toucher l'image déplace le carré de mise au point sur l'appareil.
4. **Déclencher** : la photo reçue s'affiche en aperçu ; « Ouvrir dans Développement » la charge.

Wi-Fi Direct : pas encore testé (prévu en décembre).

## Limites connues

- **« Supprimer » par IA** (LaMa) : bloqué par le certificat du serveur de téléchargement d'ONNX Runtime. Le code est conservé derrière `#if canImport` (voir `tools/ort_pods.sh`).
- **Masques de personnes** : en attente.
- **Compte gratuit** : 3 applications au plus, 10 identifiants d'application ; AltStore compte pour une application.
- Pas de débogage en direct de l'iPad depuis Windows : on contrôle sur l'iPad lui-même.
- Jamais de service de signature tiers (certificats souvent révoqués).

## Sur le PC (facultatif)

Moteur Rust : `cd engine && cargo test --workspace`.
Les tests Flutter se lancent avec `flutter test` ; le workflow les lance de toute façon à chaque compilation.
