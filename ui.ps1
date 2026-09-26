# Interface de l'auto-roll AOTR : choix des familles a garder, lancement / arret, suivi en direct.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class U {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
}
"@

$Dossier    = $PSScriptRoot
$Moteur     = Join-Path $Dossier 'autoroll.ps1'
$ConfigPath = Join-Path $Dossier 'config.json'
$Journal    = Join-Path $env:TEMP 'aotr-autoroll-journal.txt'
$Liste      = Import-PowerShellDataFile (Join-Path $Dossier 'familles.psd1')
$Ordre      = 'Mythic', 'Legendary', 'Epic', 'Rare', 'Common'
$NomRarete  = @{ Mythic = 'Mythique'; Legendary = 'Légendaire'; Epic = 'Épique'; Rare = 'Rare'; Common = 'Commune' }
$Couleur    = @{
    Mythic    = [Drawing.Color]::FromArgb(255, 90, 90)
    Legendary = [Drawing.Color]::FromArgb(245, 200, 90)
    Epic      = [Drawing.Color]::FromArgb(190, 140, 255)
    Rare      = [Drawing.Color]::FromArgb(120, 190, 255)
    Common    = [Drawing.Color]::FromArgb(185, 185, 185)
}
$Fond   = [Drawing.Color]::FromArgb(22, 20, 18)
$Carte  = [Drawing.Color]::FromArgb(34, 31, 28)
$Or     = [Drawing.Color]::FromArgb(222, 184, 110)
$Clair  = [Drawing.Color]::FromArgb(235, 230, 220)
$Gris   = [Drawing.Color]::FromArgb(150, 145, 135)

# ---------- Reglages enregistres ----------
$cfg = [ordered]@{}
if (Test-Path $ConfigPath) {
    try { (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
}
$gardees = if ($cfg.Contains('FamillesCibles') -and $cfg.Contains('RaretesCibles') -and @($cfg.RaretesCibles).Count -eq 0) {
    @($cfg.FamillesCibles)
} else { @($Liste.Legendary) + @($Liste.Mythic) }

# ---------- Serveur de suivi a distance (page web sur le reseau local) ----------
. (Join-Path $Dossier 'serveur-suivi.ps1')
$EtatSuivi = [hashtable]::Synchronized(@{ statut = 'en attente'; machine = $env:COMPUTERNAME; spinsFaits = 0; stats = @{}; derniers = @() })
$PortSuivi = if ($cfg.Contains('PortSuivi')) { [int]$cfg.PortSuivi } else { 8765 }
$HtmlSuivi = [IO.File]::ReadAllText((Join-Path $Dossier 'page-suivi.html'), [Text.Encoding]::UTF8)
$script:Serveur = Demarrer-ServeurSuivi $PortSuivi $EtatSuivi $HtmlSuivi (Join-Path $Dossier 'tirages.csv')
$IpLocale = @(Adresses-Locales)[0]; if (-not $IpLocale) { $IpLocale = 'localhost' }
$AdresseSuivi = "http://${IpLocale}:$PortSuivi"

# ---------- Suivi en ligne (relais Render), sans port entrant : l'envoi ne se fait que quand quelqu'un regarde ----------
. (Join-Path $Dossier 'relais-envoi.ps1')
$majCfg = $false
# Desactive par defaut : chacun heberge son propre relais (voir README) et met son adresse dans config.json
if (-not $cfg.Contains('RelaisUrl')) { $cfg['RelaisUrl'] = ''; $majCfg = $true }
if (-not ($cfg.Contains('RelaisCode') -and [string]$cfg.RelaisCode -match '^[A-Za-z0-9]{12,40}$')) {
    $cfg['RelaisCode'] = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ }); $majCfg = $true
}
if ($majCfg) { try { $cfg | ConvertTo-Json -Depth 4 | Set-Content $ConfigPath -Encoding UTF8 } catch { } }
$SignalRelais = [hashtable]::Synchronized(@{})
$AdresseEnLigne = $null
if ($cfg.RelaisUrl) {
    Demarrer-EnvoiRelais ([string]$cfg.RelaisUrl).TrimEnd('/') ([string]$cfg.RelaisCode) $EtatSuivi (Join-Path $Dossier 'tirages.csv') $SignalRelais
    $AdresseEnLigne = "$(([string]$cfg.RelaisUrl).TrimEnd('/'))/?c=$($cfg.RelaisCode)"
}
$AdressePrincipale = if ($AdresseEnLigne) { $AdresseEnLigne } else { $AdresseSuivi }
$script:Derniers = New-Object Collections.ArrayList
$script:SommeDurees = 0.0
$script:PityVal = $null; $script:PityDernierLu = $null
function Maj-Etat([hashtable]$v) {
    [Threading.Monitor]::Enter($EtatSuivi.PSBase.SyncRoot)
    try { foreach ($k in $v.Keys) { $EtatSuivi[$k] = $v[$k] }; $EtatSuivi['maj'] = (Get-Date -Format 'HH:mm:ss') } finally { [Threading.Monitor]::Exit($EtatSuivi.PSBase.SyncRoot) }
}
function Stats-Fr { $h = @{}; foreach ($k in $script:Stats.Keys) { $h[$NomRarete[$k]] = $script:Stats[$k] }; $h }

