<#
  MyPictureFolders - put any picture on a Windows folder's icon, from the right-click menu.

  Usage (normally run for you by the right-click menu):
    FolderPicture.ps1 -Install                 add "Folder picture" to the Explorer right-click menu
    FolderPicture.ps1 -Uninstall               remove it again
    FolderPicture.ps1 -Set    -Folder <path>   pick a picture and make it that folder's icon
    FolderPicture.ps1 -Set    -Folder <path> -Picture <file>   same, without the file picker
    FolderPicture.ps1 -Remove -Folder <path>   put the normal folder icon back

  How it works: the picture is converted to a multi-size .ico saved (hidden) inside the
  folder, and the folder's desktop.ini gets an IconResource line pointing at it - the same
  mechanism as Properties > Customize > Change Icon. Nothing is installed system-wide; the
  menu lives under HKEY_CURRENT_USER, so no admin rights are needed.
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
  [Parameter(ParameterSetName = 'Install', Mandatory)]   [switch] $Install,
  [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
  [Parameter(ParameterSetName = 'Set')]                  [switch] $Set,
  [Parameter(ParameterSetName = 'Remove', Mandatory)]    [switch] $Remove,
  [Parameter(ParameterSetName = 'Set', Mandatory)]
  [Parameter(ParameterSetName = 'Remove', Mandatory)]    [string] $Folder,
  [Parameter(ParameterSetName = 'Set')]                  [string] $Picture,
  [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$IconPrefix = 'folder-picture-'
$MenuKey    = 'MyPictureFolders.FolderPicture'
$OldMenuKeys = @('PicDatabase.FolderPicture')   # earlier name; cleaned up on install/uninstall
$Sizes      = 256, 128, 64, 48, 32, 24, 16

# Invisible always-on-top owner so dialogs open in front of Explorer, not behind it.
function New-Owner {
  $f = New-Object System.Windows.Forms.Form
  $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.Opacity = 0
  $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point -32000, -32000
  $f.Show(); $f.Activate()
  $f
}

function Show-Message([string] $text, [string] $icon = 'Information') {
  if ($Quiet) { Write-Host $text; return }
  $owner = New-Owner
  try { [void][System.Windows.Forms.MessageBox]::Show($owner, $text, 'Folder picture', 'OK', $icon) }
  finally { $owner.Dispose() }
}

# ------------------------------------------------------------------ shell refresh

if (-not ('FolderPicture.Shell' -as [type])) {
  Add-Type -Namespace FolderPicture -Name Shell -MemberDefinition @'
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
'@
}

function Update-Explorer([string] $dir) {
  $SHCNE_UPDATEDIR = 0x1000; $SHCNE_UPDATEITEM = 0x2000; $SHCNE_ASSOCCHANGED = 0x08000000
  $SHCNF_PATHW = 0x0005; $SHCNF_FLUSH = 0x1000
  [FolderPicture.Shell]::SHChangeNotify($SHCNE_UPDATEITEM, $SHCNF_PATHW -bor $SHCNF_FLUSH, $dir, [IntPtr]::Zero)
  $parent = Split-Path -Parent $dir
  if ($parent) {
    [FolderPicture.Shell]::SHChangeNotify($SHCNE_UPDATEDIR, $SHCNF_PATHW -bor $SHCNF_FLUSH, $parent, [IntPtr]::Zero)
  }
  [FolderPicture.Shell]::SHChangeNotify($SHCNE_ASSOCCHANGED, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

# ------------------------------------------------------------------ icon building

function Get-OrientedImage([string] $file) {
  # Read into memory so the source file is never locked or modified.
  $stream = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($file))
  $img = [System.Drawing.Image]::FromStream($stream)
  # Honour the camera's EXIF rotation so portrait photos are not sideways.
  if ($img.PropertyIdList -contains 0x0112) {
    $flip = switch ([int]$img.GetPropertyItem(0x0112).Value[0]) {
      2 { 'RotateNoneFlipX' } 3 { 'Rotate180FlipNone' } 4 { 'Rotate180FlipX' }
      5 { 'Rotate90FlipX' }   6 { 'Rotate90FlipNone' }  7 { 'Rotate270FlipX' }
      8 { 'Rotate270FlipNone' } default { $null }
    }
    if ($flip) { $img.RotateFlip([System.Drawing.RotateFlipType]::$flip) }
  }
  $img
}

function New-IconBytes([System.Drawing.Image] $img) {
  $pngs = foreach ($size in $Sizes) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode  = 'HighQualityBicubic'
    $g.SmoothingMode      = 'HighQuality'
    $g.PixelOffsetMode    = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    # Fit the whole picture inside the square (nothing cropped), centred.
    $scale = [Math]::Min($size / $img.Width, $size / $img.Height)
    $w = [Math]::Max(1, [int][Math]::Round($img.Width * $scale))
    $h = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
    $attrs = New-Object System.Drawing.Imaging.ImageAttributes
    $attrs.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no grey fringe on edges
    $dest = New-Object System.Drawing.Rectangle ([int](($size - $w) / 2)), ([int](($size - $h) / 2)), $w, $h
    $g.DrawImage($img, $dest, 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
    $g.Dispose(); $attrs.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
  }

  # ICO container with PNG-compressed entries (supported since Windows Vista).
  $out = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter $out
  $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$Sizes.Count)
  $offset = 6 + 16 * $Sizes.Count
  for ($i = 0; $i -lt $Sizes.Count; $i++) {
    $dim = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$pngs[$i].Length); $bw.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
  }
  foreach ($png in $pngs) { $bw.Write([byte[]]$png) }
  $bw.Flush()
  $out.ToArray()
}

# ------------------------------------------------------------------ desktop.ini

function Read-DesktopIni([string] $iniPath) {
  if (Test-Path -LiteralPath $iniPath) { @(Get-Content -LiteralPath $iniPath) } else { @() }
}

function Write-DesktopIni([string] $iniPath, [string[]] $lines) {
  if (Test-Path -LiteralPath $iniPath) {
    # desktop.ini is normally Hidden+System, which blocks overwriting it.
    [System.IO.File]::SetAttributes($iniPath, [System.IO.FileAttributes]::Normal)
  }
  [System.IO.File]::WriteAllLines($iniPath, [string[]]$lines, [System.Text.Encoding]::Unicode)
  [System.IO.File]::SetAttributes($iniPath, [System.IO.FileAttributes]'Hidden, System')
}

# Returns the lines with icon settings removed from [.ShellClassInfo], and the
# index just after that section's header (or -1 if there is no such section).
function Remove-IconLines([string[]] $lines) {
  $result = New-Object System.Collections.Generic.List[string]
  $inSection = $false; $insertAt = -1
  foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -match '^\[.*\]$') {
      $inSection = $t -ieq '[.ShellClassInfo]'
      $result.Add($line)
      if ($inSection -and $insertAt -lt 0) { $insertAt = $result.Count }
      continue
    }
    if ($inSection -and $t -match '^(IconResource|IconFile|IconIndex)\s*=') { continue }
    $result.Add($line)
  }
  , @($result.ToArray(), $insertAt)
}

