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

The picture picker displays thumbnails even when Explorer is set to always show icons.

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
