<#
  MyPictureFolders - put any picture on a Windows folder's icon, from the right-click menu.

  Usage (normally run for you by the right-click menu):
    FolderPicture.ps1 -Install                 add "Folder picture" to the Explorer right-click menu
    FolderPicture.ps1 -Uninstall               remove it again
    FolderPicture.ps1 -Set    -Folder <path>   pick a picture and make it that folder's icon
    FolderPicture.ps1 -Set    -Folder <path> -Picture <file>   same, without the file picker
    FolderPicture.ps1 -Set -Clipboard -Folder <path>   use the picture on the clipboard
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
  [Parameter(ParameterSetName = 'Set')]                  [switch] $Clipboard,
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

function Send-FolderChange([string] $path) {
  $flags = 0x0005 -bor 0x1000 # SHCNF_PATHW | SHCNF_FLUSH
  [FolderPicture.Shell]::SHChangeNotify(0x0800, $flags, $path, [IntPtr]::Zero) # SHCNE_ATTRIBUTES
  [FolderPicture.Shell]::SHChangeNotify(0x2000, $flags, $path, [IntPtr]::Zero) # SHCNE_UPDATEITEM
  $parent = Split-Path -Parent $path
  if ($parent) {
    [FolderPicture.Shell]::SHChangeNotify(0x1000, $flags, $parent, [IntPtr]::Zero) # SHCNE_UPDATEDIR
  }
}

function Update-Explorer([string] $dir, [switch] $Network) {
  Send-FolderChange $dir
  if ($Network) {
    # Explorer may be displaying a different path to the same network folder.
    $mapped = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot })
    $networkPath = $dir
    $driveRoot = [System.IO.Path]::GetPathRoot($dir)
    $drive = $mapped | Where-Object { $_.Root -eq $driveRoot } | Select-Object -First 1
    if ($drive) {
      $networkPath = Join-Path $drive.DisplayRoot $dir.Substring($driveRoot.Length)
    }

    $paths = @($dir, $networkPath)
    foreach ($mapping in $mapped) {
      $prefix = $mapping.DisplayRoot.TrimEnd([char]92) + [char]92
      if ($networkPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $paths += Join-Path $mapping.Root $networkPath.Substring($prefix.Length)
      }
    }
    $paths = @($paths | Select-Object -Unique)
    $parents = @($paths | ForEach-Object { (Split-Path -Parent $_).TrimEnd([char]92) })
    $shell = New-Object -ComObject Shell.Application

    # Refresh only views showing this folder's parent. Retry after the network
    # client's directory metadata has had more time to expire.
    foreach ($delay in 1000, 10000) {
      Start-Sleep -Milliseconds $delay
      foreach ($path in $paths) { Send-FolderChange $path }
      foreach ($window in $shell.Windows()) {
        try {
          $viewPath = [string]$window.Document.Folder.Self.Path
          if ($parents -contains $viewPath.TrimEnd([char]92)) { $window.Refresh() }
        } catch {
          # Explorer can close a view while we enumerate it.
          continue
        }
      }
    }
    return
  }
  [FolderPicture.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
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

# Crop one continuous photo across the folder, then outline its perimeter.
function New-FolderComposite([System.Drawing.Image] $photo, [int] $width = 100, [int] $height = 100,
    [int] $horizontal = 0, [int] $vertical = 0) {
  $bmp = New-Object System.Drawing.Bitmap 256, 256, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.SmoothingMode     = 'AntiAlias'
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.PixelOffsetMode   = 'HighQuality'

  $fx = 8; $fy = 24; $fw = 240; $fh = 208
  $scale = [Math]::Max($fw / $photo.Width, $fh / $photo.Height)
  $srcW = $fw / $scale * (100 / $width)
  $srcH = $fh / $scale * (100 / $height)
  # Keep the crop inside the photo, even at the ends of the movement controls.
  $srcX = [Math]::Max(0, $photo.Width - $srcW) * (100 - $horizontal) / 200
  $srcY = [Math]::Max(0, $photo.Height - $srcH) * (100 - $vertical) / 200

  $scaled = New-Object System.Drawing.Bitmap $fw, $fh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $sg = [System.Drawing.Graphics]::FromImage($scaled)
  $sg.InterpolationMode = 'HighQualityBicubic'; $sg.PixelOffsetMode = 'HighQuality'
  $attrs = New-Object System.Drawing.Imaging.ImageAttributes
  $attrs.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)   # no grey fringe on edges
  $sg.DrawImage($photo, (New-Object System.Drawing.Rectangle 0, 0, $fw, $fh),
    [single]$srcX, [single]$srcY, [single]$srcW, [single]$srcH, [System.Drawing.GraphicsUnit]::Pixel, $attrs)
  $sg.Dispose(); $attrs.Dispose()

  $tex = New-Object System.Drawing.TextureBrush $scaled, ([System.Drawing.Drawing2D.WrapMode]::Clamp)
  $tex.TranslateTransform($fx, $fy)
  $silhouette = New-Object System.Drawing.Drawing2D.GraphicsPath
  # Follow the tab, shoulder, and rounded outer corners as one closed outline.
  $silhouette.AddArc(8, 24, 24, 24, 180, 90)
  $silhouette.AddLine(20, 24, 101, 24)
  $silhouette.AddLine(101, 24, 119, 40)
  $silhouette.AddLine(119, 40, 234, 40)
  $silhouette.AddArc(220, 40, 28, 28, 270, 90)
  $silhouette.AddLine(248, 54, 248, 218)
  $silhouette.AddArc(220, 204, 28, 28, 0, 90)
  $silhouette.AddLine(234, 232, 22, 232)
  $silhouette.AddArc(8, 204, 28, 28, 90, 90)
  $silhouette.CloseFigure()
  $g.FillPath($tex, $silhouette)

  $border = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(229, 197, 132)), 7
  $border.LineJoin = 'Round'
  $g.DrawPath($border, $silhouette)
  $border.Dispose(); $silhouette.Dispose(); $tex.Dispose(); $scaled.Dispose(); $g.Dispose()
  $bmp
}

