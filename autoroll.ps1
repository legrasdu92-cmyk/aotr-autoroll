# Auto-roll des familles - Attack on Titan Revolution (Roblox)
#
# Aucune calibration : le programme lit les textes du jeu (OCR Windows) pour
#   - trouver le bouton "ROLL (xx)" et le nombre de spins restants,
#   - lire la famille actuelle "NOM (Rarete)",
#   - repondre YES a "Are you sure you want to reroll your 'XXX' family?" (epiques),
# et s'arrete des qu'une famille a garder sort (choisies dans ui.ps1 / config.json).
#
# Regle de securite : il ne clique sur ROLL que s'il a LU la famille actuelle
# et qu'elle n'est pas a garder. Il ne confirme jamais le reroll d'une famille a garder.
#   F8 = arret immediat a tout moment.
param(
    [switch]$Test,
    [string]$ImageTest,
    [string]$Journal,      # fichier de suivi lu par l'interface (ui.ps1)
    [switch]$SansPopup     # l'interface affiche elle-meme le resultat
)

$ErrorActionPreference = 'Stop'
$Dossier    = $PSScriptRoot
$ConfigPath = Join-Path $Dossier 'config.json'
$LogPath    = Join-Path $Dossier 'historique.txt'
$TiragesPath = Join-Path $Dossier 'tirages.csv'     # historique complet des tirages (lu par la page de suivi)
$SessionId  = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------- Reglages (modifiables dans config.json) ----------
$cfg = [ordered]@{
    RaretesCibles        = @('Legendary', 'Mythic', 'Mythical', 'Secret')
    FamillesCibles       = @('Ackerman', 'Yeager', 'Reiss', 'Fritz', 'Helos', 'Shiki')
    MaxSpins             = 400       # nombre max de spins pour cette session
    GarderSpins          = 0         # s'arrete s'il ne reste que ce nombre de spins
    GarderInconnuesRares = $true     # garde une famille absente de familles.psd1 si elle est Legendary/Mythic
    DelaiReclicMs        = 1200      # apres ce delai, meme nom + meme compteur visibles = clic rate -> on reclique
    DelaiMaxRollMs       = 10000     # temps max d'attente du resultat d'un spin
    EchelleOCR           = 1         # agrandissement avant lecture (2 = plus fiable, plus lent)
    ModeClic             = 'fond'    # 'fond' = clic eclair (PC utilisable) ; 'premierplan' = Roblox doit rester devant
    DelaiEclairMs        = 60        # temps laisse a Roblox pour devenir actif avant le clic eclair
    WebhookDiscord       = ''        # URL d'un webhook Discord pour suivre le roll a distance (vide = desactive)
    NotifChaqueSpins     = 20        # mise a jour du message de suivi Discord tous les N spins
    PauseUtilisateurMs   = 250       # clic eclair seulement apres ce temps sans action de ta part...
    AttentePauseMaxMs    = 1500      # ...en attendant au plus ce temps
    # Zones de lecture, en fraction de la fenetre Roblox (x1, y1, x2, y2)
    ZoneBas              = @(0.72, 0.85, 1.00, 0.985)
    ZoneConfirmation     = @(0.28, 0.30, 0.72, 0.70)
}
if (Test-Path $ConfigPath) {
    $perso = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $perso.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
} else {
    $cfg | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8
}

$liste = Import-PowerShellDataFile (Join-Path $Dossier 'familles.psd1')
$Familles = [ordered]@{}
foreach ($r in 'Common', 'Rare', 'Epic', 'Legendary', 'Mythic') { $Familles[$r] = @($liste[$r]) }
$TousNoms = @($Familles.Values | ForEach-Object { $_ })
$Raretes = @('Common', 'Rare', 'Epic', 'Legendary', 'Mythic', 'Mythical', 'Secret')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class W {
  public struct POINT { public int X; public int Y; }
  public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  // Passe une fenetre devant en contournant le verrou de Windows (entree clavier rattachee)
  public static bool Activer(IntPtr h) {
    if (GetForegroundWindow() == h) return true;
    keybd_event(0x87, 0, 0, IntPtr.Zero); keybd_event(0x87, 0, 2, IntPtr.Zero);  // F24 (touche inutilisee)
    if (SetForegroundWindow(h) && GetForegroundWindow() == h) return true;
    uint moi = GetCurrentThreadId();
    uint devant = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    AttachThreadInput(moi, devant, true);
    BringWindowToTop(h); SetForegroundWindow(h);
    AttachThreadInput(moi, devant, false);
    return GetForegroundWindow() == h;
  }
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
  // millisecondes depuis la derniere action clavier/souris (la tienne ou la notre)
  public static long InactifDepuis() { var i = new LASTINPUTINFO(); i.cbSize = 8; GetLastInputInfo(ref i); return (long)(uint)Environment.TickCount - i.dwTime; }
  // Distance de Levenshtein (nombre de lettres a changer), en C# pour la vitesse
  public static int Distance(string a, string b) {
    int[,] d = new int[a.Length + 1, b.Length + 1];
    for (int i = 0; i <= a.Length; i++) d[i, 0] = i;
    for (int j = 0; j <= b.Length; j++) d[0, j] = j;
    for (int i = 1; i <= a.Length; i++)
      for (int j = 1; j <= b.Length; j++)
        d[i, j] = Math.Min(Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1), d[i - 1, j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    return d[a.Length, b.Length];
  }
}
"@
[W]::SetProcessDPIAware() | Out-Null
$VK_F8 = 0x77

# ---------- OCR Windows (integre, rien a installer), directement en memoire ----------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
$AsTaskGen = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$AsTaskOcr = $AsTaskGen.MakeGenericMethod([Windows.Media.Ocr.OcrResult])
$Ocr = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'en-US'))
if (-not $Ocr) { $Ocr = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }

