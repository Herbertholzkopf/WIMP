<#
================================================================================
 WIMP - Windows IIS, MySQL & PHP Installer
 (PHP + IIS + MySQL Setup-Assistent für Windows Server 2022 / 2025)
 Version 2.1
================================================================================
 Führt durch die Installation von IIS, PHP und MySQL und richtet auf einem
 frischen Windows Server mit wenigen Klicks ein:
   - IIS inkl. CGI/FastCGI, Verwaltungskonsole, URL Rewrite 2.1
   - Visual C++ Redistributable 2015-2022 (x64)
   - PHP (Non Thread Safe, x64) nach C:\Program Files\PHP, fertige php.ini,
     PATH-Eintrag, Session-/Upload-Ordner, FastCGI-Handler, Funktionstest
   - optional MySQL 8.4 LTS als Windows-Dienst (+ Workbench, + Anwendungs-DB)
   - optional Python 3 (neueste Version von python.org, systemweit,
     inklusive pip und PATH-Eintrag)

 BEDIENUNG
   Start -> Auswahl -> Installieren -> Fertig. Alle Feineinstellungen liegen
   unter "Erweiterte Optionen..." und sind mit sinnvollen Standardwerten belegt.

 START ALS SKRIPT
   Rechtsklick -> "Mit PowerShell ausführen"  oder in einer Konsole:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\PHP-IIS-MySQL-Setup.ps1
   Das Skript hebt sich bei Bedarf selbst auf Administratorrechte an.

 ALS EXE WEITERGEBEN (empfohlen für Kunden)
   Build-Exe.ps1 ausführen - oder von Hand mit dem Modul PS2EXE:
   Install-Module ps2exe -Scope CurrentUser
   Invoke-ps2exe .\PHP-IIS-MySQL-Setup.ps1 .\PHP-IIS-MySQL-Setup.exe `
       -noConsole -requireAdmin -STA -x64 `
       -title 'PHP + IIS Setup-Assistent' -version '2.1.0.0'
   -requireAdmin bettet ein UAC-Manifest ein, -STA ist für die Oberfläche
   Pflicht, -noConsole unterdrückt das schwarze Konsolenfenster.

 BILDNACHWEIS
   Symbol: "Werkzeugkasten" von Magnific
   https://www.magnific.com/de/icon/werkzeugkasten_17119213
   Das Symbol wurde nachträglich mit KI verändert.

 HINWEISE
   - Diese Datei ist UTF-8 mit BOM gespeichert. Beim Bearbeiten die Kodierung
     beibehalten, sonst werden Umlaute in der Oberfläche falsch dargestellt.
   - Das Skript ist wiederholt ausführbar (idempotent): Vorhandenes wird
     erkannt und nicht dupliziert.
   - Voraussetzung: Windows Server mit Desktop Experience, Internetzugang.
================================================================================
#>

[CmdletBinding()]
param(
    [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
# Ohne das ist Invoke-WebRequest um ein Vielfaches langsamer:
$ProgressPreference    = 'SilentlyContinue'
# TLS 1.2 für Downloads sicherstellen (auf aelteren Systemen nicht Standard)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==============================================================================
#  0) Administratorrechte und STA-Modus sicherstellen
# ==============================================================================

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Läuft das Ganze als PS2EXE-Exe, ist $PSCommandPath leer. Dann ist die
# eigene Exe der Neustart-Kandidat, sonst powershell.exe mit dem Skript.
$script:IsCompiled = [string]::IsNullOrEmpty($PSCommandPath)
$script:SelfPath   = if ($script:IsCompiled) {
    [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
} else {
    $PSCommandPath
}

if (-not $NoRelaunch) {
    $isAdmin = Test-IsAdmin
    $isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
    if (-not $isAdmin -or -not $isSta) {
        try {
            if ($script:IsCompiled) {
                if (-not $isSta) {
                    throw 'Die EXE wurde ohne den Schalter -STA erzeugt. Bitte mit "Invoke-ps2exe ... -STA -requireAdmin -noConsole" neu erstellen.'
                }
                Start-Process -FilePath $script:SelfPath -ArgumentList '-NoRelaunch' -Verb RunAs
            } else {
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script:SelfPath`"", '-NoRelaunch')
                if ($isAdmin) {
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
                } else {
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Der Assistent benötigt Administratorrechte und konnte nicht neu gestartet werden.`r`n`r`n" +
                "$($_.Exception.Message)`r`n`r`n" +
                'Bitte per Rechtsklick "Als Administrator ausführen" starten.',
                'PHP + IIS Setup-Assistent', 'OK', 'Warning') | Out-Null
        }
        exit
    }
}

# ==============================================================================
#  1) Konstanten, Standardwerte und Zustand
# ==============================================================================

$script:AppTitle     = 'PHP + IIS Setup-Assistent'
$script:AppVersion   = '2.1'
# Bildnachweis für das Programmsymbol (wird im Dialog "Info" angezeigt)
$script:IconCreditText = 'Symbol: "Werkzeugkasten" von Magnific, nachträglich mit KI verändert.'
$script:IconCreditUrl  = 'https://www.magnific.com/de/icon/werkzeugkasten_17119213'

$script:PhpRoot      = Join-Path $env:ProgramFiles 'PHP'
$script:InetRoot     = Join-Path $env:SystemDrive 'inetpub'
$script:WwwRoot      = Join-Path $script:InetRoot 'wwwroot'
$script:InetTemp     = Join-Path $script:InetRoot 'temp'
$script:SessionDir   = Join-Path $script:InetTemp 'php_sessions'
$script:UploadDir    = Join-Path $script:InetTemp 'php_upload'
$script:LogDir       = Join-Path $env:ProgramData 'PHP-IIS-Setup'
$script:LogFile      = Join-Path $script:LogDir ('setup_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))

$script:VcRedistUrl  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
$script:CaCertUrl    = 'https://curl.se/ca/cacert.pem'
# IIS URL Rewrite Module 2.1, x64. Die MSI setzt laut eigener Startbedingung
# CoreWebEngine und W3SVC voraus - sie darf erst nach der IIS-Installation laufen.
$script:RewriteUrls  = [ordered]@{
    'Deutsch'  = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_de-DE.msi'
    'Englisch' = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'
}
$script:ReleaseIndex = 'https://windows.php.net/downloads/releases/'
$script:ArchiveIndex = 'https://windows.php.net/downloads/releases/archives/'
$script:AppCmd       = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'

$script:MySqlUrlDefault = 'https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.11-winx64.msi'
$script:WbUrlDefault    = 'https://cdn.mysql.com/Downloads/MySQLGUITools/mysql-workbench-community-8.0.47-winx64.msi'

# Built-in Gruppe IIS_IUSRS - über SID, damit es auf jeder Sprachversion klappt
$script:IisUsersSid  = 'S-1-5-32-568'
# Das anonyme IIS-Konto. PHP arbeitet damit, sobald fastcgi.impersonate = 1
# gesetzt ist - dann reicht ein Recht für IIS_IUSRS allein nicht aus.
$script:IusrSid      = 'S-1-5-17'

$script:IisFeatures = @(
    # DISM-Namen (nicht die ServerManager-Namen). -All zieht Elternfeatures mit.
    'IIS-WebServerRole'
    'IIS-WebServer'
    'IIS-CommonHttpFeatures'
    'IIS-DefaultDocument'            # Standarddokument (index.php)
    'IIS-StaticContent'
    'IIS-HttpErrors'
    'IIS-HealthAndDiagnostics'
    'IIS-HttpLogging'
    'IIS-RequestMonitor'
    'IIS-Performance'
    'IIS-HttpCompressionStatic'
    'IIS-Security'
    'IIS-RequestFiltering'           # maxAllowedContentLength
    'IIS-ApplicationDevelopment'
    'IIS-CGI'
    'IIS-WebServerManagementTools'
    'IIS-ManagementConsole'          # IIS-Verwaltungskonsole
    'IIS-ManagementScriptingTools'   # Modul WebAdministration
)

# Extensions, die in einer php.ini-production für Windows vorkommen. Die
# Liste wird in "Erweiterte Optionen" angezeigt; beim Schreiben der php.ini
# werden nur Einträge angefasst, zu denen dort auch eine Zeile existiert.
$script:KnownExtensions = @(
    'bz2', 'curl', 'exif', 'ffi', 'fileinfo', 'ftp', 'gd', 'gettext', 'gmp',
    'intl', 'ldap', 'mbstring', 'mysqli', 'odbc', 'openssl', 'pdo_mysql',
    'pdo_odbc', 'pdo_pgsql', 'pdo_sqlite', 'pgsql', 'shmop', 'snmp', 'soap',
    'sockets', 'sodium', 'sqlite3', 'tidy', 'xsl', 'zip'
)
$script:CommonExtensions = @(
    'curl', 'fileinfo', 'gd', 'intl', 'mbstring', 'exif', 'mysqli',
    'openssl', 'pdo_mysql', 'pdo_sqlite', 'sqlite3', 'zip'
)

<#
 Arbeitsspeicher in MB. Windows meldet über TotalPhysicalMemory grundsätzlich
 etwas weniger, als tatsächlich zugewiesen ist (Firmware/Hypervisor behält
 einen kleinen Teil ein) - auf einer Hyper-V-VM mit 8 GB kommen z. B. 8191 MB
 heraus. Deshalb wird auf das nächste Vielfache von 256 MB aufgerundet, damit
 alle abgeleiteten Werte glatt bleiben.
#>
function Get-TotalRamMb {
    $raw = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    [int]([math]::Ceiling($raw / 256.0) * 256)
}

<#
 Empfohlene Größe für innodb_buffer_pool_size: rund ein Viertel des
 Arbeitsspeichers, aufgerundet auf die nächste sinnvolle Stufe.
 Die Stufen sind alle Vielfache von 128 MB - das entspricht der Standardgröße
 eines Buffer-Pool-Chunks (innodb_buffer_pool_chunk_size). MySQL rundet einen
 krummen Wert ohnehin auf ein Vielfaches davon auf; mit den Stufen steht in
 der my.ini derselbe Wert, den der Server später tatsächlich benutzt.
#>
function Get-InnoDbPoolSizeMb {
    param([int]$RamMb = 0)
    if ($RamMb -le 0) { $RamMb = Get-TotalRamMb }
    $want   = $RamMb * 0.25
    $stufen = @(128, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536)
    foreach ($s in $stufen) { if ($want -le $s) { return [int]$s } }
    # darüber hinaus auf volle Gigabyte aufrunden
    [int]([math]::Ceiling($want / 1024.0) * 1024)
}

function New-MySqlPassword {
    param([int]$Length = 20)
    # Zeichen, die sich in Kommandozeilen und INI-Dateien nicht beißen
    $set = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#%+-=?_'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    -join ($bytes | ForEach-Object { $set[$_ % $set.Length] })
}

<#
 Alle Einstellungen liegen zentral in $script:Cfg. Die Installationsroutinen
 lesen ausschließlich von hier; die Oberfläche (einfache Seite und Dialog
 "Erweiterte Optionen") schreibt hinein. So bleibt die Engine unabhängig von
 Steuerelementen und die einfache Oberfläche kann klein bleiben.
#>
function New-DefaultConfig {
    $ramMb = Get-TotalRamMb
    $ext = @{}
    foreach ($e in $script:KnownExtensions) { $ext[$e] = ($script:CommonExtensions -contains $e) }

    @{
        # --- Hauptauswahl (einfache Seite) ---
        InstallWebStack = $true
        InstallMySql    = $true
        InstallWorkbench= $true
        InstallPython   = $false      # optional, standardmäßig aus
        AppDbEnabled    = $false
        AppDbName       = ''
        AppDbUser       = ''
        AppDbPass       = (New-MySqlPassword 16)

        # --- Erweitert: Installation ---
        InstallIis      = $true
        InstallVcRedist = $true
        InstallPhp      = $true
        AddPath         = $true
        InstallRewrite  = $true
        RewriteLang     = 'Deutsch'
        PhpUrl          = ''          # wird aus der Versionsliste gesetzt
        PyUrl           = ''          # leer = neueste Version von python.org ermitteln

        # --- Erweitert: php.ini ---
        MaxExec         = 60
        MemLimit        = '512M'      # pro Request, nicht insgesamt - siehe Hinweis im Dialog
        PostMax         = '32M'
        UploadMax       = '16M'
        MaxFiles        = 20
        SessionDir      = $script:SessionDir
        UploadDir       = $script:UploadDir
        Timezone        = 'Europe/Berlin'
        Curl            = $true
        IisTuning       = $true
        ContentLength   = $true
        Opcache         = $true
        Extensions      = $ext        # Name -> $true/$false

        # --- Erweitert: MySQL ---
        MyUrl           = $script:MySqlUrlDefault
        WbUrl           = $script:WbUrlDefault
        MyInstallDir    = (Join-Path $env:ProgramFiles 'MySQL\MySQL Server 8.4')
        MyDataDir       = (Join-Path $env:ProgramData 'MySQL\MySQL Server 8.4\Data')
        MyService       = 'MySQL84'
        MyPort          = 3306
        MyBufferPool    = (Get-InnoDbPoolSizeMb -RamMb $ramMb)
        MyRootPw        = (New-MySqlPassword 20)
        MyNetMode       = 'local'     # local | lan | any
        MyUsers         = @()         # @{ User; Pass; Host; Db }
    }
}

$script:Cfg          = New-DefaultConfig
$script:Busy         = $false
$script:PhpReleases  = @()     # @{ Display; Url; Version; Branch; IsLatest }
$script:Preflight    = $null
$script:RebootNeeded = $false
$script:AppIcon      = $null   # Symbol für Fenster und Dialoge
$script:LblToolsStatus = $null   # Statuszeile des Werkzeuge-Dialogs, nur während dieser offen ist
$script:Result       = @{}

# ==============================================================================
#  2) Hilfsfunktionen (Protokoll, Status, Hintergrundarbeit, Prozesse, Downloads)
# ==============================================================================

# Oberfläche weiterlaufen lassen, während im Vordergrund gewartet wird.
function Invoke-UiPump { [System.Windows.Forms.Application]::DoEvents() }

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info'
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line  = '[{0}] {1}' -f $stamp, $Message

    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        Add-Content -LiteralPath $script:LogFile -Value ('{0} {1}' -f $Level.PadRight(5), $line) -Encoding UTF8
    } catch { }

    if ($script:LogBox) {
        $color = switch ($Level) {
            'Ok'    { [System.Drawing.Color]::FromArgb(126, 211, 133) }
            'Warn'  { [System.Drawing.Color]::FromArgb(240, 180,  90) }
            'Error' { [System.Drawing.Color]::FromArgb(240, 120, 110) }
            'Step'  { [System.Drawing.Color]::FromArgb(120, 190, 240) }
            default { [System.Drawing.Color]::FromArgb(210, 210, 210) }
        }
        $prefix = switch ($Level) {
            'Ok'    { '  OK   ' }
            'Warn'  { '  !    ' }
            'Error' { '  X    ' }
            'Step'  { '  >    ' }
            default { '       ' }
        }
        $script:LogBox.SelectionStart  = $script:LogBox.TextLength
        $script:LogBox.SelectionLength = 0
        $script:LogBox.SelectionColor  = $color
        $script:LogBox.AppendText(($prefix + $line + [Environment]::NewLine))
        $script:LogBox.ScrollToCaret()
    }
    # Werkzeuge-Dialog: letzte Meldung anzeigen
    if ($script:LblToolsStatus -and $Message) {
        try { $script:LblToolsStatus.Text = $Message } catch { }
    }
    Invoke-UiPump
}

function Set-Status {
    param([string]$Text)
    if ($script:StatusLabel) { $script:StatusLabel.Text = $Text }
    if ($script:LblCurrent -and $script:Busy) { $script:LblCurrent.Text = $Text }
    Invoke-UiPump
}

# Fortschrittsbalken des aktuellen Schritts: -1 = Laufbalken (unbestimmt), 0..100 = bestimmt
function Set-Progress {
    param([int]$Percent = -1)
    if (-not $script:Progress) { return }
    if ($Percent -lt 0) {
        if ($script:Progress.Style -ne 'Marquee') { $script:Progress.Style = 'Marquee' }
    } else {
        if ($script:Progress.Style -ne 'Continuous') { $script:Progress.Style = 'Continuous' }
        $script:Progress.Value = [math]::Min(100, [math]::Max(0, $Percent))
    }
    Invoke-UiPump
}

function Set-Busy {
    param([bool]$On)
    $script:Busy = $On
    foreach ($b in @($script:BtnBack, $script:BtnNext, $script:BtnAdvanced, $script:BtnTools, $script:BtnAbout, $script:BtnRecheck)) {
        if ($b) { $b.Enabled = -not $On }
    }
    if ($script:Form) {
        $script:Form.Cursor = if ($On) { [System.Windows.Forms.Cursors]::AppStarting }
                              else      { [System.Windows.Forms.Cursors]::Default }
    }
    if (-not $On) { Set-Progress -1 }
    Invoke-UiPump
}

function Get-PhpCgiPath { Join-Path $script:PhpRoot 'php-cgi.exe' }
function Get-PhpExePath { Join-Path $script:PhpRoot 'php.exe' }
function Get-PhpIniPath { Join-Path $script:PhpRoot 'php.ini' }

function Stop-PhpProcesses {
    $procs = Get-Process -Name 'php-cgi', 'php' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Beende $($procs.Count) laufende PHP-Prozesse ..." 'Info'
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
        Write-Log 'PHP-Prozesse beendet.' 'Ok'
    } else {
        Write-Log 'Keine laufenden PHP-Prozesse gefunden.' 'Info'
    }
}

<#
 Führt eine lange Operation in einem eigenen Runspace aus und hält dabei die
 Oberfläche bedienbar. Bewusst Runspace statt Start-Job: das läuft im selben
 Prozess, braucht keinen zweiten PowerShell-Host und funktioniert deshalb auch
 in einer mit PS2EXE erzeugten Exe zuverlässig.
 Der Skriptblock erhält die Argumente als positionsgebundene param()-Werte und
 darf keine Funktionen dieses Skripts und keine Oberfläche verwenden.
#>
function Invoke-LongRunning {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [string]$Activity = 'Vorgang',
        [scriptblock]$OnTick = $null        # optional: wird alle 250 ms im UI-Thread aufgerufen
    )
    Write-Log "$Activity ..." 'Info'
    $ps = [powershell]::Create()
    $rs = [runspacefactory]::CreateRunspace()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $rs.Open()
        $ps.Runspace = $rs
        [void]$ps.AddScript($ScriptBlock.ToString())
        foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()

        $next = 20
        while (-not $handle.IsCompleted) {
            Start-Sleep -Milliseconds 250
            if ($OnTick) { & $OnTick } else { Set-Status ('{0} ... {1:mm\:ss}' -f $Activity, $sw.Elapsed) }
            Invoke-UiPump
            if ($sw.Elapsed.TotalSeconds -ge $next) {
                $next += 20
                Write-Log ('... läuft seit {0:mm\:ss}' -f $sw.Elapsed)
            }
        }
        try {
            $out = $ps.EndInvoke($handle)
        } catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            throw "$Activity fehlgeschlagen: $($inner.Message)"
        }
        if ($ps.Streams.Error.Count -gt 0) {
            # Nicht abbrechende Fehler im Hintergrund: nur protokollieren
            foreach ($e in $ps.Streams.Error) { Write-Log "Hinweis aus dem Hintergrund: $($e.Exception.Message)" 'Warn' }
        }
        Write-Log ('{0} - fertig nach {1:mm\:ss}' -f $Activity, $sw.Elapsed) 'Ok'
        return $out
    } finally {
        $sw.Stop()
        try { $ps.Dispose() } catch { }
        try { $rs.Dispose() } catch { }
    }
}

# Wie Start-Process -Wait, blockiert aber die Oberfläche nicht.
# Bewusst über System.Diagnostics.Process statt Start-Process -PassThru:
# Letzteres liefert ohne -Wait keinen verlässlichen ExitCode.
# Hinweis: Argumente müssen von der aufrufenden Stelle bereits korrekt
# gequotet sein, sie werden nur mit Leerzeichen verbunden.
function Start-ProcessWithUi {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Activity = 'Vorgang',
        [switch]$NoNewWindow
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = [bool]$NoNewWindow
    if ($ArgumentList.Count -gt 0) { $psi.Arguments = ($ArgumentList -join ' ') }

    Write-Log "$Activity ..." 'Info'
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $sw   = [System.Diagnostics.Stopwatch]::StartNew()
        $next = 20
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 250
            Invoke-UiPump
            Set-Status ('{0} ... {1:mm\:ss}' -f $Activity, $sw.Elapsed)
            if ($sw.Elapsed.TotalSeconds -ge $next) {
                $next += 20
                Write-Log ('... läuft seit {0:mm\:ss}' -f $sw.Elapsed)
            }
        }
        $proc.WaitForExit()
        $sw.Stop()
        $code = [int]$proc.ExitCode
        Write-Log ('{0} - beendet nach {1:mm\:ss}, Exitcode {2}' -f $Activity, $sw.Elapsed, $code)
        return $code
    } finally {
        $proc.Dispose()
    }
}

<#
 Startet ein Konsolenprogramm ohne sichtbares Fenster und liefert Ausgabe und
 Exitcode zurück. Ersetzt "& exe args 2>&1": in einer -noConsole-Exe würde
 sonst bei jedem Aufruf kurz ein schwarzes Fenster aufblitzen.
 -StdIn wird dem Programm über die Standardeingabe übergeben (mysql.exe).
#>
function Invoke-ExeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$StdIn = $null,
        [int]$TimeoutSec = 600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = ($null -ne $StdIn)
    if ($ArgumentList.Count -gt 0) { $psi.Arguments = ($ArgumentList -join ' ') }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        # Ausgaben asynchron lesen, sonst kann es zu einer gegenseitigen Blockade kommen
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        if ($null -ne $StdIn) {
            $proc.StandardInput.Write($StdIn)
            $proc.StandardInput.Close()
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 100
            Invoke-UiPump
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                try { $proc.Kill() } catch { }
                throw "$([System.IO.Path]::GetFileName($FilePath)) antwortet nicht (Zeitüberschreitung nach $TimeoutSec s)."
            }
        }
        $proc.WaitForExit()
        $out = [string]$outTask.Result
        $err = [string]$errTask.Result
        [pscustomobject]@{
            ExitCode = [int]$proc.ExitCode
            Output   = $out
            Error    = $err
            Lines    = @((($out + "`n" + $err) -split "`r?`n") | Where-Object { $_ -ne '' })
        }
    } finally {
        $proc.Dispose()
    }
}

# Download im Hintergrund mit echter Fortschrittsanzeige.
function Get-FileWithUi {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Activity = 'Download',
        [int]$TimeoutSec = 1800
    )
    $sync = [hashtable]::Synchronized(@{ Done = [long]0; Total = [long]-1 })
    # Wird von Invoke-LongRunning im UI-Thread aufgerufen; $sync und $Activity
    # sind über den Aufrufkontext sichtbar.
    $tick = {
        $done  = [long]$sync.Done
        $total = [long]$sync.Total
        if ($total -gt 0) {
            $pct = [int](($done * 100) / $total)
            Set-Progress $pct
            Set-Status ('{0} ... {1:N1} / {2:N1} MB ({3} %)' -f $Activity, ($done / 1MB), ($total / 1MB), $pct)
        } else {
            Set-Status ('{0} ... {1:N1} MB' -f $Activity, ($done / 1MB))
        }
    }

    try {
        Invoke-LongRunning -Activity $Activity -OnTick $tick -ArgumentList @($Url, $OutFile, $sync) -ScriptBlock {
            param($u, $o, $s)
            $ErrorActionPreference = 'Stop'
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.UserAgent         = 'PHP-IIS-Setup/2.0 (Windows)'
            $req.AllowAutoRedirect = $true
            $req.Timeout           = 60000
            $req.ReadWriteTimeout  = 60000
            $resp = $req.GetResponse()
            try {
                $s.Total = [long]$resp.ContentLength
                $in  = $resp.GetResponseStream()
                $out = [System.IO.File]::Create($o)
                try {
                    $buf = New-Object byte[] 262144
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $out.Write($buf, 0, $n)
                        $s.Done = [long]$s.Done + $n
                    }
                } finally {
                    $out.Close(); $in.Close()
                }
            } finally {
                $resp.Close()
            }
        } | Out-Null
    } finally {
        Set-Progress -1
    }
    if (-not (Test-Path $OutFile)) { throw "$Activity : Datei wurde nicht geschrieben." }
    Write-Log ('Größe: {0:N1} MB' -f ((Get-Item $OutFile).Length / 1MB))
}

# ==============================================================================
#  3) Systemprüfung
# ==============================================================================

<#
 Ermittelt, ob ein Neustart aussteht.
 Bewusst zweistufig: die CBS- und Windows-Update-Marker blockieren wirklich,
 PendingFileRenameOperations dagegen ist auf laufenden Systemen fast immer
 gefüllt und taugt allein nicht als Grund für eine Warnung.
#>
function Get-PendingRebootInfo {
    $hard = @()

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $hard += 'Komponenteninstallation (CBS RebootPending)'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress') {
        $hard += 'Komponenteninstallation noch nicht abgeschlossen (CBS RebootInProgress)'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $hard += 'Windows Update'
    }

    # Rechnerumbenennung, die erst nach dem Neustart wirksam wird
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $target = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'       -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $target -and $active -ne $target) { $hard += "Umbenennung des Rechners ($active -> $target)" }

    $raw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    $sources = @($raw | Where-Object { $_ -match '^\\\?\?\\' })

    [pscustomobject]@{
        Hard        = $hard
        FileRenames = $sources
    }
}

function Test-MySqlServiceExists {
    [bool](Get-Service -Name ([string]$script:Cfg.MyService) -ErrorAction SilentlyContinue)
}

<#
 Systemprüfung. Liefert eine Liste von Prüfpunkten (Level Ok/Warn/Error/Info,
 Name, Text) für die Anzeige auf der Startseite und schreibt alles ins Protokoll.
#>
function Invoke-Preflight {
    Write-Log 'Systemprüfung' 'Step'
    $items = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Level, $Name, $Text)
        $items.Add([pscustomobject]@{ Level = $Level; Name = $Name; Text = $Text })
        Write-Log ("{0,-16}: {1}" -f $Name, $Text) $Level
    }
    $ok = $true

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 20348) {
        & $add 'Warn' 'Betriebssystem' ("{0} (Build {1}) - erwartet wird Windows Server 2022 oder neuer" -f $os.Caption, $build)
    } elseif ($os.ProductType -eq 1) {
        & $add 'Warn' 'Betriebssystem' ("{0} - das ist eine Client-Version, kein Server (funktioniert meist trotzdem)" -f $os.Caption)
    } else {
        & $add 'Ok' 'Betriebssystem' ("{0} (Build {1})" -f $os.Caption, $build)
    }

    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        & $add 'Error' 'Architektur' ("{0} - es werden ausschließlich x64-Builds installiert" -f $env:PROCESSOR_ARCHITECTURE)
        $ok = $false
    } else {
        & $add 'Ok' 'Architektur' 'x64'
    }

    $ram = Get-TotalRamMb
    if ($ram -lt 2048) { & $add 'Warn' 'Arbeitsspeicher' "$ram MB - recht wenig für IIS + PHP + MySQL" }
    else               { & $add 'Ok'   'Arbeitsspeicher' "$ram MB" }

    $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGb -lt 2) { & $add 'Warn' 'Freier Platz' "$freeGb GB auf $env:SystemDrive - das kann knapp werden" }
    else               { & $add 'Ok'   'Freier Platz' "$freeGb GB auf $env:SystemDrive" }

    try {
        $null = Invoke-WebRequest -Uri 'https://windows.php.net/' -UseBasicParsing -TimeoutSec 15 -Method Head
        & $add 'Ok' 'Internet' 'windows.php.net ist erreichbar'
    } catch {
        & $add 'Error' 'Internet' "windows.php.net nicht erreichbar ($($_.Exception.Message)). Ohne Internet können keine Pakete geladen werden."
        $ok = $false
    }

    $reboot = Get-PendingRebootInfo
    if ($reboot.Hard.Count -gt 0) {
        & $add 'Warn' 'Neustart' ("Ausstehend: {0}. Bitte zuerst neu starten, sonst kann die IIS-Installation hängen bleiben." -f ($reboot.Hard -join ', '))
    } else {
        & $add 'Ok' 'Neustart' 'Kein blockierender Neustart ausstehend'
    }
    if ($reboot.FileRenames.Count -gt 0) {
        Write-Log ("Nebenbei: {0} vorgemerkte Dateiumbenennungen - im laufenden Betrieb normal, kein Neustartgrund." -f $reboot.FileRenames.Count)
    }

    $existing = @()
    if (Test-Path (Get-PhpExePath)) { $existing += "PHP unter $script:PhpRoot" }
    if (Test-Path $script:AppCmd)   { $existing += 'IIS' }
    if (Test-MySqlServiceExists)    { $existing += "MySQL-Dienst '$($script:Cfg.MyService)'" }
    $pyHave = Get-PythonInstallInfo
    if ($pyHave) { $existing += "Python $($pyHave.Version)" }
    if ($existing.Count -gt 0) {
        & $add 'Info' 'Vorhanden' ("{0} - wird erkannt und aktualisiert, nicht doppelt installiert" -f ($existing -join ', '))
    } else {
        & $add 'Ok' 'Vorhanden' 'Keine frühere Installation gefunden'
    }

    if ($ok) { Write-Log 'Systemprüfung abgeschlossen - bereit.' 'Ok' }
    else     { Write-Log 'Systemprüfung mit Fehlern beendet.' 'Error' }

    [pscustomobject]@{ Ok = $ok; Items = $items.ToArray(); Reboot = $reboot }
}

