# La Taverne

**La Taverne joins your guild and its allied guilds as if they were one: shared guild chat, plus a dungeon group finder where you post or join groups and show when you're available to play.**

*Français plus bas.*

---

## English

### Features

**Shared guild chat with allied guilds**
- What you type in guild chat also reaches the allied guilds, and theirs reaches you, in your usual guild chat (same colors, timestamps, clickable names) and in the guild window.
- The allied guild's tag shows in front of the name (optional).
- Allied players are checked: their own guild confirms they really belong to it. A player who isn't confirmed is marked, and an impostor's messages are dropped.

**Dungeon group finder**
- Post a group in a few clicks: dungeon, the roles you're looking for, a note, and options like "New players welcome" or "Discord required".
- Browse the open groups of your guild and allied guilds, filtered by your roles, your level and the dungeons you want. Dungeon level ranges use the game's difficulty colors.
- Ask to join with every role you can play. The leader accepts you as one of them, and La Taverne sends the party invite.
- Invite players by name, follow requests and members in "My group", and look for replacements once the run has started.
- Get a chat alert (with a sound if you want) when a new group fits you.

**"I'm available"**
- Tell your guild and allied guilds you're free to play: your roles, the dungeons you want, for how long, and a note.
- Group leaders see you right away and can invite you in one click.

**Auto-invite**
- Turn it on, and guild members (and allied players) who type a keyword like `+1` or `inv` in guild chat get a party invite, right away or when you click.
- Keywords and the time limit are yours to set. It's always off when you log in.

**Also**
- Dungeon names in the other language (English / French) in tooltips, handy when your guild mixes game languages.
- Minimap button, key binding, and a status tooltip.
- English and French.

### Getting started

1. Install La Taverne and log in. Everyone who wants to use it needs the addon.
2. Open it with the minimap button, `/taverne`, or a key binding (Options > Key Bindings > AddOns).
3. That's it inside your guild: groups, availability and auto-invite work right away, with no setup.

### Allied guilds (officers)

Linking guilds is done once by an officer of each guild, someone who can edit the Guild Info:

1. **Alliance** tab > **Setup** page: add the allied guilds and a short tag for each, create the shared key, then **Save**. The game doesn't let addons change the Guild Info, so La Taverne shows the new Guild Info text to copy and paste: your current text with a few short lines starting with `LT:` added, the rest left alone.
2. **Export**, and send the text to an officer of each allied guild. They paste it with **Import**, then **Save**.
3. Every member's addon reads the Guild Info and connects on its own.

Already using GuildUnion? **Import > From GuildUnion** copies its guilds and tags. Both addons' lines fit side by side in the Guild Info. While both are installed, keep only one of them sharing guild chat, or allied lines show twice. In La Taverne it's in **Options**.

### Commands

- `/taverne`: open or close the window
- `/taverne autoinvite`: turn auto-invite on or off
- `/taverne errors`: the error report, to send along with a bug report

### Bugs and suggestions

Please open an issue on GitHub, or leave a comment on CurseForge. If La Taverne reported an error, **Options > Error report** has a text you can copy into your message.

### Credits

- Allied guild chat in the guild window follows GuildUnion's approach (MIT, by Sadance).
- Uses Ace3 (AceComm, AceSerializer, CallbackHandler), ChatThrottleLib, LibStub, LibDataBroker and LibDBIcon.

### License

MIT

---

## Français

**La Taverne réunit votre guilde et ses guildes alliées comme une seule : chat de guilde partagé, et une recherche de groupes de donjon pour publier ou rejoindre des groupes et indiquer quand vous êtes disponible.**

### Fonctionnalités

**Chat de guilde partagé avec les guildes alliées**
- Ce que vous écrivez dans le chat de guilde arrive aussi aux guildes alliées, et le leur vous arrive, dans votre chat de guilde habituel (mêmes couleurs, horodatage, noms cliquables) et dans la fenêtre de guilde.
- Le tag de la guilde alliée s'affiche devant le nom (au choix).
- Les joueurs alliés sont vérifiés : leur propre guilde confirme qu'ils en font bien partie. Un joueur non confirmé est signalé, et les messages d'un imposteur sont ignorés.

