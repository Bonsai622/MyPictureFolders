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

Select several folders first to give them all the same picture in one go.

There is also a **Folder picture** submenu in the full (classic) right-click menu: hold
<kbd>Shift</kbd> while right-clicking, or choose **Show more options**. That one also
works on the empty space inside an open folder.

## Updating

```powershell
cd C:\Projects\MyPictureFolders
git pull
```

Then double-click **`Install Folder Picture Menu.cmd`** again.

## Details

- Works with JPG, PNG, BMP, GIF, TIFF, and ICO. Phone photos are rotated the right way up.
- The icon keeps the folder shape: the yellow tab and back of a folder, with your
  picture covering the whole front and a folded lip and crease along its top. The
  picture keeps its proportions, so a little is trimmed off the sides (or top and
  bottom) when its shape doesn't match the folder front.
- Your original picture is never changed. A small hidden `folder-picture-….ico` and the
  usual hidden `desktop.ini` are saved inside the folder — the same mechanism as
  Properties → Customize → Change Icon. Like Windows' own setting, it records the icon's
  full path, so if you move or rename the folder, set the picture again.
- Drives (like `C:\`) can't be given a picture — only folders.
- To take the menus away, run **`Uninstall Folder Picture Menu.cmd`**. Folders that already
  have a picture keep it.

## From a terminal

```powershell
.\FolderPicture.ps1 -Set -Folder "D:\Photos\2024 Trip"                      # pick with a dialog
.\FolderPicture.ps1 -Set -Folder "D:\Photos\2024 Trip" -Picture "D:\cover.jpg"
.\FolderPicture.ps1 -Remove -Folder "D:\Photos\2024 Trip"
```