# ==============================================================================
#  4) PHP-Versionsliste
# ==============================================================================

# Läuft im Hintergrund (Invoke-LongRunning) und darf deshalb keine UI-Funktionen
# aufrufen. Liefert Hashtables, sortiert neueste zuerst.
function Get-PhpReleaseList {
    $res = Invoke-LongRunning -Activity 'PHP-Versionsliste wird geladen' -ArgumentList @($script:ReleaseIndex, $script:ArchiveIndex) -ScriptBlock {
        param($releaseIdx, $archiveIdx)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference    = 'SilentlyContinue'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $list = New-Object System.Collections.Generic.List[object]
        $warn = @()

        # feste "immer aktuell"-Einträge - brechen nicht, wenn eine Version abgelöst wird
        foreach ($branch in @('8.5', '8.4')) {
            $file = "php-$branch-nts-Win32-vs17-x64-latest.zip"
            $list.Add(@{
                Sort     = [version]"$branch.9999"
                Version  = $null
                Branch   = $branch
                IsLatest = $true
                Display  = "PHP $branch - immer der aktuellste Build"
                Url      = 'https://windows.php.net/downloads/releases/latest/' + $file
            })
        }
        foreach ($idx in @($releaseIdx, $archiveIdx)) {
            try {
                $html = (Invoke-WebRequest -Uri $idx -UseBasicParsing -TimeoutSec 30).Content
            } catch {
                $warn += "Verzeichnis nicht erreichbar: $idx"
                continue
            }
            $seen = @{}
            foreach ($m in [regex]::Matches($html, 'php-(\d+\.\d+\.\d+)-nts-Win32-vs(\d+)-x64\.zip')) {
                if ($seen.ContainsKey($m.Value)) { continue }
                $seen[$m.Value] = $true
                $ver = [version]$m.Groups[1].Value
                if ($ver -lt [version]'8.2.0') { continue }   # ältere Zweige sind EOL
                $list.Add(@{
                    Sort     = $ver
                    Version  = $ver
                    Branch   = ('{0}.{1}' -f $ver.Major, $ver.Minor)
                    IsLatest = $false
                    Display  = ('PHP {0}  (vs{1}, x64, NTS)' -f $ver, $m.Groups[2].Value)
                    Url      = $idx + $m.Value
                })
            }
        }
        $sorted = @($list | Sort-Object -Property { $_.Sort } -Descending)
        # Duplikate (gleiche Datei in releases/ und archives/) entfernen, erste gewinnt
        $out = New-Object System.Collections.Generic.List[object]
        $known = @{}
        foreach ($e in $sorted) {
            $leaf = Split-Path $e.Url -Leaf
            if ($known.ContainsKey($leaf)) { continue }
            $known[$leaf] = $true
            $out.Add($e)
        }
        @{ List = $out.ToArray(); Warnings = $warn }
    }
    foreach ($w in @($res.Warnings)) { Write-Log $w 'Warn' }
    return @($res.List)
}

# Empfehlung für die einfache Seite: neueste konkrete Version (kein "latest"-Platzhalter)
function Get-RecommendedPhpRelease {
    foreach ($r in $script:PhpReleases) { if (-not $r.IsLatest) { return $r } }
    if ($script:PhpReleases.Count -gt 0) { return $script:PhpReleases[0] }
    return $null
}

# ==============================================================================
#  5) Installationsschritte
# ==============================================================================

# Schnelltest über die Registrierung, um den Download zu sparen.
function Test-VcRedistInstalled {
    try {
        $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction Stop
        if ([int]$p.Installed -eq 1) {
            $v = [version](([string]$p.Version).TrimStart('v', 'V'))
            if ($v -ge [version]'14.30') { return $v }
        }
    } catch { }
    return $null
}

function Install-VcRedist {
    Write-Log 'Visual C++ Redistributable 2015-2022 (x64)' 'Step'
    $have = Test-VcRedistInstalled
    if ($have) {
        Write-Log "Bereits installiert (Version $have) - übersprungen." 'Ok'
        return
    }
    $exe = Join-Path $env:TEMP 'vc_redist.x64.exe'
    Get-FileWithUi -Url $script:VcRedistUrl -OutFile $exe -Activity 'Visual C++ Redistributable wird geladen' -TimeoutSec 300

    $code = Start-ProcessWithUi -FilePath $exe -ArgumentList @('/install', '/quiet', '/norestart') `
                                -Activity 'Visual C++ Redistributable wird installiert'
    switch ($code) {
        0     { Write-Log 'Visual C++ Redistributable installiert.' 'Ok' }
        1638  { Write-Log 'Eine neuere Version ist bereits installiert - übersprungen.' 'Ok' }
        3010  { Write-Log 'Installiert. Windows meldet: Neustart erforderlich (später nachholen).' 'Warn'; $script:RebootNeeded = $true }
        default {
            throw "vc_redist.x64.exe wurde mit Exitcode $code beendet. Details in %TEMP%\dd_vcredist*.log"
        }
    }
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Install-IisFeatures {
    Write-Log 'IIS-Rollen und Features' 'Step'
    Write-Log 'Installation über DISM (Get-/Enable-WindowsOptionalFeature). Das ServerManager-Modul' 'Info'
    Write-Log 'wird bewusst nicht verwendet - es bleibt auf manchen Servern beim Laden des IIS-Plug-Ins hängen.' 'Info'

    $states = Invoke-LongRunning -Activity 'Featurestatus wird gelesen' -ArgumentList @(, $script:IisFeatures) -ScriptBlock {
        param($features)
        $out = @()
        foreach ($f in $features) {
            try {
                $s = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
                $out += [pscustomobject]@{ Name = $f; State = [string]$s.State }
            } catch {
                $out += [pscustomobject]@{ Name = $f; State = 'Unbekannt' }
            }
        }
        $out
    }

    $todo = @()
    foreach ($st in @($states)) {
        switch ($st.State) {
            'Enabled'   { Write-Log "bereits aktiviert: $($st.Name)" }
            'Unbekannt' { Write-Log "Feature '$($st.Name)' ist auf diesem System unbekannt - übersprungen." 'Warn' }
            default     { $todo += $st.Name }
        }
    }

    if ($todo.Count -eq 0) {
        Write-Log 'Alle benötigten IIS-Features sind bereits aktiviert.' 'Ok'
    } else {
        Write-Log ("Aktiviere: {0}" -f ($todo -join ', '))
        Write-Log 'Auf einem frischen Server dauert das erfahrungsgemäß 1 bis 5 Minuten.' 'Info'
        # -All zieht übergeordnete Features automatisch mit hoch.
        $res = Invoke-LongRunning -Activity 'IIS-Features werden aktiviert' -ArgumentList @(, $todo) -ScriptBlock {
            param($features)
            $ErrorActionPreference = 'Stop'
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $features -All -NoRestart -WarningAction SilentlyContinue
            [string]$r.RestartNeeded
        }
        Write-Log 'IIS-Features aktiviert.' 'Ok'
        if ("$res" -match 'True|Yes') {
            Write-Log 'Windows meldet: Neustart erforderlich. Bitte nach Abschluss nachholen.' 'Warn'
            $script:RebootNeeded = $true
        }
    }

    # Kontrolle, dass die drei entscheidenden Bausteine wirklich da sind
    $must = @{
        'IIS-WebServer'                = 'Webserver'
        'IIS-CGI'                      = 'CGI (für PHP FastCGI)'
        'IIS-ManagementScriptingTools' = 'Verwaltungsskripts (Modul WebAdministration)'
    }
    foreach ($k in $must.Keys) {
        $st = (@($states) | Where-Object Name -eq $k).State
        if ($st -ne 'Enabled' -and $todo -notcontains $k) {
            Write-Log "Pflichtbaustein fehlt: $k ($($must[$k]))" 'Error'
        }
    }

    # WebAdministration steht direkt nach der Aktivierung manchmal erst mit
    # kurzer Verzögerung bereit - deshalb mit Wiederholung.
    for ($i = 1; $i -le 3; $i++) {
        try {
            Import-Module WebAdministration -ErrorAction Stop
            Write-Log 'PowerShell-Modul WebAdministration geladen.' 'Ok'
            return
        } catch {
            if ($i -eq 3) {
                Write-Log 'WebAdministration lässt sich nicht laden. IIS-Konfiguration läuft über appcmd.exe.' 'Warn'
            } else {
                Start-Sleep -Seconds 3
            }
        }
    }
}

# Nachweis für ein installiertes URL Rewrite Module: das Kernmodul rewrite.dll
# liegt immer im inetsrv-Ordner, unabhängig von der Paketsprache.
function Test-UrlRewriteInstalled {
    if (Test-Path -LiteralPath (Join-Path $env:windir 'system32\inetsrv\rewrite.dll')) { return $true }
    $ah = Join-Path $env:windir 'system32\inetsrv\config\applicationHost.config'
    if (Test-Path -LiteralPath $ah) {
        return ((Get-Content -LiteralPath $ah -Raw -ErrorAction SilentlyContinue) -match 'RewriteModule')
    }
    return $false
}

function Install-UrlRewrite {
    Write-Log 'IIS URL Rewrite Module 2.1' 'Step'

    if (Test-UrlRewriteInstalled) {
        Write-Log 'URL Rewrite ist bereits vorhanden - übersprungen.' 'Ok'
        return
    }
    if (-not (Test-Path $script:AppCmd)) {
        throw 'URL Rewrite setzt ein installiertes IIS voraus. Bitte unter "Erweiterte Optionen" die IIS-Installation aktiviert lassen.'
    }
    # Die MSI prüft, ob die IIS-Dienste laufen
    $w3 = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    if ($w3 -and $w3.Status -ne 'Running') {
        Write-Log 'Starte W3SVC, die Installation verlangt laufende IIS-Dienste.' 'Info'
        Start-Service -Name W3SVC -ErrorAction SilentlyContinue
    }

    $lang = $script:Cfg.RewriteLang
    if (-not $script:RewriteUrls.Contains($lang)) { $lang = 'Deutsch' }
    $url = $script:RewriteUrls[$lang]

    $msi = Join-Path $env:TEMP (Split-Path $url -Leaf)
    Write-Log "Paketsprache: $lang"
    Get-FileWithUi -Url $url -OutFile $msi -Activity 'URL Rewrite wird geladen' -TimeoutSec 600

    $log  = Join-Path $script:LogDir 'urlrewrite-msi.log'
    $code = Start-ProcessWithUi -FilePath 'msiexec.exe' -Activity 'URL Rewrite wird installiert' -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart', '/lv', "`"$log`""
    )
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    # Auch hier gilt: das Ergebnis zählt, nicht der Rückgabewert.
    if (Test-UrlRewriteInstalled) {
        if ($code -eq 3010) { Write-Log 'Installiert. Windows meldet: Neustart erforderlich.' 'Warn'; $script:RebootNeeded = $true }
        elseif ($code -ne 0) { Write-Log "msiexec meldete Exitcode $code, das Modul ist aber vorhanden." 'Warn' }
        Write-Log 'URL Rewrite Module 2.1 installiert.' 'Ok'
        Write-Log 'Regeln liegen anschließend in der web.config unter system.webServer/rewrite.' 'Info'
        return
    }
    if ($code -eq 1603) {
        throw ("URL Rewrite: msiexec Exitcode 1603. Häufigste Ursache ist eine nicht erfüllte " +
               "Startbedingung des Pakets - es verlangt die IIS-Bausteine CoreWebEngine und W3SVC. " +
               "Details: $log")
    }
    throw "URL Rewrite konnte nicht installiert werden (Exitcode $code). Details: $log"
}

function Install-Php {
    param([Parameter(Mandatory)][string]$Url)

    Write-Log 'PHP herunterladen und entpacken' 'Step'
    $zip = Join-Path $env:TEMP (Split-Path $Url -Leaf)
    Write-Log "Quelle: $Url"
    Get-FileWithUi -Url $Url -OutFile $zip -Activity 'PHP wird geladen' -TimeoutSec 900

    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Write-Log "SHA256: $hash"
    Write-Log 'Prüfsumme bei Bedarf mit der Angabe auf windows.php.net/download vergleichen.' 'Info'

    Stop-PhpProcesses

    if (-not (Test-Path $script:PhpRoot)) {
        New-Item -ItemType Directory -Path $script:PhpRoot -Force | Out-Null
    }

    # bestehende php.ini retten - Expand-Archive überschreibt sie zwar nicht,
    # aber sicher ist sicher
    $ini = Get-PhpIniPath
    if (Test-Path $ini) {
        $iniBackup = "$ini.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        Copy-Item -LiteralPath $ini -Destination $iniBackup -Force
        Write-Log "Bestehende php.ini gesichert nach $(Split-Path $iniBackup -Leaf)" 'Info'
    }

    Write-Log "Entpacke nach $script:PhpRoot ..."
    Set-Status 'PHP wird entpackt ...'
    Invoke-LongRunning -Activity 'PHP wird entpackt' -ArgumentList @($zip, $script:PhpRoot) -ScriptBlock {
        param($z, $dest)
        $ErrorActionPreference = 'Stop'
        Expand-Archive -LiteralPath $z -DestinationPath $dest -Force
    } | Out-Null
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path (Get-PhpCgiPath))) {
        throw "php-cgi.exe wurde nach dem Entpacken nicht gefunden. Falsches Archiv (TS statt NTS)?"
    }
    Write-Log 'PHP entpackt.' 'Ok'
}

<#
 Trägt Ordner in den maschinenweiten PATH ein (falls noch nicht vorhanden),
 zieht die aktuelle Sitzung nach und informiert laufende Programme.
 Wichtig: der PATH wird unaufgelöst gelesen (DoNotExpandEnvironmentNames),
 sonst würden %SystemRoot%-Einträge anderer Programme in feste Pfade
 umgeschrieben.
#>
function Add-ToMachinePath {
    param([Parameter(Mandatory)][string[]]$Dirs)
    $key  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $item = Get-Item -LiteralPath $key
    $raw  = $item.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

    $parts   = @($raw -split ';' | Where-Object { $_ -ne '' })
    $changed = $false
    foreach ($d in $Dirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $dTrim = $d.TrimEnd('\')
        if (@($parts | ForEach-Object { $_.TrimEnd('\') }) -contains $dTrim) {
            Write-Log "$d steht bereits im PATH." 'Ok'
        } else {
            $parts  += $d
            $changed = $true
            Write-Log "$d zum maschinenweiten PATH hinzugefügt." 'Ok'
        }
        # aktuelle Sitzung sofort nachziehen
        if ((@($env:Path -split ';') | ForEach-Object { $_.TrimEnd('\') }) -notcontains $dTrim) {
            $env:Path = $env:Path.TrimEnd(';') + ';' + $d
        }
    }
    if ($changed) {
        Set-ItemProperty -LiteralPath $key -Name 'Path' -Value ($parts -join ';') -Type ExpandString
    }

    # laufende Programme über die Änderung informieren
    try {
        if (-not ('Win32.EnvBroadcast' -as [type])) {
            Add-Type -Namespace 'Win32' -Name 'EnvBroadcast' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        [UIntPtr]$r = [UIntPtr]::Zero
        [void][Win32.EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
    } catch { }
}

function Add-PhpToMachinePath {
    Write-Log 'PATH-Umgebungsvariable' 'Step'
    Add-ToMachinePath -Dirs @($script:PhpRoot)
}

# ==============================================================================
#  6) php.ini
# ==============================================================================

function Initialize-PhpIni {
    $ini = Get-PhpIniPath
    if (Test-Path $ini) {
        Write-Log 'php.ini ist bereits vorhanden - wird weiterverwendet.' 'Info'
        return
    }
    $prod = Join-Path $script:PhpRoot 'php.ini-production'
    if (-not (Test-Path $prod)) { throw "php.ini-production nicht gefunden in $script:PhpRoot" }

    # kopieren statt umbenennen: die Vorlage bleibt als Referenz erhalten
    Copy-Item -LiteralPath $prod -Destination $ini -Force
    Write-Log 'php.ini aus php.ini-production erzeugt.' 'Ok'
}

<#
 Setzt eine Direktive in der php.ini.
 - Ist sie aktiv vorhanden -> Wert ersetzen
 - Ist sie nur auskommentiert -> Kommentarzeichen entfernen und Wert setzen
 - Gar nicht vorhanden -> am Dateiende ergänzen
 Weitere aktive Duplikate werden auskommentiert, damit nicht der letzte
 Treffer in der Datei den Wert wieder überschreibt.
 -PreferLast ist für extension_dir gedacht: dort stehen mehrere
 auskommentierte Beispiele, das Windows-Beispiel ist das letzte.
#>
function Set-IniDirective {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$PreferLast
    )
    $esc       = [regex]::Escape($Key)
    $activeRx  = "^\s*$esc\s*="
    $commentRx = "^\s*;\s*$esc\s*="
    $newLine   = "$Key = $Value"

    $activeIdx  = @()
    $commentIdx = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if     ($Lines[$i] -match $activeRx)  { $activeIdx  += $i }
        elseif ($Lines[$i] -match $commentRx) { $commentIdx += $i }
    }

    if ($activeIdx.Count -gt 0) {
        $target = if ($PreferLast) { $activeIdx[-1] } else { $activeIdx[0] }
        $Lines[$target] = $newLine
        foreach ($j in $activeIdx) {
            if ($j -ne $target) { $Lines[$j] = ';' + $Lines[$j] }
        }
        return
    }
    if ($commentIdx.Count -gt 0) {
        $target = if ($PreferLast) { $commentIdx[-1] } else { $commentIdx[0] }
        $Lines[$target] = $newLine
        return
    }
    $Lines.Add('')
    $Lines.Add('; --- vom PHP-IIS-Setup ergänzt ---')
    $Lines.Add($newLine)
}

<#
 Kommentiert alle aktiven Zeilen aus, die auf das Muster passen.
 Gegenstück zu Set-IniDirective, wenn eine Direktive nicht gesetzt, sondern
 entfernt werden soll (z. B. eine zend_extension-Zeile, die es nicht mehr gibt).
 Liefert die Anzahl der geänderten Zeilen.
#>
function Disable-IniDirective {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][string]$Pattern
    )
    $n = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\s*;' -and $Lines[$i] -match $Pattern) {
            $Lines[$i] = '; ' + $Lines[$i] + '   ; vom PHP-IIS-Setup deaktiviert'
            $n++
        }
    }
    return $n
}

<#
 Liest alle extension= / zend_extension= Zeilen aus der php.ini.
 Dokumentationsbeispiele (";   extension=modulename") werden ausgefiltert,
 indem geprüft wird, ob die passende DLL in ext\ wirklich existiert.
#>
function Get-PhpExtensionList {
    param([string[]]$Lines)

    $extDir = Join-Path $script:PhpRoot 'ext'
    $items  = New-Object System.Collections.Generic.List[object]
    $rx     = '^(?<cmt>\s*;\s*)?(?<type>zend_extension|extension)\s*=\s*(?<val>[^\s;]+)'

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $m = [regex]::Match($Lines[$i], $rx)
        if (-not $m.Success) { continue }

        $raw  = $m.Groups['val'].Value.Trim('"', "'")
        $name = $raw -replace '^php_', '' -replace '\.dll$', ''

        if ($raw -match '[\\/]') { continue }   # Pfadbeispiel aus der Doku

        $dll = $null
        foreach ($cand in @("php_$name.dll", "$name.dll")) {
            $p = Join-Path $extDir $cand
            if (Test-Path -LiteralPath $p) { $dll = $p; break }
        }
        if (-not $dll) { continue }   # kein passendes Modul vorhanden

        # Echte Einträge stehen ohne Leerzeichen hinter dem Semikolon
        # (";extension=curl"), Doku-Beispiele mit (";   extension=mysqli").
        $score = if (-not $m.Groups['cmt'].Success) { 2 }
                 elseif ($m.Groups['cmt'].Value -eq ';') { 1 }
                 else { 0 }

        $items.Add([pscustomobject]@{
            LineIndex = $i
            Type      = $m.Groups['type'].Value
            Raw       = $raw
            Name      = $name
            Enabled   = -not $m.Groups['cmt'].Success
            Score     = $score
        })
    }

    # Pro Extension bleibt genau ein Eintrag übrig: der aktive, sonst der
    # echte Konfigurationseintrag, sonst der zuletzt gefundene.
    $best = @{}
    foreach ($e in $items) {
        if (-not $best.ContainsKey($e.Name) -or $e.Score -ge $best[$e.Name].Score) { $best[$e.Name] = $e }
    }
    , @($best.Values | Sort-Object Name)
}

function Set-PhpExtensionState {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory)][hashtable]$Wanted   # Name -> $true/$false
    )
    $current = Get-PhpExtensionList -Lines $Lines
    $changed = 0
    foreach ($ext in $current) {
        if (-not $Wanted.ContainsKey($ext.Name)) { continue }
        $should = [bool]$Wanted[$ext.Name]
        if ($should -eq $ext.Enabled) { continue }
        $Lines[$ext.LineIndex] = if ($should) { "$($ext.Type)=$($ext.Raw)" } else { ";$($ext.Type)=$($ext.Raw)" }
        Write-Log ("Extension {0}: {1}" -f $ext.Name, $(if ($should) { 'aktiviert' } else { 'deaktiviert' }))
        $changed++
    }
    Write-Log "$changed Extension-Zeilen geändert." 'Ok'
}

# ==============================================================================
#  7) Verzeichnisse und Berechtigungen
# ==============================================================================

function New-WritableDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Log "Ordner angelegt: $Path" 'Ok'
    } else {
        Write-Log "Ordner vorhanden: $Path"
    }

    # Zwei Konten brauchen Schreibrechte:
    #   S-1-5-32-568  IIS_IUSRS - enthält die virtuellen Anwendungspool-Konten
    #   S-1-5-17      IUSR      - das anonyme Konto; unter fastcgi.impersonate = 1
    #                             greift PHP mit dieser Identität auf Dateien zu
    $acl = Get-Acl -LiteralPath $Path
    $granted = @()
    foreach ($sidValue in @($script:IisUsersSid, $script:IusrSid)) {
        try {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        } catch {
            Write-Log "SID $sidValue auf diesem System unbekannt - übersprungen." 'Warn'
            continue
        }
        $name = try { $sid.Translate([System.Security.Principal.NTAccount]).Value } catch { $sidValue }
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::Modify,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
             [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
        $granted += $name
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    if ($granted.Count -eq 0) {
        Write-Log "Auf $Path konnte kein Schreibrecht gesetzt werden." 'Error'
        return
    }
    Write-Log ("Recht 'Ändern' gesetzt für: {0}" -f ($granted -join ', ')) 'Ok'

    # Nachkontrolle, damit im Protokoll steht, was wirklich im Ordner hängt
    $eff = (Get-Acl -LiteralPath $Path).Access |
           Where-Object { "$($_.FileSystemRights)" -match 'Modify|FullControl|Write' } |
           ForEach-Object { [string]$_.IdentityReference } |
           Sort-Object -Unique
    Write-Log ("Schreibberechtigt laut Ordner: {0}" -f ($eff -join ', '))
}

# ==============================================================================
#  8) IIS-Konfiguration
# ==============================================================================

function Test-WebAdministration {
    try { Import-Module WebAdministration -ErrorAction Stop; return $true }
    catch { return $false }
}

function Invoke-AppCmd {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Argumente mit Leerzeichen (z. B. Pfade unter "Program Files") für die
    # Kommandozeile in Anführungszeichen setzen, sofern noch nicht geschehen.
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '\s' -and $a -notmatch '^".*"$') { '"' + $a + '"' } else { $a }
    }
    $r = Invoke-ExeCapture -FilePath $script:AppCmd -ArgumentList @($quoted)
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = ($r.Lines -join ' ') }
}

