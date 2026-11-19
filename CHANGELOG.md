# La Taverne 0.32.1-alpha

*2026-11-18*

## English

### Fixes
- In combat, boss fights, Mythic+, PvP matches and some areas, the game blocks addons from reading the Guild Info. La Taverne kept trying, which filled the error report with "ADDON_ACTION_BLOCKED ... UNKNOWN()" and turned the Guild Alliance off until the fight ended. It now waits for the restriction to end and stays connected.
- Logging in or reloading in a dungeon or in combat: the Guild Alliance starts right away with the setup saved last time, instead of waiting for the end of the restriction.
- Saving the alliance setup during such a restriction is refused with a message, instead of risking erasing the rest of the Guild Info.

## Français

### Corrections
- En combat, contre un boss, en mythique+, en match JcJ et dans certaines zones, le jeu empêche les addons de lire les informations de guilde. La Taverne essayait quand même, ce qui remplissait le rapport d'erreurs de « ADDON_ACTION_BLOCKED ... UNKNOWN() » et coupait l'alliance de guildes jusqu'à la fin du combat. Elle attend maintenant la fin de la restriction et reste connectée.
- En se connectant ou en rechargeant l'interface dans un donjon ou en combat, l'alliance de guildes démarre tout de suite avec la configuration enregistrée la dernière fois, au lieu d'attendre la fin de la restriction.
- Enregistrer la configuration de l'alliance pendant une de ces restrictions est refusé avec un message, au lieu de risquer d'effacer le reste des informations de guilde.
