# MTop

Moniteur système natif macOS inspiré de [btop](https://github.com/aristocratos/btop), écrit en SwiftUI et AppKit.

**[English](README.md)** · **Français**

## Fonctions

- **CPU** : charge totale et par cœur avec le dégradé vert, jaune et rouge de btop, utilisation du GPU, charge moyenne, durée de fonctionnement, batterie
- **Mémoire** : les mêmes catégories que le Moniteur d'activité (applications, câblée, compressée, en cache, libre), swap et pression mémoire
- **Réseau** : débits en réception et en envoi de l'interface principale, ou de celle choisie dans le menu
- **Disques** : lecture et écriture en temps réel ; espace disponible par volume comme le compte le Finder, la part purgeable étant distinguée
- **Processus** : table native triable, recherche, filtre « Mes processus », vue en arborescence (⌥⌘T) et inspecteur avec graphes CPU et mémoire du processus. Terminer, forcer à quitter, suspendre ou reprendre, après confirmation

- **Icône du Dock animée**, comme le Moniteur d'activité : **Affichage > Icône du Dock** montre l'utilisation du CPU par cœur, du GPU, la mémoire, l'activité réseau ou disque, et continue de s'animer fenêtre masquée

Intervalle de mesure de 0,5 à 5 s, pause avec ⇧⌘P. Quand la fenêtre est masquée ou recouverte, MTop continue de mesurer pour que les graphes restent complets, mais cesse de mettre à jour l'interface.

Sans droits administrateur, macOS ne fournit ni le CPU ni la mémoire des processus des autres utilisateurs (root, démons système) : ils apparaissent avec un tiret.

## Installation

Téléchargez le zip de la [dernière version](https://github.com/brihx001/MTop/releases/latest), décompressez-le et placez `MTop.app` dans `/Applications`.

L'application est signée en ad-hoc, pas notarisée par Apple : macOS met le téléchargement en quarantaine. Levez-la avant le premier lancement :

```bash
xattr -dr com.apple.quarantine /Applications/MTop.app
```

## Construction

macOS 14 ou plus récent, Swift 6.

```bash
./build.sh release
open MTop.app
```

Pour régénérer l'icône :

```bash
cd Packaging/Icon && swift make-icon.swift . && iconutil --convert icns --output ../AppIcon.icns AppIcon.iconset
```

## Licence

MIT, voir [LICENSE](LICENSE).