# ---------- Fenetre ----------
$police      = New-Object Drawing.Font 'Segoe UI', 10
$policeGras  = New-Object Drawing.Font 'Segoe UI Semibold', 10.5
$policeTitre = New-Object Drawing.Font 'Georgia', 18

$form = New-Object Windows.Forms.Form
$Version = if (Test-Path (Join-Path $Dossier 'version.txt')) { (Get-Content (Join-Path $Dossier 'version.txt') -Raw).Trim() } else { '?' }
$form.Text = "Auto-roll familles AOTR  -  version $Version"
$form.ClientSize = New-Object Drawing.Size 980, 806
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = $Fond
$form.ForeColor = $Clair
$form.Font = $police

function Nouveau($type, $x, $y, $w, $h, $parent = $form) {
    $c = New-Object "Windows.Forms.$type"
    $c.Location = New-Object Drawing.Point $x, $y
    $c.Size = New-Object Drawing.Size $w, $h
    $parent.Controls.Add($c)
    $c
}
function Bouton($texte, $x, $y, $w, $h, $parent = $form) {
    $b = Nouveau Button $x $y $w $h $parent
    $b.Text = $texte; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $Or
    $b.BackColor = $Carte; $b.ForeColor = $Clair; $b.Cursor = 'Hand'
    $b
}

$titre = Nouveau Label 20 14 600 36; $titre.Text = 'Auto-roll des familles'; $titre.Font = $policeTitre; $titre.ForeColor = $Or
$sous = Nouveau Label 22 50 560 22; $sous.ForeColor = $Gris
$sous.Text = 'Coche les familles à GARDER : le roll s''arrête dessus. Toutes les autres sont rerollées.'

# ---------- Choix des familles ----------
$panneau = Nouveau Panel 20 82 560 470
$panneau.BackColor = $Carte; $panneau.AutoScroll = $true
$cases = @{}
$y = 10
foreach ($r in $Ordre) {
    $entete = Nouveau Label 14 $y 200 24 $panneau
    $entete.Text = "$($NomRarete[$r])"; $entete.Font = $policeGras; $entete.ForeColor = $Couleur[$r]
    $tout = Nouveau LinkLabel 330 ($y + 3) 90 20 $panneau; $tout.Text = 'tout garder'
    $rien = Nouveau LinkLabel 430 ($y + 3) 100 20 $panneau; $rien.Text = 'tout reroll'
    foreach ($l in $tout, $rien) { $l.LinkColor = $Gris; $l.ActiveLinkColor = $Or; $l.Tag = $r }
    $tout.Add_LinkClicked({ foreach ($c in $cases[$this.Tag]) { $c.Checked = $true } })
    $rien.Add_LinkClicked({ foreach ($c in $cases[$this.Tag]) { $c.Checked = $false } })
    $y += 28
    $cases[$r] = @()
    $i = 0
    foreach ($nom in $Liste[$r]) {
        $cb = Nouveau CheckBox (22 + ($i % 4) * 130) ($y + [Math]::Floor($i / 4) * 28) 125 26 $panneau
        $cb.Text = $nom; $cb.ForeColor = $Couleur[$r]; $cb.Checked = ($gardees -contains $nom)
        $cb.Add_CheckedChanged({ Maj-Resume })
        $cases[$r] += $cb
        $i++
    }
    $y += [Math]::Ceiling($Liste[$r].Count / 4) * 28 + 14
}