function Set-IisPhpHandler {
    Write-Log 'IIS: FastCGI-Anwendung und Handlerzuordnung' 'Step'
    $phpCgi = Get-PhpCgiPath
    $iniPath = Get-PhpIniPath
    $hasModule = Test-WebAdministration

    # --- 8a) FastCGI-Anwendung -------------------------------------------------
    # Ohne diesen Eintrag läuft die Handlerzuordnung in einen HTTP 500.
    # Die IIS-Oberfläche legt ihn beim Anlegen der Modulzuordnung automatisch an,
    # per Skript muss man das ausdrücklich tun.
    $exists = $false
    if ($hasModule) {
        $f = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' `
             -Filter "system.webServer/fastCgi/application[@fullPath='$phpCgi']" -ErrorAction SilentlyContinue
        $exists = [bool]$f
    }
    if ($exists) {
        Write-Log 'FastCGI-Anwendung für php-cgi.exe ist bereits eingetragen.'
    } else {
        if ($hasModule) {
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Filter 'system.webServer/fastCgi' -Name '.' -Value @{ fullPath = $phpCgi } -ErrorAction Stop
        } else {
            $r = Invoke-AppCmd @('set', 'config', '/section:system.webServer/fastCgi',
                                 "/+[fullPath='$phpCgi']", '/commit:apphost')
            if ($r.ExitCode -ne 0 -and $r.Output -notmatch 'already|vorhanden|duplicate') { throw "appcmd: $($r.Output)" }
        }
        Write-Log 'FastCGI-Anwendung angelegt.' 'Ok'
    }

    if ($hasModule) {
        $flt = "system.webServer/fastCgi/application[@fullPath='$phpCgi']"
        # instanceMaxRequests + PHP_FCGI_MAX_REQUESTS gegen Speicherfragmentierung
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $flt -Name 'instanceMaxRequests' -Value 10000
        # monitorChangesTo: IIS recycelt die php-cgi-Prozesse automatisch, sobald
        # sich die php.ini ändert. Damit entfällt das manuelle "Prozesse killen".
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $flt -Name 'monitorChangesTo' -Value $iniPath

        $maxExec = [int]$script:Cfg.MaxExec
        # activityTimeout (Standard 30 s) und requestTimeout (Standard 90 s) müssen
        # größer sein als max_execution_time, sonst bricht IIS vorher ab.
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $flt -Name 'activityTimeout' -Value ([int]($maxExec + 30))
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $flt -Name 'requestTimeout'  -Value ([int]($maxExec + 60))

        $envVars = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' `
                   -Filter "$flt/environmentVariables/environmentVariable[@name='PHP_FCGI_MAX_REQUESTS']" -ErrorAction SilentlyContinue
        if (-not $envVars) {
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$flt/environmentVariables" `
                -Name '.' -Value @{ name = 'PHP_FCGI_MAX_REQUESTS'; value = '10000' }
        }
        Write-Log ('FastCGI-Timeouts gesetzt (activityTimeout {0}s, requestTimeout {1}s).' -f ($maxExec + 30), ($maxExec + 60)) 'Ok'
    }

    # --- 8b) Handlerzuordnung --------------------------------------------------
    $handlerExists = $false
    if ($hasModule) {
        $h = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' `
             -Filter "system.webServer/handlers/add[@name='PHP']" -ErrorAction SilentlyContinue
        $handlerExists = [bool]$h
    }
    if ($handlerExists) {
        Write-Log "Handlerzuordnung 'PHP' existiert bereits - wird aktualisiert."
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter "system.webServer/handlers/add[@name='PHP']" -Name 'scriptProcessor' -Value $phpCgi
    } else {
        if ($hasModule) {
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/handlers' `
                -Name '.' -AtIndex 0 -Value @{
                    name            = 'PHP'
                    path            = '*.php'      # nicht ".php" - IIS erwartet ein Muster
                    verb            = '*'
                    modules         = 'FastCgiModule'
                    scriptProcessor = $phpCgi
                    resourceType    = 'Either'
                    requireAccess   = 'Script'
                } -ErrorAction Stop
        } else {
            $r = Invoke-AppCmd @('set', 'config', '/section:system.webServer/handlers',
                "/+[name='PHP',path='*.php',verb='*',modules='FastCgiModule',scriptProcessor='$phpCgi',resourceType='Either',requireAccess='Script']",
                '/commit:apphost')
            if ($r.ExitCode -ne 0 -and $r.Output -notmatch 'already|vorhanden|duplicate') { throw "appcmd: $($r.Output)" }
        }
        Write-Log "Handlerzuordnung 'PHP' für *.php angelegt (Modul FastCgiModule)." 'Ok'
    }
}

function Add-DefaultDocument {
    param([string]$Name = 'index.php')
    Write-Log 'IIS: Standarddokument' 'Step'
    $hasModule = Test-WebAdministration

    if ($hasModule) {
        $exists = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' `
                  -Filter "system.webServer/defaultDocument/files/add[@value='$Name']" -ErrorAction SilentlyContinue
        if ($exists) {
            Write-Log "Standarddokument '$Name' ist bereits eingetragen." 'Ok'
            return
        }
        # Doppelte Einträge erzeugen einen harten IIS-Konfigurationsfehler,
        # deshalb die Prüfung oben.
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter 'system.webServer/defaultDocument/files' -Name '.' -AtIndex 0 -Value @{ value = $Name }
    } else {
        $r = Invoke-AppCmd @('set', 'config', '/section:system.webServer/defaultDocument',
                             "/+files.[value='$Name']", '/commit:apphost')
        if ($r.ExitCode -ne 0 -and $r.Output -notmatch 'already|vorhanden|duplicate') {
            Write-Log "Standarddokument konnte nicht gesetzt werden: $($r.Output)" 'Warn'
            return
        }
    }
    Write-Log "Standarddokument '$Name' hinzugefügt." 'Ok'
}

