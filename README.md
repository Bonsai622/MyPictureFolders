# MyPictureFolders

Put any picture on a folder's icon in Windows Explorer, straight from the right-click menu.

## Install

1. Put this folder at `C:\Projects\MyPictureFolders` (anywhere works, but don't move it
   after installing — or just run the installer again if you do).
2. Double-click **`Install Folder Picture Menu.cmd`**.

No admin rights needed; it only affects your own Windows account.

## Use

Right-click any folder → **Send to** → **Folder picture - Set**, choose an image, and the
folder's icon becomes that picture (best seen in Medium/Large icons view).
**Folder picture - Remove** puts the normal folder icon back.

**Folder picture - From clipboard** uses whatever picture you last copied instead of
asking: a picture copied from a browser (right-click → Copy image), a screenshot
(<kbd>Win</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd>), a picture copied in Paint or Photos, or a
picture file selected in Explorer and copied with <kbd>Ctrl</kbd>+<kbd>C</kbd>.

The picker opens in the selected folder (the first folder for a multi-selection).
Use **Pictures** for your Windows Pictures folder, **Drives** for local and mapped
drives, or **Clipboard** for a copied image or screenshot. The picker displays thumbnails even when Explorer is set to always show icons.

Picking an image or using the clipboard opens a live preview. Use **Stretch width**
and **Stretch height** to resize the picture independently, and **Move left / right**
and **Move up / down** to position it. **Reset** restores the centered crop.
Click **Apply** when the preview looks right.

Select several folders first to give them all the same picture in one go.

There is also a **Folder picture** submenu in the full (classic) right-click menu: hold
<kbd>Shift</kbd> while right-clicking, or choose **Show more options**. That one also
works on the empty space inside an open folder.

## Updating

```powershell
cd C:\Projects\MyPictureFolders
git pull
```

Then double-click **`Install Folder Picture Menu.cmd`** again (needed whenever new menu
entries are added).

## Details

- Works with JPG, PNG, BMP, GIF, TIFF, and ICO. Phone photos are rotated the right way up.
- The picture fills the folder silhouette, including the tab, with a manila border
  around the outside. The default crop keeps the picture's proportions.
- Your original picture is never changed. A small hidden `folder-picture-….ico` and the
  usual hidden `desktop.ini` are saved inside the folder — the same mechanism as
  Properties → Customize → Change Icon. Local folders use the icon's full path, so
  apply the picture again after moving or renaming a local folder. Network shares use
  a relative icon path so the same icon file can be found through different mappings.
- Drives (like `C:\`) can't be given a picture — only folders.
- To take the menus away, run **`Uninstall Folder Picture Menu.cmd`**. Folders that already
  have a picture keep it.

## NAS and network shares

After updating from an older version, apply the picture again to the NAS folder to rewrite
its existing icon settings. Refresh the parent folder in Explorer to check the result.

Windows security updates can block folder customization from untrusted network sources.
If the icon works on a local folder but still does not show on your NAS, Windows may
need to trust your NAS hostname. See
[Microsoft's guidance on custom folder icons after the June 2026 security update](https://support.microsoft.com/en-us/servicing/os/windows/docs/2026/06/custom-folder-icons-or-localized-folder-names-might-not-appear-after-installing-the-june-2026-window).

## From a terminal

```powershell
.\FolderPicture.ps1 -Set -Folder "D:\Photos\2024 Trip"                      # pick with a dialog
.\FolderPicture.ps1 -Set -Folder "D:\Photos\2024 Trip" -Picture "D:\cover.jpg"
.\FolderPicture.ps1 -Remove -Folder "D:\Photos\2024 Trip"
```

## MyPictureFolders desktop app

Run **Install Folder Picture Menu.cmd** once after updating. In Explorer select one or
more folders and choose **Send to → MyPictureFolders**. The app remembers their actual
paths and opens a cover editor for each. Sending a NAS folder adds it in place.
Double-click **Open MyPictureFolders.cmd** to return to your library.

The first launch creates a per-user Python environment and installs Pillow. It needs
Windows Python 3 with Tk (3.9 or later) and internet access for initial setup.
Choose a display name, border color, image, position and stretch. **Save cover** writes
the artwork and settings to a .mypicturefolders.json file inside the folder, so the
account used for the NAS share needs write access. These covers appear inside the app.
Ordinary folders use a plain folder illustration and images have independent thumbnails.
Use **New folder** and **Add files** to create real folders and copy files into them.

## Indexed media catalog

Open **Media catalog → Watch folder** and select your library root. The scanner indexes
photos and videos recursively. It stores file paths, metadata, favorites, tags and small
thumbnail images in a local SQLite database under %LOCALAPPDATA%\MyPictureFolders.
The originals stay on the selected drive or NAS. The first scan reads the originals to
build previews. Later scans use file size and modification time to identify changes.
Leave the same drive mapping available, or select the NAS using its UNC path.
A disconnected share leaves previous catalog entries available for browsing.

The app registers **MyPictureFolders hourly media scan** in Windows Task Scheduler for
the signed-in user. It runs even when the app window is closed, while the PC is awake
and the account is signed in. **Scan now** requests an immediate scan.
Double-click a folder to browse its direct media or change View to browse all indexed
photos/videos. Double-click media to open the original with its Windows default app.
Select a tile to edit its comma-separated tags. Folder tags also match its direct media
in filtered views. Use **Toggle favorite** on a folder, then **Favorite folders only**.
Tags and favorites are keyed to paths; externally renaming or moving items can create
new catalog entries.

The person label uses the part of the folder name before the first digit, replacing
hyphens, underscores and periods with spaces. For example, Jane-2025 is Jane,
Jane-B-2025 is Jane B, and Jane-Brown-2025 is Jane Brown. Undated subfolders inherit
a recognized parent label. Use the Person menu to see indexed names.
