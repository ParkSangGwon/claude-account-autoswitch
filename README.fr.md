<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="Icône de Claude AutoSwitch">
</p>
<h1 align="center">Claude AutoSwitch</h1>
<p align="center">
  Plusieurs abonnements Claude, un seul Claude Code. Une app de barre des menus qui fait tourner vos comptes<br>
  automatiquement à mesure que leurs limites se remplissent, et affiche le quota de chaque compte d'un coup d'œil.
</p>
<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Ni Node ni CLI à installer" src="https://img.shields.io/badge/runtime-none%20needed-2ea44f">
  <img alt="7 langues" src="https://img.shields.io/badge/languages-7-3b82f6">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>
<p align="center" data-readme-switcher>
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · Français
</p>

<p align="center">
  <img src="docs/assets/menubar/menubar-item.png" width="440" alt="L'élément de barre des menus : 3h18m 33% à côté des éléments système">
</p>
<p align="center">
  <img src="docs/assets/menubar/popover-dark.png" width="406" alt="Le panneau : table des comptes, barres de tous les comptes, routage, sessions et journal de rotation">
</p>

## Le problème

**Un seul forfait Max à $200 ne suffit plus, alors vous en payez deux ou trois.**<br>
Voici à quoi ça ressemble de l'intérieur.

#### Le freelance aux deux forfaits Max

> « Chaque après-midi, c'est la même ligne : `You've hit your usage limit · resets at 4pm`.<br>
> Navigateur, déconnexion, reconnexion, retour au terminal, retrouver où j'en étais. »

Deux ou trois fois par jour, cinq minutes à chaque fois.<br>
Soit une demi-journée perdue chaque mois.

#### Celui qui a installé un commutateur de comptes

> « Ça m'épargne un clic. Ça ne me dit pas quand cliquer.<br>
> Je surveille toujours la limite et je bascule à la main. »

#### Celui qui utilise un TUI à rotation

> « La bascule est automatique maintenant. Voir ce qu'il reste ne l'est pas.<br>
> C'est un terminal de plus et une commande de plus, à côté de celui dans lequel je travaille vraiment. »

**« Je ne peux pas simplement… »**

- **…utiliser deux comptes ?** Si. À chaque limite atteinte, le commutateur, c'est vous.
- **…installer un commutateur de comptes ?** Il raccourcit la bascule à un clic. Savoir quand basculer, et vers quel compte, reste à votre charge.
- **…lancer un des TUI qui font tourner les comptes ?** Ils les font tourner. Ils gardent aussi l'usage dans un terminal que vous devez laisser ouvert.

**Ça vous parle ?**

- [ ] Vous payez plus d'un forfait Max.
- [ ] Un message de limite vous envoie tout droit dans le navigateur.
- [ ] Il vous arrive d'oublier sur quel compte est un terminal.
- [ ] Vous ouvrez un terminal juste pour voir ce qu'il reste.
- [ ] La limite hebdomadaire vous surprend à chaque fois.

Trois cases cochées ou plus, et la section suivante est pour vous.

## La solution

Claude AutoSwitch est un proxy local doté d'une barre des menus.<br>
Connectez deux comptes Claude ou plus et placez le proxy devant Claude Code.<br>
Chaque requête part avec le jeton d'un compte qui a encore de la marge.<br>
Quand un compte atteint sa limite 5 heures ou hebdomadaire, la requête suivante utilise simplement un autre compte.<br>
Claude Code ne se déconnecte jamais, ne redémarre jamais, et n'en sait jamais rien.<br>
La limite qu'il lit est celle de la rotation, pas celle d'un seul compte : tant qu'un autre compte a de la marge, aucun message de limite n'apparaît.<br>
Le quota de chaque compte s'affiche dans la barre des menus, si bien que vous n'ouvrez plus jamais un terminal juste pour y jeter un œil.

Ce n'est pas un *commutateur* de comptes : rien n'est échangé dans le trousseau et aucune session n'est interrompue.<br>
La rotation se fait par requête, avant que la limite ne soit atteinte, et plusieurs terminaux peuvent être sur des comptes différents en même temps.

## Installation

Prérequis : macOS 14 Sonoma ou plus récent et Claude Code.<br>
Il n'y a ni Node, ni paquet npm, ni autre proxy à installer.

### Homebrew

```sh
brew install --cask ParkSangGwon/tap/claude-autoswitch
```

Si macOS refuse ensuite d'ouvrir l'app, retirez l'attribut de quarantaine : `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"` (ou « Ouvrir quand même », décrit plus bas).

