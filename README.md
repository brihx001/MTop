# MTop

Moniteur système natif macOS inspiré de [btop](https://github.com/aristocratos/btop), écrit en SwiftUI.

- CPU : charge totale et par cœur, GPU, charge moyenne, durée de fonctionnement, batterie
- Mémoire : mêmes catégories que le Moniteur d'activité, pression mémoire, swap
- Réseau : débits en réception et en envoi par interface
- Disques : lecture et écriture, espace disponible par volume (y compris purgeable)
- Processus : table triable, recherche, vue en arborescence (⌥⌘T), inspecteur, signaux (terminer, forcer, suspendre, reprendre)

Sans droits administrateur, macOS ne fournit ni le CPU ni la mémoire des processus des autres utilisateurs : ils apparaissent avec un tiret.

## Construction

macOS 14 ou plus récent, Swift 6.

```bash
./build.sh release
open MTop.app
```

L'icône se régénère avec :

```bash
cd Packaging/Icon && swift make-icon.swift . && iconutil --convert icns --output ../AppIcon.icns AppIcon.iconset
```
