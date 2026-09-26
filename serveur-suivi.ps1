# Serveur de suivi a distance, lance par ui.ps1.
# Sert une page web (/) et l'etat du roll en JSON (/etat) sur le reseau local.
# TcpListener : pas besoin de droits admin (contrairement a HttpListener).

function Adresses-Locales {
    $ips = [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and $_.Description -notmatch 'Virtual|VMware|VirtualBox|Hyper-V|WSL|Loopback' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -notlike '169.254.*' } |
        ForEach-Object { $_.Address.ToString() }
    # les adresses de box (192.168.x / 10.x) en premier
    @($ips | Sort-Object { if ($_ -like '192.168.*') { 0 } elseif ($_ -like '10.*') { 1 } else { 2 } })
}

function Demarrer-ServeurSuivi([int]$Port, $Etat, [string]$Html, [string]$FichierTirages) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($Port, $Etat, $Html, $FichierTirages)
        # Historique complet : tirages.csv -> JSON compact [[date,heure,session,spin,nom,rarete,reste], ...]
        function Json-Historique {
            if (-not $FichierTirages -or -not (Test-Path $FichierTirages)) { return '[]' }
            $fs = New-Object IO.FileStream $FichierTirages, 'Open', 'Read', 'ReadWrite'
            try { $txt = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
            $txt = $txt.Replace('"', '').Replace('\', '')
            $lignes = $txt.Split([char]10)
            $sb = New-Object Text.StringBuilder ($txt.Length * 2)
            [void]$sb.Append('[')
            $premier = $true
            for ($i = [Math]::Max(0, $lignes.Length - 20000); $i -lt $lignes.Length; $i++) {
                $l = $lignes[$i].TrimEnd([char]13)
                if (($l.Length - $l.Replace(';', '').Length) -lt 6) { continue }
                if (-not $premier) { [void]$sb.Append(',') }; $premier = $false
                [void]$sb.Append('["').Append($l.Replace(';', '","')).Append('"]')
            }
            [void]$sb.Append(']'); $sb.ToString()
        }
        try {
            $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Any, $Port)
            $l.Start()
            $Etat['_serveur'] = 'ok'
        } catch { $Etat['_serveur'] = "erreur : $($_.Exception.Message)"; return }
        while ($true) {
            $c = $l.AcceptTcpClient()
            try {
                $c.ReceiveTimeout = 3000; $c.SendTimeout = 3000
                $s = $c.GetStream()
                $r = New-Object IO.StreamReader($s, [Text.Encoding]::ASCII)
                $ligne = $r.ReadLine()
                while (($h = $r.ReadLine()) -and $h -ne '') { }
                $chemin = if ($ligne -match '^GET\s+(\S+)') { $matches[1] } else { '/' }
                if ($chemin -like '/historique*') {
                    $corps = [Text.Encoding]::UTF8.GetBytes((Json-Historique))
                    $type = 'application/json; charset=utf-8'
                } elseif ($chemin -like '/etat*') {
                    [Threading.Monitor]::Enter($Etat.PSBase.SyncRoot)
                    try { $copie = @{}; foreach ($k in @($Etat.Keys)) { $copie[$k] = $Etat[$k] } } finally { [Threading.Monitor]::Exit($Etat.PSBase.SyncRoot) }
                    $corps = [Text.Encoding]::UTF8.GetBytes(($copie | ConvertTo-Json -Depth 5 -Compress))
                    $type = 'application/json; charset=utf-8'
                } else {
                    $corps = [Text.Encoding]::UTF8.GetBytes($Html)
                    $type = 'text/html; charset=utf-8'
                }
                $tete = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: $type`r`nContent-Length: $($corps.Length)`r`nCache-Control: no-store`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n")
                $s.Write($tete, 0, $tete.Length); $s.Write($corps, 0, $corps.Length); $s.Flush()
            } catch { } finally { $c.Close() }
        }
    }).AddArgument($Port).AddArgument($Etat).AddArgument($Html).AddArgument($FichierTirages)
    [void]$ps.BeginInvoke()
    $ps
}
