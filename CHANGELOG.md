# La Taverne 0.33.0-alpha

*2026-11-19*

## English

A big update: everyone in the guild (and the allied guilds) should update, so all of you run the same version. A `/reload` is enough, no game restart needed.

### New
- **Side tabs reorganized:** Groups (the open groups, and your own group while you're in one), Availability, Alliance, Auto-invite, then Setup (only for players who can edit the Guild Info) and Options. Settings pages open from a button on their page, with Back.
- **Alliance tab:** one card per guild, folding, with who is online with La Taverne, players seen in the last two weeks (offline ones in grey), and each guild's open groups and available players. Online players show within seconds of logging in.
- **Auto-invite:**
  - Keyword sets: several leaders can invite at once, each with their own words (`+1`, `+2`...), all editable in Settings.
  - The queue page shows who else is inviting, with their keywords, and turns orange when one of them uses yours.
  - Officers choose who may use it (everyone, only some ranks, or nobody), on the Setup tab.
  - Allied guilds are only listened to when you tick them (off by default), and guild chat can be turned off.
- **Setup tab** (officers): auto-invite rules and the Guild Alliance in one place, with one Save and a preview of the Guild Info lines.
- **Options in sections** (General, Minimap, Alerts, Shared guild chat): window size, the chat window for La Taverne's lines, minimap glow, a sound for join requests, and **Quiet in dungeons, raids and combat**.
- An entry in the game's add-on menu, and a La Taverne page in the game's AddOns options.
- Allied players seen in earlier sessions can be invited by name.
- Test mode, Debug tab: a **Message log** of every hidden La Taverne message, to help track down bugs (also `/taverne msglog`).

### Changes
- Create form: no role picked at first on a new character, then it starts with the role of your last group. What's missing shows in the Post button's tooltip.
- Each class can only pick its own roles.
- Battleground and Dungeon Finder groups don't count as being in a party.
- Shared guild chat with the allied guilds is always on.
- The minimap button and side tabs show a green dot when something of yours is running there.

### Fixes
- An allied player who only said hello is no longer shown with their guild tag before their guild confirms them.
- The "group posted" sound follows the quiet option, and no longer plays when the party lead is handed to you.
- Auto-invite: an allowed rank no longer loses it for a few seconds after logging in; the minutes typed in Settings are kept when you add or delete a keyword set.
- The Alliance tab no longer counts another guild's groups as yours.
- A guildmate is no longer dropped from the Alliance tab after one slow answer.
- "You're in this group" no longer overlaps the role spots in the group list.
- Logging in sends one request for the open groups instead of two.

## Français

Une grosse mise à jour : tout le monde dans la guilde (et dans les guildes alliées) devrait mettre à jour, pour que tous aient la même version. Un `/reload` suffit, pas besoin de relancer le jeu.

### Nouveautés
- **Onglets réorganisés :** Groupes (les groupes ouverts, et votre groupe quand vous en avez un), Disponibilités, Alliance, Invitation automatique, puis Configuration (seulement pour qui peut modifier les infos de guilde) et Options. Les pages de réglages s'ouvrent par un bouton sur leur page, avec Retour.
- **Onglet Alliance :** une carte par guilde, repliable, avec qui est en ligne avec La Taverne, les joueurs vus ces deux dernières semaines (en gris s'ils sont hors ligne), et les groupes ouverts et joueurs disponibles de chaque guilde. Les joueurs en ligne s'affichent quelques secondes après la connexion.
- **Invitation automatique :**
  - Jeux de mots-clés : plusieurs chefs peuvent inviter en même temps, chacun avec ses mots (`+1`, `+2`...), tous modifiables dans Réglages.
  - La page de la file montre qui d'autre invite, avec ses mots-clés, et passe en orange quand l'un d'eux utilise les vôtres.
  - Les officiers choisissent qui peut l'utiliser (tout le monde, certains rangs seulement, ou personne), dans l'onglet Configuration.
  - Les guildes alliées ne sont écoutées que si vous les cochez (désactivé par défaut), et le chat de guilde peut être désactivé.
- **Onglet Configuration** (officiers) : les règles de l'invitation automatique et l'alliance de guildes au même endroit, avec un seul Enregistrer et un aperçu des lignes des infos de guilde.
- **Options en sections** (Général, Minicarte, Alertes, Chat de guilde partagé) : taille de la fenêtre, fenêtre de chat pour les lignes de La Taverne, halo de la minicarte, un son pour les demandes à rejoindre, et **Silencieux en donjon, en raid et en combat**.
- Une entrée dans le menu des addons du jeu, et une page La Taverne dans les options AddOns du jeu.
- Les joueurs alliés vus lors de sessions précédentes peuvent être invités par leur nom.
- Mode test, onglet Débogage : un **Journal des messages** de chaque message caché de La Taverne, pour aider à trouver les bugs (aussi `/taverne msglog`).

### Changements
- Formulaire de création : aucun rôle choisi au départ sur un nouveau personnage, puis il reprend le rôle de votre dernier groupe. Ce qui manque s'affiche dans l'infobulle du bouton Publier.
- Chaque classe ne peut choisir que ses propres rôles.
- Les groupes de champ de bataille et de la recherche de donjon ne comptent pas comme être en groupe.
- Le chat de guilde partagé avec les guildes alliées est toujours actif.
- Le bouton de la minicarte et les onglets montrent un point vert quand quelque chose à vous y est en cours.

### Corrections
- Un joueur allié qui a seulement dit bonjour n'est plus affiché avec le tag de sa guilde avant que sa guilde le confirme.
- Le son « groupe publié » suit l'option silencieux, et ne joue plus quand on vous passe le chef du groupe.
- Invitation automatique : un rang autorisé ne la perd plus quelques secondes après la connexion ; les minutes tapées dans Réglages sont gardées quand vous ajoutez ou supprimez un jeu de mots-clés.
- L'onglet Alliance ne compte plus les groupes d'une autre guilde comme les vôtres.
- Un membre de la guilde ne disparaît plus de l'onglet Alliance après une seule réponse lente.
- « Vous êtes dans ce groupe » ne chevauche plus les places de rôle dans la liste des groupes.
- La connexion envoie une seule demande des groupes ouverts au lieu de deux.