function OCR-Bitmap($bmp) {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $octets = New-Object byte[] ($data.Stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $octets, 0, $octets.Length)
    $bmp.UnlockBits($data)
    $buf = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer($octets)
    $sb = [Windows.Graphics.Imaging.SoftwareBitmap]::CreateCopyFromBuffer($buf, [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, $bmp.Width, $bmp.Height)
    $t = $AsTaskOcr.Invoke($null, @($Ocr.RecognizeAsync($sb)))
    $t.Wait(-1) | Out-Null
    $sb.Dispose()
    $t.Result
}

# ---------- Fenetre Roblox ----------
function Fenetre-Roblox {
    $p = Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { return $null }
    $h = $p.MainWindowHandle
    if ([W]::IsIconic($h)) { return $null }
    $r = New-Object W+RECT; [W]::GetClientRect($h, [ref]$r) | Out-Null
    $o = New-Object W+POINT; [W]::ClientToScreen($h, [ref]$o) | Out-Null
    [pscustomobject]@{ Handle = $h; X = $o.X; Y = $o.Y; W = $r.R; H = $r.B }
}

# Image complete de la fenetre, meme cachee (lent : seulement pour le test hors premier plan)
function Capture-Fenetre-Complete($f) {
    $bmp = New-Object System.Drawing.Bitmap $f.W, $f.H
    $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
    [W]::PrintWindow($f.Handle, $hdc, 3) | Out-Null   # PW_CLIENTONLY | PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp
}

# Lit une zone (fractions de la fenetre). Renvoie les lignes et la position ECRAN de chaque mot.
function Lire-Zone($f, $zone, $echelle = 1) {
    $x1 = [int]($zone[0] * $f.W); $y1 = [int]($zone[1] * $f.H)
    $w  = [int]($zone[2] * $f.W) - $x1; $h = [int]($zone[3] * $f.H) - $y1
    $W2 = [int]($w * $echelle); $H2 = [int]($h * $echelle)
    $bmp = New-Object System.Drawing.Bitmap $W2, $H2, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dest = New-Object System.Drawing.Rectangle 0, 0, $W2, $H2
    if ($script:ImageSource) {
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($script:ImageSource, $dest, $x1, $y1, $w, $h, [System.Drawing.GraphicsUnit]::Pixel)
    } elseif ([W]::GetForegroundWindow() -eq $f.Handle -and $echelle -eq 1) {
        $g.CopyFromScreen($f.X + $x1, $f.Y + $y1, 0, 0, $bmp.Size)       # rapide : copie directe de l'ecran
    } else {
        if (-not $script:Plein) {
            $script:Plein = if ([W]::GetForegroundWindow() -eq $f.Handle) {
                $b = New-Object System.Drawing.Bitmap $f.W, $f.H; $gg = [System.Drawing.Graphics]::FromImage($b)
                $gg.CopyFromScreen($f.X, $f.Y, 0, 0, $b.Size); $gg.Dispose(); $b
            } else { Capture-Fenetre-Complete $f }
        }
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($script:Plein, $dest, $x1, $y1, $w, $h, [System.Drawing.GraphicsUnit]::Pixel)
    }
    $g.Dispose()
    $res = OCR-Bitmap $bmp
    $bmp.Dispose()
    $lignes = foreach ($l in $res.Lines) {
        $mots = foreach ($m in $l.Words) {
            $r = $m.BoundingRect
            [pscustomobject]@{
                Texte = $m.Text
                X = [int]($f.X + $x1 + ($r.X + $r.Width / 2) / $echelle)
                Y = [int]($f.Y + $y1 + ($r.Y + $r.Height / 2) / $echelle)
            }
        }
        [pscustomobject]@{ Texte = $l.Text; Mots = @($mots) }
    }
    [pscustomobject]@{ Texte = $res.Text; Lignes = @($lignes) }
}

# ---------- Reconnaissance du texte ----------
# Mot de la liste le plus proche (tolere les petites erreurs de lecture), sinon $null
function Plus-Proche([string]$mot, $liste) {
    $m = ($mot.ToUpper() -replace '0', 'O' -replace '[^A-Z]', '')
    if (-not $m) { return $null }
    $max = if ($m.Length -le 3) { 0 } elseif ($m.Length -le 5) { 1 } else { 2 }
    $meilleur = $null; $dMin = 99
    foreach ($x in $liste) {
        $d = [W]::Distance($m, $x.ToUpper())
        if ($d -lt $dMin) { $dMin = $d; $meilleur = $x }
    }
    if ($dMin -le $max) { $meilleur } else { $null }
}

function Rarete-De-Famille([string]$nom) {
    foreach ($r in $Familles.Keys) { if ($Familles[$r] -contains $nom) { return $r } }
    $null
}

function Est-Cible($famille) {
    if ($cfg.FamillesCibles -contains $famille.Nom) { return $true }
    if ($cfg.RaretesCibles -contains $famille.Rarete) { return $true }
    $inconnue = -not (Rarete-De-Famille $famille.Nom)
    ($inconnue -and $cfg.GarderInconnuesRares -and (@('Legendary', 'Mythic', 'Secret') -contains $famille.Rarete))
}

# Analyse la zone du bas : famille actuelle, bouton ROLL, spins restants
function Analyser-Bas($lecture) {
    $res = [pscustomobject]@{ Famille = $null; Roll = $null; Spins = $null }
    foreach ($l in $lecture.Lignes) {
        # Bouton "ROLL (86)"
        for ($i = 0; $i -lt $l.Mots.Count; $i++) {
            if (-not $res.Roll -and (Plus-Proche $l.Mots[$i].Texte @('ROLL'))) {
                $res.Roll = $l.Mots[$i]
                # "(6,065)" : on garde les chiffres jusqu'a la parenthese fermante (separateurs de milliers ignores)
                $suite = ($l.Mots | Select-Object -Skip ($i + 1) -First 3 | ForEach-Object Texte) -join ''
                if ($suite -match '^[\(\[\{]?([\d,\.\s''O]+)') {
                    $chiffres = $matches[1] -replace 'O', '0' -replace '[^\d]', ''
                    if ($chiffres) { $res.Spins = [int]$chiffres }
                }
            }
        }
        # Famille "BOYEGA (Common)" (l'OCR perd souvent les parentheses : "BOYEGA Common")
        for ($i = 1; $i -lt $l.Mots.Count -and -not $res.Famille; $i++) {
            $rar = Plus-Proche $l.Mots[$i].Texte $Raretes
            if (-not $rar) { continue }
            if ($rar -eq 'Mythical') { $rar = 'Mythic' }
            $nomLu = $l.Mots[$i - 1].Texte -replace '[^A-Za-z0-9]', ''
            if ($nomLu.Length -lt 2) { continue }
            $nom = Plus-Proche $nomLu $TousNoms
            if ($nom) { $rar = Rarete-De-Famille $nom }
            $res.Famille = [pscustomobject]@{ Nom = $(if ($nom) { $nom } else { $nomLu }); Rarete = $rar; Lu = $l.Texte.Trim() }
        }
        # Rarete illisible (ex. "(Epic)" lu "E ic") : si le 1er mot est une famille connue, sa rarete vient de la liste
        if (-not $res.Famille -and $l.Mots.Count -ge 1 -and $l.Mots.Count -le 4) {
            $nom = Plus-Proche ($l.Mots[0].Texte -replace '[^A-Za-z0-9]', '') $TousNoms
            if ($nom) { $res.Famille = [pscustomobject]@{ Nom = $nom; Rarete = (Rarete-De-Famille $nom); Lu = $l.Texte.Trim() } }
        }
    }
    $res
}

# Fenetre "Are you sure you want to reroll your 'XXX' family?" -> renvoie l'etat et le bouton YES
function Analyser-Confirmation($lecture) {
    if (-not $lecture -or $lecture.Texte -notmatch '(?i)sure|re-?roll') { return $null }
    $cibleVue = $null; $oui = $null; $nomVu = $null
    foreach ($l in $lecture.Lignes) {
        foreach ($m in $l.Mots) {
            $n = Plus-Proche $m.Texte $TousNoms
            if ($n) { $nomVu = $n }
            if ($n -and (Est-Cible ([pscustomobject]@{ Nom = $n; Rarete = (Rarete-De-Famille $n) }))) { $cibleVue = $n }
            if (-not $oui -and (Plus-Proche $m.Texte @('YES'))) { $oui = $m }
        }
    }
    [pscustomobject]@{ Texte = $lecture.Texte; CibleEnJeu = $cibleVue; Oui = $oui; NomVu = $nomVu }
}

# Pity affichee par le jeu (« EPIC+ PITY: 84/400 ») : petite zone lue en agrandi, sinon l'OCR se trompe
function Lire-Pity($f) {
    $script:Plein = $null
    try {
        # plusieurs essais (zone serree tres agrandie d'abord) ; une seule capture de la fenetre pour tous
        foreach ($essai in @(@(@(0.78, 0.955, 0.94, 0.99), 4), @(@(0.78, 0.955, 0.94, 0.99), 3), @(@(0.72, 0.95, 1.00, 0.995), 4))) {
            $l = Lire-Zone $f $essai[0] $essai[1]
            if ($l.Texte -match '(\d{1,3})\s*/\s*4[0O]{2}') { $v = [int]$matches[1]; if ($v -le 400) { return $v } }
        }
    } catch { } finally { if ($script:Plein) { $script:Plein.Dispose(); $script:Plein = $null } }
    $null
}

function Lire-Etat($f, [bool]$avecConfirm = $true) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:Plein = $null
    try {
        $lb = Lire-Zone $f $cfg.ZoneBas $cfg.EchelleOCR
        # Ecran plus petit (texte trop fin) : si rien n'est lu, on essaie en agrandi et on garde ce reglage s'il marche
        if ($cfg.EchelleOCR -eq 1 -and -not $lb.Lignes.Count -and -not $script:EchelleTestee) {
            $lb2 = Lire-Zone $f $cfg.ZoneBas 2
            if ($lb2.Lignes.Count -and (Analyser-Bas $lb2).Roll) { $cfg.EchelleOCR = 2; $lb = $lb2; Write-Host 'Lecture agrandie activee (petit ecran).' -ForegroundColor DarkCyan }
            $script:EchelleTestee = $true
        }
        if ($cfg.EchelleOCR -eq 1 -and $lb.Lignes.Count -and -not (Analyser-Bas $lb).Roll -and -not $script:EchelleTestee2) {
            $lb2 = Lire-Zone $f $cfg.ZoneBas 2
            if ((Analyser-Bas $lb2).Roll) { $cfg.EchelleOCR = 2; $lb = $lb2; Write-Host 'Lecture agrandie activee (petit ecran).' -ForegroundColor DarkCyan }
            $script:EchelleTestee2 = $true
        }
        $lc = if ($avecConfirm) { Lire-Zone $f $cfg.ZoneConfirmation 1 } else { $null }
        # Fenetre de confirmation reperee : relecture agrandie pour bien lire le nom et le bouton YES
        if ($lc -and $lc.Texte -match '(?i)sure|re-?roll') { $lc = Lire-Zone $f $cfg.ZoneConfirmation 2 }
        [pscustomobject]@{ Bas = Analyser-Bas $lb; Confirm = Analyser-Confirmation $lc; LuBas = $lb; Ms = $sw.ElapsedMilliseconds }
    } finally { if ($script:Plein) { $script:Plein.Dispose(); $script:Plein = $null } }
}