# ---------- Options ----------
$opt = Nouveau Panel 600 82 360 322
$opt.BackColor = $Carte
$l1 = Nouveau Label 16 16 200 24 $opt; $l1.Text = 'Nombre max de spins :'
$numMax = Nouveau NumericUpDown 250 14 90 26 $opt
$numMax.Maximum = 100000; $numMax.Minimum = 1; $numMax.Value = $(if ($cfg.Contains('MaxSpins')) { $cfg.MaxSpins } else { 400 })
$l2 = Nouveau Label 16 52 230 24 $opt; $l2.Text = 'Garder au moins ce nb de spins :'
$numGarder = Nouveau NumericUpDown 250 50 90 26 $opt
$numGarder.Maximum = 100000; $numGarder.Value = $(if ($cfg.Contains('GarderSpins')) { $cfg.GarderSpins } else { 0 })
foreach ($n in $numMax, $numGarder) { $n.BackColor = $Fond; $n.ForeColor = $Clair }
$cbInconnue = Nouveau CheckBox 16 90 330 44 $opt
$cbInconnue.Text = 'Garder aussi une famille inconnue (nouvelle) Légendaire ou Mythique'
$cbInconnue.Checked = $(if ($cfg.Contains('GarderInconnuesRares')) { [bool]$cfg.GarderInconnuesRares } else { $true })
$l3 = Nouveau Label 16 142 70 24 $opt; $l3.Text = 'Clics :'
$cbMode = Nouveau ComboBox 90 139 250 26 $opt
$cbMode.DropDownStyle = 'DropDownList'; $cbMode.BackColor = $Fond; $cbMode.ForeColor = $Clair; $cbMode.FlatStyle = 'Flat'
[void]$cbMode.Items.Add('Arrière-plan (clic éclair, PC utilisable)'); [void]$cbMode.Items.Add('Premier plan (Roblox reste devant)')
$cbMode.SelectedIndex = $(if ($cfg.Contains('ModeClic') -and $cfg.ModeClic -eq 'premierplan') { 1 } else { 0 })
$resume = Nouveau Label 16 184 330 44 $opt; $resume.Font = $policeGras
$aide = Nouveau Label 16 234 330 44 $opt; $aide.ForeColor = $Gris
$l4 = Nouveau Label 16 287 70 24 $opt; $l4.Text = 'Suivi :'
$lbAdresse = Nouveau LinkLabel 72 287 210 24 $opt
$lbAdresse.Text = ($AdressePrincipale -replace '^https?://', ''); $lbAdresse.AutoEllipsis = $true
$lbAdresse.LinkColor = $Or; $lbAdresse.ActiveLinkColor = $Clair
$lbAdresse.Add_LinkClicked({ Start-Process $AdressePrincipale })
$btCopier = Bouton 'Copier' 286 282 60 28 $opt
$aide.Text = "F8 arrête à tout moment. Roblox doit rester sur l'écran des familles (pas réduit)."

# ---------- Boutons ----------
$btTest   = Bouton 'Tester la lecture' 600 418 170 40
$btLancer = Bouton '▶  Lancer' 790 418 170 40
$btStop   = Bouton '■  Arrêter' 790 418 170 40
$btLancer.BackColor = [Drawing.Color]::FromArgb(70, 55, 25); $btLancer.Font = $policeGras
$btStop.BackColor = [Drawing.Color]::FromArgb(90, 30, 30); $btStop.Font = $policeGras; $btStop.Visible = $false

# ---------- Etat ----------
$etat = Nouveau Panel 600 472 360 142
$etat.BackColor = $Carte
$lbFam = Nouveau Label 16 10 330 26 $etat; $lbFam.Font = $policeGras
$lbSpins = Nouveau Label 16 40 170 24 $etat
$lbFaits = Nouveau Label 190 40 160 24 $etat
$lbStats = Nouveau Label 16 66 330 22 $etat; $lbStats.ForeColor = $Gris
$lbStatut = Nouveau Label 16 94 330 44 $etat; $lbStatut.ForeColor = $Gris

# ---------- Journal ----------
$log = Nouveau RichTextBox 20 630 940 160
$log.BackColor = [Drawing.Color]::FromArgb(14, 13, 12); $log.ForeColor = $Clair
$log.BorderStyle = 'None'; $log.ReadOnly = $true; $log.Font = New-Object Drawing.Font 'Consolas', 9.5

function Ajouter-Log([string]$ligne) {
    $c = $Clair
    foreach ($r in $Ordre) { if ($ligne -match "\($r\)") { $c = $Couleur[$r] } }
    if ($ligne -match '\*\*\*') { $c = [Drawing.Color]::FromArgb(120, 230, 120) }
    elseif ($ligne -match 'Arret|pause|introuvable|Impossible|securite|inconnue|ferme|reagit') { $c = [Drawing.Color]::FromArgb(240, 170, 90) }
    $log.SelectionStart = $log.TextLength; $log.SelectionLength = 0
    $log.SelectionColor = $c
    $log.AppendText($ligne + "`n")
    $log.ScrollToCaret()
}