function Remove-OldIcons([string] $dir, [string] $keep) {
  Get-ChildItem -LiteralPath $dir -Force -File -Filter "$IconPrefix*.ico" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $keep } |
    ForEach-Object {
      $_.Attributes = 'Normal'
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ actions

function Resolve-Folder([string] $path) {
  # A drive root arrives as  C:\"  and the shell eats the quote, leaving  C:"
  $path = $path.Trim().Trim('"')
  if ($path -match '^[A-Za-z]:\\?$') {
    throw "Windows only shows custom pictures on folders, not on whole drives ($path).`n`nRight-click a folder instead."
  }
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Folder not found: $path" }
  (Get-Item -LiteralPath $path -Force).FullName.TrimEnd('\')
}

function Set-FolderPicture([string] $dir, [string] $file) {
  if (-not $file) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Choose a picture for `"$(Split-Path -Leaf $dir)`""
    $dlg.Filter = 'Pictures|*.jpg;*.jpeg;*.jfif;*.png;*.bmp;*.gif;*.tif;*.tiff;*.ico|All files|*.*'
    $dlg.InitialDirectory = $dir
    $owner = New-Owner
    try { $ok = $dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK }
    finally { $owner.Dispose() }
    if (-not $ok) { return }
    $file = $dlg.FileName
  }

  try { $img = Get-OrientedImage $file }
  catch { throw "Windows can't read that picture:`n$file`n`nTry a JPG, PNG, BMP, GIF or TIFF." }
  try { $bytes = New-IconBytes $img } finally { $img.Dispose() }

  # A fresh file name every time - Explorer caches icons by path, so reusing a
  # name would keep showing the old picture.
  $iconName = $IconPrefix + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ico'
  $iconPath = Join-Path $dir $iconName
  [System.IO.File]::WriteAllBytes($iconPath, $bytes)
  [System.IO.File]::SetAttributes($iconPath, [System.IO.FileAttributes]'Hidden, System')

  $iniPath = Join-Path $dir 'desktop.ini'
  $lines, $insertAt = Remove-IconLines (Read-DesktopIni $iniPath)
  $entry = "IconResource=$iconName,0"
  if ($insertAt -ge 0) {
    $lines = @($lines[0..($insertAt - 1)]) + $entry + @(if ($insertAt -lt $lines.Count) { $lines[$insertAt..($lines.Count - 1)] })
  } else {
    $lines = @('[.ShellClassInfo]', $entry) + @($lines)
  }
  Write-DesktopIni $iniPath $lines

  # Explorer only reads desktop.ini on folders marked ReadOnly or System.
  # (ReadOnly on a folder does not make its files read-only.)
  $folderItem = Get-Item -LiteralPath $dir -Force
  $folderItem.Attributes = $folderItem.Attributes -bor [System.IO.FileAttributes]::ReadOnly

  Remove-OldIcons $dir $iconName
  Update-Explorer $dir
}

function Remove-FolderPicture([string] $dir) {
  $iniPath = Join-Path $dir 'desktop.ini'
  if (Test-Path -LiteralPath $iniPath) {
    $lines, $null = Remove-IconLines (Read-DesktopIni $iniPath)
    $meaningful = $lines | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\[.*\]$' }
    if ($meaningful) {
      Write-DesktopIni $iniPath $lines
    } else {
      # Nothing else was in it - delete it and drop the ReadOnly flag we added.
      [System.IO.File]::SetAttributes($iniPath, [System.IO.FileAttributes]::Normal)
      Remove-Item -LiteralPath $iniPath -Force
      $folderItem = Get-Item -LiteralPath $dir -Force
      $folderItem.Attributes = $folderItem.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
  }
  Remove-OldIcons $dir ''
  Update-Explorer $dir
}

function Remove-MenuKeys([string[]] $names) {
  foreach ($root in 'Directory', 'Directory\Background') {
    foreach ($name in $names) {
      $menu = "HKCU:\Software\Classes\$root\shell\$name"
      if (Test-Path $menu) { Remove-Item -Path $menu -Recurse -Force }
    }
  }
}

function Install-Menu {
  Remove-MenuKeys $OldMenuKeys
  $script = $PSCommandPath
  Unblock-File -LiteralPath $script -ErrorAction SilentlyContinue
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $base = "`"$ps`" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

  # Right-click ON a folder (Directory) and right-click the EMPTY SPACE inside an
  # open folder (Directory\Background). %V is the folder in both cases.
  foreach ($root in 'Directory', 'Directory\Background') {
    $menu = "HKCU:\Software\Classes\$root\shell\$MenuKey"
    New-Item -Path $menu -Force | Out-Null
    Set-ItemProperty -Path $menu -Name 'MUIVerb' -Value 'Folder picture'
    Set-ItemProperty -Path $menu -Name 'Icon' -Value 'imageres.dll,-72'
    Set-ItemProperty -Path $menu -Name 'SubCommands' -Value ''
    Set-ItemProperty -Path $menu -Name 'MultiSelectModel' -Value 'Single'

    $items = @(
      @{ Key = '1set';    Label = 'Set picture...';      Icon = 'imageres.dll,-72'; Args = '-Set -Folder "%V"' },
      @{ Key = '2remove'; Label = 'Remove picture';      Icon = 'shell32.dll,131'; Args = '-Remove -Folder "%V"' }
    )
    foreach ($it in $items) {
      $k = "$menu\shell\$($it.Key)"
      New-Item -Path "$k\command" -Force | Out-Null
      Set-ItemProperty -Path $k -Name 'MUIVerb' -Value $it.Label
      Set-ItemProperty -Path $k -Name 'Icon' -Value $it.Icon
      Set-Item -Path "$k\command" -Value "$base $($it.Args)"
    }
  }
}

function Uninstall-Menu {
  Remove-MenuKeys (@($MenuKey) + $OldMenuKeys)
}

try {
  switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-Menu;   Show-Message "Done. Right-click any folder and choose `"Folder picture`".`n`nOn Windows 11 it is under `"Show more options`" (or hold Shift while right-clicking)." }
    'Uninstall' { Uninstall-Menu; Show-Message 'The "Folder picture" menu has been removed. Folders that already have a picture keep it.' }
    'Set'       { Set-FolderPicture (Resolve-Folder $Folder) $Picture }
    'Remove'    { Remove-FolderPicture (Resolve-Folder $Folder) }
  }
} catch {
  Show-Message $_.Exception.Message 'Error'
  exit 1
}
