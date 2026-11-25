<#
  MyPictureFolders - put any picture on a Windows folder's icon, from the right-click menu.

  Usage (normally run for you by the right-click menu):
    FolderPicture.ps1 -Install                 add "Folder picture" to the Explorer right-click menu
    FolderPicture.ps1 -Uninstall               remove it again
    FolderPicture.ps1 -Set    -Folder <path>   pick a picture and make it that folder's icon
    FolderPicture.ps1 -Set    -Folder <path> -Picture <file>   same, without the file picker
    FolderPicture.ps1 -Remove -Folder <path>   put the normal folder icon back
    Several folders can follow -Folder (that is what "Send to" passes when you select
    more than one); -Set then asks for one picture and puts it on all of them.

  How it works: the picture is converted to a multi-size .ico saved (hidden) inside the
  folder, and the folder's desktop.ini gets an IconResource line pointing at it - the same
  mechanism as Properties > Customize > Change Icon. Nothing is installed system-wide; the
  menu lives under HKEY_CURRENT_USER, so no admin rights are needed.
#>
# PositionalBinding off: extra folder paths from Send to must land in $MoreFolders, not $Picture.
[CmdletBinding(DefaultParameterSetName = 'Set', PositionalBinding = $false)]
param(
  [Parameter(ParameterSetName = 'Install', Mandatory)]   [switch] $Install,
  [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
  [Parameter(ParameterSetName = 'Set')]                  [switch] $Set,
  [Parameter(ParameterSetName = 'Remove', Mandatory)]    [switch] $Remove,
  [Parameter(ParameterSetName = 'Set', Mandatory)]
  [Parameter(ParameterSetName = 'Remove', Mandatory)]    [string] $Folder,
  [Parameter(ParameterSetName = 'Set')]                  [string] $Picture,
  [Parameter(ParameterSetName = 'Set', ValueFromRemainingArguments)]
  [Parameter(ParameterSetName = 'Remove', ValueFromRemainingArguments)] [string[]] $MoreFolders,
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
  # Dialogs centre themselves on their owner, so the owner sits (invisibly) in the
  # middle of the screen - parking it off-screen would put the dialogs off-screen too.
  $f.TopMost = $true; $f.ShowInTaskbar = $false; $f.Opacity = 0
  $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Size = New-Object System.Drawing.Size 1, 1
  $f.Location = New-Object System.Drawing.Point ([int]($area.X + $area.Width / 2)), ([int]($area.Y + $area.Height / 3))
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
  # Ask Windows to refresh its icon cache as well.
  $ie4 = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
  if (Test-Path -LiteralPath $ie4) {
    try { Start-Process -FilePath $ie4 -ArgumentList '-show' -WindowStyle Hidden -Wait } catch { }
  }
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

# A 32-bit icon bitmap: BITMAPINFOHEADER (height doubled for the mask), BGRA rows
# bottom-up, then an all-zero AND mask (transparency comes from the alpha channel).
function ConvertTo-IconDib([System.Drawing.Bitmap] $bmp) {
  $n = $bmp.Width
  $rect = New-Object System.Drawing.Rectangle 0, 0, $n, $n
  $data = $bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $n * 4
  $pixels = New-Object byte[] ($stride * $n)
  for ($y = 0; $y -lt $n; $y++) {
    [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $pixels, $y * $stride, $stride)
  }
  $bmp.UnlockBits($data)

  $maskRow = [int][Math]::Ceiling($n / 32) * 4
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter $ms
  $bw.Write([UInt32]40); $bw.Write([Int32]$n); $bw.Write([Int32]($n * 2))
  $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]0)
  $bw.Write([UInt32]($stride * $n + $maskRow * $n))
  $bw.Write([Int32]0); $bw.Write([Int32]0); $bw.Write([UInt32]0); $bw.Write([UInt32]0)
  for ($y = $n - 1; $y -ge 0; $y--) { $bw.Write($pixels, $y * $stride, $stride) }
  $bw.Write((New-Object byte[] ($maskRow * $n)))
  $bw.Flush()
  $ms.ToArray()
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
    if ($size -ge 256) {
      # 256px entry: PNG-compressed, as Windows' own icons do.
      $ms = New-Object System.IO.MemoryStream
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      , $ms.ToArray()
    } else {
      # Smaller entries: classic uncompressed bitmap, which every part of Explorer reads.
      $dib = ConvertTo-IconDib $bmp
      $bmp.Dispose()
      , $dib
    }
  }

  # ICO container: header, one directory entry per size, then the image data.
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

function Write-DesktopIni([string] $iniPath, [string[]] $lines) {
  if (Test-Path -LiteralPath $iniPath) {
    # desktop.ini is normally Hidden+System, which blocks overwriting it.
    [System.IO.File]::SetAttributes($iniPath, [System.IO.FileAttributes]::Normal)
  }
  [System.IO.File]::WriteAllLines($iniPath, [string[]]$lines, [System.Text.Encoding]::Unicode)
  [System.IO.File]::SetAttributes($iniPath, [System.IO.FileAttributes]'Hidden, System')
}