function Show-PicturePreview([System.Drawing.Image] $photo) {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = 'Adjust folder picture'
  $dialog.ClientSize = New-Object System.Drawing.Size 448, 528
  $dialog.StartPosition = 'CenterScreen'
  $dialog.FormBorderStyle = 'FixedDialog'
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false
  $dialog.TopMost = $true

  $preview = New-Object System.Windows.Forms.PictureBox
  $preview.SetBounds(96, 8, 256, 256)
  $dialog.Controls.Add($preview)

  $sliders = @{}
  $rows = @(
    @{ Key = 'Width'; Label = 'Stretch width'; Minimum = 100; Maximum = 400; Value = 100 },
    @{ Key = 'Height'; Label = 'Stretch height'; Minimum = 100; Maximum = 400; Value = 100 },
    @{ Key = 'Horizontal'; Label = 'Move left / right'; Minimum = -100; Maximum = 100; Value = 0 },
    @{ Key = 'Vertical'; Label = 'Move up / down'; Minimum = -100; Maximum = 100; Value = 0 }
  )
  $y = 270
  foreach ($row in $rows) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $row.Label
    $label.SetBounds(12, ($y + 6), 120, 22)
    $slider = New-Object System.Windows.Forms.TrackBar
    $slider.SetBounds(134, $y, 298, 36)
    $slider.TickStyle = 'None'
    $slider.Minimum = $row.Minimum
    $slider.Maximum = $row.Maximum
    $slider.Value = $row.Value
    $slider.SmallChange = 1
    $slider.LargeChange = 10
    $slider.AccessibleName = $row.Label
    $sliders[$row.Key] = $slider
    $dialog.Controls.Add($label)
    $dialog.Controls.Add($slider)
    $y += 40
  }

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = 'Stretch an axis to make more room to move the picture.'
  $hint.SetBounds(12, 434, 424, 38)
  $dialog.Controls.Add($hint)

  $redraw = {
    $previous = $preview.Image
    $preview.Image = New-FolderComposite $photo $sliders.Width.Value $sliders.Height.Value `
      $sliders.Horizontal.Value $sliders.Vertical.Value
    if ($previous) { $previous.Dispose() }
  }
  foreach ($slider in $sliders.Values) { $slider.Add_ValueChanged($redraw) }

  $reset = New-Object System.Windows.Forms.Button
  $reset.Text = 'Reset'
  $reset.SetBounds(12, 482, 88, 32)
  $reset.Add_Click({ foreach ($row in $rows) { $sliders[$row.Key].Value = $row.Value } })
  $apply = New-Object System.Windows.Forms.Button
  $apply.Text = 'Apply'
  $apply.SetBounds(250, 482, 88, 32)
  $apply.DialogResult = 'OK'
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.SetBounds(348, 482, 88, 32)
  $cancel.DialogResult = 'Cancel'
  $dialog.Controls.AddRange(@($reset, $apply, $cancel))
  $dialog.AcceptButton = $apply
  $dialog.CancelButton = $cancel

  try {
    & $redraw
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $result = $preview.Image
      $preview.Image = $null
      $result
    }
  } finally {
    if ($preview.Image) { $preview.Image.Dispose() }
    $dialog.Dispose()
  }
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
    # Fit the (square) folder image into this icon size.
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
  $inSection = $false; $insertAt = -1; $previousIcon = $null
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
      if ($inSection -and $t -match '^(IconResource|IconFile)\s*=\s*(.+)$') {
        $value = $Matches[2] -replace ',\s*0$', ''
        $previousIcon = [System.IO.Path]::GetFileName($value.Trim().Trim('"'))
        continue
      }
      if ($inSection -and $t -match '^IconIndex\s*=') { continue }
      $result.Add([string]$line)
    }
  }
  [pscustomobject]@{ Lines = $result; InsertAt = $insertAt; PreviousIcon = $previousIcon }
}

function Remove-OldIcons([string] $dir, [string] $keep, [string] $previous) {
  Get-ChildItem -LiteralPath $dir -Force -File -Filter "$IconPrefix*.ico" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $keep -and $_.Name -ne $previous } |
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
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = 'Choose a folder picture'
  $dialog.ClientSize = New-Object System.Drawing.Size 780, 500
  $dialog.MinimumSize = New-Object System.Drawing.Size 680, 460
  $dialog.StartPosition = 'CenterScreen'
  $dialog.TopMost = $true

  $layout = New-Object System.Windows.Forms.TableLayoutPanel
  $layout.Dock = 'Fill'
  $layout.ColumnCount = 1
  $layout.RowCount = 3
  [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle 'Absolute', 38))
  [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle 'Percent', 100))
  [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle 'Absolute', 42))
  $dialog.Controls.Add($layout)

  $navigation = New-Object System.Windows.Forms.TableLayoutPanel
  $navigation.Dock = 'Fill'
  $navigation.ColumnCount = 6
  foreach ($width in 50, 85, 75, 90) {
    [void]$navigation.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle 'Absolute', $width))
  }
  [void]$navigation.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle 'Percent', 100))
  [void]$navigation.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle 'Absolute', 50))
  $layout.Controls.Add($navigation, 0, 0)
  $up = New-Object System.Windows.Forms.Button
  $up.Text = 'Up'
  $pictures = New-Object System.Windows.Forms.Button
  $pictures.Text = 'Pictures'
  $drives = New-Object System.Windows.Forms.Button
  $drives.Text = 'Drives'
  $driveMenu = New-Object System.Windows.Forms.ContextMenuStrip
  $paste = New-Object System.Windows.Forms.Button
  $paste.Text = 'Clipboard'
  $address = New-Object System.Windows.Forms.TextBox
  $address.Dock = 'Fill'
  $address.AccessibleName = 'Picture folder path'
  $go = New-Object System.Windows.Forms.Button
  $go.Text = 'Go'
  $navigation.Controls.Add($up, 0, 0)
  $navigation.Controls.Add($pictures, 1, 0)
  $navigation.Controls.Add($drives, 2, 0)
  $navigation.Controls.Add($paste, 3, 0)
  $navigation.Controls.Add($address, 4, 0)
  $navigation.Controls.Add($go, 5, 0)

  $split = New-Object System.Windows.Forms.SplitContainer
  $split.Dock = 'Fill'
  $split.Width = 780
  $split.SplitterDistance = 160
  $layout.Controls.Add($split, 0, 1)
  $folders = New-Object System.Windows.Forms.ListBox
  $folders.Dock = 'Fill'
  $folders.DisplayMember = 'Name'
  $folders.AccessibleName = 'Subfolders'
  $split.Panel1.Controls.Add($folders)
  $gallery = New-Object System.Windows.Forms.ListView
  $gallery.Dock = 'Fill'
  $gallery.View = 'LargeIcon'
  $gallery.MultiSelect = $false
  $gallery.HideSelection = $false
  $gallery.AccessibleName = 'Picture thumbnails'
  $split.Panel2.Controls.Add($gallery)

  $footer = New-Object System.Windows.Forms.FlowLayoutPanel
  $footer.Dock = 'Fill'
  $layout.Controls.Add($footer, 0, 2)
  $previous = New-Object System.Windows.Forms.Button
  $previous.Text = 'Previous'
  $next = New-Object System.Windows.Forms.Button
  $next.Text = 'Next'
  $status = New-Object System.Windows.Forms.Label
  $status.Width = 245
  $status.TextAlign = 'MiddleLeft'
  $open = New-Object System.Windows.Forms.Button
  $open.Text = 'Open'
  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.DialogResult = 'Cancel'
  $dialog.CancelButton = $cancel
  $footer.Controls.AddRange(@($previous, $next, $status, $open, $cancel))

  $state = @{ Path = ''; Files = @(); Offset = 0; Selection = $null }
  $pageSize = 36
  $showPage = {
    $gallery.BeginUpdate()
    try {
      $gallery.Items.Clear()
      $oldImages = $gallery.LargeImageList
      $images = New-Object System.Windows.Forms.ImageList
      $images.ImageSize = New-Object System.Drawing.Size 96, 84
      $images.ColorDepth = 'Depth32Bit'
      $null = $images.Handle
      $gallery.LargeImageList = $images
      if ($oldImages) { $oldImages.Dispose() }
      $end = [Math]::Min($state.Offset + $pageSize, $state.Files.Count)
      for ($index = $state.Offset; $index -lt $end; $index++) {
        $file = $state.Files[$index]
        $item = New-Object System.Windows.Forms.ListViewItem $file.Name
        $item.Tag = $file.FullName
        try {
          $image = Get-OrientedImage $file.FullName
          try {
            $scale = [Math]::Min(96 / $image.Width, 84 / $image.Height)
            $width = [Math]::Max(1, [int]($scale * $image.Width))
            $height = [Math]::Max(1, [int]($scale * $image.Height))
            $thumb = New-Object System.Drawing.Bitmap 96, 84
            $graphics = [System.Drawing.Graphics]::FromImage($thumb)
            try {
              $graphics.InterpolationMode = 'HighQualityBicubic'
              $graphics.DrawImage($image, [int]((96 - $width) / 2), [int]((84 - $height) / 2), $width, $height)
            } finally { $graphics.Dispose() }
            $images.Images.Add($thumb)
            $thumb.Dispose()
            $item.ImageIndex = $images.Images.Count - 1
          } finally { $image.Dispose() }
        } catch {
          # Keep the filename visible even when its preview cannot be decoded.
        }
        [void]$gallery.Items.Add($item)
      }
      $previous.Enabled = $state.Offset -gt 0
      $next.Enabled = $end -lt $state.Files.Count
      $open.Enabled = $false
      $status.Text = if ($end) { "Pictures $($state.Offset + 1)-$end of $($state.Files.Count)" }
                     else { 'No pictures in this folder' }
    } finally { $gallery.EndUpdate() }
  }

  $navigate = {
    param([string] $path)
    if (-not $path) { return }
    try {
      $folder = Get-Item -LiteralPath $path -ErrorAction Stop
      if (-not $folder.PSIsContainer) { throw 'Choose a folder path.' }
      $children = @(Get-ChildItem -LiteralPath $folder.FullName -ErrorAction Stop | Sort-Object Name)
    } catch {
      Show-Message "Could not open that picture folder:`n$($_.Exception.Message)" 'Error'
      return
    }
    $state.Path = $folder.FullName
    $state.Offset = 0
    $state.Files = @($children | Where-Object { -not $_.PSIsContainer -and $_.Extension -match '^\.(jpe?g|jfif|png|bmp|gif|tiff?|ico)$' })
    $address.Text = $state.Path
    $folders.Items.Clear()
    foreach ($child in $children) {
      if ($child.PSIsContainer) { [void]$folders.Items.Add($child) }
    }
    $up.Enabled = [bool](Split-Path -Parent $state.Path)
    & $showPage
  }
  $choose = {
    if ($gallery.SelectedItems.Count) {
      $state.Selection = @{ Path = [string]$gallery.SelectedItems[0].Tag; Temp = $false }
      $dialog.DialogResult = 'OK'
    }
  }
  $up.Add_Click({ & $navigate (Split-Path -Parent $state.Path) })
  $pictures.Add_Click({ & $navigate ([Environment]::GetFolderPath('MyPictures')) })
  $drives.Add_Click({
    $driveMenu.Items.Clear()
    foreach ($root in [System.IO.Directory]::GetLogicalDrives()) {
      $entry = $driveMenu.Items.Add($root)
      $entry.Tag = $root
    }
    $driveMenu.Show($drives, 0, $drives.Height)
  })
  $driveMenu.Add_ItemClicked({
    param($sender, $eventArgs)
    & $navigate $eventArgs.ClickedItem.Tag
  })
  $paste.Add_Click({
    try {
      $state.Selection = Get-ClipboardPicture
      $dialog.DialogResult = 'OK'
    } catch {
      [void][System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Clipboard', 'OK', 'Information')
    }
  })
  $go.Add_Click({ & $navigate $address.Text })
  $address.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') {
      $eventArgs.SuppressKeyPress = $true
      & $navigate $address.Text
    }
  })
  $folders.Add_DoubleClick({ if ($folders.SelectedItem) { & $navigate $folders.SelectedItem.FullName } })
  $previous.Add_Click({ $state.Offset -= $pageSize; & $showPage })
  $next.Add_Click({ $state.Offset += $pageSize; & $showPage })
  $gallery.Add_SelectedIndexChanged({ $open.Enabled = $gallery.SelectedItems.Count -gt 0 })
  $gallery.Add_DoubleClick($choose)
  $open.Add_Click($choose)
  $dialog.AcceptButton = $open

  try {
    & $navigate $dirs[0]
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $state.Selection }
  } finally {
    $driveMenu.Dispose()
    if ($gallery.LargeImageList) { $gallery.LargeImageList.Dispose() }
    $dialog.Dispose()
  }
}

