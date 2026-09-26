# Auto-roll des familles — Attack on Titan Revolution (Roblox)

Relance automatiquement les familles dans **Attack on Titan Revolution** jusqu'à obtenir celle que tu veux
(Légendaire, Mythique… tu choisis précisément lesquelles garder).

- **Windows 10/11, rien à installer** : PowerShell et la reconnaissance de texte intégrée à Windows, pas besoin des droits admin.
- **Tu peux utiliser ton PC pendant le roll** (mode « clic éclair » : il attend que tu ne bouges plus la souris, clique en ~60 ms et te rend la main).
- **Sécurités** : il ne clique sur ROLL que s'il a lu ta famille actuelle et qu'elle n'est pas à garder. Il ne confirme jamais le reroll d'une famille gardée, ne compte un spin que si le compteur a baissé et s'arrête au nombre max de spins choisi.
- **Mise à jour automatique** à chaque lancement, sans toucher à tes réglages ni à ton historique.
- **Suivi à distance (optionnel)** depuis ton téléphone ou un autre PC : en direct, historique, stats (taux obtenus comparés aux taux du jeu, pity, probabilités).

## Installation

1. Télécharge **`AutoRoll-AOTR.zip`** dans la [dernière version](https://github.com/legrasdu92-cmyk/aotr-autoroll/releases/latest).
2. Clic droit sur le zip › **Propriétés** › coche **« Débloquer »** › OK.
3. Clic droit › **Extraire tout** (sur le Bureau par exemple).

## Utilisation

1. Lance Roblox, rejoins AOTR et va sur l'**écran des familles** (bouton ROLL en bas à droite). Roblox peut être derrière d'autres fenêtres mais **jamais réduit**.
2. Double-clic sur **`Auto-roll AOTR.vbs`**. Si Windows affiche « Windows a protégé votre ordinateur », clique sur « Informations complémentaires » puis « Exécuter quand même ». Si le .vbs est bloqué, lance `Lancer si le vbs est bloque.bat`.
3. Coche les familles à **garder**, clique sur **Tester la lecture**, puis sur **▶ Lancer**. Pour arrêter : **■ Arrêter** ou la touche **F8**.

Tous les détails et le dépannage sont dans [`1 - LIS-MOI D'ABORD.txt`](1%20-%20LIS-MOI%20D'ABORD.txt).

## Suivi en ligne (optionnel)

Il te faut ton propre petit serveur relais, gratuit sur Render :
[legrasdu92-cmyk/aotr-suivi-relais](https://github.com/legrasdu92-cmyk/aotr-suivi-relais).
Mets ensuite son adresse dans `config.json` (`"RelaisUrl": "https://ton-service.onrender.com"`). Le programme n'envoie
rien tant que personne n'a la page ouverte, ce qui économise les heures gratuites.

## Avertissement

Outil non officiel, sans lien avec Roblox ni les développeurs d'AOTR. Il se contente de lire l'écran et de cliquer comme
un joueur (aucune injection, aucune modification du jeu), mais l'automatisation peut être contraire aux règles de Roblox
ou du jeu. **Utilisation à tes risques.** La mise à jour automatique télécharge le code depuis ce dépôt.