### Release GitHub

Téléchargez `Claude-AutoSwitch-vX.Y.Z.zip` depuis la [dernière release](https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest).<br>
Décompressez-la et glissez **Claude AutoSwitch.app** dans `/Applications`.

### Depuis les sources

```sh
git clone https://github.com/ParkSangGwon/claude-account-autoswitch
cd claude-account-autoswitch
make install          # builds dist/Claude AutoSwitch.app and copies it to /Applications
```

L'app est signée ad hoc, pas notarisée.<br>
Au premier lancement, macOS peut indiquer qu'il ne peut pas vérifier le développeur.<br>
Ouvrez **Réglages Système → Confidentialité et sécurité** et cliquez sur **Ouvrir quand même**, ou clic droit sur l'app → **Ouvrir**.

## Configuration en trois étapes

1. **Ajoutez des comptes.** Réglages → Comptes → *Ajouter un compte…*
   - Connectez-vous via le navigateur.
   - Collez un code quand le navigateur ne peut pas joindre ce Mac.
   - Importez la connexion que Claude Code a déjà (trousseau).
2. **Placez le proxy devant Claude Code.** Une seule ligne, affichée avec un bouton Copier sous Réglages → Proxy :
   ```sh
   [ -f "$HOME/Library/Application Support/Claude AutoSwitch/env.sh" ] && source "$HOME/Library/Application Support/Claude AutoSwitch/env.sh"
   ```
   Ajoutez-la à votre profil de shell, ou utilisez *Ouvrir le Terminal avec Claude Code*.
   Pour un éditeur ou un lanceur qui exécute le binaire directement, pointez-le sur `claude-autoswitch` dans le même dossier plutôt que sur `claude`.
3. **Activez Ouvrir à l'ouverture de session** (Réglages → Général) pour que le proxy soit là dès que Claude Code l'est.

C'est toute la configuration.<br>
Claude Code garde sa propre connexion et continue de parler à `api.anthropic.com`, si bien que le contrôle à distance, les réglages gérés et la politique d’organisation continuent de fonctionner.<br>
Le proxy remplace le jeton à la sortie et laisse tout le reste de la requête intact.

## Le certificat

Le proxy se place devant `api.anthropic.com`, ce qui veut dire qu’il doit terminer le TLS de cet hôte, et donc qu’il lui faut un certificat que Claude Code accepte.<br>
L’app crée une autorité de certification sur ce Mac et n’y dirige que Claude Code, via la variable `NODE_EXTRA_CA_CERTS` du fichier de configuration.<br>
Elle n’est **pas** ajoutée au trousseau système : aucun navigateur, aucune autre app et aucun autre outil ne lui fait confiance, et par défaut rien n’y est dirigé.<br>
Tant que Claude Code lui fait confiance, le proxy déchiffre puis rechiffre le trafic de l’API Claude de ce processus — c’est précisément le mécanisme qui remplace le jeton, et les versions utilisant `ANTHROPIC_BASE_URL` voyaient déjà ces mêmes requêtes en clair.<br>
Quiconque détient la **clé privée** de la CA pourrait émettre des certificats que Claude Code accepterait : cette clé n’est donc jamais écrite sur le disque ; le renouvellement régénère toute la chaîne, et le seul secret stocké est une clé leaf pour un seul hôte.<br>
Supprimez le dossier de l’app et la confiance disparaît avec lui, sans rien laisser dans le trousseau système.

## Ce que vous obtenez

- **Un élément de barre des menus qui se lit comme un usage.**
  - `1h12m 42%` est la fenêtre 5 heures de tous les comptes : le temps avant sa réinitialisation, puis la part utilisée. Les barres en dessous sont 5 heures et hebdomadaire.
  - Orange quand une barre devance sa fenêtre, rouge au seuil de bascule ou quand rien ne peut servir.
  - `→ par` pendant six secondes lors d'une rotation, `—` quand l'écoute est arrêtée.
- **Chaque compte d'un coup d'œil.**
  - Barres Session, Hebdomadaire et par famille (Fable, Sonnet), avec le nombre et la réinitialisation sous chacune.
  - Palier, priorité, comptes à rebours de bridage et les sessions épinglées sur le compte.
  - Un menu par ligne : définir comme compte actuel, activer, ignorer un moment, priorité, retirer.
- **Où va la prochaine requête, et pourquoi.**
  - La raison de l'ancien compte, une meilleure priorité, ou « reste sur ted ».