# ---------- Souris / clavier ----------
function Touche-Appuyee($vk) { ([W]::GetAsyncKeyState($vk) -band 0x8000) -ne 0 }
# Roblox suit la souris via les mouvements "materiels" (raw input) : SetCursorPos ne lui suffit pas
# (teste : le bouton YES ne reagissait jamais). On simule donc un vrai deplacement absolu.
$BureauVirtuel = [System.Windows.Forms.SystemInformation]::VirtualScreen
function Bouger($x, $y) {
    $nx = [int](($x - $BureauVirtuel.Left) * 65535 / ($BureauVirtuel.Width - 1))
    $ny = [int](($y - $BureauVirtuel.Top) * 65535 / ($BureauVirtuel.Height - 1))
    [W]::mouse_event(0x0001 -bor 0x8000 -bor 0x4000, $nx, $ny, 0, [IntPtr]::Zero)   # MOVE | ABSOLUTE | VIRTUALDESK
}
function Clic($x, $y) {
    Bouger ($x + 5) $y; Start-Sleep -Milliseconds 20
    Bouger $x $y;       Start-Sleep -Milliseconds 25
    [W]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 45
    [W]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
}

# --- Mode arriere-plan : "clic eclair" ---
# Roblox ignore les clics envoyes a sa fenetre quand elle n'est pas active (teste : PostMessage /
# SendMessage / fausse activation ne font rien). On passe donc Roblox devant ~0,2 s, on clique,
# puis on rend la fenetre active et la souris exactement comme avant.
function Clic-Eclair($x, $y) {
    $h = $script:F.Handle
    # attend que tu aies relache les boutons de ta souris (pas de clic au milieu d'un glisser)
    $limite = (Get-Date).AddSeconds(5)
    while ((Touche-Appuyee 0x01) -or (Touche-Appuyee 0x02) -or (Touche-Appuyee 0x04)) {
        if ((Get-Date) -gt $limite) { break }
        Start-Sleep -Milliseconds 30
    }
    $avant = [W]::GetForegroundWindow()
    if ($avant -ne $h) {
        # attend une micro-pause de ta part (tu ne tapes pas / ne bouges pas la souris) pour ne rien envoyer a Roblox par erreur
        $limite = (Get-Date).AddMilliseconds($cfg.AttentePauseMaxMs)
        while ([W]::InactifDepuis() -lt $cfg.PauseUtilisateurMs -and (Get-Date) -lt $limite) { Start-Sleep -Milliseconds 20 }
        $avant = [W]::GetForegroundWindow()
    }
    $pos = New-Object W+POINT; [W]::GetCursorPos([ref]$pos) | Out-Null
    if ($avant -ne $h) {
        $ok = $false
        for ($k = 0; $k -lt 3 -and -not $ok; $k++) { $ok = [W]::Activer($h); if (-not $ok) { Start-Sleep -Milliseconds 40 } }
        if (-not $ok) { $script:EclairRefuse++; return }   # Roblox n'a pas pu passer devant : on ne clique surtout pas dans ta fenetre
        Start-Sleep -Milliseconds $cfg.DelaiEclairMs
    }
    Clic $x $y; Start-Sleep -Milliseconds 30
    Bouger $pos.X $pos.Y
    if ($avant -ne $h -and $avant -ne [IntPtr]::Zero) { [W]::Activer($avant) | Out-Null }
}
function Clic-Jeu($x, $y) {
    if ($cfg.ModeClic -eq 'premierplan') { Clic $x $y } else { Clic-Eclair $x $y }
}
function Methode-Validee { $script:RatesDeSuite = 0 }
# Clic sans effet : on retente, et on abandonne apres plusieurs echecs de suite
function Methode-Suivante { $script:RatesDeSuite++; $script:RatesDeSuite -lt 4 }
$script:RatesDeSuite = 0
# ---------- Suivi a distance par Discord (webhook) ----------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Txt([string]$s) { [regex]::Replace($s, '(?i)\\u([0-9A-F]{4,5})', { param($m) [char]::ConvertFromUtf32([Convert]::ToInt32($m.Groups[1].Value, 16)) }) }
$NomFr = @{ Common = 'Commune'; Rare = 'Rare'; Epic = (Txt 'Épique'); Legendary = (Txt 'Légendaire'); Mythic = 'Mythique'; Secret = 'Secrète' }
$script:Stats = [ordered]@{}; $script:MsgSuivi = $null; $script:DernierReste = $null; $script:FamilleActuelle = ''
function Discord([string]$methode, [string]$url, [string]$contenu) {
    if (-not $cfg.WebhookDiscord) { return $null }
    try {
        $corps = [Text.Encoding]::UTF8.GetBytes((@{ content = $contenu } | ConvertTo-Json -Compress))
        Invoke-RestMethod -Method $methode -Uri $url -Body $corps -ContentType 'application/json; charset=utf-8' -TimeoutSec 6
    } catch { Write-Host "   (Discord indisponible : $($_.Exception.Message))" -ForegroundColor DarkGray; $null }
}
function Texte-Suivi([string]$etat) {
    $st = (@('Mythic', 'Legendary', 'Epic', 'Rare', 'Common') | Where-Object { $script:Stats[$_] } | ForEach-Object { "$($NomFr[$_]) $($script:Stats[$_])" }) -join '  |  '
    (Txt '\U1F3B2') + " **Auto-roll AOTR** - $etat`n" +
    "Spins faits : **$spins**   |   Spins restants : **$(if ($null -ne $script:DernierReste) { $script:DernierReste } else { '?' })**`n" +
    "Famille actuelle : $($script:FamilleActuelle)`n" +
    $(if ($st) { "Tirages : $st`n" } else { '' }) +
    (Txt "Mis à jour à ") + (Get-Date -Format 'HH:mm:ss')
}
function Suivi-Discord([string]$etat = 'en cours') {
    if (-not $cfg.WebhookDiscord) { return }
    $base = $cfg.WebhookDiscord.TrimEnd('/')
    if ($script:MsgSuivi) { $null = Discord 'Patch' "$base/messages/$($script:MsgSuivi)" (Texte-Suivi $etat) }
    else { $r = Discord 'Post' "$base`?wait=true" (Texte-Suivi $etat); if ($r) { $script:MsgSuivi = $r.id } }
}
# Ajoute une ligne a un fichier en le laissant lisible par les autres (interface, bloc-notes...).
# Ne plante jamais : si le fichier est bloque, on reessaie puis on abandonne cette ligne.
function Ecrire-Ligne([string]$chemin, [string]$ligne) {
    for ($k = 0; $k -lt 10; $k++) {
        try {
            $fs = New-Object IO.FileStream $chemin, ([IO.FileMode]::Append), ([IO.FileAccess]::Write), ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $w = New-Object IO.StreamWriter $fs, (New-Object Text.UTF8Encoding $false)
            $w.WriteLine($ligne); $w.Dispose()
            return
        } catch { Start-Sleep -Milliseconds 25 }
    }
}
function Log([string]$msg, [string]$couleur = 'Gray') {
    $ligne = '{0:HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Host $ligne -ForegroundColor $couleur
    Ecrire-Ligne $LogPath $ligne
    if ($Journal) { Ecrire-Ligne $Journal $ligne }
}
function Verifier-F8 { if (Touche-Appuyee $VK_F8) { Log 'Arret demande (F8).' 'Yellow'; exit } }
function Attendre([int]$ms) {
    $fin = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $fin) { Verifier-F8; Start-Sleep -Milliseconds 20 }
}
function Fin([string]$msg, [string]$couleur, [switch]$Victoire) {
    Log $msg $couleur
    if ($cfg.WebhookDiscord -and -not $Test -and -not $ImageTest) {
        Suivi-Discord $(if ($Victoire) { Txt 'TERMINÉ' } else { Txt 'ARRÊTÉ' })
        $icone = if ($Victoire) { Txt '✅' } else { Txt '⚠️' }
        $null = Discord 'Post' $cfg.WebhookDiscord.TrimEnd('/') "$icone $($msg.Replace('***', '').Trim())"
    }
    if ($Victoire) { 1..3 | ForEach-Object { [Console]::Beep(880, 200); [Console]::Beep(1320, 300) } }
    if (-not $SansPopup) { [System.Windows.Forms.MessageBox]::Show($msg, 'Auto-roll AOTR') | Out-Null }
    exit
}
$script:OuiMemo = $null; $script:DernierOui = $null
function Gerer-Confirmation($c, $fam) {
    if ($c.CibleEnJeu) { Fin "*** Confirmation demandee pour $($c.CibleEnJeu) : je NE confirme PAS. Arret. ***" 'Green' -Victoire }
    # Juste apres un clic sur YES, la fenetre est en train de se fermer (bouton survole/anime, souvent illisible) :
    # on la laisse disparaitre au lieu de recliquer ou de s'arreter
    if ($script:DernierOui -and $script:DernierOui.ElapsedMilliseconds -lt 1500) { Attendre 200; return }
    if (-not $c.Oui) {
        # Fenetre en cours d'apparition ou bouton mal lu : on relit plusieurs fois
        for ($i = 0; $i -lt 8 -and -not $c.Oui; $i++) {
            Attendre 250
            $e = Lire-Etat $script:F $true
            if (-not $e.Confirm) { return }   # fermee entre-temps
            $c = $e.Confirm
            if ($c.CibleEnJeu) { Fin "*** Confirmation demandee pour $($c.CibleEnJeu) : je NE confirme PAS. Arret. ***" 'Green' -Victoire }
        }
    }
    if (-not $c.Oui) {
        # Toujours illisible : on clique la ou YES a deja ete vu, seulement si le nom de la famille (non gardee) est bien lu
        $m = $script:OuiMemo
        if ($m -and $c.NomVu -and $m.W -eq $script:F.W -and $m.H -eq $script:F.H) {
            Log "   bouton YES illisible : clic a sa position habituelle" 'DarkYellow'
            $c = [pscustomobject]@{ Oui = [pscustomobject]@{ X = $script:F.X + $m.DX; Y = $script:F.Y + $m.DY } }
        } else { Fin "Fenetre de confirmation sans bouton YES lisible : arret par securite. [$($c.Texte)]" 'Red' }
    }
    if ($fam) { Log "   confirmation du reroll de $($fam.Nom) ($($fam.Rarete)) -> YES" 'DarkCyan' }
    Clic-Jeu $c.Oui.X $c.Oui.Y
    $script:OuiMemo = [pscustomobject]@{ DX = $c.Oui.X - $script:F.X; DY = $c.Oui.Y - $script:F.Y; W = $script:F.W; H = $script:F.H }
    $script:DernierOui = [Diagnostics.Stopwatch]::StartNew()
}