**Recherche de groupes de donjon**
- Publiez un groupe en quelques clics : le donjon, les rôles recherchés, une note, et des options comme « Nouveaux joueurs bienvenus » ou « Discord requis ».
- Parcourez les groupes ouverts de votre guilde et des guildes alliées, filtrés selon vos rôles, votre niveau et les donjons voulus. Les tranches de niveau prennent les couleurs de difficulté du jeu.
- Demandez à rejoindre avec tous les rôles que vous pouvez jouer. Le chef vous accepte dans l'un d'eux, et La Taverne envoie l'invitation de groupe.
- Invitez des joueurs par leur nom, suivez demandes et membres dans « Mon groupe », et cherchez des remplaçants une fois le donjon commencé.
- Recevez une alerte dans le chat (avec un son si vous voulez) quand un nouveau groupe vous convient.

**« Je suis disponible »**
- Indiquez à votre guilde et aux guildes alliées que vous êtes libre pour jouer : vos rôles, les donjons voulus, pour combien de temps, et une note.
- Les chefs de groupe vous voient tout de suite et peuvent vous inviter en un clic.

**Invitation automatique**
- Activez-la, et les membres de la guilde (et les joueurs alliés) qui tapent un mot-clé comme `+1` ou `inv` dans le chat de guilde reçoivent une invitation de groupe, tout de suite ou quand vous cliquez.
- Vous choisissez les mots-clés et la durée. Elle est toujours désactivée à la connexion.

**Et aussi**
- Le nom des donjons dans l'autre langue (anglais / français) dans les infobulles, pratique quand votre guilde mélange les langues du jeu.
- Bouton de minicarte, raccourci clavier et infobulle d'état.
- En anglais et en français.

### Pour commencer

1. Installez La Taverne et connectez-vous. Chaque joueur qui veut l'utiliser a besoin de l'addon.
2. Ouvrez-la avec le bouton de la minicarte, `/taverne`, ou un raccourci clavier (Options > Raccourcis > AddOns).
3. C'est tout dans votre guilde : groupes, disponibilité et invitation automatique marchent tout de suite, sans configuration.

### Guildes alliées (officiers)

Le lien entre les guildes se fait une fois, par un officier de chaque guilde qui peut modifier les infos de guilde :

1. Onglet **Alliance** > page **Configuration** : ajoutez les guildes alliées avec un tag court pour chacune, créez la clé partagée, puis **Enregistrer**. Le jeu ne permet pas aux addons de modifier les infos de guilde : La Taverne affiche donc le nouveau texte à copier-coller, c'est-à-dire votre texte actuel avec quelques lignes courtes commençant par `LT:` en plus, le reste tel quel.
2. **Exporter**, et envoyez le texte à un officier de chaque guilde alliée. Il le colle avec **Importer**, puis **Enregistrer**.
3. L'addon de chaque membre lit les infos de guilde et se connecte tout seul.

Vous utilisez déjà GuildUnion ? **Importer > Depuis GuildUnion** reprend ses guildes et ses tags. Les lignes des deux addons tiennent ensemble dans les infos de guilde. Tant que les deux sont installés, ne laissez qu'un seul des deux partager le chat de guilde, sinon les lignes alliées s'affichent deux fois. Dans La Taverne, c'est dans **Options**.

### Commandes

- `/taverne` : ouvrir ou fermer la fenêtre
- `/taverne autoinvite` : activer ou désactiver l'invitation automatique
- `/taverne errors` : le rapport d'erreurs, à joindre à un signalement de bug

### Bugs et suggestions

Ouvrez une issue sur GitHub, ou laissez un commentaire sur CurseForge. Si La Taverne a signalé une erreur, **Options > Rapport d'erreurs** contient un texte à copier dans votre message.

### Remerciements

- Le chat allié dans la fenêtre de guilde reprend l'approche de GuildUnion (MIT, par Sadance).
- Utilise Ace3 (AceComm, AceSerializer, CallbackHandler), ChatThrottleLib, LibStub, LibDataBroker et LibDBIcon.

### Licence

MIT