- **Totaux de tous les comptes et chronologie des réinitialisations.**
  - Agrégats pondérés par palier qui ne comptent que les comptes pouvant encore utiliser la fenêtre.
  - Chaque prochaine réinitialisation de fenêtre, avec `↑` sur celles qui remettent un compte en rotation.
- **Des fenêtres qui suivent l'horloge, pas l'heure à laquelle vous vous installez.**
  - Claude démarre une fenêtre de 5 heures à votre première requête : une fenêtre touchée à 16h30 court donc jusqu'à 21h30, et la journée en contient moins qu'elle ne le pourrait.
  - *Garder la fenêtre de 5 heures ouverte*, dans le popover sous la chronologie des réinitialisations, ouvre la fenêtre suivante de chaque compte dès que la précédente se réinitialise.
  - C'est désactivé tant que vous ne le demandez pas, car la requête part avec votre compte, et un Mac qui a dormi ouvre une réinitialisation manquée dans la minute qui suit le réveil.
- **Une rotation qui gère les cas réels.**
  - Un 429 qui nomme une fenêtre fermée bride le compte pour la durée de son retry-after.
  - Un 429 qui ne nomme aucune fenêtre transmet seulement la requête au compte suivant et laisse le compte dans la rotation ; seules les répétitions l'écartent.
  - Un jeton expiré est rafraîchi une fois puis la requête est rejouée.
  - 403 et 5xx basculent.
  - Quand tous les comptes sont épuisés, les requêtes peuvent être mises en attente pendant une durée configurable au lieu d'échouer.
  - Le refus qui suit nomme la fenêtre fermée et l'heure de sa réouverture, si bien que Claude Code patiente et reprend la tâche de lui-même au lieu de s'arrêter sur une erreur.
  - Un redémarrage reprend là où la rotation s'était arrêtée, au lieu d'envoyer la première requête à un compte déjà épuisé.
- **Sessions.**
  - Chaque session Claude Code reste sur son compte par compartiment hebdomadaire.
  - La distribution équilibrée, optionnelle, répartit les nouvelles sessions sur le compte le moins chargé.
- **Quand quelque chose cloche, l'app le dit.**
  - Un fichier de configuration illisible n'est jamais écrasé, et l'erreur nomme la clé à corriger.
  - Un port occupé nomme le programme qui le tient et en propose un libre ; un proxy auquel personne ne parle le signale.
- **Basculez depuis n'importe où.**
  - Le menu des comptes dans le panneau, le menu du clic droit, ou `⌃⌥⌘N` pour le prochain compte qui peut servir.
  - `⌃⌥⌘T` ouvre le panneau.
- **Des notifications qui ont un sens.**
  - Seuils de tous les comptes, une rotation avec sa raison, un compte qui quitte la rotation ou y revient.
  - Une reconnexion nécessaire, la sonde en échec, une mise en attente, la facturation du dépassement.
  - Suspendez-les pendant une heure.
- **Sept jours d'historique.**
  - Un échantillon par minute tant que l'app tourne : sparklines de tous les comptes et bande d'état par compte, conservés localement.
- **Parle votre langue.**
  - English, 한국어, 日本語, 简体中文, Español, Deutsch, Français.
  - Suit la liste des langues du Mac et se change sur place.

## Galerie

#### Comptes
<img src="docs/assets/menubar/settings-accounts.png" width="780" alt="Volet Comptes">

#### Rotation
<img src="docs/assets/menubar/settings-rotation.png" width="780" alt="Volet Rotation : seuil de bascule, seuils par compartiment, distribution des sessions, mise en attente">

#### Proxy
<img src="docs/assets/menubar/settings-proxy.png" width="780" alt="Volet Proxy : état de l'écoute et la ligne dont Claude Code a besoin">

#### Général
<img src="docs/assets/menubar/settings-general.png" width="780" alt="Volet Général : style de la barre des menus, langue, actualisation, raccourcis, notifications">

## L'élément de barre des menus

| Titre | Signification |
| --- | --- |
| `1h12m 42%` | La fenêtre 5 heures de tous les comptes se réinitialise dans 1h12m et est utilisée à 42 %. Les barres en dessous sont 5 heures (haut) et hebdomadaire (bas). |
| `ted 1h12m 42%` | Épinglé sur le compte actuel (Réglages → Général) : son tag à trois lettres ouvre le titre. |
| `1h12m 42% · 3d12h 61%` | Le style *Barres + 5h · 7d* : la fenêtre hebdomadaire aussi. |
| `1h12m 93%!` | Critique : au seuil de bascule, ou rien ne peut servir. |
| `→ par` | Une rotation vient d'avoir lieu ; affiché pendant six secondes. |
| `—` | L'écoute est arrêtée (en général le port est occupé). |
| `0%` | Aucun compte pour l'instant. |