function Set-IisRequestLimit {
    param([Parameter(Mandatory)][long]$Bytes)
    Write-Log 'IIS: maxAllowedContentLength' 'Step'
    # IIS begrenzt Requests standardmäßig auf ca. 28,6 MB. Ist post_max_size
    # größer, würde IIS mit 404.13 abbrechen, bevor PHP überhaupt anläuft.
    try {
        if (Test-WebAdministration) {
            Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Filter 'system.webServer/security/requestFiltering/requestLimits' `
                -Name 'maxAllowedContentLength' -Value $Bytes
        } else {
            $r = Invoke-AppCmd @('set', 'config', '/section:system.webServer/security/requestFiltering',
                                 "/requestLimits.maxAllowedContentLength:$Bytes", '/commit:apphost')
            if ($r.ExitCode -ne 0) { throw $r.Output }
        }
        Write-Log ("maxAllowedContentLength = {0} Bytes ({1} MB)." -f $Bytes, [math]::Round($Bytes / 1MB, 1)) 'Ok'
    } catch {
        Write-Log "maxAllowedContentLength konnte nicht gesetzt werden: $($_.Exception.Message)" 'Warn'
    }
}

function Restart-IisStack {
    Write-Log 'IIS neu starten' 'Step'
    try {
        $r = Invoke-ExeCapture -FilePath (Join-Path $env:windir 'system32\iisreset.exe') -ArgumentList @('/restart') -TimeoutSec 180
        Write-Log (($r.Lines | Where-Object { $_ -match '\S' }) -join ' | ')
        if ($r.ExitCode -ne 0) { throw "iisreset Exitcode $($r.ExitCode)" }
        Write-Log 'IIS wurde neu gestartet.' 'Ok'
    } catch {
        Write-Log "iisreset fehlgeschlagen, versuche Dienstneustart: $($_.Exception.Message)" 'Warn'
        Restart-Service -Name W3SVC -Force
        Write-Log 'Dienst W3SVC neu gestartet.' 'Ok'
    }
}

# ==============================================================================
#  9) Hilfsdateien
# ==============================================================================

function New-PhpInfoPage {
    if (-not (Test-Path $script:WwwRoot)) { New-Item -ItemType Directory -Path $script:WwwRoot -Force | Out-Null }
    $file = Join-Path $script:WwwRoot 'phpinfo.php'
    $content = @'
<?php
   phpinfo();
?>
'@
    # Ohne BOM schreiben: ein BOM landet sonst vor dem <?php in der Ausgabe
    [System.IO.File]::WriteAllText($file, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Testseite angelegt: $file" 'Ok'
    Write-Log 'phpinfo.php verrät die komplette Serverkonfiguration - nach dem Test wieder löschen.' 'Warn'
    return $file
}

function New-PhpCheckPage {
    if (-not (Test-Path $script:WwwRoot)) { New-Item -ItemType Directory -Path $script:WwwRoot -Force | Out-Null }
    $file = Join-Path $script:WwwRoot 'phpcheck.php'
    $content = @'
<?php
header('Content-Type: text/plain; charset=utf-8');

echo "=== PHP ===\n";
echo "Version        : " . PHP_VERSION . "  (SAPI: " . PHP_SAPI . ")\n";
echo "Prozessbenutzer: " . @get_current_user() . "\n";
echo "LOGON_USER     : " . (isset($_SERVER['LOGON_USER']) && $_SERVER['LOGON_USER'] !== '' ? $_SERVER['LOGON_USER'] : '(leer - anonymer Zugriff)') . "\n";
echo "impersonate    : " . (ini_get('fastcgi.impersonate') ? 'an' : 'aus') . "\n\n";

echo "=== Schreibrechte ===\n";
foreach (array('session.save_path', 'upload_tmp_dir') as $key) {
    $dir = trim(ini_get($key), '"');
    echo str_pad($key, 18) . ": $dir\n";
    if ($dir === '') { echo str_pad('', 18) . "  nicht gesetzt\n"; continue; }
    echo str_pad('', 18) . "  vorhanden: " . (is_dir($dir) ? 'ja' : 'NEIN') . ", beschreibbar: " . (is_writable($dir) ? 'ja' : 'NEIN') . "\n";
    $tmp = @tempnam($dir, 'chk');
    if ($tmp !== false) { echo str_pad('', 18) . "  Schreibtest: ok\n"; @unlink($tmp); }
    else { echo str_pad('', 18) . "  Schreibtest: FEHLGESCHLAGEN\n"; }
}
echo "\nSession starten: ";
echo @session_start() ? "ok (id " . session_id() . ")\n" : "FEHLGESCHLAGEN\n";

echo "\n=== Verbindungszeit zur Datenbank ===\n";
echo "Deutlich langsamer bei 'localhost' bedeutet: Windows probiert erst ::1.\n";
foreach (array('localhost', '127.0.0.1', '::1') as $host) {
    $start = microtime(true);
    $sock = @fsockopen($host, 3306, $errno, $errstr, 5);
    printf("  %-12s %7.3f s   %s\n", $host, microtime(true) - $start,
           $sock ? 'verbunden' : 'fehlgeschlagen: ' . $errstr);
    if ($sock) { fclose($sock); }
}

echo "\n=== Namensaufloesung ===\n";
$start = microtime(true);
$ip = gethostbyname('localhost');
printf("  gethostbyname('localhost') = %s  (%.3f s)\n", $ip, microtime(true) - $start);

'@
    [System.IO.File]::WriteAllText($file, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Diagnoseseite angelegt: $file" 'Ok'
    Write-Log 'Auch diese Seite nach der Fehlersuche wieder löschen.' 'Warn'
    return $file
}

function Remove-TestPages {
    $any = $false
    foreach ($n in @('phpinfo.php', 'phpcheck.php')) {
        $file = Join-Path $script:WwwRoot $n
        if (Test-Path $file) { Remove-Item -LiteralPath $file -Force; Write-Log "$n gelöscht." 'Ok'; $any = $true }
    }
    if (-not $any) { Write-Log 'Weder phpinfo.php noch phpcheck.php vorhanden.' 'Info' }
    return $any
}

function Get-CaCertBundle {
    Write-Log 'CA-Bundle für cURL/OpenSSL' 'Step'
    $dir  = Join-Path $script:PhpRoot 'extras\ssl'
    $file = Join-Path $dir 'cacert.pem'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Get-FileWithUi -Url $script:CaCertUrl -OutFile $file -Activity 'CA-Bundle (cacert.pem) wird geladen' -TimeoutSec 180
    $kb = [math]::Round((Get-Item $file).Length / 1KB)
    Write-Log "cacert.pem gespeichert ($kb KB): $file" 'Ok'
    return $file
}

function Open-InBrowser {
    param([Parameter(Mandatory)][string]$Url)
    try {
        Start-Process $Url -ErrorAction Stop
        Write-Log "Browser geöffnet: $Url" 'Ok'
        return $true
    } catch {
        Write-Log 'Kein Standardbrowser registriert - versuche Edge, dann Internet Explorer.' 'Warn'
        foreach ($exe in @('msedge.exe', 'iexplore.exe')) {
            try { Start-Process $exe -ArgumentList $Url -ErrorAction Stop; return $true } catch { }
        }
        Write-Log "Kein Browser gefunden. Seite manuell aufrufen: $Url" 'Error'
        Write-Log 'Auf frischen Servern blockiert außerdem oft die IE-Sicherheitsverstärkung (IE ESC) die Anzeige.' 'Info'
        return $false
    }
}

# ==============================================================================
# 10) Ablauf: Installation (IIS, VC++, URL Rewrite, PHP, PATH)
# ==============================================================================

function Invoke-InstallVcRedist { if ($script:Cfg.InstallVcRedist) { Install-VcRedist } else { Write-Log 'VC++ Redistributable laut Auswahl übersprungen.' 'Info' } }
function Invoke-InstallIis      { if ($script:Cfg.InstallIis)      { Install-IisFeatures } else { Write-Log 'IIS-Installation laut Auswahl übersprungen.' 'Info' } }
function Invoke-InstallRewrite  { if ($script:Cfg.InstallRewrite)  { Install-UrlRewrite } else { Write-Log 'URL Rewrite laut Auswahl übersprungen.' 'Info' } }

function Invoke-InstallPhpStep {
    if ($script:Cfg.InstallPhp) {
        $url = [string]$script:Cfg.PhpUrl
        if ([string]::IsNullOrWhiteSpace($url)) { throw 'Es ist keine Download-URL für PHP gesetzt (Versionsliste nicht geladen?). Unter "Erweiterte Optionen" eine Version wählen.' }
        Install-Php -Url $url
        Initialize-PhpIni
    } else {
        Write-Log 'PHP-Download laut Auswahl übersprungen.' 'Info'
    }
    if ($script:Cfg.AddPath) { Add-PhpToMachinePath }
}

# ==============================================================================
# 11) Ablauf: Konfiguration (php.ini, Ordner, IIS-Handler, Neustart)
# ==============================================================================

function ConvertTo-Bytes([string]$v) {
    if ($v -match '^(\d+)([KMGkmg])?$') {
        $n = [long]$Matches[1]
        $unit = if ($Matches[2]) { ([string]$Matches[2]).ToUpper() } else { '' }
        switch ($unit) { 'K' { $n * 1KB } 'M' { $n * 1MB } 'G' { $n * 1GB } default { $n } }
    } else { 0 }
}

# Prüft die php.ini-Werte aus $script:Cfg. Liefert Fehlertext oder $null.
function Test-PhpConfigValues {
    $sizeRx = '^\d+[KMGkmg]?$'
    foreach ($f in @(
        @{ Key = 'MemLimit';  Name = 'memory_limit' }
        @{ Key = 'PostMax';   Name = 'post_max_size' }
        @{ Key = 'UploadMax'; Name = 'upload_max_filesize' }
    )) {
        $v = ([string]$script:Cfg[$f.Key]).Trim()
        if ($v -notmatch $sizeRx) {
            return "$($f.Name): '$v' ist kein gültiger Wert. Erlaubt sind Angaben wie 512M, 2G oder 268435456."
        }
    }
    foreach ($f in @(
        @{ Key = 'SessionDir'; Name = 'session.save_path' }
        @{ Key = 'UploadDir';  Name = 'upload_tmp_dir' }
    )) {
        $v = ([string]$script:Cfg[$f.Key]).Trim()
        if (-not $v -or -not [System.IO.Path]::IsPathRooted($v)) {
            return "$($f.Name): '$v' ist kein absoluter Pfad."
        }
    }
    return $null
}

function Invoke-ConfigurePhase {
    Write-Log '=== PHP konfigurieren ===' 'Step'
    $ini = Get-PhpIniPath
    if (-not (Test-Path $ini)) { throw "php.ini nicht gefunden ($ini). Ist PHP installiert?" }

    $err = Test-PhpConfigValues
    if ($err) { throw $err }

    if ((ConvertTo-Bytes ([string]$script:Cfg.PostMax).Trim()) -lt (ConvertTo-Bytes ([string]$script:Cfg.UploadMax).Trim())) {
        Write-Log 'post_max_size ist kleiner als upload_max_filesize - Uploads in dieser Größe werden fehlschlagen.' 'Warn'
    }

    $backup = "$ini.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
    Copy-Item -LiteralPath $ini -Destination $backup -Force
    Write-Log "Sicherung: $(Split-Path $backup -Leaf)" 'Info'

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in (Get-Content -LiteralPath $ini)) { $lines.Add($l) }

    # --- Grundeinstellungen ---
    Write-Log 'php.ini: Grundeinstellungen' 'Step'
    Set-IniDirective -Lines $lines -Key 'extension_dir' -Value ('"{0}"' -f (Join-Path $script:PhpRoot 'ext')) -PreferLast
    Set-IniDirective -Lines $lines -Key 'max_execution_time'  -Value ([string][int]$script:Cfg.MaxExec)
    Set-IniDirective -Lines $lines -Key 'memory_limit'        -Value ([string]$script:Cfg.MemLimit).Trim()
    Set-IniDirective -Lines $lines -Key 'post_max_size'       -Value ([string]$script:Cfg.PostMax).Trim()
    Set-IniDirective -Lines $lines -Key 'upload_max_filesize' -Value ([string]$script:Cfg.UploadMax).Trim()
    Set-IniDirective -Lines $lines -Key 'max_file_uploads'    -Value ([string][int]$script:Cfg.MaxFiles)
    Set-IniDirective -Lines $lines -Key 'session.save_path'   -Value ('"{0}"' -f ([string]$script:Cfg.SessionDir).Trim()) -PreferLast
    Set-IniDirective -Lines $lines -Key 'upload_tmp_dir'      -Value ('"{0}"' -f ([string]$script:Cfg.UploadDir).Trim())
    if (([string]$script:Cfg.Timezone).Trim()) {
        Set-IniDirective -Lines $lines -Key 'date.timezone' -Value ([string]$script:Cfg.Timezone).Trim()
    }
    Write-Log 'Grundeinstellungen gesetzt.' 'Ok'

    # --- IIS-spezifische Empfehlungen ---
    if ($script:Cfg.IisTuning) {
        Write-Log 'php.ini: IIS-Empfehlungen' 'Step'
        Set-IniDirective -Lines $lines -Key 'fastcgi.impersonate' -Value '1'
        Set-IniDirective -Lines $lines -Key 'cgi.fix_pathinfo'    -Value '1'
        Set-IniDirective -Lines $lines -Key 'cgi.force_redirect'  -Value '0'
        Set-IniDirective -Lines $lines -Key 'expose_php'          -Value 'Off'
        Write-Log 'fastcgi.impersonate, cgi.fix_pathinfo, cgi.force_redirect, expose_php gesetzt.' 'Ok'
    }

    # --- OPcache ---
    <#
     Wichtig: Bis einschließlich PHP 8.4 liegt OPcache als eigene Datei
     ext\php_opcache.dll bei und muss mit "zend_extension=opcache" geladen
     werden. Ab PHP 8.5 ist OPcache fest in php8.dll eingebaut, die DLL gibt
     es nicht mehr - eine zend_extension-Zeile führt dort bei jedem Aufruf zu
     "Failed loading Zend extension 'opcache'". Deshalb wird anhand der Datei
     entschieden und eine vorhandene Zeile gegebenenfalls deaktiviert.
    #>
    if ($script:Cfg.Opcache) {
        Write-Log 'php.ini: OPcache' 'Step'
        $opcacheDll = Join-Path (Join-Path $script:PhpRoot 'ext') 'php_opcache.dll'
        if (Test-Path -LiteralPath $opcacheDll) {
            Set-IniDirective -Lines $lines -Key 'zend_extension'              -Value 'opcache'
        } else {
            $off = Disable-IniDirective -Lines $lines -Pattern '^\s*zend_extension\s*=\s*"?(php_)?opcache(\.dll)?"?\s*$'
            Write-Log 'OPcache ist in dieser PHP-Version fest eingebaut (keine php_opcache.dll) - es wird keine zend_extension-Zeile gesetzt.' 'Info'
            if ($off -gt 0) { Write-Log "$off vorhandene zend_extension-Zeile(n) für OPcache deaktiviert." 'Ok' }
        }
        Set-IniDirective -Lines $lines -Key 'opcache.enable'                  -Value '1'
        Set-IniDirective -Lines $lines -Key 'opcache.enable_cli'              -Value '0'
        Set-IniDirective -Lines $lines -Key 'opcache.memory_consumption'      -Value '128'
        Set-IniDirective -Lines $lines -Key 'opcache.interned_strings_buffer' -Value '8'
        Set-IniDirective -Lines $lines -Key 'opcache.max_accelerated_files'   -Value '10000'
        Set-IniDirective -Lines $lines -Key 'opcache.validate_timestamps'     -Value '1'
        Set-IniDirective -Lines $lines -Key 'opcache.revalidate_freq'         -Value '2'
        Write-Log 'OPcache aktiviert (128 MB, Zeitstempelprüfung alle 2 Sekunden).' 'Ok'
    }

    # --- Extensions ---
    Write-Log 'php.ini: Extensions' 'Step'
    $wanted = @{}
    foreach ($k in $script:Cfg.Extensions.Keys) { $wanted[$k] = [bool]$script:Cfg.Extensions[$k] }
    if ($script:Cfg.Curl) {
        # Ohne aktive Extensions bringen curl.cainfo/openssl.cafile nichts
        $wanted['curl'] = $true; $wanted['openssl'] = $true
        $script:Cfg.Extensions['curl'] = $true; $script:Cfg.Extensions['openssl'] = $true
    }
    Set-PhpExtensionState -Lines $lines -Wanted $wanted

    # --- cURL / OpenSSL ---
    if ($script:Cfg.Curl) {
        $pem = Get-CaCertBundle
        Set-IniDirective -Lines $lines -Key 'curl.cainfo'    -Value ('"{0}"' -f $pem)
        Set-IniDirective -Lines $lines -Key 'openssl.cafile' -Value ('"{0}"' -f $pem)
        Write-Log 'curl.cainfo und openssl.cafile gesetzt.' 'Ok'
    }

    [System.IO.File]::WriteAllLines($ini, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "php.ini geschrieben ($($lines.Count) Zeilen)." 'Ok'

    # --- Verzeichnisse ---
    Write-Log 'Verzeichnisse und Berechtigungen' 'Step'
    New-WritableDirectory -Path ([string]$script:Cfg.SessionDir).Trim()
    New-WritableDirectory -Path ([string]$script:Cfg.UploadDir).Trim()

    # --- IIS ---
    if (-not (Test-Path $script:AppCmd)) {
        Write-Log 'IIS ist nicht installiert - Handlerzuordnung wird übersprungen.' 'Warn'
        return
    }
    Set-IisPhpHandler
    Add-DefaultDocument -Name 'index.php'
    if ($script:Cfg.ContentLength) {
        $mb = 32
        if (([string]$script:Cfg.PostMax).Trim() -match '^(\d+)\s*[Mm]?') { $mb = [int]$Matches[1] }
        Set-IisRequestLimit -Bytes ($mb * 1MB)
    }

    # --- Neustart ---
    Stop-PhpProcesses
    Restart-IisStack
    Write-Log 'PHP-Konfiguration abgeschlossen.' 'Ok'
}

# ==============================================================================
# 12) Ablauf: Funktionstest
# ==============================================================================

function Invoke-VerifyPhase {
    Write-Log '=== Funktionstest ===' 'Step'
    $php = Get-PhpExePath
    if (-not (Test-Path $php)) { throw "php.exe nicht gefunden ($php)." }

    $v = Invoke-ExeCapture -FilePath $php -ArgumentList @('-v') -TimeoutSec 60
    $firstLine = ($v.Lines | Select-Object -First 1)
    if (-not $firstLine) { $firstLine = '(keine Ausgabe von php -v)' }
    Write-Log $firstLine 'Ok'
    $version = if ($firstLine -match 'PHP (\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
    $script:Result.PhpVersion = $version

    $m = Invoke-ExeCapture -FilePath $php -ArgumentList @('-m') -TimeoutSec 60
    $mods = $m.Lines
    $warnings = @($mods | Where-Object { $_ -match 'Warning|Unable to load|Fatal' })
    if ($warnings.Count -gt 0) {
        foreach ($w in $warnings) { Write-Log $w 'Error' }
        Write-Log 'Mindestens eine Extension lädt nicht. Meist fehlt das VC++ Redistributable oder extension_dir stimmt nicht.' 'Warn'
    } else {
        $count = @($mods | Where-Object { $_ -match '^\w' -and $_ -notmatch '^\[' }).Count
        Write-Log "$count Module geladen, keine Ladefehler." 'Ok'
        $script:Result.PhpOk = $true
    }
    if ($script:Cfg.Opcache) {
        if ($mods -contains 'Zend OPcache') { Write-Log 'OPcache ist geladen.' 'Ok' }
        else { Write-Log 'OPcache erscheint nicht in "php -m" - bitte php.ini prüfen.' 'Warn' }
    }
    $script:Result.PhpModules = $mods

    if (-not (Test-Path $script:AppCmd)) {
        Write-Log 'IIS nicht installiert - HTTP-Test wird übersprungen.' 'Warn'
        return
    }

    New-PhpInfoPage | Out-Null
    try {
        $resp = Invoke-WebRequest -Uri 'http://localhost/phpinfo.php' -UseBasicParsing -TimeoutSec 30
        if ($resp.Content -match 'PHP Version ([\d\.]+)') {
            Write-Log "IIS liefert PHP $($Matches[1]) aus - die Handlerzuordnung funktioniert." 'Ok'
            $script:Result.HttpOk = $true
        } else {
            Write-Log 'Die Seite antwortet, enthält aber keine phpinfo-Ausgabe. Wird die Datei als Text ausgeliefert?' 'Warn'
        }
    } catch {
        Write-Log "HTTP-Test fehlgeschlagen: $($_.Exception.Message)" 'Error'
        Write-Log 'Typische Ursachen: FastCGI-Anwendung fehlt, VC++ Redistributable fehlt, IIS nicht neu gestartet.' 'Warn'
    }
}

# ==============================================================================
# 13) MySQL 8.4 LTS
# ==============================================================================

function Get-MySqlPaths {
    $base = ([string]$script:Cfg.MyInstallDir).Trim()
    $data = ([string]$script:Cfg.MyDataDir).Trim()
    [pscustomobject]@{
        Base    = $base
        Bin     = Join-Path $base 'bin'
        Mysqld  = Join-Path $base 'bin\mysqld.exe'
        Mysql   = Join-Path $base 'bin\mysql.exe'
        Data    = $data
        Ini     = Join-Path (Split-Path $data -Parent) 'my.ini'
        Service = ([string]$script:Cfg.MyService).Trim()
        Port    = [int]$script:Cfg.MyPort
    }
}

<#
 Prüft einen MySQL-Benutzernamen. Großbuchstaben sind bewusst nicht erlaubt:
 MySQL unterscheidet bei Benutzernamen Groß- und Kleinschreibung, gemischte
 Schreibweise führt später regelmäßig zu Anmeldefehlern.
#>
function Test-MySqlUserName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name))       { return 'Benutzername darf nicht leer sein.' }
    if ($Name -cmatch '[A-Z]')                     { return "'$Name': Großbuchstaben sind nicht erlaubt." }
    if ($Name.Length -gt 32)                       { return "'$Name': maximal 32 Zeichen." }
    if ($Name -notmatch '^[a-z0-9_][a-z0-9_.-]*$') { return "'$Name': erlaubt sind Kleinbuchstaben, Ziffern, _ . und -, beginnend mit Buchstabe, Ziffer oder _." }
    return $null
}

function Test-MySqlDbName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Datenbankname darf nicht leer sein.' }
    if ($Name -cmatch '[A-Z]')               { return "Datenbank '$Name': Großbuchstaben sind nicht erlaubt." }
    if ($Name.Length -gt 64)                 { return "Datenbank '$Name': maximal 64 Zeichen." }
    if ($Name -notmatch '^[a-z0-9_$-]+$')    { return "Datenbank '$Name': erlaubt sind Kleinbuchstaben, Ziffern, _ - und `$." }
    return $null
}

# Ohne Parameter werden die Werte aus $script:Cfg genommen; der Dialog
# "Erweiterte Optionen" übergibt seine noch nicht gespeicherten Eingaben.
function Get-MySqlFirewallPlan {
    param(
        [string]$Mode    = [string]$script:Cfg.MyNetMode,
        [string]$Service = ([string]$script:Cfg.MyService).Trim(),
        [int]$Port       = [int]$script:Cfg.MyPort,
        [string]$Mysqld  = (Get-MySqlPaths).Mysqld
    )
    $p = [pscustomobject]@{ Service = $Service; Port = $Port; Mysqld = $Mysqld }
    $mode = $Mode
    if ($mode -notin @('local', 'lan', 'any')) { $mode = 'local' }

    if ($mode -eq 'local') {
        return [pscustomobject]@{
            Mode    = $mode
            Needed  = $false
            Bind    = '127.0.0.1,::1'
            Profile = ''
            Text    = @"
KEINE Firewallregel erforderlich.

MySQL lauscht ausschließlich auf den Loopback-Adressen 127.0.0.1 und ::1.
Der Port ist von außen selbst dann nicht erreichbar, wenn eine Firewall ihn
freigibt. PHP und IIS auf demselben Server erreichen die Datenbank unverändert.

Beide Loopback-Adressen sind Absicht: Windows löst "localhost" zuerst nach
::1 auf. Fehlt die Bindung dort, läuft jeder Verbindungsversuch erst in einen
Zeitablauf von rund zwei Sekunden, bevor auf 127.0.0.1 zurückgefallen wird.

Für Fremd-Firewalls (Antivirus o.ä.) ist nichts einzutragen.
"@
        }
    }

    $prof = if ($mode -eq 'lan') { 'Domain,Private' } else { 'Domain,Private,Public' }
    $profDe = if ($mode -eq 'lan') { 'Domäne, Privat' } else { 'Domäne, Privat, Öffentlich' }
    $warn = if ($mode -eq 'any') {
        "`r`nACHTUNG: Profil 'Öffentlich' gibt den Port auch in fremden Netzen frei.`r`nNur wählen, wenn das wirklich gebraucht wird.`r`n"
    } else { '' }

    [pscustomobject]@{
        Mode    = $mode
        Needed  = $true
        Bind    = '*'
        Profile = $prof
        Text    = @"
Diese Regel wird angelegt (Windows Defender Firewall):

  Name (Anzeige) : MySQL Server $($p.Service) (TCP $($p.Port))
  Richtung       : Eingehend
  Aktion         : Zulassen
  Protokoll      : TCP
  Lokaler Port   : $($p.Port)
  Remote-Port    : beliebig
  Profile        : $profDe
  Programm       : $($p.Mysqld)
  Dienst         : $($p.Service)

MySQL lauscht dann auf allen Adressen (IPv4 und IPv6), ist also über jede
Netzwerkkarte erreichbar.
Das Benutzerkonto root bleibt trotzdem auf localhost beschränkt.
$warn
Wenn eine andere Firewall im Einsatz ist (z. B. aus einer Antiviren-Suite),
dort dieselben Angaben eintragen: eingehend, TCP, Port $($p.Port), Programm
$($p.Mysqld) zulassen.

PowerShell-Äquivalent zum Nachvollziehen:
  New-NetFirewallRule -DisplayName "MySQL Server $($p.Service) (TCP $($p.Port))" ``
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($p.Port) ``
    -Profile $prof -Program "$($p.Mysqld)"
"@
    }
}

function Test-MySqlAlreadyInstalled {
    $svc = Get-Service -Name ([string]$script:Cfg.MyService).Trim() -ErrorAction SilentlyContinue
    if ($svc) { return "Der Dienst '$($svc.Name)' existiert bereits (Status: $($svc.Status))." }
    $data = ([string]$script:Cfg.MyDataDir).Trim()
    if ((Test-Path $data) -and @(Get-ChildItem -LiteralPath $data -ErrorAction SilentlyContinue).Count -gt 0) {
        return "Das Datenverzeichnis '$data' ist bereits vorhanden und nicht leer."
    }
    return $null
}

function Get-MySqlErrorLogPath {
    Join-Path (Split-Path (Get-MySqlPaths).Ini -Parent) 'mysql-error.log'
}

# Zeigt das Ende der MySQL-Fehlerdatei im Protokoll an.
function Write-MySqlErrorLogTail {
    param([int]$Lines = 25)
    $log = Get-MySqlErrorLogPath
    if (-not (Test-Path -LiteralPath $log)) {
        Write-Log "Keine Fehlerdatei unter $log vorhanden." 'Warn'
        return
    }
    Write-Log "--- letzte $Lines Zeilen aus $log ---" 'Info'
    foreach ($l in (Get-Content -LiteralPath $log -Tail $Lines -ErrorAction SilentlyContinue)) {
        if ($l -match '\[ERROR\]') { Write-Log $l 'Error' } else { Write-Log $l }
    }
    Write-Log '--- Ende des Auszugs ---' 'Info'
}

# Ein initialisiertes Datenverzeichnis erkennt man am Systemschema und an ibdata1.
function Test-MySqlDataInitialized {
    $d = (Get-MySqlPaths).Data
    (Test-Path -LiteralPath (Join-Path $d 'mysql')) -and (Test-Path -LiteralPath (Join-Path $d 'ibdata1'))
}

function Install-MySqlMsi {
    Write-Log 'MySQL Server herunterladen und installieren' 'Step'
    $p = Get-MySqlPaths
    if (Test-Path $p.Mysqld) {
        Write-Log "mysqld.exe ist bereits vorhanden unter $($p.Mysqld) - MSI-Installation übersprungen." 'Ok'
        return
    }
    $url = ([string]$script:Cfg.MyUrl).Trim()
    if ([string]::IsNullOrWhiteSpace($url)) { throw 'Keine Download-URL für MySQL gesetzt.' }

    $msi = Join-Path $env:TEMP (Split-Path $url -Leaf)
    Write-Log "Quelle: $url"
    Get-FileWithUi -Url $url -OutFile $msi -Activity 'MySQL Server wird geladen'
    Write-Log ("SHA256: {0}" -f (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash)

    $log = Join-Path $script:LogDir 'mysql-msi.log'
    # ADDLOCAL: nur Server und Kommandozeilenwerkzeuge, keine Router-/Devel-Teile.
    # LAUNCHPRODUCT=0 verhindert, dass der grafische MySQL Configurator aufgeht.
    $msiArgs = @(
        '/i', "`"$msi`"", '/qn', '/norestart',
        '/lv', "`"$log`"",
        "INSTALLDIR=`"$($p.Base)`"",
        'ADDLOCAL=MYSQLSERVER,Client',
        'LAUNCHPRODUCT=0'
    )
    $code = Start-ProcessWithUi -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Activity 'MySQL Server wird installiert'
    switch ($code) {
        0       { Write-Log 'MySQL Server installiert.' 'Ok' }
        3010    { Write-Log 'Installiert. Windows meldet: Neustart erforderlich.' 'Warn'; $script:RebootNeeded = $true }
        1603    { throw "msiexec Exitcode 1603 (schwerer Fehler). Details: $log" }
        default { throw "msiexec wurde mit Exitcode $code beendet. Details: $log" }
    }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $p.Mysqld)) { throw "mysqld.exe nicht gefunden unter $($p.Mysqld)" }
}

function New-MySqlIni {
    Write-Log 'my.ini schreiben' 'Step'
    $p    = Get-MySqlPaths
    $plan = Get-MySqlFirewallPlan
    $pool = [int]$script:Cfg.MyBufferPool
    $logDir = Split-Path $p.Ini -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    if (Test-Path $p.Ini) {
        $bak = "$($p.Ini).bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date)
        Copy-Item -LiteralPath $p.Ini -Destination $bak -Force
        Write-Log "Bestehende my.ini gesichert nach $(Split-Path $bak -Leaf)" 'Info'
    }

    # In der my.ini sind Schrägstriche unter Windows die sichere Variante
    $fw = { param($x) $x -replace '\\', '/' }
    $ini = @"
# Erzeugt vom PHP + IIS Setup-Assistenten am $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# MySQL 8.4 LTS

[mysqld]
basedir                 = "$(& $fw $p.Base)"
datadir                 = "$(& $fw $p.Data)"
port                    = $($p.Port)
bind-address            = $($plan.Bind)

# Ab MySQL 8.4 ersetzt authentication_policy die entfallene Variable
# default_authentication_plugin. mysql_native_password ist standardmaessig aus.
authentication_policy   = caching_sha2_password

character-set-server    = utf8mb4
collation-server        = utf8mb4_0900_ai_ci
default-storage-engine  = INNODB

innodb_buffer_pool_size = ${pool}M
innodb_flush_log_at_trx_commit = 1
max_connections         = 151
max_allowed_packet      = 64M

log-error               = "$(& $fw (Join-Path $logDir 'mysql-error.log'))"
slow_query_log          = 1
slow_query_log_file     = "$(& $fw (Join-Path $logDir 'mysql-slow.log'))"
long_query_time         = 5

[client]
port                    = $($p.Port)
default-character-set   = utf8mb4
"@
    [System.IO.File]::WriteAllText($p.Ini, $ini, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "my.ini geschrieben: $($p.Ini)" 'Ok'
    Write-Log ("bind-address = {0}, Port {1}, InnoDB-Buffer-Pool {2} MB" -f $plan.Bind, $p.Port, $pool)
}

function Initialize-MySqlData {
    Write-Log 'Datenverzeichnis initialisieren' 'Step'
    $p = Get-MySqlPaths

    if (Test-MySqlDataInitialized) {
        Write-Log 'Das Datenverzeichnis ist bereits initialisiert - Schritt wird übersprungen.' 'Warn'
        Write-Log 'Vorhandene Datenbanken bleiben erhalten.' 'Info'
        return
    }
    if (-not (Test-Path $p.Data)) { New-Item -ItemType Directory -Path $p.Data -Force | Out-Null }

    # --initialize-insecure legt root@localhost ohne Passwort an. Das Passwort
    # setzen wir gleich danach über eine lokale Verbindung; so taucht es nie
    # in einer Kommandozeile auf.
    $code = Start-ProcessWithUi -FilePath $p.Mysqld -NoNewWindow -Activity 'Datenverzeichnis wird initialisiert' -ArgumentList @(
        "--defaults-file=`"$($p.Ini)`"", '--initialize-insecure'
    )

    # Entscheidend ist das Ergebnis, nicht der Rückgabewert.
    if (-not (Test-MySqlDataInitialized)) {
        Write-MySqlErrorLogTail
        throw "Das Datenverzeichnis konnte nicht angelegt werden (Exitcode '$code'). Der Auszug aus mysql-error.log steht im Protokoll."
    }
    if ($code -ne 0) {
        Write-Log "mysqld meldete Exitcode $code, das Datenverzeichnis wurde aber korrekt angelegt." 'Warn'
        Write-MySqlErrorLogTail -Lines 10
    }
    Write-Log 'Datenverzeichnis initialisiert.' 'Ok'
}

function Register-MySqlService {
    Write-Log 'Windows-Dienst registrieren' 'Step'
    $p = Get-MySqlPaths

    if (Get-Service -Name $p.Service -ErrorAction SilentlyContinue) {
        Write-Log "Dienst '$($p.Service)' existiert bereits." 'Info'
    } else {
        $code = Start-ProcessWithUi -FilePath $p.Mysqld -NoNewWindow -Activity 'Dienst wird registriert' -ArgumentList @(
            '--install', $p.Service, "--defaults-file=`"$($p.Ini)`""
        )
        if ($code -ne 0) { throw "mysqld --install endete mit Exitcode $code." }
        Write-Log "Dienst '$($p.Service)' registriert (Autostart)." 'Ok'
    }

    Set-Service -Name $p.Service -StartupType Automatic
    $svc = Get-Service -Name $p.Service
    if ($svc.Status -ne 'Running') { Start-Service -Name $p.Service }

    # Warten, bis der Server Verbindungen annimmt
    $ok = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 2
        Invoke-UiPump
        Set-Status "Warte auf MySQL-Dienst ... ($i)"
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $t.Connect('127.0.0.1', $p.Port)
            $t.Close(); $ok = $true; break
        } catch { }
    }
    if (-not $ok) { throw "Der Dienst '$($p.Service)' nimmt auf Port $($p.Port) keine Verbindungen an." }
    Write-Log "Dienst läuft, Port $($p.Port) antwortet." 'Ok'
}

<#
 Führt SQL aus, ohne dass Passwörter in einer Kommandozeile landen.
 Ohne -RootPassword wird die passwortlose Erstverbindung genutzt.
#>
function Invoke-MySqlScript {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [string]$RootPassword
    )
    $p = Get-MySqlPaths
    $tmp = Join-Path $env:TEMP ('mysql_{0}.cnf' -f [guid]::NewGuid().ToString('N'))
    try {
        if ($RootPassword) {
            $cnf = "[client]`r`nuser=root`r`npassword=`"$RootPassword`"`r`nhost=127.0.0.1`r`nport=$($p.Port)`r`n"
        } else {
            $cnf = "[client]`r`nuser=root`r`nhost=127.0.0.1`r`nport=$($p.Port)`r`n"
        }
        [System.IO.File]::WriteAllText($tmp, $cnf, (New-Object System.Text.UTF8Encoding($false)))

        $r = Invoke-ExeCapture -FilePath $p.Mysql -ArgumentList @("`"--defaults-extra-file=$tmp`"", '--batch', '--silent') -StdIn $Sql -TimeoutSec 120
        if ($r.ExitCode -ne 0) { throw "mysql.exe meldet Fehler: $($r.Lines -join ' ')" }
        return $r.Lines
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Set-MySqlRootPassword {
    param([Parameter(Mandatory)][string]$Password)
    Write-Log 'root-Passwort setzen' 'Step'
    $esc = $Password -replace "'", "''"
    # root bleibt bewusst auf localhost: auch bei offenem Port keine
    # Administratoranmeldung aus dem Netz.
    $sql = @"
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$esc';
FLUSH PRIVILEGES;
"@
    try {
        Invoke-MySqlScript -Sql $sql | Out-Null
        Write-Log 'root-Passwort gesetzt (Konto bleibt auf localhost beschränkt).' 'Ok'
        return
    } catch {
        Write-Log 'Anmeldung ohne Passwort nicht möglich - offenbar ist bereits eines vergeben.' 'Info'
    }
    # Zweiter Versuch mit dem eingetragenen Passwort: macht den Durchlauf
    # wiederholbar, falls das Passwort schon früher gesetzt wurde.
    try {
        Invoke-MySqlScript -Sql $sql -RootPassword $Password | Out-Null
        Write-Log 'Das eingetragene root-Passwort war bereits gültig und wurde bestätigt.' 'Ok'
    } catch {
        Write-MySqlErrorLogTail -Lines 15
        throw ("Das root-Passwort konnte nicht gesetzt werden. Entweder ist bereits ein anderes " +
               "Passwort vergeben - dann dieses unter 'Erweiterte Optionen > MySQL' eintragen - oder der Dienst antwortet nicht. " +
               "Alternativ das Datenverzeichnis '$((Get-MySqlPaths).Data)' löschen und neu einrichten.")
    }
}

# Alle anzulegenden Benutzer: Anwendungs-DB von der einfachen Seite plus die
# Liste aus "Erweiterte Optionen".
function Get-MySqlUserPlan {
    $rows = New-Object System.Collections.Generic.List[object]
    if ($script:Cfg.AppDbEnabled) {
        $rows.Add([pscustomobject]@{
            User = ([string]$script:Cfg.AppDbUser).Trim()
            Pass = [string]$script:Cfg.AppDbPass
            Host = 'localhost'
            Db   = ([string]$script:Cfg.AppDbName).Trim()
        })
    }
    foreach ($u in @($script:Cfg.MyUsers)) {
        if (-not $u) { continue }
        $h = [string]$u.Host; if (-not $h) { $h = 'localhost' }
        $rows.Add([pscustomobject]@{
            User = ([string]$u.User).Trim()
            Pass = [string]$u.Pass
            Host = $h.Trim()
            Db   = ([string]$u.Db).Trim()
        })
    }
    return $rows.ToArray()
}

# Liefert Fehlertext oder $null
function Test-MySqlUserPlan {
    foreach ($r in (Get-MySqlUserPlan)) {
        $err = Test-MySqlUserName -Name $r.User
        if ($err) { return $err }
        if ([string]::IsNullOrWhiteSpace($r.Pass)) { return "Benutzer '$($r.User)': Passwort fehlt." }
        if ($r.Db) { $err = Test-MySqlDbName -Name $r.Db; if ($err) { return $err } }
    }
    return $null
}

function New-MySqlUsers {
    param([Parameter(Mandatory)][string]$RootPassword)
    $rows = Get-MySqlUserPlan
    if ($rows.Count -eq 0) { return }

    Write-Log 'Benutzer anlegen' 'Step'
    $err = Test-MySqlUserPlan
    if ($err) { throw $err }

    foreach ($r in $rows) {
        $pw = $r.Pass -replace "'", "''"
        $sql = "CREATE USER IF NOT EXISTS '$($r.User)'@'$($r.Host)' IDENTIFIED WITH caching_sha2_password BY '$pw';`r`n"
        # Passwort auch setzen, falls der Benutzer bereits existierte (Wiederholbarkeit)
        $sql += "ALTER USER '$($r.User)'@'$($r.Host)' IDENTIFIED WITH caching_sha2_password BY '$pw';`r`n"
        if ($r.Db) {
            $sql += "CREATE DATABASE IF NOT EXISTS ``$($r.Db)`` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;`r`n"
            $sql += "GRANT ALL PRIVILEGES ON ``$($r.Db)``.* TO '$($r.User)'@'$($r.Host)';`r`n"
        }
        $sql += "FLUSH PRIVILEGES;`r`n"
        Invoke-MySqlScript -Sql $sql -RootPassword $RootPassword | Out-Null
        if ($r.Db) { Write-Log "Benutzer '$($r.User)'@'$($r.Host)' angelegt, Vollzugriff auf '$($r.Db)'." 'Ok' }
        else       { Write-Log "Benutzer '$($r.User)'@'$($r.Host)' angelegt (noch ohne Rechte)." 'Ok' }
    }
}

function Set-MySqlFirewallRule {
    $plan = Get-MySqlFirewallPlan
    $p    = Get-MySqlPaths
    Write-Log 'Firewall' 'Step'

    if (-not $plan.Needed) {
        Write-Log 'Nur lokaler Zugriff gewählt - es wird keine Firewallregel angelegt.' 'Ok'
        return
    }

    $name = "MySQL Server $($p.Service) (TCP $($p.Port))"
    $existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Firewallregel '$name' existiert bereits." 'Info'
        return
    }
    New-NetFirewallRule -DisplayName $name -Description 'Vom PHP + IIS Setup-Assistenten angelegt' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p.Port `
        -Profile ($plan.Profile -split ',') -Program $p.Mysqld | Out-Null
    Write-Log "Firewallregel angelegt: $name (Profile: $($plan.Profile))" 'Ok'
    Write-Log 'Bei Einsatz einer Fremd-Firewall die Angaben aus "Erweiterte Optionen > MySQL" übernehmen.' 'Warn'
}

function Install-MySqlWorkbench {
    Write-Log 'MySQL Workbench installieren' 'Step'
    $wbExe = Join-Path $env:ProgramFiles 'MySQL\MySQL Workbench 8.0\MySQLWorkbench.exe'
    if (Test-Path $wbExe) {
        Write-Log 'MySQL Workbench ist bereits installiert - übersprungen.' 'Ok'
        return
    }
    $url = ([string]$script:Cfg.WbUrl).Trim()
    $msi = Join-Path $env:TEMP (Split-Path $url -Leaf)
    Write-Log "Quelle: $url"
    Get-FileWithUi -Url $url -OutFile $msi -Activity 'MySQL Workbench wird geladen'

    $log = Join-Path $script:LogDir 'workbench-msi.log'
    $code = Start-ProcessWithUi -FilePath 'msiexec.exe' -Activity 'MySQL Workbench wird installiert' -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart', '/lv', "`"$log`""
    )
    if ($code -in @(0, 3010)) { Write-Log 'MySQL Workbench installiert.' 'Ok'; if ($code -eq 3010) { $script:RebootNeeded = $true } }
    else { Write-Log "Workbench-Installation endete mit Exitcode $code. Details: $log" 'Warn' }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
}

function Save-MySqlCredentials {
    param([Parameter(Mandatory)][string]$Password)
    $p    = Get-MySqlPaths
    $file = Join-Path $script:LogDir 'mysql-zugangsdaten.txt'
    $users = Get-MySqlUserPlan
    $userText = ''
    foreach ($u in $users) {
        $userText += "`r`nBenutzer    : $($u.User)@$($u.Host)`r`nPasswort    : $($u.Pass)`r`n"
        if ($u.Db) { $userText += "Datenbank   : $($u.Db)  (Vollzugriff)`r`n" }
    }
    if ($userText) { $userText = "`r`n--- Weitere Benutzer ---`r`n" + $userText }

    $text = @"
MySQL 8.4 LTS - Zugangsdaten
Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
Server:   $env:COMPUTERNAME

Host        : 127.0.0.1
Port        : $($p.Port)
Dienst      : $($p.Service)
Benutzer    : root  (nur von localhost aus nutzbar)
Passwort    : $Password
$userText
my.ini      : $($p.Ini)
Datenordner : $($p.Data)

Diese Datei enthält Klartextpasswörter. Nach dem Übertragen in einen
Passwortspeicher bitte löschen.
"@
    [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))

    # Zugriff auf Administratoren und SYSTEM beschränken
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $id, 'FullControl', 'Allow')))
        }
        $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $file -AclObject $acl
    } catch {
        Write-Log "Rechte auf der Zugangsdatendatei konnten nicht eingeschränkt werden: $($_.Exception.Message)" 'Warn'
    }
    Write-Log "Zugangsdaten gespeichert: $file" 'Ok'
    Write-Log 'Die Datei enthält Passwörter im Klartext - nach dem Übertragen löschen.' 'Warn'
    return $file
}

function Invoke-MySqlInstallPhase {
    Write-Log '=== MySQL 8.4 LTS: Installation ===' 'Step'
    $pw = [string]$script:Cfg.MyRootPw
    if ([string]::IsNullOrWhiteSpace($pw)) { throw 'Es ist kein root-Passwort gesetzt.' }
    if ($pw.Length -lt 8) { throw 'Das root-Passwort muss mindestens 8 Zeichen haben.' }
    $err = Test-MySqlUserPlan
    if ($err) { throw $err }
    Install-MySqlMsi
}

function Invoke-MySqlConfigurePhase {
    Write-Log '=== MySQL 8.4 LTS: Einrichtung ===' 'Step'
    $pw = [string]$script:Cfg.MyRootPw
    New-MySqlIni
    Initialize-MySqlData
    Register-MySqlService
    Set-MySqlRootPassword -Password $pw
    New-MySqlUsers -RootPassword $pw
    Set-MySqlFirewallRule
    $script:Result.CredFile = Save-MySqlCredentials -Password $pw

    $ver = (Invoke-MySqlScript -Sql 'SELECT VERSION();' -RootPassword $pw) -join ''
    $script:Result.MySqlVersion = $ver
    $script:Result.MySqlOk = $true
    Write-Log "MySQL antwortet mit Version $ver." 'Ok'
    Write-Log 'MySQL-Einrichtung abgeschlossen.' 'Ok'
}