# Saves whatever picture is on the clipboard to a temporary PNG and returns its path.
# Handles: a picture file copied in Explorer (Ctrl+C on the file), a picture copied
# from a browser, Paint, Photos, a screenshot (Win+Shift+S / PrtScn), or a copied
# path to a picture file.
function Get-ClipboardPicture {
  $imageExt = '\.(jpe?g|jfif|png|bmp|gif|tiff?|ico)$'
  $cb = [System.Windows.Forms.Clipboard]

  if ($cb::ContainsFileDropList()) {
    $file = @($cb::GetFileDropList()) | Where-Object { $_ -match $imageExt } | Select-Object -First 1
    if ($file) { return @{ Path = $file; Temp = $false } }
  }

  $img = $null
  $data = $cb::GetDataObject()
  if ($data -and $data.GetDataPresent('PNG')) {
    # Browsers put a PNG copy here, which keeps transparency the plain bitmap loses.
    $png = $data.GetData('PNG')
    if ($png -is [System.IO.Stream]) {
      try { $img = [System.Drawing.Image]::FromStream($png) } catch { $img = $null }
    }
  }
  if (-not $img -and $cb::ContainsImage()) { $img = $cb::GetImage() }
  if ($img) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("folder-picture-clipboard-{0}.png" -f [guid]::NewGuid())
    try { $img.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
    return @{ Path = $tmp; Temp = $true }
  }

  if ($cb::ContainsText()) {
    $text = $cb::GetText().Trim().Trim('"')
    if ($text -match $imageExt -and (Test-Path -LiteralPath $text -PathType Leaf)) {
      return @{ Path = $text; Temp = $false }
    }
  }

  throw "There's no picture on the clipboard.`n`nCopy a picture first - for example right-click a picture in your browser and choose Copy image, take a screenshot with Win+Shift+S, or select a picture file in Explorer and press Ctrl+C."
}

