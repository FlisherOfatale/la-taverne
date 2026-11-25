# La Taverne 1.3.0

*2026-11-24*

## English

### New
- **Guild relay:** members of an allied guild who don't run La Taverne now show up too. One La Taverne player of each guild (the relay, picked on its own: players in a city first, never in a dungeon or raid) passes their guild chat lines on to the allied guilds, and their map positions when they share them through OpenMap. Nothing is written in the real guild chat. You can stop helping in **Options** (Help relay for my guild), and officers can turn it off for the whole guild in the Alliance setup. The Alliance tab and the minimap tooltip show who relays for each guild. Thanks to FlisherOfatale.
- **Players passed on by a relay are checked too:** a line from a relay you can vouch for confirms its author (auto-invite without a click); from a relay nobody vouches for, they're "(not checked yet)", and someone the game shows in another guild has their lines and map dot hidden. The Alliance tab lists them, folded, in each guild's card. Thanks to FlisherOfatale.
- **Controller:** with the game's controller interface on, La Taverne is used with the controller. The d-pad moves a gold frame between the window's elements (with their tooltips), A chooses, Y goes back or closes, LB / RB change section, and lists scroll to follow. A line under the window shows the buttons. B and X stay the game's; in combat the controller goes back to the game. Thanks to NuCl34R.
- **Invitation card:** when a leader invites you, a card shows on screen with the invitation and a **View** button, with its own sound (heard even with sound effects turned down) and the taskbar flash. No answer after 2 minutes: a reminder in chat and the sound once more. A key binding, **Show what's waiting (invitation, join request)**, does View without the mouse (game Options, Keybindings, AddOns). Thanks to FlisherOfatale.
- **Allied players in Availability:** the allied players online at the tavern now show in the list too, with their guild's tag, their class color and level, even when they aren't available.
- **`/taverne roster`:** the guild roster (rank, level, class, online, days offline, notes, and officer notes for ranks that can see them) and the game's roster history, as text to copy into a spreadsheet, each field in its own column. Thanks to FlisherOfatale.
- **`/taverne debug`:** everything La Taverne can tell about a problem (no chat text), in one text to copy and send to the author. **`/taverne clearcache`** forgets the remembered players (vouching, guild rosters, players seen) if they ever look wrong.

### Changes
- **Availability:** "Other members online" is now **Players not looking for a group right now**, one short line per player; someone without La Taverne shows "Doesn't have La Taverne" where Invite would be. With your group open and "Only those who fit my group" ticked, the available players who don't fit get their own folded section, **Available, but not for your group**.
- **Alliance tab:** allied players' names in their class color, and each player's level in their tooltip. Allied players running an older version show up without them until they update.
- A player's level shows under their name in tooltips: a group's leader in the list, and each player on a group's role icons.
- Allied chat: the grey mark now only shows next to players without La Taverne.
- The minimap button's glow is round.
- Updated developer tools.

### Fixes
- La Taverne now notices an alliance channel that looks connected but doesn't pass messages, and joins it again on its own.
- In allied chat, an item link keeps its rarity color even when your game doesn't know the item yet.
- The relay's speech bubble on the minimap button is no longer cut off by minimap skins.

## Français

### Nouveautés
- **Relais de guilde :** les membres d'une guilde alliée qui n'utilisent pas La Taverne apparaissent aussi. Un joueur de chaque guilde qui utilise La Taverne (le relais, choisi tout seul : les joueurs en ville d'abord, jamais en donjon ou en raid) transmet leurs lignes du chat de guilde aux guildes alliées, et leur position sur la carte quand ils la partagent avec OpenMap. Rien n'est écrit dans le vrai chat de guilde. Vous pouvez arrêter d'aider dans les **Options** (Aider à relayer pour ma guilde), et les officiers peuvent le désactiver pour toute la guilde dans la configuration de l'alliance. L'onglet Alliance et l'infobulle de la minicarte indiquent qui relaie pour chaque guilde. Merci à FlisherOfatale.
- **Les joueurs transmis par un relais sont vérifiés aussi :** une ligne d'un relais dont vous pouvez vous porter garant confirme son auteur (invitation automatique sans clic) ; d'un relais dont personne ne se porte garant, ils sont « (non vérifié) », et quelqu'un que le jeu montre dans une autre guilde a ses lignes et son point sur la carte cachés. L'onglet Alliance les liste, repliés, dans la carte de chaque guilde. Merci à FlisherOfatale.
- **Manette :** avec l'interface manette du jeu activée, La Taverne s'utilise à la manette. La croix déplace un cadre doré entre les éléments de la fenêtre (avec leurs infobulles), A choisit, Y revient en arrière ou ferme, LB / RB changent de section, et les listes défilent pour suivre. Une ligne sous la fenêtre montre les boutons. B et X restent au jeu ; en combat, la manette revient au jeu. Merci à NuCl34R.
- **Carte d'invitation :** quand un chef vous invite, une carte s'affiche à l'écran avec l'invitation et un bouton **Voir**, avec son propre son (entendu même avec les effets sonores baissés) et le clignotement de la barre des tâches. Sans réponse après 2 minutes : un rappel dans le chat et le son une fois de plus. Un raccourci, **Afficher ce qui vous attend (invitation, demande)**, fait Voir sans la souris (Options du jeu, Raccourcis, AddOns). Merci à FlisherOfatale.
- **Les joueurs alliés dans Disponibilités :** les joueurs alliés en ligne à la taverne apparaissent maintenant aussi dans la liste, avec le tag de leur guilde, la couleur de leur classe et leur niveau, même quand ils ne sont pas disponibles.
- **`/taverne roster` :** la liste de guilde (rang, niveau, classe, en ligne, jours hors ligne, notes, et notes d'officier pour les rangs qui peuvent les voir) et l'historique de la liste du jeu, en texte à copier dans un tableur, chaque champ dans sa propre colonne. Merci à FlisherOfatale.
- **`/taverne debug` :** tout ce que La Taverne peut dire sur un problème (sans le texte du chat), en un seul texte à copier et envoyer à l'auteur. **`/taverne clearcache`** oublie les joueurs mémorisés (vérifications, listes de guilde, joueurs vus) s'ils semblent erronés.

### Changements
- **Disponibilités :** « Autres membres en ligne » devient **Joueurs ne cherchant pas de groupe pour le moment**, une courte ligne par joueur ; quelqu'un sans La Taverne affiche « N'a pas La Taverne » à la place d'Inviter. Avec votre groupe ouvert et « Seulement ceux qui conviennent à mon groupe » coché, les joueurs disponibles qui ne conviennent pas ont leur propre section repliée, **Disponibles, mais pas pour votre groupe**.
- **Onglet Alliance :** le nom des joueurs alliés dans la couleur de leur classe, et le niveau de chaque joueur dans son infobulle. Les joueurs alliés qui ont une version plus ancienne s'affichent sans ces informations jusqu'à leur mise à jour.
- Le niveau d'un joueur s'affiche sous son nom dans les infobulles : le chef d'un groupe dans la liste, et chaque joueur sur les icônes de rôle d'un groupe.
- Chat allié : la marque grise ne s'affiche plus qu'à côté des joueurs sans La Taverne.
- La lueur du bouton de la minicarte est ronde.
- Outils de développement mis à jour.

### Corrections
- La Taverne repère maintenant un canal de l'alliance qui semble connecté mais ne transmet pas les messages, et le rejoint d'elle-même.
- Dans le chat allié, un lien d'objet garde la couleur de sa rareté même quand votre jeu ne connaît pas encore l'objet.
- La bulle du relais sur le bouton de la minicarte n'est plus coupée par les skins de minicarte.