# ---------- Mode test : lit l'ecran une fois, ne clique pas ----------
function Afficher-Etat($e) {
    $fam = $e.Bas.Famille
    Write-Host ("Famille actuelle : " + $(if ($fam) { "$($fam.Nom) ($($fam.Rarete))   [lu: $($fam.Lu)]" } else { 'NON TROUVEE' })) -ForegroundColor $(if ($fam) { 'Green' } else { 'Red' })
    Write-Host ("Bouton ROLL      : " + $(if ($e.Bas.Roll) { "trouve en $($e.Bas.Roll.X), $($e.Bas.Roll.Y)" } else { 'NON TROUVE' })) -ForegroundColor $(if ($e.Bas.Roll) { 'Green' } else { 'Red' })
    Write-Host ("Spins restants   : " + $(if ($null -ne $e.Bas.Spins) { $e.Bas.Spins } else { '?' }))
    Write-Host ("Confirmation     : " + $(if ($e.Confirm) { "OUI - bouton YES " + $(if ($e.Confirm.Oui) { "en $($e.Confirm.Oui.X), $($e.Confirm.Oui.Y)" } else { 'non trouve' }) } else { 'aucune' }))
    if ($e.Confirm) { Write-Host ("  -> " + $(if ($e.Confirm.CibleEnJeu) { "reroll de $($e.Confirm.CibleEnJeu) : le programme REFUSERA de confirmer" } else { 'le programme cliquera YES' })) }
    Write-Host "Temps de lecture : $($e.Ms) ms"
    if (-not $script:ImageSource -or $true) { $pt = Lire-Pity $script:FTest; Write-Host ("Pity (jeu)       : " + $(if ($null -ne $pt) { "$pt / 400" } else { 'non lue' })) }
    if ($fam) { Write-Host ("Cible ?          : " + $(if (Est-Cible $fam) { 'OUI -> le programme ne relancera pas' } else { 'non -> le programme relancera' })) }
    Write-Host "`n--- Texte lu en bas a droite ---" -ForegroundColor DarkGray
    $e.LuBas.Lignes | ForEach-Object { Write-Host "  $($_.Texte)" -ForegroundColor DarkGray }
}