# ==============================================================================
# 14) Gesamtablauf (ein Klick auf "Installieren" arbeitet alle Schritte ab)
# ==============================================================================

# ==============================================================================
# 14b) Python (optional)
# ==============================================================================

<#
 Sucht eine vorhandene systemweite Python-Installation über die Registry
 (HKLM\SOFTWARE\Python\PythonCore\<version>\InstallPath). Liefert die
 neueste Version mit Pfad oder $null.
#>
function Get-PythonInstallInfo {
    $best = $null
    foreach ($root in @('HKLM:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore')) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $verText = $k.PSChildName -replace '-32$|-64$', ''
            $ver = $null
            if (-not [version]::TryParse($verText, [ref]$ver)) { continue }
            $inst = (Get-ItemProperty -Path (Join-Path $k.PSPath 'InstallPath') -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            if (-not $inst) { continue }
            $exe = Join-Path $inst 'python.exe'
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            if (-not $best -or $ver -gt $best.Version) {
                $best = [pscustomobject]@{ Version = $ver; Path = $inst.TrimEnd('\'); Exe = $exe }
            }
        }
    }
    return $best
}

<#
 Ermittelt Download-URL und Version des Python-Installers.
 Ist unter "Erweiterte Optionen" eine URL eingetragen, wird sie verwendet;
 sonst wird die Startseite von python.org/downloads gelesen, deren
 Download-Knopf immer auf den aktuellen Windows-x64-Installer zeigt:
   https://www.python.org/ftp/python/3.13.7/python-3.13.7-amd64.exe
#>
function Get-PythonDownloadInfo {
    $own = ([string]$script:Cfg.PyUrl).Trim()
    if ($own) {
        $ver = $null
        if ($own -match 'python-(\d+\.\d+\.\d+)') { $ver = [version]$Matches[1] }
        return [pscustomobject]@{ Url = $own; Version = $ver }
    }
    $res = Invoke-LongRunning -Activity 'Aktuelle Python-Version wird ermittelt' -ArgumentList @('https://www.python.org/downloads/') -ScriptBlock {
        param($u)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference    = 'SilentlyContinue'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        $html = (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30).Content
        $m = [regex]::Match($html, 'https://www\.python\.org/ftp/python/(\d+\.\d+\.\d+)/python-\1-amd64\.exe')
        if (-not $m.Success) { throw 'Auf python.org/downloads wurde kein Windows-x64-Installer gefunden.' }
        @{ Url = $m.Value; Version = $m.Groups[1].Value }
    }
    return [pscustomobject]@{ Url = [string]$res.Url; Version = [version]$res.Version }
}

<#
 Installiert Python systemweit. Der offizielle Installer übernimmt mit
 PrependPath=1 auch den PATH-Eintrag (Programmordner und Scripts-Ordner für
 pip); zur Sicherheit wird der Eintrag danach kontrolliert und notfalls über
 Add-ToMachinePath nachgezogen. Include_test=0 spart die Testsuite.
#>
function Invoke-InstallPython {
    Write-Log 'Python (optional)' 'Step'

    $info = Get-PythonDownloadInfo
    Write-Log "Quelle: $($info.Url)"

    $have = Get-PythonInstallInfo
    if ($have -and $info.Version -and $have.Version -ge $info.Version) {
        Write-Log "Python $($have.Version) ist bereits installiert ($($have.Path)) - Installation wird übersprungen." 'Ok'
    } else {
        if ($have) { Write-Log "Vorhandene Python-Version $($have.Version) wird auf $($info.Version) aktualisiert." 'Info' }
        $exe = Join-Path $env:TEMP (Split-Path $info.Url -Leaf)
        Get-FileWithUi -Url $info.Url -OutFile $exe -Activity 'Python wird geladen'
        Write-Log ("SHA256: {0}" -f (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash)

        $code = Start-ProcessWithUi -FilePath $exe -Activity 'Python wird installiert' -ArgumentList @(
            '/quiet',
            'InstallAllUsers=1',    # systemweit nach C:\Program Files\PythonXY
            'PrependPath=1',        # PATH-Eintrag (Maschine) durch den Installer
            'Include_test=0'        # Testsuite weglassen
        )
        switch ($code) {
            0       { Write-Log 'Python installiert.' 'Ok' }
            3010    { Write-Log 'Python installiert. Windows meldet: Neustart erforderlich.' 'Warn'; $script:RebootNeeded = $true }
            1602    { throw 'Die Python-Installation wurde abgebrochen.' }
            default { throw "Python-Installer meldet Exitcode $code (Details: %TEMP%\Python*.log)." }
        }
    }

    # Kontrolle: Installation auffindbar und PATH-Einträge vorhanden?
    $py = Get-PythonInstallInfo
    if (-not $py) { throw 'Python wurde installiert, ist aber in der Registry nicht auffindbar - bitte Protokoll prüfen.' }

    $scripts = Join-Path $py.Path 'Scripts'
    Add-ToMachinePath -Dirs @($py.Path, $scripts)

    $v = Invoke-ExeCapture -FilePath $py.Exe -ArgumentList @('--version')
    if ($v.ExitCode -eq 0 -and $v.Lines.Count -gt 0) {
        Write-Log ([string]$v.Lines[0]) 'Ok'
        $script:Result.PyVersion = ([string]$v.Lines[0]) -replace '^Python\s+', ''
    }
    $pip = Invoke-ExeCapture -FilePath $py.Exe -ArgumentList @('-m', 'pip', '--version')
    if ($pip.ExitCode -eq 0 -and $pip.Lines.Count -gt 0) {
        Write-Log ([string]$pip.Lines[0]) 'Ok'
    } else {
        Write-Log 'pip antwortet nicht - bitte im Protokoll prüfen.' 'Warn'
    }
    $script:Result.PyOk   = ($v.ExitCode -eq 0)
    $script:Result.PyPath = $py.Path
}

function Get-StepPlan {
    $steps = New-Object System.Collections.Generic.List[object]
    if ($script:Cfg.InstallWebStack) {
        $steps.Add(@{ Key = 'vc';      Title = 'Visual C++ Runtime';                      Action = { Invoke-InstallVcRedist } })
        $steps.Add(@{ Key = 'iis';     Title = 'Webserver (IIS) einrichten';              Action = { Invoke-InstallIis } })
        $steps.Add(@{ Key = 'rewrite'; Title = 'URL Rewrite Module';                      Action = { Invoke-InstallRewrite } })
        $steps.Add(@{ Key = 'php';     Title = 'PHP herunterladen und entpacken';         Action = { Invoke-InstallPhpStep } })
        $steps.Add(@{ Key = 'cfg';     Title = 'PHP konfigurieren (php.ini, IIS)';        Action = { Invoke-ConfigurePhase } })
        $steps.Add(@{ Key = 'verify';  Title = 'Funktionstest';                           Action = { Invoke-VerifyPhase } })
    }
    if ($script:Cfg.InstallMySql) {
        $steps.Add(@{ Key = 'my';      Title = 'MySQL Server installieren';               Action = { Invoke-MySqlInstallPhase } })
        $steps.Add(@{ Key = 'mycfg';   Title = 'MySQL einrichten (Dienst, Passwort, Benutzer)'; Action = { Invoke-MySqlConfigurePhase } })
        if ($script:Cfg.InstallWorkbench) {
            $steps.Add(@{ Key = 'wb';  Title = 'MySQL Workbench';                         Action = { Install-MySqlWorkbench } })
        }
    }
    if ($script:Cfg.InstallPython) {
        $steps.Add(@{ Key = 'py';      Title = 'Python installieren';                     Action = { Invoke-InstallPython } })
    }
    return , $steps.ToArray()
}

function Invoke-FullSetup {
    $script:Result = @{
        PhpVersion = $null; PhpOk = $false; HttpOk = $false; PhpModules = @()
        MySqlVersion = $null; MySqlOk = $false; CredFile = $null
        PyVersion = $null; PyOk = $false; PyPath = $null
        Error = $null; FailedStep = $null; Success = $false
    }
    $plan = Get-StepPlan
    if ($plan.Count -eq 0) { throw 'Es ist nichts zur Installation ausgewählt.' }

    Initialize-StepList -Plan $plan
    Write-Log '=== Installation gestartet ===' 'Step'
    Write-Log ("Ausgewählte Schritte: {0}" -f (($plan | ForEach-Object { $_.Title }) -join ', '))

    $n = $plan.Count; $i = 0
    foreach ($s in $plan) {
        $i++
        Set-StepState -Key $s.Key -State 'Running'
        Set-OverallProgress -Done ($i - 1) -Total $n
        Set-Status "Schritt $i von $n - $($s.Title)"
        try {
            & $s.Action
            Set-StepState -Key $s.Key -State 'Done'
        } catch {
            Set-StepState -Key $s.Key -State 'Failed'
            $script:Result.Error      = $_.Exception.Message
            $script:Result.FailedStep = $s.Title
            Write-Log $_.Exception.Message 'Error'
            Write-Log "Abgebrochen bei '$($s.Title)'. Vollständiges Protokoll: $script:LogFile" 'Error'
            throw
        }
    }
    Set-OverallProgress -Done $n -Total $n
    $script:Result.Success = $true
    Write-Log '=== Installation abgeschlossen ===' 'Ok'
}

# ==============================================================================
# 15) Oberfläche: Hilfsfunktionen und Farben
# ==============================================================================

$script:ColDark   = [System.Drawing.Color]::FromArgb(28, 42, 58)
$script:ColDarkFg = [System.Drawing.Color]::FromArgb(160, 180, 200)
$script:ColCard   = [System.Drawing.Color]::FromArgb(246, 248, 250)
$script:ColAccent = [System.Drawing.Color]::FromArgb(0, 99, 177)
$script:ColGray   = [System.Drawing.Color]::FromArgb(110, 110, 110)
$script:ColOk     = [System.Drawing.Color]::FromArgb(30, 130, 60)
$script:ColWarn   = [System.Drawing.Color]::FromArgb(190, 110, 0)
$script:ColErr    = [System.Drawing.Color]::FromArgb(190, 40, 40)

$fontUi    = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontBig   = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fontHead  = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$fontMono  = New-Object System.Drawing.Font('Consolas', 9)
$fontSym   = New-Object System.Drawing.Font('Segoe UI Symbol', 10)

function New-Ctl {
    param($Type, $Parent, [int]$X, [int]$Y, [int]$W = 0, [int]$H = 0, [string]$Text = '')
    $c = New-Object $Type
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $c.Width = $W }
    if ($H -gt 0) { $c.Height = $H }
    if ($Text)    { $c.Text = $Text }
    $Parent.Controls.Add($c)
    return $c
}

function New-Label {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text, $Color = $null, $Font = $null)
    $l = New-Ctl System.Windows.Forms.Label $Parent $X $Y $W $H $Text
    if ($Color) { $l.ForeColor = $Color }
    if ($Font)  { $l.Font = $Font }
    return $l
}

function New-Card {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H)
    $p = New-Ctl System.Windows.Forms.Panel $Parent $X $Y $W $H
    $p.BackColor   = $script:ColCard
    $p.BorderStyle = 'FixedSingle'
    $p.Anchor      = 'Top,Left,Right'
    return $p
}

function Add-RtfText {
    param($Rtb, [string]$Text, [switch]$Bold, $Color = $null, [float]$Size = 0, [switch]$Mono)
    $Rtb.SelectionStart  = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $fam = if ($Mono) { 'Consolas' } else { 'Segoe UI' }
    $sz  = if ($Size -gt 0) { $Size } else { 9.5 }
    $st  = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $Rtb.SelectionFont  = New-Object System.Drawing.Font($fam, $sz, $st)
    $Rtb.SelectionColor = if ($Color) { $Color } else { [System.Drawing.Color]::FromArgb(40, 40, 40) }
    $Rtb.AppendText($Text)
}

function Show-Info {
    param([string]$Text, [string]$Title = $script:AppTitle)
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'OK', 'Information') | Out-Null
}
function Show-Warn {
    param([string]$Text, [string]$Title = $script:AppTitle)
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'OK', 'Warning') | Out-Null
}
function Show-Error {
    param([string]$Text, [string]$Title = $script:AppTitle)
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'OK', 'Error') | Out-Null
}
function Ask-YesNo {
    param([string]$Text, [string]$Title = $script:AppTitle)
    ([System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'YesNo', 'Question') -eq 'Yes')
}

# ==============================================================================
# 16) Hauptfenster
# ==============================================================================

# Ein Ort für alle Maße. Kopf (64) + Fußleiste (56) + Statuszeile (24) = 144,
# dazu die Innenabstände des Inhaltsbereichs (18 oben, 10 unten).
$script:FormW = 940
$script:FormH = 700
$pw = $script:FormW - 48    # nutzbare Breite einer Seite
$ph = $script:FormH - 144 - 28   # nutzbare Höhe einer Seite

# Alles ab hier läuft in einem Schutzblock: ein unerwarteter Fehler wird mit
# Zeilennummer angezeigt und protokolliert statt nur mit einer nackten Meldung
# (gerade in der EXE-Variante sonst schwer zu finden).
try {

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text            = $script:AppTitle
$script:Form.ClientSize      = New-Object System.Drawing.Size($script:FormW, $script:FormH)
$script:Form.StartPosition   = 'CenterScreen'

<#
 Symbol für Fenster und Taskleiste.
 In der kompilierten EXE wird das mit PS2EXE eingebettete Symbol aus der
 eigenen Datei gelesen; beim Start als .ps1 wird eine daneben liegende
 setup.ico verwendet, sofern vorhanden. Schlägt beides fehl, bleibt es beim
 Standardsymbol - kein Grund für einen Abbruch.
#>
try {
    if ($script:IsCompiled) {
        $script:AppIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:SelfPath)
    } else {
        $icoPath = Join-Path (Split-Path -Parent $script:SelfPath) 'setup.ico'
        if (Test-Path -LiteralPath $icoPath) { $script:AppIcon = New-Object System.Drawing.Icon($icoPath) }
    }
    if ($script:AppIcon) { $script:Form.Icon = $script:AppIcon }
} catch { }
$script:Form.Font            = $fontUi
$script:Form.BackColor       = [System.Drawing.Color]::White
$script:Form.MaximizeBox     = $true
# Positionen sind für 96 dpi gesetzt; bei höherer Skalierung rechnet WinForms um.
$script:Form.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
$script:Form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)

# --- Kopfbereich mit Schrittanzeige ------------------------------------------
$header = New-Object System.Windows.Forms.Panel
# Größe VOR dem Hinzufügen der Kindelemente setzen: WinForms berechnet die
# Anker (Anchor = Right/Bottom) aus der Größe, die das übergeordnete Element
# in dem Moment hat. Ein noch "leeres" Panel ist 200x100 gross - rechts
# verankerte Schaltflächen landen dann ausserhalb des sichtbaren Bereichs.
$header.Size      = New-Object System.Drawing.Size($script:FormW, 64)
$header.Dock      = 'Top'
$header.Height    = 64
$header.BackColor = $script:ColDark

$lblTitle = New-Label $header 20 11 420 26 $script:AppTitle ([System.Drawing.Color]::White) $fontTitle
$lblSub   = New-Label $header 22 38 500 18 'IIS · PHP · MySQL  -  Windows Server 2022 / 2025' $script:ColDarkFg

$script:StepNames  = @('1  Start', '2  Auswahl', '3  Installation', '4  Fertig')
$script:StepLabels = @()
$x = $script:FormW - 20
for ($i = $script:StepNames.Count - 1; $i -ge 0; $i--) {
    $w = 110
    $x -= $w
    $l = New-Label $header $x 22 $w 22 $script:StepNames[$i] $script:ColDarkFg $fontUi
    $l.TextAlign = 'MiddleCenter'
    $l.Anchor    = 'Top,Right'
    $script:StepLabels = @($l) + $script:StepLabels
}

# --- Inhaltsbereich mit vier Seiten --------------------------------------------
$content = New-Object System.Windows.Forms.Panel
$content.Size      = New-Object System.Drawing.Size($script:FormW, ($script:FormH - 144))
$content.Dock      = 'Fill'
$content.Padding   = New-Object System.Windows.Forms.Padding(24, 18, 24, 10)
$content.BackColor = [System.Drawing.Color]::White

function New-Page {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size    = New-Object System.Drawing.Size($pw, $ph)
    $p.Dock    = 'Fill'
    $p.Visible = $false
    $p.BackColor = [System.Drawing.Color]::White
    $content.Controls.Add($p)
    return $p
}
$script:PnlWelcome = New-Page
$script:PnlSelect  = New-Page
$script:PnlInstall = New-Page
$script:PnlFinish  = New-Page
$script:Pages = @{ welcome = $script:PnlWelcome; select = $script:PnlSelect; install = $script:PnlInstall; finish = $script:PnlFinish }

# ---------- Seite 1: Start / Systemprüfung ------------------------------------
New-Label $script:PnlWelcome 0 0 600 32 'Willkommen' $script:ColDark $fontHead | Out-Null
New-Label $script:PnlWelcome 0 36 $pw 40 ('Dieser Assistent richtet auf diesem Server alles ein, was für den Betrieb von PHP-Anwendungen nötig ist: ' +
    'den Webserver (IIS), PHP und auf Wunsch den Datenbankserver MySQL. Alle Komponenten werden automatisch aus ' +
    'dem Internet geladen - Sie müssen nichts vorbereiten.') $script:ColGray | Out-Null

$script:GrpPre = New-Object System.Windows.Forms.GroupBox
$script:GrpPre.Text     = ' Systemprüfung '
$script:GrpPre.Location = New-Object System.Drawing.Point(0, 84)
$script:GrpPre.Size     = New-Object System.Drawing.Size($pw, 240)
$script:GrpPre.Anchor   = 'Top,Left,Right'
$script:PnlWelcome.Controls.Add($script:GrpPre)

$script:LvPreflight = New-Object System.Windows.Forms.ListView
$script:LvPreflight.Location      = New-Object System.Drawing.Point(12, 24)
$script:LvPreflight.Size          = New-Object System.Drawing.Size(($pw - 24), 202)
$script:LvPreflight.Anchor        = 'Top,Left,Right'
$script:LvPreflight.Scrollable    = $true
$script:LvPreflight.View          = 'Details'
$script:LvPreflight.HeaderStyle   = 'None'
$script:LvPreflight.FullRowSelect = $true
$script:LvPreflight.BorderStyle   = 'None'
$script:LvPreflight.MultiSelect   = $false
$script:LvPreflight.Font          = $fontUi
[void]$script:LvPreflight.Columns.Add('', 34)
[void]$script:LvPreflight.Columns.Add('Prüfung', 140)
[void]$script:LvPreflight.Columns.Add('Ergebnis', ($pw - 24 - 34 - 140 - 8))
$script:GrpPre.Controls.Add($script:LvPreflight)

$script:BtnRecheck = New-Ctl System.Windows.Forms.Button $script:PnlWelcome 0 340 160 30 'Prüfung wiederholen'
$script:LblWelcomeNote = New-Label $script:PnlWelcome 176 345 ($pw - 176) 40 '' $script:ColGray
$script:LblWelcomeNote.Anchor = 'Top,Left,Right'

$script:LblWelcomeHint = New-Label $script:PnlWelcome 0 388 $pw 40 ('Hinweis: Voraussetzung ist ein Windows Server mit grafischer Oberfläche, Administratorrechte und Internetzugang. ' +
    'Der Assistent kann jederzeit erneut ausgeführt werden - vorhandene Installationen werden erkannt.') $script:ColGray
$script:LblWelcomeHint.Anchor = 'Top,Left,Right'

# ---------- Seite 2: Auswahl --------------------------------------------------
New-Label $script:PnlSelect 0 0 700 32 'Was soll installiert werden?' $script:ColDark $fontHead | Out-Null
New-Label $script:PnlSelect 0 36 $pw 20 'Die empfohlene Auswahl ist bereits gesetzt. Für die meisten Server muss hier nichts geändert werden.' $script:ColGray | Out-Null

# Karte 1: Webserver + PHP
$card1 = New-Card $script:PnlSelect 0 62 $pw 146
$script:ChkWeb = New-Ctl System.Windows.Forms.CheckBox $card1 14 12 400 24 'Webserver (IIS) und PHP'
$script:ChkWeb.Font = $fontBig
$script:ChkWeb.ForeColor = $script:ColDark
New-Label $card1 34 40 ($pw - 60) 34 ('Internet Information Services mit FastCGI, URL Rewrite 2.1, Visual C++ Runtime und PHP (64-Bit) nach ' +
    "$script:PhpRoot. Die php.ini wird mit sinnvollen Standardwerten eingerichtet (OPcache, cURL-Zertifikate, Upload-Limits).") $script:ColGray | Out-Null
New-Label $card1 34 84 90 22 'PHP-Version:' | Out-Null
$script:CboPhp = New-Ctl System.Windows.Forms.ComboBox $card1 126 81 400 24
$script:CboPhp.DropDownStyle = 'DropDownList'
$script:CboPhpItems = @()   # parallel zu den Einträgen: @{ Display; Url }
$script:LblPhpStatus = New-Label $card1 34 112 ($pw - 60) 22 'Versionsliste wird geladen ...' $script:ColGray
$script:LblPhpStatus.Anchor = 'Top,Left,Right'

# Karte 2: MySQL
$card2 = New-Card $script:PnlSelect 0 216 $pw 212
$script:ChkMy = New-Ctl System.Windows.Forms.CheckBox $card2 14 12 400 24 'MySQL Server 8.4 LTS'
$script:ChkMy.Font = $fontBig
$script:ChkMy.ForeColor = $script:ColDark
New-Label $card2 34 40 ($pw - 60) 34 ('Datenbankserver als Windows-Dienst mit Autostart, nur von diesem Server aus erreichbar. Das root-Passwort wird ' +
    'automatisch erzeugt, am Ende angezeigt und in einer geschützten Datei gespeichert.') $script:ColGray | Out-Null
$script:ChkWb = New-Ctl System.Windows.Forms.CheckBox $card2 34 80 600 22 'MySQL Workbench mitinstallieren (grafisches Verwaltungswerkzeug)'
$script:ChkAppDb = New-Ctl System.Windows.Forms.CheckBox $card2 34 106 600 22 'Datenbank und Benutzer für die Anwendung anlegen (falls benötigt):'
New-Label $card2 56 136 80 22 'Datenbank:' | Out-Null
$script:TxtAppDb   = New-Ctl System.Windows.Forms.TextBox $card2 136 133 150 24
New-Label $card2 300 136 70 22 'Benutzer:' | Out-Null
$script:TxtAppUser = New-Ctl System.Windows.Forms.TextBox $card2 370 133 150 24
New-Label $card2 534 136 70 22 'Passwort:' | Out-Null
$script:TxtAppPw   = New-Ctl System.Windows.Forms.TextBox $card2 604 133 150 24
$script:TxtAppPw.Font = $fontMono
$script:BtnAppGen  = New-Ctl System.Windows.Forms.Button $card2 760 132 70 26 'Neu'
foreach ($c in @($script:TxtAppDb, $script:TxtAppUser)) { $c.CharacterCasing = 'Lower' }
$script:LblAppHint = New-Label $card2 56 162 ($pw - 80) 20 'Kleinbuchstaben, Ziffern und Unterstrich. Der Benutzer erhält Vollzugriff auf genau diese Datenbank.' $script:ColGray
$script:LblMyStatus = New-Label $card2 34 184 ($pw - 60) 22 '' $script:ColWarn
$script:LblMyStatus.Anchor = 'Top,Left,Right'

# --- Karte 3: Python (optional) ------------------------------------------------
$card3 = New-Card $script:PnlSelect 0 436 $pw 54
$script:ChkPy = New-Ctl System.Windows.Forms.CheckBox $card3 16 8 620 22 'Python installieren (optional)'
$script:ChkPy.Font = $fontBig
New-Label $card3 36 30 ($pw - 60) 18 'Neueste Version 3.x von python.org, systemweit, inklusive pip und PATH-Eintrag - nur nötig, wenn zusätzlich Python-Skripte laufen sollen.' $script:ColGray | Out-Null

$script:LblAdvHint = New-Label $script:PnlSelect 0 498 $pw 16 'Pfade, Limits, PHP-Extensions, Netzwerkfreigabe und mehr: "Erweiterte Optionen ..." links unten - für den Normalfall nicht nötig.' $script:ColGray
$script:LblAdvHint.Anchor = 'Top,Left,Right'
$script:LblAdvState = New-Label $script:PnlSelect 0 ($ph - 18) $pw 18 '' $script:ColAccent
$script:LblAdvState.Anchor = 'Left,Right,Bottom'

# ---------- Seite 3: Installation ---------------------------------------------
$script:LblInstallHead = New-Label $script:PnlInstall 0 0 700 32 'Installation läuft ...' $script:ColDark $fontHead
$script:LblCurrent = New-Label $script:PnlInstall 0 36 $pw 20 'Bitte warten. Das Fenster bleibt bedienbar, die Installation läuft im Hintergrund weiter.' $script:ColGray
$script:LblCurrent.Anchor = 'Top,Left,Right'

New-Label $script:PnlInstall 0 62 120 18 'Gesamtfortschritt:' $script:ColGray | Out-Null
$script:ProgressOverall = New-Ctl System.Windows.Forms.ProgressBar $script:PnlInstall 124 62 ($pw - 124) 16
$script:ProgressOverall.Anchor  = 'Top,Left,Right'
$script:ProgressOverall.Style   = 'Continuous'
New-Label $script:PnlInstall 0 84 120 18 'Aktueller Schritt:' $script:ColGray | Out-Null
$script:Progress = New-Ctl System.Windows.Forms.ProgressBar $script:PnlInstall 124 84 ($pw - 124) 16
$script:Progress.Anchor = 'Top,Left,Right'
$script:Progress.Style  = 'Marquee'
$script:Progress.MarqueeAnimationSpeed = 30

