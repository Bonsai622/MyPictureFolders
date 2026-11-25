# MyPictureFolders

Put any picture on a folder's icon in Windows Explorer, straight from the right-click menu.

## Install

1. Put this folder at `C:\Projects\MyPictureFolders` (anywhere works, but don't move it
   after installing — or just run the installer again if you do).
2. Double-click **`Install Folder Picture Menu.cmd`**.

No admin rights needed; it only affects your own Windows account.

## Use

Right-click any folder → **Folder picture** → **Set picture…**, choose an image, and the
folder's icon becomes that picture (best seen in Medium/Large icons view). It also works by
right-clicking the empty space inside an open folder.

**Remove picture** puts the normal folder icon back.

On Windows 11 the menu is under **Show more options** (or hold <kbd>Shift</kbd> while
right-clicking).

## Details

- Works with JPG, PNG, BMP, GIF, TIFF, and ICO. Phone photos are rotated the right way up.
- The whole picture is shown, centred in the icon — nothing is cropped off.
- Your original picture is never changed. A small hidden `folder-picture-….ico` and the
  usual hidden `desktop.ini` are saved inside the folder — the same mechanism as
  Properties → Customize → Change Icon — so the picture stays with the folder if you move
  or copy it.
- Drives (like `C:\`) can't be given a picture — only folders.
- To take the menu away, run **`Uninstall Folder Picture Menu.cmd`**. Folders that already
  have a picture keep it.

## From a terminal

```powershell
.\FolderPicture.ps1 -Set -Folder "D:\Photos\2024 Trip"                      # pick with a dialog
.\FolderPicture.ps1 -Set -Folder "D:\Photos\2024 Trip" -Picture "D:\cover.jpg"
.\FolderPicture.ps1 -Remove -Folder "D:\Photos\2024 Trip"
```