if ($ImageTest) {
    $script:ImageSource = [System.Drawing.Image]::FromFile((Resolve-Path $ImageTest).Path)
    $f = [pscustomobject]@{ Handle = [IntPtr]::Zero; X = 0; Y = 0; W = $script:ImageSource.Width; H = $script:ImageSource.Height }
    $script:FTest = $f
    Afficher-Etat (Lire-Etat $f)
    return
}

if ($Test) {
    $f = Fenetre-Roblox
    if (-not $f) { Write-Host 'Roblox introuvable (lance le jeu, et ne le reduis pas).' -ForegroundColor Red; return }
    Write-Host "Fenetre Roblox : $($f.W) x $($f.H)`n" -ForegroundColor Cyan
    # si un spin est en cours (nom cache pendant l'animation ~3 s), on reessaie un peu
    $e = Lire-Etat $f
    for ($k = 0; $k -lt 20 -and -not ($e.Bas.Famille -and $e.Bas.Roll); $k++) { Start-Sleep -Milliseconds 200; $e = Lire-Etat $f }
    $script:FTest = $f
    Afficher-Etat $e
    return
}

# ---------- Boucle principale ----------
Write-Host ''
Write-Host '=== AUTO-ROLL AOTR ===    F8 = ARRET' -ForegroundColor Cyan
$fond = $cfg.ModeClic -ne 'premierplan'
Write-Host $(if ($fond) { 'Mode arriere-plan : tu peux utiliser ton PC (ne reduis pas Roblox).' } else { 'Mode premier plan : laisse Roblox devant.' })