$script:LvSteps = New-Object System.Windows.Forms.ListView
$script:LvSteps.Location      = New-Object System.Drawing.Point(0, 112)
$script:LvSteps.Size          = New-Object System.Drawing.Size(330, ($ph - 112 - 76))
$script:LvSteps.Anchor        = 'Top,Left,Bottom'
$script:LvSteps.View          = 'Details'
$script:LvSteps.HeaderStyle   = 'None'
$script:LvSteps.FullRowSelect = $true
$script:LvSteps.MultiSelect   = $false
$script:LvSteps.Font          = $fontUi
$script:LvSteps.BorderStyle   = 'FixedSingle'
[void]$script:LvSteps.Columns.Add('', 30)
[void]$script:LvSteps.Columns.Add('Schritt', 290)
$script:PnlInstall.Controls.Add($script:LvSteps)

$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location    = New-Object System.Drawing.Point(342, 112)
$script:LogBox.Size        = New-Object System.Drawing.Size(($pw - 342), ($ph - 112 - 76))
$script:LogBox.Anchor      = 'Top,Left,Right,Bottom'
$script:LogBox.ReadOnly    = $true
$script:LogBox.BackColor   = [System.Drawing.Color]::FromArgb(24, 26, 30)
$script:LogBox.ForeColor   = [System.Drawing.Color]::Gainsboro
$script:LogBox.Font        = $fontMono
$script:LogBox.BorderStyle = 'None'
$script:LogBox.WordWrap    = $false
$script:LogBox.DetectUrls  = $false
$script:PnlInstall.Controls.Add($script:LogBox)

$script:LblInstallError = New-Label $script:PnlInstall 0 ($ph - 72) $pw 44 '' $script:ColErr $fontBold
$script:LblInstallError.Anchor  = 'Left,Right,Bottom'
$script:LblInstallError.Visible = $false
$script:BtnInstallLog = New-Ctl System.Windows.Forms.Button $script:PnlInstall 0 ($ph - 28) 170 28 'Protokolldatei öffnen'
$script:BtnInstallLog.Anchor  = 'Left,Bottom'
$script:BtnInstallLog.Visible = $false

# ---------- Seite 4: Fertig ---------------------------------------------------
$script:LblFinishHead = New-Label $script:PnlFinish 0 0 700 32 'Fertig!' $script:ColDark $fontHead
$script:RtbSummary = New-Object System.Windows.Forms.RichTextBox
$script:RtbSummary.Location    = New-Object System.Drawing.Point(0, 40)
$script:RtbSummary.Size        = New-Object System.Drawing.Size($pw, ($ph - 176 - 48))
$script:RtbSummary.Anchor      = 'Top,Left,Right,Bottom'
$script:RtbSummary.ReadOnly    = $true
$script:RtbSummary.BorderStyle = 'None'
$script:RtbSummary.BackColor   = [System.Drawing.Color]::White
$script:RtbSummary.DetectUrls  = $false
$script:PnlFinish.Controls.Add($script:RtbSummary)

$script:PnlPw = New-Card $script:PnlFinish 0 ($ph - 176) $pw 48
$script:PnlPw.Anchor = 'Left,Right,Bottom'
New-Label $script:PnlPw 12 14 130 22 'MySQL root-Passwort:' $script:ColDark $fontBold | Out-Null
$script:TxtRootPwShow = New-Ctl System.Windows.Forms.TextBox $script:PnlPw 146 11 300 24
$script:TxtRootPwShow.ReadOnly = $true
$script:TxtRootPwShow.Font     = $fontMono
$script:BtnCopyPw = New-Ctl System.Windows.Forms.Button $script:PnlPw 456 10 120 26 'Kopieren'
$script:BtnOpenCred = New-Ctl System.Windows.Forms.Button $script:PnlPw 584 10 200 26 'Zugangsdaten-Datei öffnen'

$script:PnlReboot = New-Card $script:PnlFinish 0 ($ph - 124) $pw 44
$script:PnlReboot.Anchor    = 'Left,Right,Bottom'
$script:PnlReboot.BackColor = [System.Drawing.Color]::FromArgb(255, 247, 225)
New-Label $script:PnlReboot 12 12 520 22 'Windows meldet: Ein Neustart ist erforderlich, damit alle Komponenten vollständig aktiv sind.' $script:ColWarn | Out-Null
$script:BtnReboot = New-Ctl System.Windows.Forms.Button $script:PnlReboot 640 8 180 26 'Jetzt neu starten ...'
$script:BtnReboot.Anchor = 'Top,Right'

$script:BtnFinishBrowser = New-Ctl System.Windows.Forms.Button $script:PnlFinish 0 ($ph - 76) 220 30 'Testseite im Browser öffnen'
$script:BtnFinishBrowser.Anchor = 'Left,Bottom'
$script:BtnFinishDelTest = New-Ctl System.Windows.Forms.Button $script:PnlFinish 230 ($ph - 76) 170 30 'Testseiten löschen'
$script:BtnFinishDelTest.Anchor = 'Left,Bottom'
$script:BtnFinishLog     = New-Ctl System.Windows.Forms.Button $script:PnlFinish 410 ($ph - 76) 170 30 'Protokoll öffnen'
$script:BtnFinishLog.Anchor = 'Left,Bottom'
$script:LblFinishNote = New-Label $script:PnlFinish 0 ($ph - 38) $pw 38 ('Die Testseite phpinfo.php zeigt die komplette Serverkonfiguration an. Nach der Kontrolle sollte sie gelöscht werden. ' +
    'Weitere Hilfsfunktionen (IIS neu starten, php.ini bearbeiten, Diagnoseseite) finden Sie unter "Werkzeuge ...".') $script:ColGray
$script:LblFinishNote.Anchor = 'Left,Right,Bottom'

# --- Fußleiste mit Schaltflächen ----------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Size      = New-Object System.Drawing.Size($script:FormW, 56)
$footer.Dock      = 'Bottom'
$footer.Height    = 56
$footer.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 248)

$script:BtnAdvanced = New-Ctl System.Windows.Forms.Button $footer 20 13 170 30 'Erweiterte Optionen ...'
$script:BtnTools    = New-Ctl System.Windows.Forms.Button $footer 198 13 120 30 'Werkzeuge ...'
$script:BtnAbout    = New-Ctl System.Windows.Forms.Button $footer 326 13 80 30 'Info ...'
$script:BtnBack     = New-Ctl System.Windows.Forms.Button $footer ($script:FormW - 20 - 110 - 8 - 150) 13 110 30 '< Zurück'
$script:BtnBack.Anchor = 'Top,Right'
$script:BtnNext     = New-Ctl System.Windows.Forms.Button $footer ($script:FormW - 20 - 150) 13 150 30 'Weiter >'
$script:BtnNext.Anchor = 'Top,Right'
$script:BtnNext.Font   = $fontBold

# --- Statuszeile --------------------------------------------------------------
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Size      = New-Object System.Drawing.Size($script:FormW, 24)
$statusBar.Dock      = 'Bottom'
$statusBar.Height    = 24
$statusBar.BackColor = $script:ColDark
$script:StatusLabel  = New-Label $statusBar 12 4 ($script:FormW - 40) 18 'Bereit.' ([System.Drawing.Color]::FromArgb(190, 205, 220))
$script:StatusLabel.Anchor = 'Top,Left,Right'

# Reihenfolge ist wichtig: WinForms dockt von hinten nach vorne.
$script:Form.Controls.Add($content)
$script:Form.Controls.Add($footer)
$script:Form.Controls.Add($statusBar)
$script:Form.Controls.Add($header)

# Auf kleinen Konsolen (z. B. 1024x768) oder bei hoher Skalierung darf das
# Fenster nicht über den sichtbaren Bereich hinauswachsen - sonst wären die
# Schaltflächen der Fußleiste nicht erreichbar.
$script:Form.MinimumSize = New-Object System.Drawing.Size(820, 560)
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w  = [math]::Min($script:Form.Width,  [int]($wa.Width  * 0.98))
    $h  = [math]::Min($script:Form.Height, [int]($wa.Height * 0.98))
    if ($w -lt $script:Form.Width -or $h -lt $script:Form.Height) {
        $script:Form.Size = New-Object System.Drawing.Size([math]::Max(820, $w), [math]::Max(560, $h))
    }
} catch { }

# ==============================================================================
# 17) Seitensteuerung und Datenbindung der einfachen Seite
# ==============================================================================

$script:CurrentPage = 'welcome'

function Show-Page {
    param([Parameter(Mandatory)][string]$Name)
    $script:CurrentPage = $Name
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visible = ($k -eq $Name) }

    $idx = @('welcome', 'select', 'install', 'finish').IndexOf($Name)
    for ($i = 0; $i -lt $script:StepLabels.Count; $i++) {
        if ($i -eq $idx) {
            $script:StepLabels[$i].ForeColor = [System.Drawing.Color]::White
            $script:StepLabels[$i].Font      = $fontBold
        } elseif ($i -lt $idx) {
            $script:StepLabels[$i].ForeColor = [System.Drawing.Color]::FromArgb(120, 200, 140)
            $script:StepLabels[$i].Font      = $fontUi
        } else {
            $script:StepLabels[$i].ForeColor = $script:ColDarkFg
            $script:StepLabels[$i].Font      = $fontUi
        }
    }

    switch ($Name) {
        'welcome' {
            $script:BtnBack.Visible     = $false
            $script:BtnNext.Visible     = $true
            $script:BtnNext.Text        = 'Weiter >'
            $script:BtnAdvanced.Visible = $true
            $script:BtnTools.Visible    = $true
            $script:BtnAbout.Visible    = $true
        }
        'select' {
            $script:BtnBack.Visible     = $true
            $script:BtnNext.Visible     = $true
            $script:BtnNext.Text        = 'Installieren >'
            $script:BtnAdvanced.Visible = $true
            $script:BtnTools.Visible    = $true
            $script:BtnAbout.Visible    = $true
            Load-SelectPage
        }
        'install' {
            $script:BtnBack.Visible     = $false
            $script:BtnNext.Visible     = $false
            $script:BtnAdvanced.Visible = $false
            $script:BtnTools.Visible    = $false
            $script:BtnAbout.Visible    = $false
        }
        'finish' {
            $script:BtnBack.Visible     = $false
            $script:BtnNext.Visible     = $true
            $script:BtnNext.Text        = 'Schließen'
            $script:BtnAdvanced.Visible = $false
            $script:BtnTools.Visible    = $true
            $script:BtnAbout.Visible    = $true
        }
    }
    $script:Form.AcceptButton = $script:BtnNext
    Invoke-UiPump
}

<#
 Passt die Höhe des Systemprüfungs-Kastens an die Anzahl der Zeilen an und
 schiebt Schaltfläche und Hinweistexte darunter. Ohne das ist der Kasten bei
 wenigen Prüfpunkten halb leer und der Hinweistext rutscht aus dem Fenster.
#>
function Update-WelcomeLayout {
    $rowH = 20
    if ($script:LvPreflight.Items.Count -gt 0) {
        $b = $script:LvPreflight.Items[0].Bounds.Height
        if ($b -gt 6) { $rowH = $b }
    }
    $rows = [math]::Max(3, $script:LvPreflight.Items.Count)
    $lvH  = ($rows * $rowH) + 10

    # nach unten begrenzen, damit Hinweis und Schaltfläche sichtbar bleiben
    $maxH = $script:PnlWelcome.ClientSize.Height - $script:GrpPre.Top - 122 - $script:LvPreflight.Top
    if ($maxH -gt 60 -and $lvH -gt $maxH) { $lvH = $maxH }

    $script:LvPreflight.Height = $lvH
    $script:GrpPre.Height      = $script:LvPreflight.Top + $lvH + 12
    $y = $script:GrpPre.Bottom + 16
    $script:BtnRecheck.Top     = $y
    $script:LblWelcomeNote.Top = $y + 5
    $script:LblWelcomeHint.Top = $y + 48
}

function Set-PreflightView {
    param($Result)
    $script:LvPreflight.Items.Clear()
    foreach ($it in @($Result.Items)) {
        $sym = switch ($it.Level) { 'Ok' { [string][char]0x2713 } 'Warn' { '!' } 'Error' { [string][char]0x2717 } default { 'i' } }
        $lvi = New-Object System.Windows.Forms.ListViewItem($sym)
        [void]$lvi.SubItems.Add([string]$it.Name)
        [void]$lvi.SubItems.Add([string]$it.Text)
        $lvi.ForeColor = switch ($it.Level) { 'Ok' { $script:ColOk } 'Warn' { $script:ColWarn } 'Error' { $script:ColErr } default { $script:ColGray } }
        $lvi.UseItemStyleForSubItems = $true
        [void]$script:LvPreflight.Items.Add($lvi)
    }
    if ($Result.Ok) {
        $warn = @($Result.Items | Where-Object Level -eq 'Warn').Count
        if ($warn -gt 0) {
            $script:LblWelcomeNote.Text = "Bereit - mit $warn Hinweis(en). Sie können fortfahren."
            $script:LblWelcomeNote.ForeColor = $script:ColWarn
        } else {
            $script:LblWelcomeNote.Text = 'Alles in Ordnung. Klicken Sie auf "Weiter".'
            $script:LblWelcomeNote.ForeColor = $script:ColOk
        }
        $script:BtnNext.Enabled = $true
    } else {
        $script:LblWelcomeNote.Text = 'Es gibt ein Problem, das die Installation verhindert (rot markiert). Bitte beheben und "Prüfung wiederholen" wählen.'
        $script:LblWelcomeNote.ForeColor = $script:ColErr
        $script:BtnNext.Enabled = $false
    }
    Update-WelcomeLayout
}

function Invoke-PreflightUi {
    Set-Busy $true
    try {
        Set-Status 'Systemprüfung läuft ...'
        $script:Preflight = Invoke-Preflight
        Set-PreflightView -Result $script:Preflight
        Set-Status 'Systemprüfung abgeschlossen.'
    } catch {
        Write-Log $_.Exception.Message 'Error'
        $script:LblWelcomeNote.Text = "Systemprüfung fehlgeschlagen: $($_.Exception.Message)"
        $script:LblWelcomeNote.ForeColor = $script:ColErr
    } finally {
        Set-Busy $false
        $script:BtnNext.Enabled = ($null -ne $script:Preflight -and $script:Preflight.Ok)
    }
}

# Füllt das Versionsfeld der einfachen Seite: Empfehlung, neueste je Zweig,
# "immer aktuell"-Einträge, ggf. benutzerdefinierte URL.
function Update-PhpCombo {
    $items = New-Object System.Collections.Generic.List[object]
    $rec = Get-RecommendedPhpRelease
    if ($rec) {
        $items.Add(@{ Display = ('{0}   - empfohlen (neueste Version)' -f $rec.Display); Url = $rec.Url })
    }
    $seenBranch = @{}
    if ($rec) { $seenBranch[$rec.Branch] = $true }
    foreach ($r in $script:PhpReleases) {
        if ($r.IsLatest) { continue }
        if ($seenBranch.ContainsKey($r.Branch)) { continue }
        $seenBranch[$r.Branch] = $true
        $items.Add(@{ Display = $r.Display; Url = $r.Url })
    }
    foreach ($r in $script:PhpReleases) {
        if ($r.IsLatest) { $items.Add(@{ Display = $r.Display; Url = $r.Url }) }
    }
    $cur = [string]$script:Cfg.PhpUrl
    if ($cur -and -not ($items | Where-Object { $_.Url -eq $cur })) {
        $items.Add(@{ Display = ('Benutzerdefiniert: {0}' -f (Split-Path $cur -Leaf)); Url = $cur })
    }
    $script:CboPhpItems = $items.ToArray()
    $script:CboPhp.Items.Clear()
    foreach ($it in $script:CboPhpItems) { [void]$script:CboPhp.Items.Add($it.Display) }
    $sel = -1
    for ($i = 0; $i -lt $script:CboPhpItems.Count; $i++) { if ($script:CboPhpItems[$i].Url -eq $cur) { $sel = $i; break } }
    if ($sel -lt 0 -and $script:CboPhpItems.Count -gt 0) { $sel = 0; $script:Cfg.PhpUrl = $script:CboPhpItems[0].Url }
    if ($sel -ge 0) { $script:CboPhp.SelectedIndex = $sel }
    $script:CboPhp.Enabled = ($script:CboPhpItems.Count -gt 0)
}

function Load-SelectPage {
    $script:ChkWeb.Checked   = [bool]$script:Cfg.InstallWebStack
    $script:ChkMy.Checked    = [bool]$script:Cfg.InstallMySql
    $script:ChkWb.Checked    = [bool]$script:Cfg.InstallWorkbench
    $script:ChkPy.Checked    = [bool]$script:Cfg.InstallPython
    $script:ChkAppDb.Checked = [bool]$script:Cfg.AppDbEnabled
    $script:TxtAppDb.Text    = [string]$script:Cfg.AppDbName
    $script:TxtAppUser.Text  = [string]$script:Cfg.AppDbUser
    $script:TxtAppPw.Text    = [string]$script:Cfg.AppDbPass
    Update-PhpCombo
    Update-SelectPageState

    # Statusmeldungen zu vorhandenen Installationen
    if (Test-Path (Get-PhpExePath)) {
        $script:LblPhpStatus.Text = "Hinweis: PHP ist bereits unter $script:PhpRoot vorhanden. Es wird durch die gewählte Version ersetzt, die php.ini bleibt erhalten."
        $script:LblPhpStatus.ForeColor = $script:ColWarn
    } elseif ($script:CboPhpItems.Count -eq 0) {
        $script:LblPhpStatus.Text = 'Versionsliste konnte nicht geladen werden. Eine Download-URL kann unter "Erweiterte Optionen" eingetragen werden.'
        $script:LblPhpStatus.ForeColor = $script:ColErr
    } else {
        $script:LblPhpStatus.Text = 'Die empfohlene Version ist vorausgewählt. Weitere Versionen und eigene Download-Adressen: "Erweiterte Optionen".'
        $script:LblPhpStatus.ForeColor = $script:ColGray
    }
    $blocker = Test-MySqlAlreadyInstalled
    if ($blocker) {
        $script:LblMyStatus.Text = "Hinweis: $blocker Eine erneute Einrichtung ist möglich, vorhandene Datenbanken bleiben erhalten."
    } else {
        $script:LblMyStatus.Text = ''
    }
    # Zusammenfassung, ob erweiterte Einstellungen vom Standard abweichen
    $def = New-DefaultConfig
    $diff = @()
    foreach ($k in @('InstallIis', 'InstallVcRedist', 'InstallPhp', 'AddPath', 'InstallRewrite', 'RewriteLang', 'MaxExec', 'MemLimit', 'PostMax',
                     'UploadMax', 'MaxFiles', 'SessionDir', 'UploadDir', 'Timezone', 'Curl', 'IisTuning', 'ContentLength', 'Opcache',
                     'MyUrl', 'WbUrl', 'MyInstallDir', 'MyDataDir', 'MyService', 'MyPort', 'MyBufferPool', 'MyNetMode', 'PyUrl')) {
        if ([string]$def[$k] -ne [string]$script:Cfg[$k]) { $diff += $k }
    }
    foreach ($k in $def.Extensions.Keys) { if ([bool]$def.Extensions[$k] -ne [bool]$script:Cfg.Extensions[$k]) { $diff += 'Extensions'; break } }
    if (@($script:Cfg.MyUsers).Count -gt 0) { $diff += 'MySQL-Benutzer' }
    if ($diff.Count -gt 0) {
        $script:LblAdvState.Text = ('Erweiterte Optionen wurden angepasst: {0}' -f (($diff | Select-Object -Unique) -join ', '))
    } else {
        $script:LblAdvState.Text = 'Erweiterte Optionen: Standardwerte.'
    }
}

function Update-SelectPageState {
    $web = $script:ChkWeb.Checked
    $my  = $script:ChkMy.Checked
    $script:CboPhp.Enabled    = $web -and ($script:CboPhpItems.Count -gt 0)
    $script:ChkWb.Enabled     = $my
    $script:ChkAppDb.Enabled  = $my
    $on = $my -and $script:ChkAppDb.Checked
    foreach ($c in @($script:TxtAppDb, $script:TxtAppUser, $script:TxtAppPw, $script:BtnAppGen)) { $c.Enabled = $on }
    $script:LblAppHint.Visible = $on
}

# Übernimmt die einfache Seite nach $script:Cfg. Liefert Fehlertext oder $null.
function Save-SelectPage {
    $script:Cfg.InstallWebStack  = $script:ChkWeb.Checked
    $script:Cfg.InstallMySql     = $script:ChkMy.Checked
    $script:Cfg.InstallWorkbench = $script:ChkWb.Checked
    $script:Cfg.InstallPython    = $script:ChkPy.Checked
    $script:Cfg.AppDbEnabled     = $script:ChkAppDb.Checked
    $script:Cfg.AppDbName        = $script:TxtAppDb.Text.Trim()
    $script:Cfg.AppDbUser        = $script:TxtAppUser.Text.Trim()
    $script:Cfg.AppDbPass        = $script:TxtAppPw.Text
    if ($script:CboPhp.SelectedIndex -ge 0 -and $script:CboPhp.SelectedIndex -lt $script:CboPhpItems.Count) {
        $script:Cfg.PhpUrl = $script:CboPhpItems[$script:CboPhp.SelectedIndex].Url
    }

    if (-not $script:Cfg.InstallWebStack -and -not $script:Cfg.InstallMySql -and -not $script:Cfg.InstallPython) {
        return 'Bitte mindestens eine Komponente auswählen.'
    }
    if ($script:Cfg.InstallWebStack -and $script:Cfg.InstallPhp -and [string]::IsNullOrWhiteSpace([string]$script:Cfg.PhpUrl)) {
        return 'Für PHP ist keine Version gewählt. Bitte die Versionsliste laden oder unter "Erweiterte Optionen" eine Download-URL eintragen.'
    }
    if ($script:Cfg.InstallWebStack) {
        $e = Test-PhpConfigValues
        if ($e) { return "Erweiterte Optionen > PHP-Einstellungen: $e" }
    }
    if ($script:Cfg.InstallMySql) {
        if (([string]$script:Cfg.MyRootPw).Length -lt 8) { return 'Das MySQL-root-Passwort muss mindestens 8 Zeichen haben (Erweiterte Optionen > MySQL).' }
        if ($script:Cfg.AppDbEnabled) {
            $e = Test-MySqlDbName -Name $script:Cfg.AppDbName
            if ($e) { return "Anwendungsdatenbank: $e" }
            $e = Test-MySqlUserName -Name $script:Cfg.AppDbUser
            if ($e) { return "Anwendungsdatenbank: $e" }
            if ([string]::IsNullOrWhiteSpace($script:Cfg.AppDbPass)) {
                $script:Cfg.AppDbPass = New-MySqlPassword 16
                $script:TxtAppPw.Text = $script:Cfg.AppDbPass
            }
        }
        $e = Test-MySqlUserPlan
        if ($e) { return "MySQL-Benutzer: $e" }
    }
    return $null
}

# --- Schrittliste auf der Installationsseite ----------------------------------
function Initialize-StepList {
    param($Plan)
    $script:LvSteps.Items.Clear()
    foreach ($s in $Plan) {
        $lvi = New-Object System.Windows.Forms.ListViewItem([string][char]0x25CB)   # ○
        [void]$lvi.SubItems.Add([string]$s.Title)
        $lvi.Tag = $s.Key
        $lvi.ForeColor = $script:ColGray
        $lvi.UseItemStyleForSubItems = $true
        [void]$script:LvSteps.Items.Add($lvi)
    }
    Invoke-UiPump
}

function Set-StepState {
    param([string]$Key, [ValidateSet('Waiting', 'Running', 'Done', 'Failed')][string]$State)
    foreach ($lvi in $script:LvSteps.Items) {
        if ([string]$lvi.Tag -ne $Key) { continue }
        switch ($State) {
            'Waiting' { $lvi.Text = [string][char]0x25CB; $lvi.ForeColor = $script:ColGray }
            'Running' { $lvi.Text = [string][char]0x25B6; $lvi.ForeColor = $script:ColAccent; $lvi.Font = $fontBold }
            'Done'    { $lvi.Text = [string][char]0x2713; $lvi.ForeColor = $script:ColOk;     $lvi.Font = $fontUi }
            'Failed'  { $lvi.Text = [string][char]0x2717; $lvi.ForeColor = $script:ColErr;    $lvi.Font = $fontBold }
        }
        $lvi.UseItemStyleForSubItems = $true
        $lvi.EnsureVisible()
    }
    Invoke-UiPump
}

function Set-OverallProgress {
    param([int]$Done, [int]$Total)
    if ($Total -le 0) { return }
    $script:ProgressOverall.Value = [math]::Min(100, [int](($Done * 100) / $Total))
    Invoke-UiPump
}