# Reads desktop.ini with the icon settings taken out of [.ShellClassInfo].
# Returns an object (not a bare array, which PowerShell would unroll) holding the
# remaining lines and the index just after the [.ShellClassInfo] header (-1 if none).
# Stray lines that are neither a setting, a section header nor a comment are dropped -
# that also cleans up the junk lines an earlier version of this script wrote.
function Get-IniWithoutIcon([string] $iniPath) {
  $result = New-Object System.Collections.Generic.List[string]
  $inSection = $false; $insertAt = -1
  if (Test-Path -LiteralPath $iniPath) {
    foreach ($line in @(Get-Content -LiteralPath $iniPath -Force)) {
      $t = ([string]$line).Trim()
      if ($t -match '^\[.*\]$') {
        $inSection = $t -ieq '[.ShellClassInfo]'
        if ($inSection -and $insertAt -ge 0) { continue }   # duplicate header
        $result.Add($t)
        if ($inSection) { $insertAt = $result.Count }
        continue
      }
      if ($t -and $t -notmatch '^;' -and $t -notmatch '=') { continue }   # junk
      if ($inSection -and $t -match '^(IconResource|IconFile|IconIndex)\s*=') { continue }
      $result.Add([string]$line)
    }
  }
  [pscustomobject]@{ Lines = $result; InsertAt = $insertAt }
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
  if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    throw "That isn't a folder:`n$path`n`nFolder pictures can only go on folders."
  }
  (Get-Item -LiteralPath $path -Force).FullName.TrimEnd('\')
}

function Select-Picture([string[]] $dirs) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = if ($dirs.Count -eq 1) { "Choose a picture for `"$(Split-Path -Leaf $dirs[0])`"" }
                 else { "Choose a picture for $($dirs.Count) folders" }
    $dlg.Filter = 'Pictures|*.jpg;*.jpeg;*.jfif;*.png;*.bmp;*.gif;*.tif;*.tiff;*.ico|All files|*.*'
    $dlg.InitialDirectory = $dirs[0]
    $owner = New-Owner
    try { $ok = $dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK }
    finally { $owner.Dispose() }
    if ($ok) { $dlg.FileName }
}

function Set-FolderPicture([string] $dir, [string] $file) {

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
  $ini = Get-IniWithoutIcon $iniPath
  # Full path, the same way Windows' own Properties > Customize > Change Icon writes it.
  $entry = "IconResource=$iconPath,0"
  if ($ini.InsertAt -ge 0) {
    $ini.Lines.Insert($ini.InsertAt, $entry)
  } else {
    $ini.Lines.Insert(0, $entry)
    $ini.Lines.Insert(0, '[.ShellClassInfo]')
  }
  Write-DesktopIni $iniPath $ini.Lines.ToArray()

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
    $lines = (Get-IniWithoutIcon $iniPath).Lines.ToArray()
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
  Install-SendTo $ps $script
}

# "Send to" entries. Unlike the classic right-click menu, Send to shows directly in
# the Windows 11 right-click menu. Send to adds the selected folder path(s) after -Folder.
$SendToItems = @(
  @{ Name = 'Folder picture - Set';    Args = '-Set -Folder';    Icon = 'imageres.dll,-72' },
  @{ Name = 'Folder picture - Remove'; Args = '-Remove -Folder'; Icon = 'shell32.dll,131' }
)

function Install-SendTo([string] $ps, [string] $script) {
  $sendTo = [Environment]::GetFolderPath('SendTo')
  $shell = New-Object -ComObject WScript.Shell
  foreach ($it in $SendToItems) {
    $lnk = $shell.CreateShortcut((Join-Path $sendTo "$($it.Name).lnk"))
    $lnk.TargetPath = $ps
    $lnk.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" $($it.Args)"
    $lnk.IconLocation = "$env:SystemRoot\System32\$($it.Icon)"
    $lnk.WindowStyle = 7   # start minimised so no console flashes up
    $lnk.Save()
  }
}

function Uninstall-SendTo {
  $sendTo = [Environment]::GetFolderPath('SendTo')
  foreach ($it in $SendToItems) {
    Remove-Item -LiteralPath (Join-Path $sendTo "$($it.Name).lnk") -Force -ErrorAction SilentlyContinue
  }
}

function Uninstall-Menu {
  Remove-MenuKeys (@($MenuKey) + $OldMenuKeys)
  Uninstall-SendTo
}

try {
  switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-Menu;   Show-Message "Done. Right-click any folder, then:`n`n  Send to > Folder picture - Set`n`nor hold Shift while right-clicking and choose Folder picture." }
    'Uninstall' { Uninstall-Menu; Show-Message 'The "Folder picture" menu has been removed. Folders that already have a picture keep it.' }
    'Set' {
      $dirs = @(@($Folder) + @($MoreFolders) | Where-Object { $_ } | ForEach-Object { Resolve-Folder $_ })
      if (-not $Picture) { $Picture = Select-Picture $dirs }
      if ($Picture) { foreach ($d in $dirs) { Set-FolderPicture $d $Picture } }
    }
    'Remove' {
      $dirs = @(@($Folder) + @($MoreFolders) | Where-Object { $_ } | ForEach-Object { Resolve-Folder $_ })
      foreach ($d in $dirs) { Remove-FolderPicture $d }
    }
  }
} catch {
  Show-Message $_.Exception.Message 'Error'
  exit 1
}