$spins = 0; $echecs = 0; $relectures = 0; $enPause = $false; $depart = $false; $e = $null
Log "Demarrage ($(if ($fond) { 'arriere-plan' } else { 'premier plan' })) - familles gardees : $(@($cfg.FamillesCibles) -join ', ')" 'Cyan'
$erreursDeSuite = 0
while ($true) { try {
    Verifier-F8
    $f = Fenetre-Roblox
    if (-not $f) {
        # Roblox reduit ou ferme : on attend (reduit = plus d'image, impossible de lire)
        if (-not (Get-Process RobloxPlayerBeta -ErrorAction SilentlyContinue)) { Fin 'Roblox est ferme. Arret.' 'Red' }
        if (-not $enPause) { Log 'En pause : Roblox est reduit (remets-le en fenetre, meme derriere d''autres).' 'DarkYellow'; $enPause = $true }
        $e = $null; Attendre 500; continue
    }
    $script:F = $f
    if (-not $fond -and [W]::GetForegroundWindow() -ne $f.Handle) {
        if (-not $enPause) { Log 'En pause : Roblox n''est pas au premier plan (clique dans le jeu pour reprendre).' 'DarkYellow'; $enPause = $true }
        $e = $null; Attendre 300; continue
    }
    if ($enPause) { Log 'Reprise.' 'DarkYellow'; $enPause = $false }

    # Lecture complete (au depart, apres une pause ou un souci) ; sinon on reutilise le resultat du spin
    if (-not $e) {
        $e = Lire-Etat $f $true
        if ($e.Confirm) { Gerer-Confirmation $e.Confirm $null; $e = $null; Attendre 400; continue }
    }
    $fam = $e.Bas.Famille

    if (-not $fam -or -not $e.Bas.Roll) {
        $echecs++
        if ($echecs -ge 60) { Fin 'Impossible de lire la famille ou le bouton ROLL depuis ~15 s. Es-tu bien sur l''ecran des familles ? Arret.' 'Red' }
        $e = $null; Attendre 150; continue
    }
    # Nom non reconnu (lecture ratee ?) : on relit avant de decider quoi que ce soit
    if (-not (Rarete-De-Famille $fam.Nom) -and $relectures -lt 5) { $relectures++; $e = $null; Attendre 150; continue }
    $echecs = 0; $relectures = 0

    if (-not $depart) {
        Log ("Famille de depart : {0} ({1}) - reste {2}" -f $fam.Nom, $fam.Rarete, $(if ($null -ne $e.Bas.Spins) { $e.Bas.Spins } else { '?' })) 'Cyan'
        $depart = $true
        $script:DernierReste = $e.Bas.Spins; $script:FamilleActuelle = "$($fam.Nom) ($($NomFr[$fam.Rarete]))"
        Suivi-Discord (Txt 'démarré')
    }
    if (Est-Cible $fam) { Fin "*** $($fam.Nom.ToUpper()) ($($fam.Rarete)) obtenu apres $spins spins ! ***" 'Green' -Victoire }
    if ($spins -ge $cfg.MaxSpins) { Fin "Limite de $($cfg.MaxSpins) spins atteinte. Famille actuelle : $($fam.Nom) ($($fam.Rarete))." 'Yellow' }
    if ($null -ne $e.Bas.Spins -and $e.Bas.Spins -le $cfg.GarderSpins) { Fin "Plus de spins (reste $($e.Bas.Spins)). Famille actuelle : $($fam.Nom) ($($fam.Rarete))." 'Yellow' }

    # --- Spin ---
    $avant = $fam.Nom; $spinsAvant = $e.Bas.Spins
    $popupPossible = @('Common', 'Rare') -notcontains $fam.Rarete   # la confirmation n'existe qu'a partir d'Epic
    $script:EclairRefuse = 0
    Clic-Jeu $e.Bas.Roll.X $e.Bas.Roll.Y
    $chrono = [Diagnostics.Stopwatch]::StartNew()
    $e = $null; $signe = $false; $vuDisparaitre = $false; $absences = 0; $candidat = $null; $pareil = 0

    # --- Attente du resultat, lecture en continu ---
    while ($true) {
        Verifier-F8
        $ms = $chrono.ElapsedMilliseconds
        $e2 = Lire-Etat $f ($popupPossible -or $ms -gt 1500)
        if ($e2.Confirm) { Methode-Validee; Gerer-Confirmation $e2.Confirm $fam; $signe = $true; $candidat = $null; $chrono.Restart(); continue }

        $f2 = $e2.Bas.Famille
        $spinsBaisse = ($null -ne $spinsAvant -and $null -ne $e2.Bas.Spins -and $e2.Bas.Spins -lt $spinsAvant)
        if ($spinsBaisse) { $signe = $true }
        if (-not $f2 -or -not $e2.Bas.Roll -or -not $f2.Rarete) {
            # animation en cours (texte absent ou illisible) - 2 lectures de suite pour ne pas se fier a un rate d'OCR
            $absences++; $candidat = $null; $pareil = 0
            if ($absences -ge 2) { $vuDisparaitre = $true; $signe = $true }
        } else {
            $absences = 0
            # Resultat accepte seulement si le compteur de spins a baisse (quand il est lisible)
            $spinFait = if ($null -ne $spinsAvant -and $null -ne $e2.Bas.Spins) { $spinsBaisse } else { $vuDisparaitre -or $f2.Nom -ne $avant }
            if ($spinFait -and ($vuDisparaitre -or $f2.Nom -ne $avant -or $ms -gt 2500)) {
                # lectures identiques pour etre sur : 2 pour une famille connue, 3 pour un nom inconnu
                if ($candidat -eq $f2.Nom) { $pareil++ } else { $candidat = $f2.Nom; $pareil = 1 }
                $requis = if (Rarete-De-Famille $f2.Nom) { 2 } else { 3 }
                if ($pareil -ge $requis) { $e = $e2; break }
                continue
            }
            $candidat = $null; $pareil = 0   # les lectures valides doivent se suivre
            # Apres le delai, meme nom ET meme compteur bien visibles = le clic n'a pas ete pris
            # (une vraie animation cache le nom jusqu'a ~3,2 s)
            if ($ms -gt $cfg.DelaiReclicMs -and $f2.Nom -eq $avant -and $null -ne $spinsAvant -and $e2.Bas.Spins -eq $spinsAvant) { $signe = $false; break }
        }
        if (-not $signe -and $ms -gt $cfg.DelaiReclicMs) { break }   # le clic n'a pas ete pris
        if ($ms -gt $cfg.DelaiMaxRollMs) { break }
        Start-Sleep -Milliseconds 15
    }
    if (-not $e) {
        if ($signe) { Log '   resultat pas lu a temps, relecture' 'DarkYellow' }
        elseif (-not (Methode-Suivante)) { Fin 'Le bouton ROLL ne reagit plus aux clics (4 essais). Arret.' 'Red' }
        else { Log $(if ($script:EclairRefuse) { '   Windows a refuse de passer Roblox devant, nouvel essai' } else { '   clic non pris en compte, nouvel essai' }) 'DarkYellow' }
        continue
    }
    Methode-Validee
    $spins++
    $r = $e.Bas.Famille
    if (-not (Rarete-De-Famille $r.Nom)) { Log "   famille inconnue lue : `"$($r.Lu)`" (ajoute-la dans familles.psd1 si elle existe)" 'DarkYellow' }
    $script:Stats[$r.Rarete] = 1 + [int]$script:Stats[$r.Rarete]
    $script:DernierReste = $e.Bas.Spins; $script:FamilleActuelle = "$($r.Nom) ($($NomFr[$r.Rarete]))"
    if ($cfg.NotifChaqueSpins -gt 0 -and ($spins % $cfg.NotifChaqueSpins) -eq 0) { Suivi-Discord }
    $coul = switch ($r.Rarete) { 'Rare' { 'Cyan' } 'Epic' { 'Magenta' } 'Legendary' { 'Yellow' } 'Mythic' { 'Red' } default { 'Gray' } }
    Ecrire-Ligne $TiragesPath ('{0:yyyy-MM-dd};{0:HH:mm:ss};{1};{2};{3};{4};{5}' -f (Get-Date), $SessionId, $spins, $r.Nom, $r.Rarete, $e.Bas.Spins)
    $pity = Lire-Pity $f
    Log (("Spin {0,4} : {1,-10} ({2})   reste {3}   [{4:N1} s]" -f $spins, $r.Nom, $r.Rarete, $(if ($null -ne $e.Bas.Spins) { $e.Bas.Spins } else { '?' }), ($chrono.ElapsedMilliseconds / 1000)) + $(if ($null -ne $pity) { "   pity $pity" } else { '' })) $coul
    $erreursDeSuite = 0
} catch {
    # Erreur imprevue : on la note et on reprend proprement (arret apres 10 erreurs de suite)
    $erreursDeSuite++
    Log "   erreur : $($_.Exception.Message) (reprise)" 'Red'
    if ($erreursDeSuite -ge 10) { Fin "Trop d'erreurs de suite, arret. Derniere : $($_.Exception.Message)" 'Red' }
    $e = $null; Start-Sleep -Milliseconds 500
} }