# Mise a jour automatique de l'auto-roll depuis GitHub (depot public legrasdu92-cmyk/aotr-autoroll).
# Appelee par lancer.ps1 avant d'ouvrir la fenetre. Tes donnees (config.json, tirages.csv,
# historique.txt) ne sont jamais touchees : seuls les fichiers du programme listes dans fichiers.txt.
# En cas de souci (pas d'internet, GitHub indisponible...), on garde simplement la version actuelle.
$Dossier = $PSScriptRoot
$Depot   = 'legrasdu92-cmyk/aotr-autoroll'
$Info    = Join-Path $Dossier 'maj-derniere.txt'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Telecharger([string]$chemin) {
    # API GitHub en mode "raw" : pas de cache, octets exacts (accents et BOM preserves)
    $wc = New-Object Net.WebClient
    $wc.Headers.Add('User-Agent', 'aotr-autoroll')
    $wc.Headers.Add('Accept', 'application/vnd.github.raw')
    $wc.DownloadData("https://api.github.com/repos/$Depot/contents/$([Uri]::EscapeDataString($chemin))?ref=main")
}

try {
    $distante = [int]([Text.Encoding]::UTF8.GetString((Telecharger 'version.txt')).Trim())
    $fLocale = Join-Path $Dossier 'version.txt'
    $locale = if (Test-Path $fLocale) { [int]((Get-Content $fLocale -Raw).Trim()) } else { 0 }
    if ($distante -le $locale) { return }

    $liste = [Text.Encoding]::UTF8.GetString((Telecharger 'fichiers.txt')) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '[\\/:]|\.\.' }
    # 1) tout telecharger d'abord (si un fichier echoue, on ne touche a rien)
    $recus = @{}
    foreach ($nom in $liste) { $recus[$nom] = Telecharger $nom }
    # 2) puis remplacer
    foreach ($nom in $liste) { [IO.File]::WriteAllBytes((Join-Path $Dossier $nom), $recus[$nom]) }
    Set-Content $fLocale $distante -Encoding ASCII
    Set-Content $Info "Mise a jour installee : version $locale -> $distante ($($liste.Count) fichiers)" -Encoding UTF8
} catch {
    Set-Content $Info "Mise a jour impossible pour l'instant ($($_.Exception.Message)) : version actuelle conservee." -Encoding UTF8
}