function Afficher-Famille($nom, $rar, $reste) {
    $lbFam.Text = "Famille : $nom ($($NomRarete[$rar]))"
    $lbFam.ForeColor = $(if ($Couleur[$rar]) { $Couleur[$rar] } else { $Clair })
    if ($reste) { $lbSpins.Text = "Spins restants : $reste" }
}

function Familles-Gardees { foreach ($r in $Ordre) { foreach ($c in $cases[$r]) { if ($c.Checked) { $c.Text } } } }

function Maj-Resume {
    $g = @(Familles-Gardees).Count
    $total = ($Ordre | ForEach-Object { $Liste[$_].Count } | Measure-Object -Sum).Sum
    $resume.Text = "Garder : $g famille(s)   ·   Reroll : $($total - $g)"
    $resume.ForeColor = $(if ($g -eq 0) { [Drawing.Color]::FromArgb(240, 120, 100) } else { $Or })
    if ($g -eq 0) { $resume.Text += "`nCoche au moins une famille !" }
    if (-not $script:Proc) { $btLancer.Enabled = ($g -gt 0) }
}

function Sauver-Config {
    if (Test-Path $ConfigPath) {
        try { (Get-Content $ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch { }
    }
    foreach ($vieux in 'ZoneFamille', 'DelaiMaxRollMs', 'MethodeFond') { if ($cfg.Contains($vieux)) { $cfg.Remove($vieux) } }
    $cfg['ModeClic'] = $(if ($cbMode.SelectedIndex -eq 1) { 'premierplan' } else { 'fond' })
    $cfg['FamillesCibles'] = @(Familles-Gardees)
    $cfg['RaretesCibles'] = @()
    $cfg['MaxSpins'] = [int]$numMax.Value
    $cfg['GarderSpins'] = [int]$numGarder.Value
    $cfg['GarderInconnuesRares'] = $cbInconnue.Checked
    $cfg | ConvertTo-Json -Depth 4 | Set-Content $ConfigPath -Encoding UTF8
}

function Activer-Roblox {
    $p = Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return $false }
    if ([U]::IsIconic($p.MainWindowHandle)) { [U]::ShowWindow($p.MainWindowHandle, 9) | Out-Null }
    [U]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
    $true
}

function Mode-Roll([bool]$actif) {
    $btLancer.Visible = -not $actif; $btStop.Visible = $actif
    $btTest.Enabled = -not $actif; $panneau.Enabled = -not $actif; $opt.Enabled = -not $actif
}

# ---------- Actions ----------
$btCopier.Add_Click({
    [Windows.Forms.Clipboard]::SetText($AdressePrincipale)
    Ajouter-Log "Adresse copiée : $AdressePrincipale  (ouvre-la sur ton PC principal ou ton téléphone)"
})
$btTest.Add_Click({
    $form.Cursor = 'WaitCursor'; $btTest.Enabled = $false
    $lbStatut.Text = 'Lecture de l''écran du jeu...'; $form.Refresh()
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Moteur`" -Test"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding(850)
        $p = [Diagnostics.Process]::Start($psi)
        $sortie = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        Ajouter-Log '--- Test de lecture ---'
        foreach ($l in ($sortie -split "`r?`n")) {
            if ($l -match '^\s*$' -or $l -match '^---|^  ') { continue }
            Ajouter-Log $l
            if ($l -match 'Famille actuelle : (\S+) \((\w+)\)') { Afficher-Famille $matches[1] $matches[2] $null; Maj-Etat @{ famille = $matches[1]; rarete = $NomRarete[$matches[2]] } }
            if ($l -match 'Spins restants\s*: (\d+)') { $lbSpins.Text = "Spins restants : $($matches[1])"; Maj-Etat @{ spinsRestants = $matches[1] } }
        }
        $lbStatut.Text = $(if ($sortie -match 'Famille actuelle : NON' -or $sortie -match 'NON TROUVE' -or $sortie -match 'introuvable') { 'Lecture incomplète : vérifie que le jeu est sur l''écran des familles.' } else { 'Lecture OK, tu peux lancer.' })
    } catch { Ajouter-Log "Erreur : $_" }
    $form.Cursor = 'Default'; $btTest.Enabled = $true
})

$btLancer.Add_Click({
    Sauver-Config
    # journal neuf a chaque lancement (jamais bloque par un ancien fichier encore ouvert)
    Get-ChildItem "$env:TEMP\aotr-autoroll-journal*.txt" -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item $_.FullName -ErrorAction Stop } catch { } }
    $script:Journal = Join-Path $env:TEMP ("aotr-autoroll-journal-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
    [IO.File]::WriteAllText($script:Journal, '')
    $script:LuJusqua = 0; $script:Faits = 0; $script:Stats = @{}; $lbStats.Text = ''
    $lbFaits.Text = 'Spins faits : 0'
    $script:Derniers.Clear(); $script:SommeDurees = 0.0
    Maj-Etat @{ statut = 'démarrage'; spinsFaits = 0; stats = @{}; derniers = @(); victoire = $false; message = ''; vitesse = $null
                debut = (Get-Date -Format 'HH:mm'); gardees = @(Familles-Gardees) }
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Moteur`" -Journal `"$script:Journal`" -SansPopup"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $script:Proc = [Diagnostics.Process]::Start($psi)
    Mode-Roll $true
    $lbStatut.Text = 'Démarrage... (quelques secondes)'
    Ajouter-Log "--- Lancement : garder $(@(Familles-Gardees) -join ', ') ---"
    if ($cbMode.SelectedIndex -eq 1) { if (-not (Activer-Roblox)) { Ajouter-Log 'Roblox introuvable : lance le jeu.' } }
    $timer.Start()
})

$btStop.Add_Click({
    if ($script:Proc -and -not $script:Proc.HasExited) {
        $script:Proc.Kill()
        [U]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # relache le clic au cas ou
    }
    Ajouter-Log 'Arrêté depuis la fenêtre.'
})

# ---------- Suivi du journal ----------
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    if ($script:Journal -and (Test-Path $script:Journal)) {
        $fs = New-Object IO.FileStream $script:Journal, 'Open', 'Read', 'ReadWrite'
        try {
            if ($fs.Length -gt $script:LuJusqua) {
                $fs.Position = $script:LuJusqua
                $sr = New-Object IO.StreamReader $fs, ([Text.Encoding]::UTF8)
                $neuf = $sr.ReadToEnd()
                $script:LuJusqua = $fs.Length
                foreach ($l in ($neuf -split "`r?`n")) {
                    $l = $l.TrimStart([char]0xFEFF)
                    if (-not $l.Trim()) { continue }
                    Ajouter-Log $l
                    if ($l -match 'Spin\s+(\d+) : (\S+)\s+\((\w+)\)\s+reste (\S+)') {
                        $script:Faits = [int]$matches[1]; $lbFaits.Text = "Spins faits : $($matches[1])"
                        $script:Stats[$matches[3]] = 1 + [int]$script:Stats[$matches[3]]
                        $lbStats.Text = (@('Mythic', 'Legendary', 'Epic', 'Rare', 'Common') | Where-Object { $script:Stats[$_] } | ForEach-Object { "$($NomRarete[$_]) $($script:Stats[$_])" }) -join '  ·  '
                        $nomF = $matches[2]; $rarF = $matches[3]; $resteF = $matches[4]
                        Afficher-Famille $nomF $rarF $resteF
                        if ($l -match '\[(\d+[,.]\d+) s\]') { $script:SommeDurees += [double]($matches[1] -replace ',', '.') }
                        # pity : suivie spin par spin, recalee seulement sur deux lectures coherentes du jeu (N puis N+1, ou 0 apres une epique+)
                        $epPlus = @('Epic', 'Legendary', 'Mythic', 'Secret') -contains $rarF
                        if ($null -ne $script:PityVal) { $script:PityVal = if ($epPlus) { 0 } else { [Math]::Min(400, $script:PityVal + 1) } }
                        $lu = if ($l -match 'pity (\d+)') { [int]$matches[1] } else { $null }
                        if ($null -ne $lu) {
                            if ($null -ne $script:PityDernierLu -and ($lu -eq $script:PityDernierLu + 1 -or ($epPlus -and $lu -eq 0))) { $script:PityVal = $lu }
                            $script:PityDernierLu = $lu
                        } else { $script:PityDernierLu = $null }
                        if ($null -ne $script:PityVal) { Maj-Etat @{ pity = $script:PityVal } }
                        [void]$script:Derniers.Insert(0, @{ nom = $nomF; rarete = $NomRarete[$rarF]; heure = ($l.Substring(0, 8)) })
                        while ($script:Derniers.Count -gt 15) { $script:Derniers.RemoveAt(15) }
                        Maj-Etat @{ statut = 'en cours'; spinsFaits = $script:Faits; spinsRestants = $resteF; famille = $nomF; rarete = $NomRarete[$rarF]
                                    stats = (Stats-Fr); derniers = @($script:Derniers.ToArray()); vitesse = ('{0:N1}' -f ($script:SommeDurees / [Math]::Max(1, $script:Faits))) }
                        $lbStatut.Text = 'Roll en cours... (F8 ou Arrêter pour stopper)'
                    } elseif ($l -match 'Famille de depart : (\S+) \((\w+)\) - reste (\S+)') {
                        Afficher-Famille $matches[1] $matches[2] $matches[3]
                        Maj-Etat @{ statut = 'en cours'; famille = $matches[1]; rarete = $NomRarete[$matches[2]]; spinsRestants = $matches[3] }
                        $lbStatut.Text = 'Roll en cours... (F8 ou Arrêter pour stopper)'
                    } elseif ($l -match 'En pause') {
                        $lbStatut.Text = 'En pause : clique dans Roblox pour reprendre.'
                        Maj-Etat @{ statut = 'en pause'; message = ($l.Substring(10)) }
                    } elseif ($l -match 'Reprise') {
                        Maj-Etat @{ statut = 'en cours' }
                    }
                    if ($l -match '\*\*\*') { Maj-Etat @{ victoire = $true; message = ($l.Substring(10) -replace '\*\*\*', '').Trim() } }
                    elseif ($l -match 'Arret|Limite|Impossible|introuvable|ferme') { Maj-Etat @{ message = $l.Substring(10).Trim() } }
                }
            }
        } finally { $fs.Dispose() }
    }
    if ($script:Proc -and $script:Proc.HasExited) {
        $timer.Stop(); $script:Proc = $null
        Mode-Roll $false; Maj-Resume
        $dernier = ($log.Lines | Where-Object { $_.Trim() } | Select-Object -Last 1)
        $lbStatut.Text = 'Terminé.'
        Maj-Etat @{ statut = $(if ($EtatSuivi['victoire']) { 'terminé' } else { 'arrêté' }) }
        $form.Activate()
        if ($dernier -match '\*\*\*') {
            [Windows.Forms.MessageBox]::Show(($dernier -replace '^\S+\s+', ''), 'Famille obtenue !', 'OK', 'Information') | Out-Null
        }
    }
})

$form.Add_FormClosing({
    Sauver-Config
    if ($script:Proc -and -not $script:Proc.HasExited) { $script:Proc.Kill() }
})

Maj-Resume
$lbFam.Text = 'Famille : —'; $lbSpins.Text = 'Spins restants : —'; $lbFaits.Text = 'Spins faits : 0'
$lbStatut.Text = 'Clique sur « Tester la lecture » pour vérifier.'
Start-Sleep -Milliseconds 400
$fMaj = Join-Path $Dossier 'maj-derniere.txt'
if (Test-Path $fMaj) { Ajouter-Log (Get-Content $fMaj -Raw -Encoding UTF8).Trim(); try { [IO.File]::Delete($fMaj) } catch { } }
if ($AdresseEnLigne) { Ajouter-Log "Suivi en ligne (PC principal, téléphone...) : $AdresseEnLigne" }
if ($EtatSuivi['_serveur'] -eq 'ok') { Ajouter-Log "Suivi sur le réseau de la maison : $AdresseSuivi" }
# etat du relais dans le journal, seulement quand il change
$script:DernierRelais = ''
$timerRelais = New-Object Windows.Forms.Timer; $timerRelais.Interval = 3000
$timerRelais.Add_Tick({
    $r = [string]$SignalRelais['relais']
    $cat = if ($r -like 'envoi*') { 'envoi' } elseif ($r -like 'erreur*') { $r } else { 'veille' }
    if ($cat -ne $script:DernierRelais) {
        $script:DernierRelais = $cat
        if ($cat -eq 'envoi') { Ajouter-Log 'Suivi en ligne : quelqu''un regarde la page, envoi des données.' }
        elseif ($cat -eq 'veille') { if ($AdresseEnLigne) { Ajouter-Log 'Suivi en ligne : en veille (rien n''est envoyé tant que personne ne regarde).' } }
        else { Ajouter-Log "Suivi en ligne : $cat" }
    }
})
$timerRelais.Start()
[void]$form.ShowDialog()
