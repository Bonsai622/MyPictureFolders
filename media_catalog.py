"""Local metadata and preview cache for media kept on disk or on an SMB share."""
import contextlib
import io
import os
from pathlib import Path
import re
import sqlite3
import shutil
import subprocess
import sys
import time
import unicodedata

from PIL import Image, ImageOps

PHOTOS = {".jpg", ".jpeg", ".jfif", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff", ".avif"}
VIDEOS = {".mp4", ".m4v", ".mov", ".mkv", ".avi", ".wmv", ".webm", ".mpg", ".mpeg", ".mts", ".m2ts"}
TASK = "MyPictureFolders hourly media scan"


def person_name(name):
    prefix = re.split(r"\d", unicodedata.normalize("NFKC", name), maxsplit=1)[0]
    # Folder names may use a typographic dash or open a bracket before the date.
    prefix = "".join(" " if unicodedata.category(c) == "Pd" or c in "_." else c for c in prefix)
    prefix = re.sub(r"(?<=[a-z])(?=[A-Z](?:[a-z]|$|[^\w]))", " ", prefix)
    cleaned = " ".join(prefix.strip(" ()[]{}").split())
    if cleaned.casefold().replace(" ", "") == "jodiegasson":
        return "Jodie Gasson"
    # Old sets often use all caps or all lowercase. Use a consistent display
    # label while keeping initials distinct (Jo E and Joe are different keys).
    return " ".join(word.capitalize() if word.isupper() or word.islower() else word
                    for word in cleaned.split())


def migrate_model_keys(db, table):
    # Retain old keys as backups when two formerly separate covers converge.
    with db:
        if table == "model_covers":
            for name, data in db.execute("SELECT model,settings FROM model_covers ORDER BY model").fetchall():
                key = person_name(name).casefold()
                if key and key != name:
                    db.execute("INSERT OR IGNORE INTO model_covers VALUES(?,?)", (key,data))
        else:
            for (name,) in db.execute("SELECT name FROM favorites WHERE kind='model'").fetchall():
                key = person_name(name).casefold()
                if key and key != name:
                    db.execute("INSERT OR IGNORE INTO favorites VALUES('model',?)", (key,))
                    db.execute("DELETE FROM favorites WHERE kind='model' AND name=?", (name,))


def connect(home):
    home.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(home / "media.sqlite", timeout=15)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript("""
      CREATE TABLE IF NOT EXISTS config(k TEXT PRIMARY KEY, v TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS media(
        id INTEGER PRIMARY KEY, root TEXT COLLATE NOCASE, path TEXT COLLATE NOCASE,
        folder TEXT COLLATE NOCASE, name TEXT COLLATE NOCASE, person TEXT COLLATE NOCASE,
        kind TEXT, bytes INTEGER, modified INTEGER, parent TEXT COLLATE NOCASE, UNIQUE(root,path));
      CREATE INDEX IF NOT EXISTS media_parent ON media(root,parent,name,id);
      CREATE INDEX IF NOT EXISTS media_folder ON media(root,folder,name,id);
      CREATE INDEX IF NOT EXISTS media_person ON media(root,person,folder,name,id);
      CREATE TABLE IF NOT EXISTS albums(id INTEGER PRIMARY KEY,root TEXT COLLATE NOCASE,
        path TEXT COLLATE NOCASE,name TEXT COLLATE NOCASE,person TEXT COLLATE NOCASE,
        favorite INTEGER NOT NULL DEFAULT 0, UNIQUE(root,path));
      CREATE INDEX IF NOT EXISTS album_names ON albums(root,name,id);
      CREATE INDEX IF NOT EXISTS album_people ON albums(root,person,name,id);
      CREATE TABLE IF NOT EXISTS album_tags(id INTEGER REFERENCES albums ON DELETE CASCADE,
        tag TEXT COLLATE NOCASE, PRIMARY KEY(id,tag));
      CREATE INDEX IF NOT EXISTS album_tags_name ON album_tags(tag,id);
      CREATE TABLE IF NOT EXISTS previews(id INTEGER PRIMARY KEY REFERENCES media ON DELETE CASCADE, jpg BLOB);
      CREATE TABLE IF NOT EXISTS tags(id INTEGER REFERENCES media ON DELETE CASCADE,
        tag TEXT COLLATE NOCASE, PRIMARY KEY(id,tag));
      CREATE INDEX IF NOT EXISTS tags_by_name ON tags(tag,id);
    """)
    with db:
        db.execute("CREATE TABLE IF NOT EXISTS favorites(kind TEXT, name TEXT COLLATE NOCASE, PRIMARY KEY(kind,name))")
        if not option(db, "favorites_migrated"):
            db.execute("INSERT OR IGNORE INTO favorites SELECT 'folder',path FROM albums WHERE favorite=1")
            put(db, "favorites_migrated", "1")
    migrate_model_keys(db, "favorites")
    return db


def set_favorite(db, kind, name, enabled):
    with db:
        if enabled:
            db.execute("INSERT OR IGNORE INTO favorites VALUES(?,?)", (kind,name))
        else:
            db.execute("DELETE FROM favorites WHERE kind=? AND name=?", (kind,name))


def option(db, key):
    row = db.execute("SELECT v FROM config WHERE k=?", (key,)).fetchone()
    return row[0] if row else ""


def put(db, key, value):
    db.execute("INSERT OR REPLACE INTO config VALUES(?,?)", (key, value))


def thumbnail(path, kind):
    if kind == "Video":
        try:
            import imageio_ffmpeg
            executable = imageio_ffmpeg.get_ffmpeg_exe()
        except ImportError:
            executable = shutil.which("ffmpeg")
            if not executable:
                raise RuntimeError("Video preview decoder unavailable")
        frame = subprocess.run([executable, "-nostdin", "-loglevel", "error",
            "-i", str(path), "-frames:v", "1", "-vf", "scale=192:144:force_original_aspect_ratio=decrease",
            "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1"], stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=25, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return frame.stdout or None
    with Image.open(path) as source:
        source.draft("RGB", (192, 192))
        source.thumbnail((192, 192))
        image = ImageOps.exif_transpose(source).convert("RGB")
        buf = io.BytesIO()
        image.save(buf, format="JPEG", quality=78)
        return buf.getvalue()


@contextlib.contextmanager
def scan_lock(home):
    with (home / "media-scan.lock").open("a+b") as f:
        if f.tell() == 0:
            f.write(b"0")
            f.flush()
        f.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True


def scan(home):
    with contextlib.closing(connect(home)) as db, scan_lock(home) as acquired:
        if not acquired:
            return
        root = option(db, "root")
        if not root:
            return
        try:
            with db:
                put(db, "status", "Scanning…")
            index_folder(db, root)
        except Exception as exc:
            db.rollback()
            with db:
                put(db, "status", f"Scan interrupted: {exc}")


def index_folder(db, root):
    db.execute("CREATE TEMP TABLE seen(path TEXT PRIMARY KEY COLLATE NOCASE)")
    db.execute("CREATE TEMP TABLE seen_albums(path TEXT PRIMARY KEY COLLATE NOCASE)")
    stack = [(Path(root), person_name(Path(root).name) if re.search(r"\d", Path(root).name) else "")]
    scanned = changed = errors = 0
    last_commit = time.monotonic()
    while stack:
        folder, person = stack.pop()
        db.execute("INSERT INTO seen_albums VALUES(?)", (str(folder),))
        db.execute("""INSERT INTO albums(root,path,name,person) VALUES(?,?,?,?)
                   ON CONFLICT(root,path) DO UPDATE SET person=excluded.person
                   WHERE albums.person IS NOT excluded.person COLLATE BINARY""",
                   (root,str(folder),folder.name,person))
        db.execute("UPDATE media SET person=? WHERE root=? AND parent=? AND person IS NOT ? COLLATE BINARY",
                   (person,root,str(folder),person))
        with os.scandir(folder) as entries:
            for entry in entries:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    # Skip Windows junctions to avoid recursive traversal.
                    if getattr(entry.stat(follow_symlinks=False), "st_file_attributes", 0) & 0x400:
                        continue
                    who = person_name(entry.name)
                    if not re.search(r"\d", entry.name) and person:
                        who = person
                    stack.append((Path(entry.path), who or person))
                    continue
                ext = Path(entry.name).suffix.lower()
                if ext not in PHOTOS and ext not in VIDEOS:
                    continue
                stat = entry.stat()
                path = entry.path
                scanned += 1
                db.execute("INSERT INTO seen VALUES(?)", (path,))
                row = db.execute("SELECT id,bytes,modified FROM media WHERE root=? AND path=?", (root,path)).fetchone()
                if not row or (row["bytes"], row["modified"]) != (stat.st_size,stat.st_mtime_ns):
                    kind = "Video" if ext in VIDEOS else "Photo"
                    # Release the main database write lock during slow NAS decoding.
                    db.commit()
                    try:
                        jpg = thumbnail(path, kind)
                    except (ImportError, OSError, ValueError, RuntimeError, subprocess.SubprocessError, Image.DecompressionBombError):
                        jpg = None
                        errors += 1
                    db.execute("""INSERT INTO media(root,path,folder,name,person,kind,bytes,modified,parent)
                        VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(root,path) DO UPDATE SET
                        folder=excluded.folder,name=excluded.name,person=excluded.person,
                        bytes=excluded.bytes,modified=excluded.modified,kind=excluded.kind""",
                        (root,path,folder.name,entry.name,person,kind,stat.st_size,stat.st_mtime_ns,str(folder)))
                    media_id = db.execute("SELECT id FROM media WHERE root=? AND path=?", (root,path)).fetchone()[0]
                    db.execute("INSERT OR REPLACE INTO previews VALUES(?,?)", (media_id,jpg))
                    changed += 1
                if time.monotonic()-last_commit > 2:
                    put(db, "status", f"Scanning… {scanned:,} checked")
                    db.commit()
                    if option(db,"root") != root:
                        return
                    last_commit = time.monotonic()
    with db:
        db.execute("DELETE FROM media WHERE root=? AND path NOT IN (SELECT path FROM seen)", (root,))
        db.execute("DELETE FROM albums WHERE root=? AND path NOT IN (SELECT path FROM seen_albums)", (root,))
        put(db, "status", f"{time.strftime('%Y-%m-%d %H:%M')} · {scanned:,} checked · {changed:,} updated"
            + (f" · {errors} preview errors" if errors else ""))


def background_scan():
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--scan"],
                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def install_hourly():
    # Interactive user context is needed for the user's SMB credentials.
    command = subprocess.list2cmdline([sys.executable, str(Path(__file__).resolve()), "--scan"])
    subprocess.run(["schtasks.exe", "/Create", "/F", "/TN", TASK, "/SC", "HOURLY", "/MO", "1",
                    "/IT", "/TR", command], check=True, capture_output=True,
                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def storage():
    return Path(os.getenv("LOCALAPPDATA", Path.home())) / "MyPictureFolders"


if __name__ == "__main__" and "--scan" in sys.argv:
    scan(storage())


def catalog_page(db, root, view="Folders", person="", tag="", favorites=False, parent="", sort="Folder name", offset=0, photo_paths=False):
    albums = view == "Folders"
    table = "albums" if albums else "media"
    where = ["m.root=?"]
    args = [root]
    if parent and not albums:
        where.append("m.parent=?")
        args.append(parent)
    if view in ("Photos", "Videos"):
        where.append("m.kind=?")
        args.append(view[:-1])
    if person:
        where.append("m.person=?")
        args.append(person)
    if favorites:
        path_column = "m.path" if albums else "m.parent"
        where.append(f"EXISTS(SELECT 1 FROM favorites f WHERE f.kind='folder' AND f.name={path_column})")
    if tag:
        if albums:
            where.append("EXISTS(SELECT 1 FROM album_tags t WHERE t.id=m.id AND t.tag=?)")
            args.append(tag)
        else:
            where.append("""(EXISTS(SELECT 1 FROM tags t WHERE t.id=m.id AND t.tag=?) OR
                EXISTS(SELECT 1 FROM albums a JOIN album_tags t ON t.id=a.id
                WHERE a.root=m.root AND a.path=m.parent AND t.tag=?))""")
            args.extend([tag,tag])
    order = ("m.name,m.id" if albums else "m.folder,m.name,m.id")
    if sort == "Person":
        order = "m.person," + order
    if sort == "File name" and not albums:
        order = "m.name,m.id"
    columns = ("EXISTS(SELECT 1 FROM favorites f WHERE f.kind='folder' AND f.name=m.path) AS favorite,'Folder' AS kind,(SELECT f.id FROM media f WHERE f.root=m.root AND f.parent=m.path ORDER BY f.name,f.id LIMIT 1) AS preview"
               if albums else "0 AS favorite,m.kind,m.id AS preview")
    if photo_paths:
        return [r[0] for r in db.execute("SELECT m.path FROM media m WHERE " + " AND ".join(where)
                                          + f" AND m.kind='Photo' ORDER BY {order}", args)]
    return db.execute(f"SELECT m.id,m.name,m.path,m.person,{columns} FROM {table} m WHERE "
                      + " AND ".join(where) + f" ORDER BY {order} LIMIT 101 OFFSET ?", args+[offset]).fetchall()


def show_catalog(browser):
    import tkinter as tk
    from tkinter import filedialog, messagebox, simpledialog, ttk
    from PIL import ImageTk
    from picture_viewer import PictureViewer, bind_grid_wheel
    existing = getattr(browser, "catalog_window", None)
    if existing and existing.winfo_exists():
        existing.lift()
        return
    db = connect(storage())
    win = tk.Toplevel(browser.root)
    browser.catalog_window = win
    win.title("Media catalog")
    win.geometry("1120x780")
    bar = ttk.Frame(win, padding=5)
    bar.pack(fill="x")
    state = {"page":0, "parent":"", "selected":None, "status":None}
    view = tk.StringVar(value="Folders")
    person = tk.StringVar()
    tag = tk.StringVar()
    favorites = tk.BooleanVar()
    sort = tk.StringVar(value="Folder name")
    info = tk.StringVar()
    selection = tk.StringVar()
    tools = ttk.Frame(win)
    tools.pack(fill="x")
    filters = ttk.Frame(win)
    filters.pack(fill="x")
    area = tk.Canvas(win, highlightthickness=0)
    foot = ttk.Frame(win, padding=5)
    foot.pack(side="bottom",fill="x")
    scroll = ttk.Scrollbar(win, orient="vertical", command=area.yview)
    scroll.pack(side="right",fill="y")
    area.pack(fill="both",expand=True)
    area.configure(yscrollcommand=scroll.set)
    grid = ttk.Frame(area)
    grid_id = area.create_window(0,0,anchor="nw",window=grid)
    grid.bind("<Configure>",lambda e: area.configure(scrollregion=area.bbox("all")))
    area.bind("<Configure>",lambda e: area.itemconfigure(grid_id,width=e.width))
    photos = []

    def refresh(reset=False):
        if reset:
            state["page"] = 0
        state["selected"] = None
        selection.set("Click pictures to view · Double-click folders or videos to open")
        for child in grid.winfo_children():
            child.destroy()
        photos.clear()
        rows = catalog_page(db,option(db,"root"),view.get(),person.get().strip(),tag.get().strip(),
                            favorites.get(),state["parent"],sort.get(),state["page"]*100)
        prev.configure(state="normal" if state["page"] else "disabled")
        nxt.configure(state="normal" if len(rows)>100 else "disabled")
        page_label.configure(text=f"Page {state['page']+1}")
        if not rows:
            ttk.Label(grid,text="No matches yet. Choose a watch folder or change the filters.",padding=16).grid()
        folder_view = view.get() == "Folders"
        preview_size = (131, 96) if folder_view else (98, 72)
        columns = 6 if folder_view else 8
        tile_width = 20 if folder_view else 15
        for i,row in enumerate(rows[:100]):
            cached = db.execute("SELECT jpg FROM previews WHERE id=?", (row["preview"],)).fetchone()
            image = ""
            if cached and cached[0]:
                with Image.open(io.BytesIO(cached[0])) as preview:
                    preview.thumbnail(preview_size)
                    image = ImageTk.PhotoImage(preview)
                    photos.append(image)
            text = ("♥ " if row["favorite"] else "") + ("▶ " if row["kind"]=="Video" else "") + row["name"]
            tile = ttk.Button(grid,text=text[:20],image=image,compound="top",width=tile_width,
                              command=lambda r=row: click_tile(r))
            tile.grid(row=i//columns,column=i%columns,padx=1,pady=1,sticky="nsew")
            if row["kind"] != "Photo":
                tile.bind("<Double-Button-1>",lambda e,r=row: open_item(r))
        area.yview_moveto(0)

    def click_tile(row):
        select(row)
        if row["kind"] == "Photo":
            open_item(row)

    def select(row):
        state["selected"] = row
        table = "album_tags" if row["kind"]=="Folder" else "tags"
        labels = ", ".join(r[0] for r in db.execute(f"SELECT tag FROM {table} WHERE id=? ORDER BY tag",(row["id"],)))
        selection.set("   ·   ".join(part for part in (row["path"],row["person"],labels) if part))

    def open_item(row):
        if row["kind"]=="Folder":
            state["parent"] = row["path"]
            view.set("All media")
            refresh(True)
        elif row["kind"] == "Photo":
            paths = catalog_page(db,option(db,"root"),view.get(),person.get().strip(),tag.get().strip(),
                                 favorites.get(),state["parent"],sort.get(),photo_paths=True)
            if row["path"] in paths:
                PictureViewer(win, paths, row["path"])
        else:
            os.startfile(row["path"])

    def favorite():
        row = state["selected"]
        if not row or row["kind"]!="Folder":
            return messagebox.showinfo("Favorite folder","Select a folder tile first.",parent=win)
        set_favorite(db,"folder",row["path"],not row["favorite"])
        refresh()

    def edit_tags():
        row = state["selected"]
        if not row:
            return messagebox.showinfo("Tags","Select a folder, photo or video first.",parent=win)
        table = "album_tags" if row["kind"]=="Folder" else "tags"
        old = ", ".join(r[0] for r in db.execute(f"SELECT tag FROM {table} WHERE id=? ORDER BY tag",(row["id"],)))
        answer = simpledialog.askstring("Edit tags", "Tags, separated by commas",initialvalue=old,parent=win)
        if answer is None:
            return
        with db:
            db.execute(f"DELETE FROM {table} WHERE id=?", (row["id"],))
            db.executemany(f"INSERT OR IGNORE INTO {table} VALUES(?,?)",
                           ((row["id"],t.strip()) for t in answer.split(",") if t.strip()))
        refresh()

    def watch():
        path = filedialog.askdirectory(parent=win,title="Choose a folder to index, including subfolders")
        if not path:
            return
        with db:
            put(db,"root",str(Path(path).absolute()))
            put(db,"status","Starting scan…")
        state["parent"] = ""
        try:
            install_hourly()
        except (OSError,subprocess.SubprocessError) as exc:
            messagebox.showwarning("Hourly scan",f"Windows could not schedule the hourly scan. Scan now is available.\n{exc}",parent=win)
        background_scan()
        refresh(True)

    def switch_view(*args):
        state["parent"] = ""
        refresh(True)

    def turn(step):
        state["page"] += step
        refresh()

    for caption,action in [("Watch folder…",watch),("Scan now",background_scan),("Edit tags…",edit_tags),
                           ("Toggle favorite",favorite)]:
        ttk.Button(bar,text=caption,command=action).pack(side="left",padx=2)
    ttk.Label(bar,textvariable=info).pack(side="left",padx=8)
    for label,var,choices in [("View",view,("Folders","All media","Photos","Videos")),
                              ("Sort",sort,("Folder name","Person","File name"))]:
        ttk.Label(tools,text=label).pack(side="left",padx=4)
        box = ttk.Combobox(tools,textvariable=var,values=choices,state="readonly",width=12)
        box.pack(side="left")
        box.bind("<<ComboboxSelected>>", switch_view if var is view else lambda e: refresh(True))
    ttk.Checkbutton(tools,text="Favorite folders only",variable=favorites,command=lambda:refresh(True)).pack(side="left")
    for label,var in [("Person",person),("Tag",tag)]:
        ttk.Label(filters,text=label).pack(side="left",padx=4)
        def choices(combo, category):
            root = option(db, "root")
            if category == "Person":
                values = db.execute("SELECT DISTINCT person FROM albums WHERE root=? AND person<>'' ORDER BY person", (root,))
            else:
                values = db.execute("""SELECT tag FROM album_tags JOIN albums USING(id) WHERE root=?
                    UNION SELECT tag FROM tags JOIN media USING(id) WHERE root=? ORDER BY tag""", (root,root))
            combo.configure(values=[""] + [r[0] for r in values])
        entry = ttk.Combobox(filters,textvariable=var,width=20)
        entry.configure(postcommand=lambda box=entry, category=label: choices(box,category))
        entry.bind("<<ComboboxSelected>>", lambda e: refresh(True))
        entry.pack(side="left")
        entry.bind("<Return>",lambda e: refresh(True))
    ttk.Button(filters,text="Filter",command=lambda: refresh(True)).pack(side="left")
    ttk.Label(foot,textvariable=selection).pack(side="bottom",anchor="w")
    prev = ttk.Button(foot,text="Previous",command=lambda:turn(-1))
    prev.pack(side="left")
    page_label = ttk.Label(foot)
    page_label.pack(side="left",padx=6)
    nxt = ttk.Button(foot,text="Next",command=lambda:turn(1))
    nxt.pack(side="left")

    def poll():
        status = option(db,"status")
        info.set(status or "Choose a watch folder to start.")
        if status != state["status"] and not status.startswith("Scanning") and not state["selected"]:
            refresh()
        state["status"] = status
        state["timer"] = win.after(3000,poll)

    def close():
        win.after_cancel(state["timer"])
        db.close()
        win.destroy()

    def go_back(event):
        if state["parent"]:
            state["parent"] = ""
            view.set("Folders")
            refresh(True)
        else:
            close()
        return "break"

    def wheel_page(step):
        button = nxt if step > 0 else prev
        if button.instate(["!disabled"]):
            turn(step)
            if step < 0:
                area.update_idletasks()
                area.yview_moveto(1)

    area.configure(yscrollincrement=20)
    bind_grid_wheel(win, area, wheel_page)
    win.bind("<Escape>", go_back)
    win.protocol("WM_DELETE_WINDOW",close)
    refresh(True)
    poll()