# --- Abschlussseite -----------------------------------------------------------
function Build-FinishPage {
    $r = $script:Result
    $rtb = $script:RtbSummary
    $rtb.Clear()

    if ($r.Success) {
        $script:LblFinishHead.Text = 'Fertig - die Installation war erfolgreich'
        $script:LblFinishHead.ForeColor = $script:ColOk
    } else {
        $script:LblFinishHead.Text = 'Installation mit Fehlern beendet'
        $script:LblFinishHead.ForeColor = $script:ColErr
    }

    if ($script:Cfg.InstallWebStack) {
        Add-RtfText $rtb "Webserver und PHP`r`n" -Bold -Size 11 -Color $script:ColDark
        if ($r.PhpVersion) {
            Add-RtfText $rtb "  PHP $($r.PhpVersion) ist installiert unter $script:PhpRoot`r`n"
        } else {
            Add-RtfText $rtb "  PHP-Version konnte nicht ermittelt werden.`r`n" -Color $script:ColWarn
        }
        if ($r.HttpOk) {
            Add-RtfText $rtb "  IIS liefert PHP-Seiten korrekt aus (Test über http://localhost/phpinfo.php bestanden).`r`n" -Color $script:ColOk
        } elseif (Test-Path $script:AppCmd) {
            Add-RtfText $rtb "  Der HTTP-Test war nicht erfolgreich - Details im Protokoll. Häufig hilft ein Neustart des Servers.`r`n" -Color $script:ColWarn
        }
        Add-RtfText $rtb "  Webseiten gehören nach: $script:WwwRoot`r`n"
        Add-RtfText $rtb "  php.ini: $(Get-PhpIniPath)`r`n`r`n"
    }

    if ($script:Cfg.InstallMySql) {
        Add-RtfText $rtb "MySQL`r`n" -Bold -Size 11 -Color $script:ColDark
        if ($r.MySqlOk) {
            Add-RtfText $rtb "  MySQL $($r.MySqlVersion) läuft als Dienst '$($script:Cfg.MyService)' auf Port $($script:Cfg.MyPort) (Host 127.0.0.1).`r`n" -Color $script:ColOk
            Add-RtfText $rtb "  Administrator-Konto: root (nur von diesem Server aus). Das Passwort steht unten.`r`n"
            foreach ($u in (Get-MySqlUserPlan)) {
                $line = "  Benutzer $($u.User)@$($u.Host), Passwort: $($u.Pass)"
                if ($u.Db) { $line += "  ->  Datenbank '$($u.Db)' (Vollzugriff)" }
                Add-RtfText $rtb ($line + "`r`n") -Mono
            }
            if ($r.CredFile) { Add-RtfText $rtb "  Alle Zugangsdaten wurden gespeichert unter: $($r.CredFile)`r`n" }
            Add-RtfText $rtb "  Diese Datei enthält Passwörter im Klartext - bitte in einen Passwortspeicher übernehmen und dann löschen.`r`n`r`n" -Color $script:ColWarn
        } else {
            Add-RtfText $rtb "  MySQL wurde nicht vollständig eingerichtet - Details im Protokoll.`r`n`r`n" -Color $script:ColWarn
        }
    }

    if ($script:Cfg.InstallPython) {
        Add-RtfText $rtb "Python`r`n" -Bold -Size 11 -Color $script:ColDark
        if ($r.PyOk) {
            Add-RtfText $rtb "  Python $($r.PyVersion) ist systemweit installiert unter $($r.PyPath)`r`n" -Color $script:ColOk
            Add-RtfText $rtb "  python und pip sind über den PATH aufrufbar - neue Konsolenfenster kennen die Befehle sofort.`r`n`r`n"
        } else {
            Add-RtfText $rtb "  Python wurde nicht vollständig eingerichtet - Details im Protokoll.`r`n`r`n" -Color $script:ColWarn
        }
    }

    if ($r.Error) {
        Add-RtfText $rtb "Fehler`r`n" -Bold -Size 11 -Color $script:ColErr
        Add-RtfText $rtb "  Schritt '$($r.FailedStep)': $($r.Error)`r`n`r`n" -Color $script:ColErr
    }
    Add-RtfText $rtb "Protokoll: $script:LogFile`r`n" -Color $script:ColGray

    $script:PnlPw.Visible = [bool]($script:Cfg.InstallMySql -and $r.MySqlOk)
    $script:TxtRootPwShow.Text = [string]$script:Cfg.MyRootPw
    $script:BtnOpenCred.Enabled = [bool]($r.CredFile -and (Test-Path $r.CredFile))
    $script:PnlReboot.Visible = $script:RebootNeeded
    $script:BtnFinishBrowser.Enabled = [bool]($script:Cfg.InstallWebStack -and (Test-Path $script:AppCmd))
    $script:BtnFinishDelTest.Enabled = $script:BtnFinishBrowser.Enabled
}

# ==============================================================================
# 18) Dialog "Erweiterte Optionen"
# ==============================================================================

function Show-AdvancedDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Erweiterte Optionen'
    $dlg.ClientSize      = New-Object System.Drawing.Size(900, 600)
    $dlg.MinimumSize     = New-Object System.Drawing.Size(820, 520)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.Font            = $fontUi
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.ShowInTaskbar   = $false
    $dlg.MinimizeBox     = $false
    $dlg.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock    = 'Fill'
    $tabs.Padding = New-Object System.Drawing.Point(12, 6)

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Size      = New-Object System.Drawing.Size(900, 52)   # vor den Schaltflächen setzen (Anker!)
    $bottom.Dock      = 'Bottom'
    $bottom.Height    = 52
    $bottom.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 248)
    $btnDefaults = New-Ctl System.Windows.Forms.Button $bottom 16 12 190 30 'Auf Standardwerte zurücksetzen'
    $btnCancel   = New-Ctl System.Windows.Forms.Button $bottom (900 - 16 - 110 - 8 - 110) 12 110 30 'Abbrechen'
    $btnCancel.Anchor = 'Top,Right'
    $btnOk       = New-Ctl System.Windows.Forms.Button $bottom (900 - 16 - 110) 12 110 30 'OK'
    $btnOk.Anchor = 'Top,Right'
    $btnOk.Font   = $fontBold
    $dlg.Controls.Add($tabs)
    $dlg.Controls.Add($bottom)
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $tabInst = New-Object System.Windows.Forms.TabPage; $tabInst.Text = 'Installation';        $tabInst.BackColor = [System.Drawing.Color]::White
    $tabPhp  = New-Object System.Windows.Forms.TabPage; $tabPhp.Text  = 'PHP-Einstellungen';   $tabPhp.BackColor  = [System.Drawing.Color]::White
    $tabExt  = New-Object System.Windows.Forms.TabPage; $tabExt.Text  = 'PHP-Extensions';      $tabExt.BackColor  = [System.Drawing.Color]::White
    $tabMy   = New-Object System.Windows.Forms.TabPage; $tabMy.Text   = 'MySQL';               $tabMy.BackColor   = [System.Drawing.Color]::White
    $tabUsr  = New-Object System.Windows.Forms.TabPage; $tabUsr.Text  = 'MySQL-Benutzer';      $tabUsr.BackColor  = [System.Drawing.Color]::White
    $tabs.TabPages.AddRange(@($tabInst, $tabPhp, $tabExt, $tabMy, $tabUsr))

    # ---------- Installation ------------------------------------------------------
    $grpComp = New-Object System.Windows.Forms.GroupBox
    $grpComp.Text = ' Komponenten (Webserver + PHP) '
    $grpComp.Location = New-Object System.Drawing.Point(16, 12)
    $grpComp.Size = New-Object System.Drawing.Size(850, 190)
    $tabInst.Controls.Add($grpComp)

    $chkIis      = New-Ctl System.Windows.Forms.CheckBox $grpComp 16 26 500 22 'IIS installieren (inkl. CGI, Verwaltungskonsole, Skripts)'
    $chkVc       = New-Ctl System.Windows.Forms.CheckBox $grpComp 16 52 500 22 'Visual C++ Redistributable 2015-2022 (x64) - wird übersprungen, wenn vorhanden'
    $chkPhp      = New-Ctl System.Windows.Forms.CheckBox $grpComp 16 78 500 22 "PHP herunterladen und nach $script:PhpRoot entpacken"
    $chkPath     = New-Ctl System.Windows.Forms.CheckBox $grpComp 16 104 500 22 'PHP-Ordner in die PATH-Variable eintragen'
    $chkRewrite  = New-Ctl System.Windows.Forms.CheckBox $grpComp 16 130 400 22 'IIS URL Rewrite Module 2.1 installieren'
    New-Label $grpComp 36 158 90 20 'Paketsprache:' | Out-Null
    $cboRwLang = New-Ctl System.Windows.Forms.ComboBox $grpComp 130 155 120 22
    $cboRwLang.DropDownStyle = 'DropDownList'
    foreach ($k in $script:RewriteUrls.Keys) { [void]$cboRwLang.Items.Add($k) }
    New-Label $grpComp 258 158 300 20 'passend zur Sprache der IIS-Konsole' $script:ColGray | Out-Null

    $grpVer = New-Object System.Windows.Forms.GroupBox
    $grpVer.Text = ' PHP-Version '
    $grpVer.Location = New-Object System.Drawing.Point(16, 212)
    $grpVer.Size = New-Object System.Drawing.Size(850, 140)
    $tabInst.Controls.Add($grpVer)
    New-Label $grpVer 16 30 90 20 'Version:' | Out-Null
    $cboVer = New-Ctl System.Windows.Forms.ComboBox $grpVer 110 26 480 24
    $cboVer.DropDownStyle = 'DropDownList'
    $btnLoadVer = New-Ctl System.Windows.Forms.Button $grpVer 604 25 170 26 'Versionen neu laden'
    New-Label $grpVer 16 66 90 20 'Download:' | Out-Null
    $txtUrl = New-Ctl System.Windows.Forms.TextBox $grpVer 110 63 724 24
    $txtUrl.Font = $fontMono
    New-Label $grpVer 110 92 724 36 ('Frei editierbar - hier kann auch eine eigene URL eingetragen werden (z. B. interner Spiegel). ' +
        'Nur Non-Thread-Safe-Builds (nts, x64) verwenden.') $script:ColGray | Out-Null

    $grpPy = New-Object System.Windows.Forms.GroupBox
    $grpPy.Text = ' Python (optional) '
    $grpPy.Location = New-Object System.Drawing.Point(16, 362)
    $grpPy.Size = New-Object System.Drawing.Size(850, 128)
    $tabInst.Controls.Add($grpPy)
    $chkAdvPy = New-Ctl System.Windows.Forms.CheckBox $grpPy 16 26 700 22 'Python installieren (systemweit, inklusive pip und PATH-Eintrag)'
    New-Label $grpPy 16 58 90 20 'Download:' | Out-Null
    $txtPyUrl = New-Ctl System.Windows.Forms.TextBox $grpPy 110 55 724 24
    $txtPyUrl.Font = $fontMono
    New-Label $grpPy 110 84 724 36 ('Leer lassen = die neueste Version wird beim Start der Installation automatisch von python.org ermittelt. ' +
        'Alternativ hier einen Windows-x64-Installer eintragen (python-3.x.y-amd64.exe, auch interner Spiegel).') $script:ColGray | Out-Null

    $fillVer = {
        $cboVer.Items.Clear()
        foreach ($r in $script:PhpReleases) { [void]$cboVer.Items.Add($r.Display) }
        $sel = -1
        for ($i = 0; $i -lt $script:PhpReleases.Count; $i++) { if ($script:PhpReleases[$i].Url -eq $txtUrl.Text.Trim()) { $sel = $i; break } }
        if ($sel -ge 0) { $cboVer.SelectedIndex = $sel }
    }
    $cboVer.Add_SelectedIndexChanged({
        $i = $cboVer.SelectedIndex
        if ($i -ge 0 -and $i -lt $script:PhpReleases.Count) { $txtUrl.Text = $script:PhpReleases[$i].Url }
    })
    $btnLoadVer.Add_Click({
        $dlg.Cursor  = [System.Windows.Forms.Cursors]::WaitCursor
        $dlg.Enabled = $false
        try {
            $script:PhpReleases = @(Get-PhpReleaseList)
            & $fillVer
            Show-Info "$($script:PhpReleases.Count) PHP-Builds gefunden." 'PHP-Versionen'
        } catch {
            Show-Error "Versionsliste konnte nicht geladen werden:`r`n$($_.Exception.Message)"
        } finally { $dlg.Enabled = $true; $dlg.Cursor = [System.Windows.Forms.Cursors]::Default }
    })

    # ---------- PHP-Einstellungen -------------------------------------------------
    $ramMb = Get-TotalRamMb
    $grpLimits = New-Object System.Windows.Forms.GroupBox
    $grpLimits.Text = ' Ausführung und Limits '
    $grpLimits.Location = New-Object System.Drawing.Point(16, 12)
    $grpLimits.Size = New-Object System.Drawing.Size(415, 224)
    $tabPhp.Controls.Add($grpLimits)
    New-Label $grpLimits 16 30 170 20 'max_execution_time (Sek.):' | Out-Null
    $numMaxExec = New-Ctl System.Windows.Forms.NumericUpDown $grpLimits 200 27 90 24
    $numMaxExec.Minimum = 5; $numMaxExec.Maximum = 3600
    New-Label $grpLimits 16 62 170 20 'memory_limit:' | Out-Null
    $txtMem = New-Ctl System.Windows.Forms.TextBox $grpLimits 200 59 90 24
    New-Label $grpLimits 298 62 110 20 ("Server: {0} MB RAM" -f $ramMb) $script:ColGray | Out-Null
    New-Label $grpLimits 16 86 390 32 'memory_limit gilt pro Request, nicht insgesamt. Bei vielen gleichzeitigen Anfragen kann der Server den Speicher ausschöpfen.' $script:ColWarn | Out-Null
    New-Label $grpLimits 16 124 170 20 'post_max_size:' | Out-Null
    $txtPost = New-Ctl System.Windows.Forms.TextBox $grpLimits 200 121 90 24
    New-Label $grpLimits 16 154 170 20 'upload_max_filesize:' | Out-Null
    $txtUpload = New-Ctl System.Windows.Forms.TextBox $grpLimits 200 151 90 24
    New-Label $grpLimits 16 184 170 20 'max_file_uploads:' | Out-Null
    $numMaxFiles = New-Ctl System.Windows.Forms.NumericUpDown $grpLimits 200 181 90 24
    $numMaxFiles.Minimum = 1; $numMaxFiles.Maximum = 500

    $grpPaths = New-Object System.Windows.Forms.GroupBox
    $grpPaths.Text = ' Pfade und Zeitzone '
    $grpPaths.Location = New-Object System.Drawing.Point(445, 12)
    $grpPaths.Size = New-Object System.Drawing.Size(421, 224)
    $tabPhp.Controls.Add($grpPaths)
    New-Label $grpPaths 16 30 140 20 'session.save_path:' | Out-Null
    $txtSess = New-Ctl System.Windows.Forms.TextBox $grpPaths 16 52 388 24
    New-Label $grpPaths 16 84 140 20 'upload_tmp_dir:' | Out-Null
    $txtUpDir = New-Ctl System.Windows.Forms.TextBox $grpPaths 16 106 388 24
    New-Label $grpPaths 16 140 100 20 'date.timezone:' | Out-Null
    $cboTz = New-Ctl System.Windows.Forms.ComboBox $grpPaths 120 137 180 24
    $cboTz.DropDownStyle = 'DropDown'
    [void]$cboTz.Items.AddRange(@('Europe/Berlin', 'Europe/Vienna', 'Europe/Zurich', 'UTC'))
    New-Label $grpPaths 16 165 388 28 'Beide Ordner werden angelegt und erhalten das Recht "Ändern" für IIS_IUSRS und IUSR.' $script:ColGray | Out-Null

    $grpOpt = New-Object System.Windows.Forms.GroupBox
    $grpOpt.Text = ' Zusatzoptionen '
    $grpOpt.Location = New-Object System.Drawing.Point(16, 246)
    $grpOpt.Size = New-Object System.Drawing.Size(850, 134)
    $tabPhp.Controls.Add($grpOpt)
    $chkCurl = New-Ctl System.Windows.Forms.CheckBox $grpOpt 16 26 820 22 'cURL/OpenSSL: cacert.pem von curl.se laden und curl.cainfo + openssl.cafile setzen (aktiviert auch die Extensions curl und openssl)'
    $chkTune = New-Ctl System.Windows.Forms.CheckBox $grpOpt 16 52 820 22 'IIS-Empfehlungen setzen: fastcgi.impersonate=1, cgi.fix_pathinfo=1, cgi.force_redirect=0, expose_php=Off'
    $chkLen  = New-Ctl System.Windows.Forms.CheckBox $grpOpt 16 78 820 22 'IIS-Anforderungslimit (maxAllowedContentLength) an post_max_size angleichen - sonst blockt IIS große Uploads mit 404.13'
    $chkOpc  = New-Ctl System.Windows.Forms.CheckBox $grpOpt 16 104 820 22 'OPcache aktivieren (empfohlen)'

    # ---------- Extensions --------------------------------------------------------
    $lblExtInfo = New-Label $tabExt 16 14 850 34 ('Haken = Extension wird in der php.ini aktiviert, kein Haken = auskommentiert. Es werden nur Extensions angefasst, ' +
        'zu denen in der php.ini eine Zeile und im Ordner ext\ eine DLL existiert. OPcache hat eine eigene Option unter "PHP-Einstellungen".') $script:ColGray
    $lstExt = New-Ctl System.Windows.Forms.CheckedListBox $tabExt 16 52 560 300
    $lstExt.CheckOnClick = $true
    $lstExt.MultiColumn  = $true
    $lstExt.ColumnWidth  = 140
    $btnExtReload = New-Ctl System.Windows.Forms.Button $tabExt 596 52 250 30 'Aus vorhandener php.ini einlesen'
    $btnExtNone   = New-Ctl System.Windows.Forms.Button $tabExt 596 90 250 30 'Alle abwählen'
    $btnExtCommon = New-Ctl System.Windows.Forms.Button $tabExt 596 128 250 30 'Übliche Auswahl setzen'
    New-Label $tabExt 596 170 250 150 ('"Übliche Auswahl" setzt: ' + ($script:CommonExtensions -join ', ') + ".`r`n`r`n" +
        '"Aus php.ini einlesen" zeigt den tatsächlichen Zustand einer bereits vorhandenen Installation an.') $script:ColGray | Out-Null

    $fillExt = {
        param([hashtable]$Map)
        $lstExt.Items.Clear()
        foreach ($n in ($Map.Keys | Sort-Object)) { [void]$lstExt.Items.Add($n, [bool]$Map[$n]) }
    }
    $btnExtNone.Add_Click({ for ($i = 0; $i -lt $lstExt.Items.Count; $i++) { $lstExt.SetItemChecked($i, $false) } })
    $btnExtCommon.Add_Click({
        for ($i = 0; $i -lt $lstExt.Items.Count; $i++) { $lstExt.SetItemChecked($i, ($script:CommonExtensions -contains [string]$lstExt.Items[$i])) }
    })
    $btnExtReload.Add_Click({
        $ini = Get-PhpIniPath
        if (-not (Test-Path $ini)) { Show-Warn 'Es ist noch keine php.ini vorhanden. Die Liste zeigt die Standardauswahl.'; return }
        $map = @{}
        for ($i = 0; $i -lt $lstExt.Items.Count; $i++) { $map[[string]$lstExt.Items[$i]] = $lstExt.GetItemChecked($i) }
        $found = Get-PhpExtensionList -Lines (Get-Content -LiteralPath $ini)
        foreach ($e in $found) { $map[$e.Name] = [bool]$e.Enabled }
        & $fillExt $map
        Show-Info "$(@($found).Count) Extensions in der php.ini gefunden, $(@($found | Where-Object Enabled).Count) davon aktiv." 'PHP-Extensions'
    })

    # ---------- MySQL -------------------------------------------------------------
    $grpMySrv = New-Object System.Windows.Forms.GroupBox
    $grpMySrv.Text = ' Server '
    $grpMySrv.Location = New-Object System.Drawing.Point(16, 12)
    $grpMySrv.Size = New-Object System.Drawing.Size(415, 330)
    $tabMy.Controls.Add($grpMySrv)
    New-Label $grpMySrv 14 26 90 20 'Download:' | Out-Null
    $txtMyUrl = New-Ctl System.Windows.Forms.TextBox $grpMySrv 14 46 388 22
    $txtMyUrl.Font = $fontMono
    New-Label $grpMySrv 14 76 90 20 'Programm:' | Out-Null
    $txtMyInst = New-Ctl System.Windows.Forms.TextBox $grpMySrv 110 73 292 22
    New-Label $grpMySrv 14 104 90 20 'Daten:' | Out-Null
    $txtMyData = New-Ctl System.Windows.Forms.TextBox $grpMySrv 110 101 292 22
    New-Label $grpMySrv 14 132 90 20 'Dienstname:' | Out-Null
    $txtMySvc = New-Ctl System.Windows.Forms.TextBox $grpMySrv 110 129 130 22
    New-Label $grpMySrv 258 132 40 20 'Port:' | Out-Null
    $numMyPort = New-Ctl System.Windows.Forms.NumericUpDown $grpMySrv 300 129 80 22
    $numMyPort.Minimum = 1; $numMyPort.Maximum = 65535
    New-Label $grpMySrv 14 162 180 20 'InnoDB-Buffer-Pool (MB):' | Out-Null
    $numPool = New-Ctl System.Windows.Forms.NumericUpDown $grpMySrv 200 159 90 22
    $numPool.Minimum = 64; $numPool.Maximum = 1048576
    $numPool.Increment = 128        # Vielfache der Chunk-Größe
    New-Label $grpMySrv 298 162 110 20 '(rund 25 % des RAM)' $script:ColGray | Out-Null
    New-Label $grpMySrv 14 194 130 20 'root-Passwort:' | Out-Null
    $txtRootPw = New-Ctl System.Windows.Forms.TextBox $grpMySrv 14 214 200 22
    $txtRootPw.UseSystemPasswordChar = $true
    $txtRootPw.Font = $fontMono
    $btnGenPw = New-Ctl System.Windows.Forms.Button $grpMySrv 222 213 100 24 'Generieren'
    $chkShowPw = New-Ctl System.Windows.Forms.CheckBox $grpMySrv 330 215 70 22 'zeigen'
    New-Label $grpMySrv 14 242 388 80 ('Das Konto root wird ausschließlich für localhost angelegt und ist auch bei geöffnetem Port nicht aus dem Netz erreichbar. ' +
        'Bei einer Wiederholung auf einem Server mit vorhandenem MySQL hier das bekannte root-Passwort eintragen.') $script:ColGray | Out-Null
    New-Label $tabMy 16 350 850 20 'Workbench-Download:' | Out-Null
    $txtWbUrl = New-Ctl System.Windows.Forms.TextBox $tabMy 150 347 716 22
    $txtWbUrl.Font = $fontMono
    $btnGenPw.Add_Click({ $txtRootPw.Text = New-MySqlPassword; $chkShowPw.Checked = $true })
    $chkShowPw.Add_CheckedChanged({ $txtRootPw.UseSystemPasswordChar = -not $chkShowPw.Checked })

    $grpMyNet = New-Object System.Windows.Forms.GroupBox
    $grpMyNet.Text = ' Erreichbarkeit und Firewall '
    $grpMyNet.Location = New-Object System.Drawing.Point(445, 12)
    $grpMyNet.Size = New-Object System.Drawing.Size(421, 330)
    $tabMy.Controls.Add($grpMyNet)
    New-Label $grpMyNet 14 24 390 18 'Soll der Datenbankserver auch von außen erreichbar sein?' | Out-Null
    $rbLocal = New-Ctl System.Windows.Forms.RadioButton $grpMyNet 14 46 390 20 'Nur lokal - PHP und IIS auf diesem Server (empfohlen)'
    $rbLan   = New-Ctl System.Windows.Forms.RadioButton $grpMyNet 14 68 390 20 'Lokales Netzwerk - Profile Domäne und Privat'
    $rbAny   = New-Ctl System.Windows.Forms.RadioButton $grpMyNet 14 90 390 20 'Alle Netzwerke - inkl. Profil Öffentlich'
    $txtFw = New-Ctl System.Windows.Forms.TextBox $grpMyNet 14 116 392 200
    $txtFw.Multiline  = $true
    $txtFw.ReadOnly   = $true
    $txtFw.ScrollBars = 'Vertical'
    $txtFw.Font       = $fontMono
    $txtFw.BackColor  = [System.Drawing.Color]::FromArgb(248, 249, 250)

    $updateFw = {
        $mode = if ($rbLan.Checked) { 'lan' } elseif ($rbAny.Checked) { 'any' } else { 'local' }
        $mysqld = Join-Path $txtMyInst.Text.Trim() 'bin\mysqld.exe'
        try {
            $txtFw.Text = (Get-MySqlFirewallPlan -Mode $mode -Service $txtMySvc.Text.Trim() -Port ([int]$numMyPort.Value) -Mysqld $mysqld).Text
        } catch { $txtFw.Text = $_.Exception.Message }
    }
    foreach ($rb in @($rbLocal, $rbLan, $rbAny)) { $rb.Add_CheckedChanged($updateFw) }
    foreach ($c in @($txtMySvc, $txtMyInst)) { $c.Add_TextChanged($updateFw) }
    $numMyPort.Add_ValueChanged($updateFw)

    # ---------- MySQL-Benutzer ----------------------------------------------------
    New-Label $tabUsr 16 14 850 34 ('Weitere Benutzer (zusätzlich zur Anwendungsdatenbank von der Hauptseite). Host leer = localhost. Ist eine Datenbank angegeben, ' +
        'wird sie angelegt und der Benutzer erhält Vollzugriff darauf. Großbuchstaben werden abgewiesen.') $script:ColGray | Out-Null
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(16, 52)
    $grid.Size = New-Object System.Drawing.Size(640, 300)
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.SelectionMode = 'CellSelect'
    $tabUsr.Controls.Add($grid)
    $colUser = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colUser.HeaderText = 'Benutzer (nur Kleinbuchstaben)'; $colUser.Width = 200; $colUser.MaxInputLength = 32
    $colPass = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPass.HeaderText = 'Passwort'; $colPass.Width = 170
    $colHost = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colHost.HeaderText = 'Host'; $colHost.Width = 100
    $colDb   = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDb.HeaderText = 'Datenbank (optional)'; $colDb.Width = 150
    # Columns.AddRange erwartet ein DataGridViewColumn[] - deshalb einzeln hinzufügen.
    foreach ($col in @($colUser, $colPass, $colHost, $colDb)) { [void]$grid.Columns.Add($col) }
    $btnUserDel = New-Ctl System.Windows.Forms.Button $tabUsr 672 52 190 28 'Markierte Zeile entfernen'
    $btnUserPw  = New-Ctl System.Windows.Forms.Button $tabUsr 672 88 190 28 'Passwort für Zeile generieren'
    $grid.Add_CellValidating({
        param($sender, $e)
        if ($e.ColumnIndex -notin @(0, 3)) { return }
        $val = [string]$e.FormattedValue
        if ([string]::IsNullOrWhiteSpace($val)) { return }
        $err = if ($e.ColumnIndex -eq 0) { Test-MySqlUserName -Name $val.Trim() } else { Test-MySqlDbName -Name $val.Trim() }
        if ($err) {
            $sender.Rows[$e.RowIndex].Cells[$e.ColumnIndex].ErrorText = $err
            $e.Cancel = $true
        } else {
            $sender.Rows[$e.RowIndex].Cells[$e.ColumnIndex].ErrorText = ''
        }
    })
    $grid.Add_EditingControlShowing({
        param($sender, $e)
        $cell = $sender.CurrentCell
        if (-not $cell) { return }
        if (-not ($e.Control | Get-Member -Name 'CharacterCasing' -MemberType Property)) { return }
        $e.Control.CharacterCasing = if ($cell.ColumnIndex -in @(0, 3)) { 'Lower' } else { 'Normal' }
    })
    $btnUserDel.Add_Click({ $row = $grid.CurrentRow; if ($row -and -not $row.IsNewRow) { $grid.Rows.Remove($row) } })
    $btnUserPw.Add_Click({ $row = $grid.CurrentRow; if ($row -and -not $row.IsNewRow) { $row.Cells[1].Value = New-MySqlPassword } })

    # ---------- Werte laden / speichern ------------------------------------------
    $loadFromCfg = {
        param([hashtable]$C)
        $chkIis.Checked = [bool]$C.InstallIis; $chkVc.Checked = [bool]$C.InstallVcRedist; $chkPhp.Checked = [bool]$C.InstallPhp
        $chkPath.Checked = [bool]$C.AddPath;   $chkRewrite.Checked = [bool]$C.InstallRewrite
        $cboRwLang.SelectedItem = [string]$C.RewriteLang
        if ($cboRwLang.SelectedIndex -lt 0) { $cboRwLang.SelectedIndex = 0 }
        $txtUrl.Text = [string]$C.PhpUrl
        $chkAdvPy.Checked = [bool]$C.InstallPython
        $txtPyUrl.Text    = [string]$C.PyUrl
        & $fillVer
        $numMaxExec.Value = [math]::Max($numMaxExec.Minimum, [math]::Min($numMaxExec.Maximum, [int]$C.MaxExec))
        $txtMem.Text = [string]$C.MemLimit; $txtPost.Text = [string]$C.PostMax; $txtUpload.Text = [string]$C.UploadMax
        $numMaxFiles.Value = [math]::Max($numMaxFiles.Minimum, [math]::Min($numMaxFiles.Maximum, [int]$C.MaxFiles))
        $txtSess.Text = [string]$C.SessionDir; $txtUpDir.Text = [string]$C.UploadDir; $cboTz.Text = [string]$C.Timezone
        $chkCurl.Checked = [bool]$C.Curl; $chkTune.Checked = [bool]$C.IisTuning; $chkLen.Checked = [bool]$C.ContentLength; $chkOpc.Checked = [bool]$C.Opcache
        & $fillExt $C.Extensions
        $txtMyUrl.Text = [string]$C.MyUrl; $txtWbUrl.Text = [string]$C.WbUrl
        $txtMyInst.Text = [string]$C.MyInstallDir; $txtMyData.Text = [string]$C.MyDataDir; $txtMySvc.Text = [string]$C.MyService
        $numMyPort.Value = [int]$C.MyPort
        $numPool.Value = [math]::Max($numPool.Minimum, [math]::Min($numPool.Maximum, [int]$C.MyBufferPool))
        $txtRootPw.Text = [string]$C.MyRootPw
        switch ([string]$C.MyNetMode) { 'lan' { $rbLan.Checked = $true } 'any' { $rbAny.Checked = $true } default { $rbLocal.Checked = $true } }
        & $updateFw
        $grid.Rows.Clear()
        foreach ($u in @($C.MyUsers)) { if ($u) { [void]$grid.Rows.Add([string]$u.User, [string]$u.Pass, [string]$u.Host, [string]$u.Db) } }
    }

    # Liefert Fehlertext oder $null; bei Erfolg ist $script:Cfg aktualisiert.
    $saveToCfg = {
        [void]$grid.EndEdit()   # offene Zellbearbeitung übernehmen
        $new = @{}
        foreach ($k in $script:Cfg.Keys) { $new[$k] = $script:Cfg[$k] }
        $new.InstallIis = $chkIis.Checked; $new.InstallVcRedist = $chkVc.Checked; $new.InstallPhp = $chkPhp.Checked
        $new.AddPath = $chkPath.Checked;   $new.InstallRewrite = $chkRewrite.Checked
        $new.RewriteLang = [string]$cboRwLang.SelectedItem
        $new.PhpUrl = $txtUrl.Text.Trim()
        $new.InstallPython = $chkAdvPy.Checked
        $new.PyUrl = $txtPyUrl.Text.Trim()
        $new.MaxExec = [int]$numMaxExec.Value; $new.MemLimit = $txtMem.Text.Trim(); $new.PostMax = $txtPost.Text.Trim()
        $new.UploadMax = $txtUpload.Text.Trim(); $new.MaxFiles = [int]$numMaxFiles.Value
        $new.SessionDir = $txtSess.Text.Trim(); $new.UploadDir = $txtUpDir.Text.Trim(); $new.Timezone = $cboTz.Text.Trim()
        $new.Curl = $chkCurl.Checked; $new.IisTuning = $chkTune.Checked; $new.ContentLength = $chkLen.Checked; $new.Opcache = $chkOpc.Checked
        $ext = @{}
        for ($i = 0; $i -lt $lstExt.Items.Count; $i++) { $ext[[string]$lstExt.Items[$i]] = $lstExt.GetItemChecked($i) }
        $new.Extensions = $ext
        $new.MyUrl = $txtMyUrl.Text.Trim(); $new.WbUrl = $txtWbUrl.Text.Trim()
        $new.MyInstallDir = $txtMyInst.Text.Trim(); $new.MyDataDir = $txtMyData.Text.Trim(); $new.MyService = $txtMySvc.Text.Trim()
        $new.MyPort = [int]$numMyPort.Value; $new.MyBufferPool = [int]$numPool.Value; $new.MyRootPw = $txtRootPw.Text
        $new.MyNetMode = if ($rbLan.Checked) { 'lan' } elseif ($rbAny.Checked) { 'any' } else { 'local' }
        $users = @()
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) { continue }
            $u = [string]$row.Cells[0].Value; $p = [string]$row.Cells[1].Value; $h = [string]$row.Cells[2].Value; $d = [string]$row.Cells[3].Value
            if (-not $u -and -not $p) { continue }
            $users += @{ User = $u.Trim(); Pass = $p; Host = $(if ($h) { $h.Trim() } else { 'localhost' }); Db = $d.Trim() }
        }
        $new.MyUsers = $users

        # Prüfungen
        $sizeRx = '^\d+[KMGkmg]?$'
        foreach ($f in @(@{ V = $new.MemLimit; N = 'memory_limit' }, @{ V = $new.PostMax; N = 'post_max_size' }, @{ V = $new.UploadMax; N = 'upload_max_filesize' })) {
            if ($f.V -notmatch $sizeRx) { return "PHP-Einstellungen: $($f.N) '$($f.V)' ist kein gültiger Wert (z. B. 512M, 2G)." }
        }
        foreach ($f in @(@{ V = $new.SessionDir; N = 'session.save_path' }, @{ V = $new.UploadDir; N = 'upload_tmp_dir' })) {
            if (-not $f.V -or -not [System.IO.Path]::IsPathRooted($f.V)) { return "PHP-Einstellungen: $($f.N) '$($f.V)' ist kein absoluter Pfad." }
        }
        foreach ($f in @(@{ V = $new.MyInstallDir; N = 'MySQL-Programmordner' }, @{ V = $new.MyDataDir; N = 'MySQL-Datenordner' })) {
            if (-not $f.V -or -not [System.IO.Path]::IsPathRooted($f.V)) { return "MySQL: $($f.N) '$($f.V)' ist kein absoluter Pfad." }
        }
        if ($new.MyService -notmatch '^[A-Za-z0-9_-]{1,80}$') { return "MySQL: Dienstname '$($new.MyService)' ist ungültig (Buchstaben, Ziffern, _ -)." }
        if ($new.MyRootPw.Length -lt 8) { return 'MySQL: Das root-Passwort muss mindestens 8 Zeichen haben.' }
        foreach ($u in $users) {
            $e = Test-MySqlUserName -Name $u.User; if ($e) { return "MySQL-Benutzer: $e" }
            if ([string]::IsNullOrWhiteSpace($u.Pass)) { return "MySQL-Benutzer '$($u.User)': Passwort fehlt." }
            if ($u.Db) { $e = Test-MySqlDbName -Name $u.Db; if ($e) { return "MySQL-Benutzer: $e" } }
        }
        $script:Cfg = $new
        return $null
    }

    $btnDefaults.Add_Click({
        if (Ask-YesNo 'Alle erweiterten Einstellungen auf die Standardwerte zurücksetzen? Das root-Passwort wird dabei neu erzeugt.') {
            $d = New-DefaultConfig
            # Hauptauswahl und gewählte PHP-URL beibehalten
            foreach ($k in @('InstallWebStack', 'InstallMySql', 'InstallWorkbench', 'AppDbEnabled', 'AppDbName', 'AppDbUser', 'AppDbPass', 'PhpUrl')) { $d[$k] = $script:Cfg[$k] }
            & $loadFromCfg $d
        }
    })
    $btnOk.Add_Click({
        $err = & $saveToCfg
        if ($err) { Show-Warn $err 'Eingabe prüfen'; return }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $btnCancel.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.Close() })

    & $loadFromCfg $script:Cfg
    $res = $dlg.ShowDialog($script:Form)
    $dlg.Dispose()
    return ($res -eq [System.Windows.Forms.DialogResult]::OK)
}