## Raccourcis

| Touches | Où | Action |
| --- | --- | --- |
| `⌃⌥⌘N` | partout | Basculer vers le prochain compte disponible |
| `⌃⌥⌘T` | partout | Afficher ou masquer le panneau |
| `⌘R` `⌘T` `⌘,` `⌘Q` | panneau | Actualiser · Ouvrir le Terminal avec Claude Code · Réglages · Quitter |
| clic droit sur l'élément | barre des menus | Basculer, actualiser, recharger la configuration, suspendre les notifications |

## Fonctionnement

- L'app fait tourner un proxy sur `127.0.0.1` (SwiftNIO), que Claude Code atteint via `HTTPS_PROXY`.
- Elle termine elle-même `CONNECT api.anthropic.com:443` et transmet chaque requête en amont avec l'`Authorization` du compte choisi à la place de celle du client ; tout autre hôte est tunnelisé sans y toucher.
- Tous les autres en-têtes passent tels quels, et `metadata.user_id` nomme le compte dont le jeton est parti.
- Les réponses sont renvoyées en flux au fur et à mesure qu'elles arrivent.
- Les comptes sont choisis par priorité, puis par la fenêtre hebdomadaire qui se réinitialise le plus tôt.
- Tout compte désactivé, bridé, au plafond, en erreur, ou à son seuil pour la famille de modèle de la requête est sauté.
- Les en-têtes `anthropic-ratelimit-*` de chaque réponse maintiennent à jour les fenêtres de chaque compte.
- Une sonde en arrière-plan de l'endpoint d'usage complète les comptes inactifs.
- Les jetons sont rafraîchis cinq minutes avant leur expiration.
- La configuration vit dans `~/Library/Application Support/Claude AutoSwitch/config.json`, écrite de façon atomique avec les permissions `0600`.
- Les jetons sont dans ce fichier et nulle part ailleurs.

La référence du fichier de configuration, de l'endpoint de santé et des règles de rotation se trouve dans [docs/reference.md](docs/reference.md).

## Confidentialité

Seuls deux hôtes sont jamais contactés : l'API Claude (vos requêtes, la sonde d'usage, le rafraîchissement des jetons) et, pendant la connexion, claude.ai / platform.claude.com.<br>
Le trafic vers tout autre hôte traverse le proxy sans être déchiffré.<br>
Pas de télémétrie, pas de vérification de mise à jour.<br>
L'export des diagnostics remplace chaque secret avant d'écrire.

## Une note sur les conditions d'utilisation

Faire tourner des requêtes sur plusieurs abonnements personnels peut sortir du cadre que les conditions grand public d'Anthropic prévoient.<br>
Ce projet vous montre le quota de vos propres comptes et vous laisse décider comment les utiliser.<br>
Lisez les conditions qui s'appliquent à votre forfait.

## Documentation

- [docs/troubleshooting.md](docs/troubleshooting.md) : Gatekeeper, un port occupé, la reconnexion, les jetons partagés avec d'autres outils.
- [docs/reference.md](docs/reference.md) : le fichier de configuration, l'endpoint de santé, les règles de rotation.
- [CHANGELOG.md](CHANGELOG.md) : ce qui a changé à chaque release.

## Développement

```sh
swift build
swift test            # engine tests run against loopback stand-ins for the Claude API
make app              # dist/Claude AutoSwitch.app
AUTOSWITCH_DEBUG_DEMO_QUOTA=1 CLAUDE_AUTOSWITCH_CONFIG=/tmp/demo.json swift run ClaudeAutoSwitch
```

- `AutoSwitchCore` : le modèle (comptes, fenêtres, bloqueurs), les règles (ordonnancement, rythme, totaux de tous les comptes), la localisation et le document de configuration.
- `AutoSwitchEngine` : le proxy, avec comptes, OAuth, quota, rotation et listener.
- `ClaudeAutoSwitch` : l'app.
- Les chaînes vivent dans `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings`, indexées par le texte anglais.
- Un test échoue si une chaîne des sources n'y a pas de ligne.
- `AUTOSWITCH_DEBUG_WINDOW=<section>` et `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` ouvrent un volet de réglages et le panneau pour les captures d'écran.
- `README.md` et les six traductions à côté changent ensemble ; `scripts/check-readmes.sh` échoue quand leur structure dérive.

## Licence

MIT.
