# La Taverne 0.32.2-alpha

*2026-11-18*

## English

### Fixes
- Guild Alliance setup: **Save** failed in a real guild ("ADDON_ACTION_FORBIDDEN: SetGuildInfoText()"), because the game doesn't let addons change the Guild Info. Save now shows the new Guild Info text, already selected: copy it (Ctrl+C), paste it over the Guild Info in the guild window (Ctrl+A, Ctrl+V) and accept. Only La Taverne's lines (LT:) change, the rest of the text stays. La Taverne reads it back on its own a few seconds later.

## Français

### Corrections
- Configuration de l'alliance de guildes : **Enregistrer** échouait dans une vraie guilde (« ADDON_ACTION_FORBIDDEN: SetGuildInfoText() »), car le jeu ne permet pas aux addons de modifier les informations de guilde. Enregistrer affiche maintenant le nouveau texte des informations de guilde, déjà sélectionné : copiez-le (Ctrl+C), collez-le à la place des informations de guilde dans la fenêtre de guilde (Ctrl+A, Ctrl+V) et validez. Seules les lignes de La Taverne (LT:) changent, le reste du texte ne bouge pas. La Taverne le relit d'elle-même quelques secondes après.
