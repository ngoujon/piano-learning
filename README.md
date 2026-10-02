# Piano Learning 🎹

Application macOS pour apprendre le piano, morceau par morceau, avec reconnaissance de la note jouée au micro.

## Fonctionnalités

- **Catalogue en ligne** : toutes les partitions gratuites de [partition-piano-gratuite.fr](https://www.partition-piano-gratuite.fr/) (niveau, compositeur, recherche), **écoute de l'aperçu MP3**, visualisation du PDF, et ajout en un clic (PDF + MIDI téléchargés).
- **Ma collection** : morceaux téléchargés ou importés (PDF, MIDI, MusicXML `.musicxml/.mxl`) via le bouton *Importer* (⌘O), le glisser-déposer, ou « Ouvrir avec » depuis le Finder. Un PDF et un MIDI portant le même nom sont regroupés ; un PDF seul reconnu dans le catalogue récupère automatiquement son MIDI.
- **Apprentissage (mode attente)** : l'app affiche la note à jouer (nom, portée clé de sol/clé de fa, touche du clavier), écoute votre piano au micro et **passe à la note suivante seulement quand la bonne touche est jouée**. Mauvaise note signalée, précision et progression enregistrées, reprise là où vous vous êtes arrêté.
  - main droite / main gauche / deux mains, « mélodie seule » ou accords complets
  - écouter la note (espace), passer (→), revenir (←), boucle sur un passage difficile
  - option « n'importe quelle octave », sensibilité du micro, choix du micro
  - partition PDF affichée à côté pendant la leçon
  - clavier MIDI USB/Bluetooth pris en charge (détection exacte)
- **Apprendre depuis un PDF seul** : reconnaissance optique de partition avec [Audiveris](https://audiveris.github.io) (logiciel libre, installable en un clic depuis l'app). Résultat fiable sur les partitions simples, approximatif sur les partitions chargées.
- **Écouter un morceau** (rendu MIDI piano, 50/75/100 %) avec les touches qui s'allument.
- **Pratique libre** : le micro affiche la note jouée (et l'accordage) pendant que vous lisez une partition.

## Construire et lancer

Nécessite macOS 14+ et les Command Line Tools (Xcode non obligatoire).

```bash
scripts/build_app.sh            # crée build/Piano Learning.app
open "build/Piano Learning.app"
scripts/build_app.sh --install  # copie aussi l'app dans /Applications
scripts/test.sh                 # tests (parseurs, détection de hauteur, tests audio de bout en bout)
```

Au premier lancement d'une leçon, macOS demande l'accès au micro : acceptez-le.

## Conseils pour la détection au micro

- Placez le micro près du piano ; un micro de casque gaming avec réduction de bruit peut atténuer le piano — un micro USB ou celui d'un Mac portable fonctionne mieux. Le micro se choisit dans *Options* ou dans les Réglages (⌘,).
- Commencez avec « Main droite » + « Mélodie seule ». Les accords sont détectés, mais la détection d'une note seule est la plus fiable.
- L'app coupe l'écoute pendant qu'elle joue elle-même un son, pour ne pas s'auto-valider.

## Architecture

- `Sources/PianoCore` : logique testable — lecture MIDI/MusicXML, écriture MIDI, découpage en étapes (mains, accords), analyse de hauteur (YIN + spectre harmonique), `NoteMatcher` (décision juste/faux), parseur du catalogue.
- `Sources/PianoLearning` : app SwiftUI — catalogue, collection, leçon, pratique libre, moteur audio (échantillonneur piano GM de macOS), micro, clavier MIDI, OCR Audiveris.
- Variable `PIANO_TEST_AUDIO=fichier.wav` : remplace le micro par un fichier audio (test d'une leçon sans piano).
