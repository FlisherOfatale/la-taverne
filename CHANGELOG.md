# La Taverne 1.2.0

*2026-11-22*

## English

### New
- **Available players where you make your group:** while creating a group, a line beside the dungeon says who's available for it ("Available: 1 Tank, 2 DPS"); click it to add one to the invitations. In **My group**, the available players who fit show under the requests, each with **Invite**.
- **Groups in progress clean up after themselves:** a group in progress is removed on its own once everyone has left (after 5 minutes alone) or after 3 hours, with a warning in chat first. The next time you open La Taverne, the form is filled in to post it again in one click.
- **Map switches at hand:** show or hide your guild's and the allies' dots with the lynx tab on the world map or the minimap button's right-click menu, without opening Options. Thanks to FlisherOfatale.
- **Alliance tab:** sort the players by name, last heard from or version (to see who needs to update), and show the offline ones or not. Each member's version shows, with "(old version)" in orange when it's behind.

### Changes
- **Announce in chat** now sends a La Taverne message to the players who run it, with a link to your group, instead of a line in guild chat. Not in the group's first 5 minutes, then once every 5 minutes. Each player can turn these messages off: **Options > Alerts > Show group announcements from leaders**.
- In the group list, groups in progress or full are folded under their own heading. The filters fit on one line, and "Hide groups in progress" is gone (the folded heading does its job).
- With OpenMap: its own "Guild members on the map" switch also hides La Taverne's guild and allied dots, and La Taverne's dot tooltips look like OpenMap's.
- Players on your ignore list stay hidden in the shared guild chat too.
- The error report starts empty with each new version.
- Updated developer tools.

### Fixes
- The alliance channel no longer stays stuck on "connecting": La Taverne joins it again on its own when the game drops it, including when it looks connected but nothing goes through, and checks it after the game's chat server comes back.
- Nothing sent by the other guilds in the first seconds after a login or `/reload` is lost any more.
- The Guild Alliance no longer turns itself off for a moment during a loading screen, and shows right after login without opening the game's guild window.
- Achievement links (Legacy objectives) in allied chat show as their name, not as code.

## Français

### Nouveautés
- **Les joueurs disponibles là où vous montez votre groupe :** pendant la création d'un groupe, une ligne à côté du donjon indique qui est disponible pour lui (« Disponibles : 1 Tank, 2 DPS ») ; un clic en ajoute un aux invitations. Dans **Mon groupe**, les joueurs disponibles qui conviennent s'affichent sous les demandes, chacun avec **Inviter**.
- **Les groupes en cours se rangent d'eux-mêmes :** un groupe en cours est retiré tout seul quand tout le monde est parti (après 5 minutes seul) ou après 3 heures, avec un avertissement dans le chat avant. À la prochaine ouverture de La Taverne, le formulaire est déjà rempli pour le republier en un clic.
- **Les options de la carte à portée de main :** affichez ou cachez les points de votre guilde et des alliés avec l'onglet lynx sur la carte du monde ou le menu du clic droit sur le bouton de la minicarte, sans ouvrir les Options. Merci à FlisherOfatale.
- **Onglet Alliance :** triez les joueurs par nom, dernier signe ou version (pour voir qui doit mettre à jour), et affichez ou non ceux qui sont hors ligne. La version de chaque membre s'affiche, avec « (ancienne version) » en orange quand elle est en retard.

### Changements
- **Annoncer dans le chat** envoie maintenant un message de La Taverne aux joueurs qui l'utilisent, avec un lien vers votre groupe, au lieu d'une ligne dans le chat de guilde. Pas dans les 5 premières minutes du groupe, puis une fois toutes les 5 minutes. Chaque joueur peut désactiver ces messages : **Options > Alertes > Afficher les annonces de groupe des chefs**.
- Dans la liste des groupes, les groupes en cours ou complets sont repliés sous leur propre titre. Les filtres tiennent sur une ligne, et « Masquer les groupes en cours » disparaît (le titre replié fait le travail).
- Avec OpenMap : sa propre option « Membres de guilde sur la carte » cache aussi les points de guilde et d'alliés de La Taverne, et les infobulles des points de La Taverne ressemblent à celles d'OpenMap.
- Les joueurs de votre liste d'ignorés restent cachés dans le chat de guilde partagé aussi.
- Le rapport d'erreurs repart vide à chaque nouvelle version.
- Outils de développement mis à jour.

### Corrections
- Le canal de l'alliance ne reste plus bloqué sur « connexion » : La Taverne le rejoint d'elle-même quand le jeu le coupe, y compris quand il semble connecté mais que rien ne passe, et le vérifie quand le serveur de chat du jeu revient.
- Plus rien de ce qu'envoient les autres guildes dans les premières secondes après une connexion ou un `/reload` n'est perdu.
- L'alliance de guildes ne se désactive plus un instant pendant un écran de chargement, et s'affiche dès la connexion sans ouvrir la fenêtre de guilde du jeu.
- Les liens de hauts faits (objectifs Legacy) dans le chat allié s'affichent avec leur nom, pas en code.