function Set-FolderPicture([string] $dir, [byte[]] $bytes) {

  $iniPath = Join-Path $dir 'desktop.ini'
  $ini = Get-IniWithoutIcon $iniPath
  $reused = $false
  if ($ini.PreviousIcon -like "$IconPrefix*.ico") {
    $oldPath = Join-Path $dir $ini.PreviousIcon
    $oldFile = Get-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
    if ($oldFile -and $oldFile.Length -eq $bytes.Length) {
      $reused = [Convert]::ToBase64String([IO.File]::ReadAllBytes($oldPath)) -ceq [Convert]::ToBase64String($bytes)
    }
  }
  if ($reused) {
    $iconName = $ini.PreviousIcon
    $iconPath = $oldPath
  } else {
    $iconName = $IconPrefix + [Guid]::NewGuid().ToString('N') + '.ico'
    $iconPath = Join-Path $dir $iconName
    [System.IO.File]::WriteAllBytes($iconPath, $bytes)
    [System.IO.File]::SetAttributes($iconPath, [System.IO.FileAttributes]'Hidden, System')
  }
  # A relative IconFile works across drive mappings and UNC paths to the same share.
  $root = [System.IO.Path]::GetPathRoot($dir)
  $isNetwork = $dir.StartsWith('\\') -or
    ([System.IO.DriveInfo]::new($root).DriveType -eq [System.IO.DriveType]::Network)
  if ($isNetwork) {
    $entries = [string[]]@("IconFile=$iconName", 'IconIndex=0')
  } else {
    $entries = [string[]]@("IconResource=$iconPath,0")
  }
  if ($ini.InsertAt -ge 0) {
    $ini.Lines.InsertRange($ini.InsertAt, $entries)
  } else {
    $ini.Lines.InsertRange(0, $entries)
    $ini.Lines.Insert(0, '[.ShellClassInfo]')
  }
  $folderItem = Get-Item -LiteralPath $dir -Force
  $folderFlag = [System.IO.FileAttributes]::ReadOnly
  if ($isNetwork) {
    $folderFlag = [System.IO.FileAttributes]::System
    # Record ownership so Remove preserves a System flag set by something else.
    if (-not ($folderItem.Attributes -band $folderFlag) -and
        -not $ini.Lines.Contains('; MyPictureFolders added the System attribute')) {
      $ini.Lines.Add('; MyPictureFolders added the System attribute')
    }
  }
  Write-DesktopIni $iniPath $ini.Lines.ToArray()

  # Explorer only reads desktop.ini on folders marked ReadOnly or System.
  # (ReadOnly on a folder does not make its files read-only.)
  $folderItem.Attributes = $folderItem.Attributes -bor $folderFlag
  if (-not ((Get-Item -LiteralPath $dir -Force).Attributes -band $folderFlag)) {
    throw "Windows could not keep the $folderFlag attribute on this folder:`n$dir"
  }

  # Explorer can still be displaying the previous icon after the write.
  if (-not $reused) { Remove-OldIcons $dir $iconName $ini.PreviousIcon }
  Update-Explorer $dir -Network:$isNetwork
}

