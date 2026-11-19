# Sursaut iPad : application d'essai (étape 0)

But : prouver la chaîne **Flutter → GitHub Actions → fichier .ipa → AltStore → iPad**, sans moteur Sursaut.
L'application ne fait qu'ouvrir une photo et bouger un curseur de luminosité (simple filtre d'affichage).

**Non vérifié** : ces fichiers n'ont pas été compilés (pas de Flutter dans l'environnement où ils ont été écrits). Le premier lancement sert de test.

## Contenu
- `lib/` : application (coque, thème, écran d'essai).
- `test/smoke_test.dart` : un test minimal.
- `.github/workflows/ios.yml` : compilation iOS non signée, lancée à la main.
- Pas de dossier `ios/` ni `windows/` : le flux les fabrique (`flutter create`).

## A. Essayer sur le PC (facultatif, recommandé avant de pousser)
```
flutter create . --platforms=windows --project-name sursaut_essai
git checkout -- lib test pubspec.yaml analysis_options.yaml   (si vous utilisez git)
flutter pub get
flutter run -d windows
```
Attendu : une fenêtre sombre ; « Choisir une photo » ouvre un sélecteur ; le curseur change la luminosité ; double appui sur le curseur = 0.

## B. Compiler pour l'iPad
1. Créer un dépôt GitHub **public et séparé** (par exemple `sursaut-ios-essai`) : minutes gratuites, aucun code de Sursaut dedans.
2. Y pousser ce dossier tel quel.
3. Onglet **Actions** > `ios-essai` > **Run workflow**.
4. À la fin : noter la **durée** et les **versions de Flutter et de Xcode** affichées dans le journal (test 0.1 du cahier), puis télécharger l'artefact `SursautEssai-ipa` (un zip contenant `SursautEssai-non-signe.ipa`).
5. Si le flux échoue : ouvrir le journal, copier les dernières lignes d'erreur et me les envoyer.

## C. Installer
Voir `sursaut-ios-premier-essai-altserver.md` (étapes A, D et E) : AltStore sur l'iPad, `.ipa` ajouté par **My Apps > +**, renouvellement au 5e jour.
