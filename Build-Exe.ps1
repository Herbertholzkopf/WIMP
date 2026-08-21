<#
 Erzeugt aus PHP-IIS-MySQL-Setup.ps1 eine eigenständige EXE (PS2EXE).

 Aufruf auf einem Windows-Rechner mit Internetzugang:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Exe.ps1

 Symbol: Liegt neben diesem Skript eine Datei setup.ico, wird sie in die EXE
 eingebettet und erscheint im Explorer, in der Taskleiste und im Fenster.
 Eine .ico-Datei aus einem PNG erzeugt New-Icon.ps1 (siehe dort).

 Bildnachweis fuer das Symbol: "Werkzeugkasten" von Magnific
 https://www.magnific.com/de/icon/werkzeugkasten_17119213
 Das Symbol wurde nachtraeglich mit KI veraendert.
#>
[CmdletBinding()]
param(
    [string]$IconFile = 'setup.ico',
    [string]$Version  = '2.1.0.0'
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installiere Modul ps2exe (PowerShell Gallery) ...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$src = Join-Path $PSScriptRoot 'PHP-IIS-MySQL-Setup.ps1'
$dst = Join-Path $PSScriptRoot 'PHP-IIS-MySQL-Setup.exe'
if (-not (Test-Path -LiteralPath $src)) { throw "Quelldatei nicht gefunden: $src" }

<#
 WICHTIG - Metadaten:
 PS2EXE schreibt diese Texte unveraendert als C#-Attribute in eine temporaere
 Quelldatei ([assembly: AssemblyTrademark("...")]) und uebersetzt sie. Ein
 doppeltes Anfuehrungszeichen im Text beendet dort die Zeichenkette und der
 Compiler bricht mit "error CS1026: ) erwartet" ab. Auch Backslashes und
 Umlaute koennen Aerger machen. Deshalb: Metadaten in ASCII und ohne " und \.
 Die Funktion unten raeumt das notfalls automatisch auf.
#>
function Get-SafeMetaText {
    param([string]$Text)
    # -creplace (Gross-/Kleinschreibung beachtend); eine Hashtable ginge nicht,
    # weil deren Schluessel in PowerShell nicht zwischen 'ä' und 'Ä' unterscheiden.
    $t = $Text -replace '"', "'" -replace '\\', '/'
    $t = $t -creplace 'ä', 'ae' -creplace 'ö', 'oe' -creplace 'ü', 'ue' `
            -creplace 'Ä', 'Ae' -creplace 'Ö', 'Oe' -creplace 'Ü', 'Ue' -creplace 'ß', 'ss'
    # alles ausserhalb des druckbaren ASCII-Bereichs entfernen
    ($t -replace '[^\x20-\x7E]', '').Trim()
}

$params = @{
    inputFile    = $src
    outputFile   = $dst
    noConsole    = $true      # kein schwarzes Konsolenfenster
    requireAdmin = $true      # UAC-Abfrage beim Doppelklick
    STA          = $true      # Pflicht fuer WinForms
    x64          = $true
    version      = $Version
    title        = (Get-SafeMetaText 'PHP + IIS Setup-Assistent')
    description  = (Get-SafeMetaText 'Richtet IIS, PHP und MySQL auf Windows Server ein')
    company      = (Get-SafeMetaText 'Intern')
    product      = (Get-SafeMetaText 'PHP-IIS-MySQL-Setup')
    copyright    = (Get-SafeMetaText ('(c) ' + (Get-Date).Year))
    # PS2EXE kennt kein Feld "Kommentar". Von den moeglichen Feldern wird
    # trademark im Explorer unter Eigenschaften > Details angezeigt - dort
    # steht deshalb der Bildnachweis fuer das Symbol.
    trademark    = (Get-SafeMetaText 'Symbol: Werkzeugkasten von Magnific (magnific.com), nachtraeglich mit KI veraendert.')
}

$ico = Join-Path $PSScriptRoot $IconFile
if (Test-Path -LiteralPath $ico) {
    $params.iconFile = $ico
    Write-Host "Symbol: $ico"
} else {
    Write-Warning "Keine Symboldatei '$IconFile' gefunden - die EXE bekommt das Standardsymbol."
}

# Zeitstempel merken: PS2EXE beendet sich auch nach einem Uebersetzungsfehler
# ohne Ausnahme, eine alte EXE bliebe dann unbemerkt liegen.
$before = if (Test-Path -LiteralPath $dst) { (Get-Item -LiteralPath $dst).LastWriteTimeUtc } else { [datetime]::MinValue }

Invoke-ps2exe @params

if (-not (Test-Path -LiteralPath $dst) -or (Get-Item -LiteralPath $dst).LastWriteTimeUtc -le $before) {
    throw ('Es wurde keine neue EXE erzeugt - PS2EXE hat abgebrochen. ' +
           'Details mit "Invoke-ps2exe @params -verbose" pruefen.')
}

Write-Host "Fertig: $dst"
Write-Host 'Hinweis: Zeigt der Explorer noch das alte Symbol, liegt das am Symbol-Zwischenspeicher.'
Write-Host 'Abhilfe: EXE umbenennen oder "ie4uinit.exe -show" ausfuehren.'