function Remove-FolderPicture([string] $dir) {
  $iniPath = Join-Path $dir 'desktop.ini'
  if (Test-Path -LiteralPath $iniPath) {
    $ini = Get-IniWithoutIcon $iniPath
    $addedSystem = $ini.Lines.Remove('; MyPictureFolders added the System attribute')
    $lines = $ini.Lines.ToArray()
    $meaningful = $lines | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\[.*\]$' }
    if ($meaningful) {
      Write-DesktopIni $iniPath $lines
    } else {
      # Nothing else was in it - delete it and drop the ReadOnly flag we added.
      [System.IO.File]::SetAttributes($iniPath, [System.IO.FileAttributes]::Normal)
      Remove-Item -LiteralPath $iniPath -Force
      $folderItem = Get-Item -LiteralPath $dir -Force
      $folderItem.Attributes = $folderItem.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
      if ($addedSystem) {
        $folderItem.Attributes = $folderItem.Attributes -band (-bnot [System.IO.FileAttributes]::System)
      }
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
  # Start clean so menu items renamed or removed in newer versions don't linger.
  Remove-MenuKeys (@($MenuKey) + $OldMenuKeys)
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
      @{ Key = '2clip';   Label = 'Set from clipboard';  Icon = 'imageres.dll,-5308'; Args = '-Set -Clipboard -Folder "%V"' },
      @{ Key = '3remove'; Label = 'Remove picture';      Icon = 'shell32.dll,131'; Args = '-Remove -Folder "%V"' }
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
  @{ Name = 'Folder picture - From clipboard'; Args = '-Set -Clipboard -Folder'; Icon = 'imageres.dll,-5308' },
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
  $app = $shell.CreateShortcut((Join-Path $sendTo 'MyPictureFolders.lnk'))
  $app.TargetPath = Join-Path (Split-Path -Parent $script) 'Open MyPictureFolders.cmd'
  $app.WorkingDirectory = Split-Path -Parent $script
  $app.IconLocation = "$env:SystemRoot\System32\imageres.dll,-72"
  $app.Save()

}

function Uninstall-SendTo {
  $sendTo = [Environment]::GetFolderPath('SendTo')
  Remove-Item -LiteralPath (Join-Path $sendTo 'MyPictureFolders.lnk') -Force -ErrorAction SilentlyContinue
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
    'Install'   { Install-Menu;   Show-Message "Done. Right-click any folder, then:`n`n  Send to > Folder picture - Set`n  Send to > Folder picture - From clipboard`n`nor hold Shift while right-clicking and choose Folder picture." }
    'Uninstall' { Uninstall-Menu; Show-Message 'The "Folder picture" menu has been removed. Folders that already have a picture keep it.' }
    'Set' {
      $dirs = @(@($Folder) + @($MoreFolders) | Where-Object { $_ } | ForEach-Object { Resolve-Folder $_ })
      $selection = $null
      $adjustPicture = $Clipboard -or -not $Picture
      try {
        if ($Clipboard) { $selection = Get-ClipboardPicture }
        elseif (-not $Picture) { $selection = Select-Picture $dirs }
        if ($selection) { $Picture = $selection.Path }
        if ($Picture) {
          try { $img = Get-OrientedImage $Picture }
          catch { throw "Windows can't read that picture:`n$Picture`n`nTry a JPG, PNG, BMP, GIF or TIFF." }
          try {
            $folderImg = if ($adjustPicture) { Show-PicturePreview $img } else { New-FolderComposite $img }
          } finally { $img.Dispose() }
          if ($folderImg) {
            try { $bytes = New-IconBytes $folderImg } finally { $folderImg.Dispose() }
            foreach ($d in $dirs) { Set-FolderPicture $d $bytes }
          }
        }
      } finally {
        if ($selection -and $selection.Temp) { Remove-Item -LiteralPath $selection.Path -Force -ErrorAction SilentlyContinue }
      }
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