# ==============================================================================
# 19) Dialog "Info" (Version und Bildnachweis)
# ==============================================================================

function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Info'
    $dlg.ClientSize      = New-Object System.Drawing.Size(520, 260)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.Font            = $fontUi
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.ShowInTaskbar   = $false
    $dlg.MinimizeBox     = $false
    $dlg.MaximizeBox     = $false
    $dlg.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    New-Label $dlg 20 18 480 28 $script:AppTitle $script:ColDark $fontTitle | Out-Null
    New-Label $dlg 20 48 480 20 ("Version {0}" -f $script:AppVersion) $script:ColGray | Out-Null
    New-Label $dlg 20 76 480 40 'Richtet IIS, PHP und - auf Wunsch - MySQL auf Windows Server 2022/2025 ein.' $script:ColGray | Out-Null

    New-Label $dlg 20 124 480 20 'Bildnachweis' $script:ColDark $fontBold | Out-Null
    New-Label $dlg 20 146 480 20 $script:IconCreditText $script:ColGray | Out-Null

    # Anklickbarer Link auf die Quelle des Symbols
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Location  = New-Object System.Drawing.Point(20, 168)
    $link.Size      = New-Object System.Drawing.Size(480, 20)
    $link.Text      = $script:IconCreditUrl
    $link.LinkColor = $script:ColAccent
    $dlg.Controls.Add($link)
    $link.Add_LinkClicked({ Open-InBrowser $script:IconCreditUrl | Out-Null })

    $btnClose = New-Ctl System.Windows.Forms.Button $dlg 394 214 110 30 'Schließen'
    $dlg.AcceptButton = $btnClose
    $dlg.CancelButton = $btnClose
    $btnClose.Add_Click({ $dlg.Close() })

    [void]$dlg.ShowDialog($script:Form)
    $dlg.Dispose()
}

# ==============================================================================
# 20) Dialog "Werkzeuge"
# ==============================================================================

# Führt eine Werkzeug-Aktion mit Wartecursor und Fehlerbehandlung aus.
function Invoke-ToolAction {
    param([Parameter(Mandatory)][scriptblock]$Action, $Owner = $null)
    if ($Owner) { $Owner.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    try { & $Action }
    catch { Write-Log $_.Exception.Message 'Error'; Show-Error $_.Exception.Message }
    finally { if ($Owner) { $Owner.Cursor = [System.Windows.Forms.Cursors]::Default } }
}

function Show-ToolsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Werkzeuge'
    $dlg.ClientSize      = New-Object System.Drawing.Size(520, 380)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.Font            = $fontUi
    $dlg.BackColor       = [System.Drawing.Color]::White
    $dlg.ShowInTaskbar   = $false
    $dlg.MinimizeBox     = $false
    $dlg.MaximizeBox     = $false
    $dlg.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
    $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    New-Label $dlg 16 12 490 36 'Hilfsfunktionen für Kontrolle und Fehlersuche. Alle Aktionen werden im Protokoll festgehalten.' $script:ColGray | Out-Null
    $b1  = New-Ctl System.Windows.Forms.Button $dlg 16 52 240 30 'phpinfo.php anlegen und öffnen'
    $b2  = New-Ctl System.Windows.Forms.Button $dlg 16 90 240 30 'Diagnoseseite (phpcheck.php) öffnen'
    $b3  = New-Ctl System.Windows.Forms.Button $dlg 16 128 240 30 'Testseiten löschen'
    $b4  = New-Ctl System.Windows.Forms.Button $dlg 16 166 240 30 'php.ini im Editor öffnen'
    $b5  = New-Ctl System.Windows.Forms.Button $dlg 264 52 240 30 'IIS neu starten'
    $b6  = New-Ctl System.Windows.Forms.Button $dlg 264 90 240 30 'php-cgi.exe beenden'
    $b7  = New-Ctl System.Windows.Forms.Button $dlg 264 128 240 30 'Protokolldatei öffnen'
    $b8  = New-Ctl System.Windows.Forms.Button $dlg 264 166 240 30 'Protokollordner öffnen'
    $b9  = New-Ctl System.Windows.Forms.Button $dlg 16 214 240 30 'MySQL-Zugangsdaten öffnen'
    $b10 = New-Ctl System.Windows.Forms.Button $dlg 264 214 240 30 'Systemprüfung erneut ausführen'
    $script:LblToolsStatus = New-Label $dlg 16 262 490 60 'Bereit.' $script:ColGray
    $bClose = New-Ctl System.Windows.Forms.Button $dlg 394 334 110 30 'Schließen'
    $dlg.CancelButton = $bClose

    # Die Handler laufen, solange ShowDialog unten aktiv ist - $dlg und die
    # Schaltflächen sind dann über den Aufrufkontext sichtbar.
    $b1.Add_Click({ Invoke-ToolAction -Owner $dlg { New-PhpInfoPage | Out-Null; Open-InBrowser 'http://localhost/phpinfo.php' | Out-Null } })
    $b2.Add_Click({ Invoke-ToolAction -Owner $dlg { New-PhpCheckPage | Out-Null; Open-InBrowser 'http://localhost/phpcheck.php' | Out-Null } })
    $b3.Add_Click({ Invoke-ToolAction -Owner $dlg { Remove-TestPages | Out-Null } })
    $b4.Add_Click({ Invoke-ToolAction -Owner $dlg {
        $ini = Get-PhpIniPath
        if (Test-Path $ini) { Start-Process notepad.exe -ArgumentList "`"$ini`"" } else { Write-Log 'php.ini existiert noch nicht.' 'Warn' }
    } })
    $b5.Add_Click({ Invoke-ToolAction -Owner $dlg { Restart-IisStack } })
    $b6.Add_Click({ Invoke-ToolAction -Owner $dlg { Stop-PhpProcesses } })
    $b7.Add_Click({ Invoke-ToolAction -Owner $dlg { if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" } else { Write-Log 'Noch keine Protokolldatei vorhanden.' 'Warn' } } })
    $b8.Add_Click({ Invoke-ToolAction -Owner $dlg { if (Test-Path $script:LogDir) { Start-Process explorer.exe -ArgumentList "`"$script:LogDir`"" } } })
    $b9.Add_Click({ Invoke-ToolAction -Owner $dlg {
        $f = Join-Path $script:LogDir 'mysql-zugangsdaten.txt'
        if (Test-Path $f) { Start-Process notepad.exe -ArgumentList "`"$f`"" } else { Write-Log 'Es wurde noch keine Zugangsdaten-Datei erzeugt.' 'Warn' }
    } })
    $b10.Add_Click({ Invoke-ToolAction -Owner $dlg { Invoke-PreflightUi; if ($script:CurrentPage -ne 'welcome') { Write-Log 'Ergebnis der Systemprüfung steht auf der Seite "Start".' 'Info' } } })
    $bClose.Add_Click({ $dlg.Close() })

    [void]$dlg.ShowDialog($script:Form)
    $script:LblToolsStatus = $null
    $dlg.Dispose()
}


# ==============================================================================
# 21) Ereignisse
# ==============================================================================

$script:BtnRecheck.Add_Click({ Invoke-PreflightUi })

foreach ($c in @($script:ChkWeb, $script:ChkMy, $script:ChkAppDb)) { $c.Add_CheckedChanged({ Update-SelectPageState }) }
$script:BtnAppGen.Add_Click({ $script:TxtAppPw.Text = New-MySqlPassword 16 })

$script:BtnAdvanced.Add_Click({
    # aktuelle Eingaben der einfachen Seite sichern, damit der Dialog sie kennt
    if ($script:CurrentPage -eq 'select') { Save-SelectPage | Out-Null }
    if (Show-AdvancedDialog) {
        if ($script:CurrentPage -eq 'select') { Load-SelectPage }
        Set-Status 'Erweiterte Optionen übernommen.'
    }
})

$script:BtnTools.Add_Click({ Show-ToolsDialog })
$script:BtnAbout.Add_Click({ Show-AboutDialog })

$script:BtnBack.Add_Click({
    switch ($script:CurrentPage) {
        'select'  { Show-Page 'welcome' }
        'install' { Show-Page 'select' }
    }
})

function Start-Installation {
    $err = Save-SelectPage
    if ($err) { Show-Warn $err 'Eingabe prüfen'; return }

    if ($script:Preflight -and -not $script:Preflight.Ok) {
        Show-Warn 'Die Systemprüfung hat ein blockierendes Problem gemeldet. Bitte auf der Seite "Start" prüfen.'; return
    }
    if ($script:Preflight -and $script:Preflight.Reboot.Hard.Count -gt 0) {
        if (-not (Ask-YesNo ("Windows meldet einen ausstehenden Neustart ({0}).`r`n`r`nDie Installation der IIS-Features kann dadurch hängen bleiben. " +
            "Empfohlen wird, den Server zuerst neu zu starten.`r`n`r`nTrotzdem jetzt installieren?" -f ($script:Preflight.Reboot.Hard -join ', ')))) { return }
    }
    if ($script:Cfg.InstallMySql) {
        $blocker = Test-MySqlAlreadyInstalled
        if ($blocker) {
            if (-not (Ask-YesNo ("$blocker`r`n`r`nDie Einrichtung wird erneut durchlaufen. Vorhandene Datenbanken bleiben erhalten; das root-Passwort " +
                "aus den erweiterten Optionen muss zum bestehenden Server passen.`r`n`r`nFortfahren?"))) { return }
        }
    }

    # Zusammenfassung als letzte Bestätigung
    $lines = @('Folgendes wird jetzt installiert:', '')
    if ($script:Cfg.InstallWebStack) {
        $v = ($script:CboPhpItems | Where-Object { $_.Url -eq $script:Cfg.PhpUrl } | Select-Object -First 1)
        $vt = if ($v) { ($v.Display -replace '\s+-\s+empfohlen.*$', '') } else { (Split-Path $script:Cfg.PhpUrl -Leaf) }
        $lines += "  - Webserver (IIS), URL Rewrite, Visual C++ Runtime"
        $lines += "  - $vt"
    }
    if ($script:Cfg.InstallMySql) {
        $lines += "  - MySQL Server 8.4 (Dienst '$($script:Cfg.MyService)', Port $($script:Cfg.MyPort))"
        if ($script:Cfg.AppDbEnabled)     { $lines += "  - Datenbank '$($script:Cfg.AppDbName)' mit Benutzer '$($script:Cfg.AppDbUser)'" }
        if ($script:Cfg.InstallWorkbench) { $lines += '  - MySQL Workbench' }
    }
    if ($script:Cfg.InstallPython) {
        $pyText = if (([string]$script:Cfg.PyUrl).Trim()) { (Split-Path ([string]$script:Cfg.PyUrl).Trim() -Leaf) }
                  else { 'neueste Version wird von python.org ermittelt' }
        $lines += "  - Python ($pyText), inklusive pip und PATH-Eintrag"
    }
    $lines += ''
    $lines += 'Die Installation dauert je nach Server und Internetverbindung etwa 5 bis 20 Minuten.'
    if (-not (Ask-YesNo ($lines -join "`r`n") 'Installation starten?')) { return }

    Show-Page 'install'
    $script:LblInstallHead.Text = 'Installation läuft ...'
    $script:LblInstallHead.ForeColor = $script:ColDark
    $script:LblInstallError.Visible = $false
    $script:BtnInstallLog.Visible = $false
    $script:ProgressOverall.Value = 0
    Set-Busy $true
    $ok = $false
    try {
        Invoke-FullSetup
        $ok = $true
    } catch {
        $msg = $_.Exception.Message
        $script:LblInstallHead.Text = 'Installation abgebrochen'
        $script:LblInstallHead.ForeColor = $script:ColErr
        $script:LblInstallError.Text = "Fehler bei '$($script:Result.FailedStep)': $msg"
        $script:LblInstallError.Visible = $true
        $script:BtnInstallLog.Visible = $true
        Set-Status 'Fehler - siehe Protokoll.'
    } finally {
        Set-Busy $false
    }

    if ($ok) {
        $script:LblInstallHead.Text = 'Installation abgeschlossen'
        $script:LblInstallHead.ForeColor = $script:ColOk
        Set-Status 'Fertig.'
        $script:BtnNext.Visible = $true
        $script:BtnNext.Text = 'Weiter >'
        $script:BtnBack.Visible = $false
        Build-FinishPage
        Show-Page 'finish'
    } else {
        # Zurück zur Auswahl oder erneut versuchen (alle Schritte sind wiederholbar)
        $script:BtnBack.Visible = $true
        $script:BtnNext.Visible = $true
        $script:BtnNext.Text = 'Erneut versuchen'
        $script:BtnTools.Visible = $true
    }
}

$script:BtnNext.Add_Click({
    switch ($script:CurrentPage) {
        'welcome' { Show-Page 'select' }
        'select'  { Start-Installation }
        'install' { Start-Installation }
        'finish'  { $script:Form.Close() }
    }
})

$script:BtnInstallLog.Add_Click({ if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" } })

# --- Abschlussseite ---
$script:BtnCopyPw.Add_Click({
    try { [System.Windows.Forms.Clipboard]::SetText([string]$script:Cfg.MyRootPw); Set-Status 'root-Passwort in die Zwischenablage kopiert.' }
    catch { Show-Warn "Zwischenablage nicht verfügbar: $($_.Exception.Message)" }
})
$script:BtnOpenCred.Add_Click({
    $f = $script:Result.CredFile
    if ($f -and (Test-Path $f)) { Start-Process notepad.exe -ArgumentList "`"$f`"" }
})
$script:BtnReboot.Add_Click({
    if (Ask-YesNo "Den Server jetzt neu starten?`r`n`r`nAlle Programme werden geschlossen." 'Neustart') {
        try { Restart-Computer -Force } catch { Show-Error "Neustart fehlgeschlagen: $($_.Exception.Message)" }
    }
})
$script:BtnFinishBrowser.Add_Click({
    try { if (-not (Test-Path (Join-Path $script:WwwRoot 'phpinfo.php'))) { New-PhpInfoPage | Out-Null } } catch { }
    Open-InBrowser 'http://localhost/phpinfo.php' | Out-Null
})
$script:BtnFinishDelTest.Add_Click({
    try {
        if (Remove-TestPages) { Set-Status 'Testseiten gelöscht.'; Show-Info 'Die Testseiten phpinfo.php und phpcheck.php wurden gelöscht.' }
        else { Show-Info 'Es waren keine Testseiten vorhanden.' }
    } catch { Show-Error $_.Exception.Message }
})
$script:BtnFinishLog.Add_Click({ if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" } })

# Während der Installation nicht einfach schließen
$script:Form.Add_FormClosing({
    param($sender, $e)
    if ($script:Busy) {
        if (-not (Ask-YesNo "Die Installation läuft noch. Wirklich abbrechen?`r`n`r`nEin Abbruch kann den Server in einem halbfertigen Zustand zurücklassen; der Assistent kann später erneut ausgeführt werden.")) {
            $e.Cancel = $true
        }
    }
})

$script:Form.Add_Shown({
    Show-Page 'welcome'
    Update-WelcomeLayout
    Write-Log "$script:AppTitle $script:AppVersion gestartet." 'Step'
    Write-Log $script:IconCreditText
    Write-Log "Protokoll: $script:LogFile"
    Write-Log "Zielordner PHP: $script:PhpRoot"
    Write-Log ("Ausführung: {0}" -f $(if ($script:IsCompiled) { "EXE ($script:SelfPath)" } else { "Skript ($script:SelfPath)" }))
    Write-Log ''
    Invoke-PreflightUi
    Write-Log ''

    # Versionsliste im Hintergrund laden, Ergebnis in die Auswahl übernehmen
    Set-Busy $true
    try {
        $script:PhpReleases = @(Get-PhpReleaseList)
        $rec = Get-RecommendedPhpRelease
        if ($rec -and [string]::IsNullOrWhiteSpace([string]$script:Cfg.PhpUrl)) { $script:Cfg.PhpUrl = $rec.Url }
        Write-Log "$($script:PhpReleases.Count) PHP-Builds gefunden." 'Ok'
        if ($rec) { Write-Log "Empfehlung: $($rec.Display)" }
    } catch {
        Write-Log "Versionsliste konnte nicht geladen werden: $($_.Exception.Message)" 'Error'
        Write-Log 'Unter "Erweiterte Optionen" kann eine Download-URL von Hand eingetragen werden.' 'Info'
    } finally {
        Set-Busy $false
        $script:BtnNext.Enabled = ($null -ne $script:Preflight -and $script:Preflight.Ok)
    }
    # MySQL bereits vorhanden? Dann standardmäßig nicht erneut anhaken.
    if (Test-MySqlServiceExists) { $script:Cfg.InstallMySql = $false; $script:Cfg.InstallWorkbench = $false }
    Set-Status 'Bereit. Klicken Sie auf "Weiter", um die Komponenten auszuwählen.'
})

[void]$script:Form.ShowDialog()
$script:Form.Dispose()

} catch {
    $inv  = $_.InvocationInfo
    $text = "Unerwarteter Fehler:`r`n`r`n$($_.Exception.Message)"
    if ($inv -and $inv.ScriptLineNumber) {
        $text += "`r`n`r`nZeile $($inv.ScriptLineNumber): $(([string]$inv.Line).Trim())"
    }
    if ($_.ScriptStackTrace) { $text += "`r`n`r`n$($_.ScriptStackTrace)" }
    try { Write-Log $text 'Error' } catch { }
    [System.Windows.Forms.MessageBox]::Show($text, "$script:AppTitle - Fehler", 'OK', 'Error') | Out-Null
}