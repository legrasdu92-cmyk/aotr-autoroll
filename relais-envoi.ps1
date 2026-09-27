# Envoi vers le relais en ligne (Render), lance par ui.ps1.
# Pour economiser les heures Render, on n'envoie RIEN tant que personne ne regarde la page :
# a son ouverture, la page publie un signal "vu" sur ntfy.sh (gratuit, sans compte), qu'on ecoute ici
# (connexion sortante uniquement). Ensuite chaque reponse du relais dit si la page est encore ouverte ;
# on s'arrete ~2,5 min apres qu'elle a ete fermee.

function Demarrer-EnvoiRelais([string]$Url, [string]$Code, $Etat, [string]$FichierTirages, $Signal) {
    $Signal['vu'] = [long]0
    $Signal['relais'] = 'en veille (personne ne regarde)'

    # --- 1) ecoute du signal "quelqu'un regarde" ---
    $rs1 = [runspacefactory]::CreateRunspace(); $rs1.Open()
    $ps1 = [powershell]::Create(); $ps1.Runspace = $rs1
    [void]$ps1.AddScript({
        param($Code, $Signal)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        while ($true) {
            try {
                $req = [Net.HttpWebRequest]::Create("https://ntfy.sh/aotr-$Code/json?since=3m")
                $req.Timeout = 20000; $req.ReadWriteTimeout = 120000   # ntfy envoie un "keepalive" toutes les ~45 s
                $rep = $req.GetResponse()
                $lecteur = New-Object IO.StreamReader($rep.GetResponseStream())
                $Signal['ecoute'] = 'ok'
                while ($null -ne ($ligne = $lecteur.ReadLine())) {
                    if ($ligne -match '"event":"message"' -and $ligne -match '"time":(\d+)') {
                        $t = [long]$matches[1]
                        if ($t -gt [long]$Signal['vu']) { $Signal['vu'] = $t }
                    }
                }
                $rep.Close()
            } catch { $Signal['ecoute'] = "erreur : $($_.Exception.Message)" }
            Start-Sleep -Seconds 5
        }
    }).AddArgument($Code).AddArgument($Signal)
    [void]$ps1.BeginInvoke()

    # --- 2) envoi vers le relais, seulement pendant qu'on regarde ---
    $rs2 = [runspacefactory]::CreateRunspace(); $rs2.Open()
    $ps2 = [powershell]::Create(); $ps2.Runspace = $rs2
    [void]$ps2.AddScript({
        param($Url, $Code, $Etat, $FichierTirages, $Signal)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $envoye = 0; $actif = $false; $lignes = @(); $tailleLue = -1
        while ($true) {
            $pause = 3
            try {
                $maintenant = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                if ($maintenant - [long]$Signal['vu'] -lt 150) {
                    if (-not $actif) { $actif = $true; $envoye = 0 }   # le relais a pu redemarrer : on renvoie tout
                    # historique (relu seulement s'il a change)
                    if ($FichierTirages -and (Test-Path $FichierTirages)) {
                        $taille = (Get-Item $FichierTirages).Length
                        if ($taille -ne $tailleLue) {
                            $fs = New-Object IO.FileStream $FichierTirages, 'Open', 'Read', 'ReadWrite'
                            try { $txt = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
                            $lignes = @($txt.Replace('"', '').Replace('\', '').Split([char]10) | ForEach-Object { $_.TrimEnd([char]13) } | Where-Object { ($_.Length - $_.Replace(';', '').Length) -ge 6 })
                            $tailleLue = $taille
                        }
                    }
                    if ($envoye -gt $lignes.Count) { $envoye = 0 }
                    $fin = [Math]::Min($lignes.Count, $envoye + 5000)
                    $sb = New-Object Text.StringBuilder
                    for ($i = $envoye; $i -lt $fin; $i++) { if ($i -gt $envoye) { [void]$sb.Append(',') }; [void]$sb.Append('["').Append($lignes[$i].Replace(';', '","')).Append('"]') }
                    # photo de l'etat
                    [Threading.Monitor]::Enter($Etat.PSBase.SyncRoot)
                    try { $copie = @{}; foreach ($k in @($Etat.Keys)) { if ($k -notlike '_*') { $copie[$k] = $Etat[$k] } } } finally { [Threading.Monitor]::Exit($Etat.PSBase.SyncRoot) }
                    $json = '{"etat":' + ($copie | ConvertTo-Json -Depth 5 -Compress) + ',"depuis":' + $envoye + ',"tirages":[' + $sb.ToString() + ']}'
                    $rep = Invoke-RestMethod -Method Post -Uri "$Url/api/envoi?c=$Code" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
                    $envoye = [int]$rep.nb
                    # le relais indique si la page est encore ouverte : on continue sans attendre de nouveau signal ntfy
                    if ($rep.spectateur -eq $true) { $Signal['vu'] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
                    if ($envoye -lt $lignes.Count) { $pause = 0 }   # reste de l'historique a envoyer : on enchaine
                    $Signal['relais'] = "envoi en cours ($(Get-Date -Format 'HH:mm:ss'))"
                } elseif ($actif) {
                    $actif = $false
                    $Signal['relais'] = 'en veille (personne ne regarde)'
                }
            } catch { $Signal['relais'] = "erreur : $($_.Exception.Message)"; $pause = 10 }
            if ($pause) { Start-Sleep -Seconds $pause }
        }
    }).AddArgument($Url).AddArgument($Code).AddArgument($Etat).AddArgument($FichierTirages).AddArgument($Signal)
    [void]$ps2.BeginInvoke()
}
