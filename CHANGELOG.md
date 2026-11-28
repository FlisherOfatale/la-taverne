# La Taverne 1.4.0

*2026-11-27*

## English

### New
- A **Professions** tab: find who in your guild or the allied guilds can make a recipe. Type its name or shift-click an item, then ask: every La Taverne whose character, or one of its alts, knows it answers within a few seconds, with the cooldown if it has one and whether they're available to help. Whisper opens the chat box on them with the item ready, not sent. Your recipes are shared the same way: untick Share my recipes on the page to stop.
- The guild relay page says, for each of your guild's relays, when it was last heard on the guild channel and on the alliance channel, and warns when the allied guilds may not be seeing it.
- The guild relay checks itself while it runs (a job nobody takes, two relays at once, a late signal, a relay the allied guilds may not see) and says so in the relay page's events and the copied report.

### Changes
- Guild relay: a relay in a fight keeps passing guild chat on right away. It only pauses during a boss fight, when the game blocks addon messages. After a boss fight it checks at once whether someone took over meanwhile, instead of waiting for its next regular signal (up to a minute, with two players relaying meanwhile).
- Groups: groups of any size from 2 to 40 show correctly (a later version will let "Other" groups choose their size). A big group shows one count per role instead of one spot per player.
- Groups: a group from a dungeon this version doesn't know shows as "Other (see note)", or with its own short title when it has one, and isn't announced in chat (later versions will use this for activities).
- Updated developer tools.

### Fixes
- Guild relay: lines written in a guild's linked Discord are no longer passed on to the allied guilds. They showed as a code like |Kx4|k: the game never gives addons their words.
- The "a newer La Taverne is in use" line no longer points players to test versions they can't get.

## Français

### Nouveautés
- Un onglet **Métiers** : trouvez qui, dans votre guilde ou les guildes alliées, peut fabriquer une recette. Tapez son nom ou faites Maj-clic sur un objet, puis demandez : chaque La Taverne dont le personnage, ou un de ses alts, la connaît répond en quelques secondes, avec le temps de recharge s'il y en a un et s'il est disponible pour aider. Chuchoter ouvre la boîte de discussion sur lui avec l'objet prêt, sans l'envoyer. Vos recettes sont partagées de la même façon : décochez Partager mes recettes sur la page pour arrêter.
- La page du relais de guilde indique, pour chaque relais de votre guilde, quand il a été entendu pour la dernière fois sur le canal de guilde et sur le canal de l'alliance, et avertit quand les guildes alliées risquent de ne pas le voir.
- Le relais de guilde se vérifie lui-même pendant qu'il fonctionne (une tâche que personne ne prend, deux relais à la fois, un signal en retard, un relais que les guildes alliées ne voient peut-être pas) et le signale dans les événements de la page du relais et dans le rapport copié.

### Changements
- Relais de guilde : un relais en combat continue de transmettre le chat de guilde tout de suite. Il ne fait une pause que pendant un combat de boss, quand le jeu bloque les messages d'add-on. Après un combat de boss, il vérifie aussitôt si quelqu'un a pris le relais entre-temps, au lieu d'attendre son prochain signal habituel (jusqu'à une minute, avec deux joueurs qui relayaient en même temps).
- Groupes : les groupes de toute taille, de 2 à 40, s'affichent correctement (une version future permettra aux groupes « Autre » de choisir leur taille). Un grand groupe affiche un compte par rôle au lieu d'une place par joueur.
- Groupes : un groupe d'un donjon que cette version ne connaît pas s'affiche comme « Autre (voir la note) », ou avec son propre titre court s'il en a un, et n'est pas annoncé dans le chat (les versions futures s'en serviront pour les activités).
- Outils de développement mis à jour.

### Corrections
- Relais de guilde : les lignes écrites dans le Discord lié à une guilde ne sont plus transmises aux guildes alliées. Elles s'affichaient comme un code du genre |Kx4|k : le jeu ne donne jamais leurs mots aux add-ons.
- La ligne « une version plus récente de La Taverne est utilisée » n'envoie plus les joueurs vers des versions de test qu'ils ne peuvent pas obtenir.
