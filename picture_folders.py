"""A visual browser for real folders. Each folder owns its portable cover."""
from dataclasses import dataclass
from datetime import date
import re
import base64
import io
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import tkinter as tk
from tkinter import colorchooser, filedialog, messagebox, simpledialog, ttk

from media_catalog import connect, person_name, set_favorite, show_catalog
from PIL import Image, ImageDraw, ImageOps, ImageTk

META = ".mypicturefolders.json"
PICTURES = {".jpg", ".jpeg", ".jfif", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff", ".ico"}
DEFAULT = {"title": "", "color": "#dbb675", "x": 50, "y": 50, "width": 100, "height": 100}
PAGE = 100


def grid_layout(count, width, height):
    # The full page fits the viewport. Wide windows get more columns.
    columns = max(1, min(count, round(math.sqrt(count * width / (height * 1.55)))))
    rows = max(1, math.ceil(count / columns))
    return columns, min(200, width // columns), min(155, height // rows)


def settings(folder):
    try:
        data = json.loads((folder / META).read_text(encoding="utf8"))
    except FileNotFoundError:
        data = {}
    return {**DEFAULT, **data}


def save_settings(folder, data):
    # Stage beside the destination so rename works on the same SMB share.
    with tempfile.NamedTemporaryFile(dir=folder, prefix=".mypf-", delete=False) as f:
        temporary = Path(f.name)
    try:
        temporary.write_text(json.dumps(data, separators=(",", ":")), encoding="utf8")
        os.replace(temporary, folder / META)
    finally:
        temporary.unlink(missing_ok=True)


def load_image(path, longest):
    with Image.open(path) as source:
        source.thumbnail((longest, longest))
        return ImageOps.exif_transpose(source).convert("RGBA")


def encode_cover(image):
    out = io.BytesIO()
    image.save(out, format="PNG")
    return base64.b64encode(out.getvalue()).decode("ascii")


def folder_art(data, photo=None):
    size = (256, 212)
    color = data["color"]
    mask = Image.new("L", size)
    pen = ImageDraw.Draw(mask)
    pen.rounded_rectangle((2, 23, 253, 209), radius=14, fill=255)
    pen.rounded_rectangle((2, 3, 115, 53), radius=12, fill=255)
    pen.polygon([(101, 3), (130, 24), (103, 42)], fill=255)
    tile = Image.new("RGBA", size, color)
    if photo is None and data.get("cover"):
        with Image.open(io.BytesIO(base64.b64decode(data["cover"]))) as src:
            photo = src.convert("RGBA")
    if photo is not None:
        scale = max(256 / photo.width, 212 / photo.height)
        w = 256 / (scale * data["width"] / 100)
        h = 212 / (scale * data["height"] / 100)
        x = max(0, photo.width - w) * data["x"] / 100
        y = max(0, photo.height - h) * data["y"] / 100
        crop = photo.transform(size, Image.Transform.EXTENT, (x, y, x+w, y+h),
                               resample=Image.Resampling.BICUBIC)
        # Inset the image to keep the chosen outline visible.
        inner = mask.resize((246, 202), Image.Resampling.LANCZOS)
        clip = Image.new("L", size)
        clip.paste(inner, (5, 5))
        tile.paste(Image.alpha_composite(tile, crop), mask=clip)
    tile.putalpha(mask)
    return tile


@dataclass
class ModelFolder:
    name: str
    sets: list


def model_folders(entries):
    groups = {}
    loose = []
    for path in entries:
        if not path.is_dir():
            loose.append(path)
            continue
        name = person_name(path.name) or "Unassigned"
        key = name.casefold()
        if key not in groups:
            groups[key] = ModelFolder(name, [])
        groups[key].sets.append(path)
    for group in groups.values():
        group.sets.sort(key=lambda path: (path.name.casefold(), str(path)))
    return [groups[key] for key in sorted(groups)] + loose


def favorite_key(entry):
    if isinstance(entry, ModelFolder):
        return ("model", entry.name.casefold())
    return ("folder", str(entry).casefold())


def entry_date(path):
    match = re.search(r"(?<!\d)(\d{4})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)", path.name)
    if match:
        try:
            return date(*map(int, match.groups())).toordinal()
        except ValueError:
            pass
    try:
        return date.fromtimestamp(path.stat().st_mtime).toordinal()
    except (OSError, ValueError, OverflowError):
        return 0


class Browser:
    def __init__(self, root, incoming):
        self.root = root
        root.title("MyPictureFolders")
        root.geometry("1000x720")
        root.minsize(700, 480)
        root.report_callback_exception = lambda typ, exc, tb: messagebox.showerror("MyPictureFolders", str(exc))
        storage = Path(os.getenv("LOCALAPPDATA", Path.home())) / "MyPictureFolders"
        storage.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(storage / "library.sqlite")
        self.db.execute("CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY COLLATE NOCASE)")
        self.db.execute("CREATE TABLE IF NOT EXISTS model_covers(model TEXT PRIMARY KEY, settings TEXT NOT NULL)")
        self.folder = None
        self.page = 0
        self.favorite_db = connect(storage)
        self.sort_order = tk.StringVar(value="A-Z")
        self.filter_mode = tk.StringVar(value="All")
        self.dates = {}
        self.directory_flags = {}
        self.favorite_menu = tk.Menu(root, tearoff=False)
        self.tiles = []
        self.layout_job = None
        self.pending = []
        self.group_history = []
        self.group_label = ""
        for arg in incoming:
            p = Path(arg).absolute()
            if p.is_dir():
                self.remember(p)
                self.pending.append(p)
        self.bar = ttk.Frame(root, padding=8)
        self.bar.pack(fill="x")
        for title, action in [("Media catalog", lambda: show_catalog(self)), ("Library", self.home), ("Up", self.up), ("Open folder…", self.browse),
                              ("New folder…", self.create), ("Add files…", self.add_files),
                              ("Edit cover…", self.edit_current), ("Group by Model", self.group_by_model)]:
            ttk.Button(self.bar, text=title, width=0, command=action).pack(side="left", padx=2)
        controls = ttk.Frame(root, padding=(8, 0))
        controls.pack(fill="x")
        for label, variable, choices in [("Sort by", self.sort_order, ("A-Z", "Date")),
                                         ("Filter", self.filter_mode, ("All", "Favorite"))]:
            ttk.Label(controls, text=label).pack(side="left", padx=4)
            chooser = ttk.Combobox(controls, textvariable=variable, values=choices, state="readonly", width=10)
            chooser.pack(side="left", padx=(0, 8))
            chooser.bind("<<ComboboxSelected>>", self.change_view)
        self.location = ttk.Label(root, padding=(12, 4))
        self.location.pack(fill="x")
        area = ttk.Frame(root)
        area.pack(fill="both", expand=True)
        self.canvas = tk.Canvas(area, highlightthickness=0, background="#f1f3f5")
        scroll = ttk.Scrollbar(area, command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.canvas.pack(side="left", expand=True, fill="both")
        self.grid = ttk.Frame(self.canvas)
        self.window = self.canvas.create_window(0, 0, window=self.grid, anchor="nw")
        self.grid.bind("<Configure>", lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.bind("<Configure>", self.schedule_layout)
        root.bind("<MouseWheel>", lambda e: self.canvas.yview_scroll(-int(e.delta/120), "units"))
        footer = ttk.Frame(root, padding=6)
        footer.pack(fill="x")
        self.prev = ttk.Button(footer, text="Previous", command=lambda: self.turn(-1))
        self.prev.pack(side="left")
        self.count = ttk.Label(footer, padding=6)
        self.count.pack(side="left")
        self.next = ttk.Button(footer, text="Next", command=lambda: self.turn(1))
        self.next.pack(side="left")
        self.home()
        root.after_idle(self.next_sent)

    def next_sent(self):
        if self.pending:
            p = self.pending.pop(0)
            self.enter(p)
            self.editor(p)
            self.root.after_idle(self.next_sent)

    def remember(self, p):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO folders VALUES (?)", (str(p),))

    def home(self):
        self.enter(None)

    def up(self):
        if self.group_history:
            self.folder, self.entries, self.page, self.group_label, mode = self.group_history.pop()
            self.filter_mode.set(mode)
            self.draw()
            return
        self.enter(self.folder.parent if self.folder and self.folder != self.folder.parent else None)

    def browse(self):
        path = filedialog.askdirectory()
        if path:
            p = Path(path)
            self.remember(p)
            self.enter(p)

    def create(self):
        parent = self.folder
        if parent is None:
            selected = filedialog.askdirectory(title="Where should the new folder go?")
            if not selected:
                return
            parent = Path(selected)
        name = simpledialog.askstring("New folder", "Folder name")
        if not name:
            return
        if name in (".", "..") or Path(name).name != name or any(c in name for c in '<>:"/\\|?*'):
            raise ValueError("Enter a single folder name.")
        p = parent / name
        p.mkdir()
        self.remember(p)
        self.enter(p)
        self.editor(p)

    def add_files(self):
        if not self.folder:
            return messagebox.showinfo("Add files", "Open a destination folder first.")
        skipped = []
        try:
            for filename in filedialog.askopenfilenames(title="Copy files into this folder"):
                src = Path(filename)
                dest = self.folder / src.name
                try:
                    output = dest.open("xb")
                except FileExistsError:
                    skipped.append(src.name)
                    continue
                try:
                    with output, src.open("rb") as original:
                        shutil.copyfileobj(original, output)
                except Exception:
                    dest.unlink(missing_ok=True)
                    raise
        finally:
            self.enter(self.folder)
        if skipped:
            messagebox.showinfo("Existing files skipped", "\n".join(skipped))

    def edit_current(self):
        if self.group_label.startswith("Models / "):
            self.editor(ModelFolder(self.group_label[len("Models / "):], self.entries))
        elif self.folder:
            self.editor(self.folder)
        else:
            messagebox.showinfo("Edit cover", "Open a folder or use its Edit cover button.")

    def remember_view(self):
        self.group_history.append((self.folder, self.entries, self.page, self.group_label, self.filter_mode.get()))

    def group_by_model(self):
        if self.group_label:
            return
        entries = model_folders(self.entries)
        self.remember_view()
        self.folder, self.entries, self.page = None, entries, 0
        self.group_label = "Models"
        self.draw()

    def open_group(self, group):
        self.remember_view()
        self.folder, self.entries, self.page = None, group.sets, 0
        self.group_label = f"Models / {group.name}"
        self.filter_mode.set("All")
        self.draw()

    def open_directory(self, folder):
        if self.group_history:
            self.remember_view()
            self.enter(folder, keep_history=True)
        else:
            self.enter(folder)

    def turn(self, step):
        self.page += step
        self.draw()

    def enter(self, folder, keep_history=False):
        if folder:
            entries = sorted((p for p in folder.iterdir() if p.name != META
                              and not p.name.startswith(".mypf-") and p.name.lower() != "desktop.ini"
                              and not (p.name.startswith("folder-picture-") and p.suffix.lower() == ".ico")),
                             key=lambda p: (not p.is_dir(), p.name.casefold()))
        else:
            entries = [Path(r[0]) for r in self.db.execute("SELECT path FROM folders ORDER BY path")]
        if not keep_history:
            self.group_history.clear()
        self.group_label = ""
        self.filter_mode.set("All")
        self.dates.clear()
        self.directory_flags.clear()
        self.entries, self.folder, self.page = entries, folder, 0
        self.draw()

    def schedule_layout(self, event=None):
        if self.layout_job is not None:
            self.root.after_cancel(self.layout_job)
        self.layout_job = self.root.after(70, self.layout_tiles)

    def layout_tiles(self):
        self.layout_job = None
        width, height = self.canvas.winfo_width(), self.canvas.winfo_height()
        if width < 10 or height < 10:
            return
        self.canvas.itemconfigure(self.window, width=width)
        columns, cell_w, cell_h = grid_layout(len(self.tiles), width, height)
        for i, (card, button, source, title) in enumerate(self.tiles):
            card.grid(row=i//columns, column=i%columns)
            card.configure(width=cell_w, height=cell_h)
            chars = max(3, (cell_w-14)//8)
            button.configure(text=title if len(title)<=chars else title[:chars-1]+"…")
            if source is not None:
                image = source.copy()
                image.thumbnail((max(1, cell_w-12), max(1, cell_h-28)), Image.Resampling.LANCZOS)
                button.bitmap = ImageTk.PhotoImage(image)
                button.configure(image=button.bitmap)

    def change_view(self, event=None):
        self.page = 0
        self.draw()

    def folder_menu(self, event, entry, enabled):
        menu = self.favorite_menu
        menu.delete(0, "end")
        def toggle():
            kind, name = favorite_key(entry)
            set_favorite(self.favorite_db, kind, str(entry) if kind == "folder" else name, not enabled)
            self.draw()
        menu.add_command(label="Remove favorite" if enabled else "Favorite", command=toggle)
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def view_entries(self, favorites):
        def order(entry):
            paths = entry.sets if isinstance(entry, ModelFolder) else [entry]
            newest = 0
            if self.sort_order.get() == "Date":
                for path in paths:
                    if path not in self.dates:
                        self.dates[path] = entry_date(path)
                    newest = max(newest, self.dates[path])
            is_file = False
            if not isinstance(entry, ModelFolder):
                if entry not in self.directory_flags:
                    self.directory_flags[entry] = entry.is_dir()
                is_file = not self.directory_flags[entry]
            return (is_file, -newest, entry.name.casefold())
        entries = self.entries
        if self.filter_mode.get() == "Favorite":
            entries = [entry for entry in entries if favorite_key(entry) in favorites]
        return sorted(entries, key=order)

    def draw(self):
        for widget in self.grid.winfo_children():
            widget.destroy()
        self.tiles.clear()
        self.location.configure(text=str(self.group_label or self.folder or "My folders"))
        favorites = {(r[0], r[1].casefold()) for r in self.favorite_db.execute("SELECT kind,name FROM favorites")}
        entries = self.view_entries(favorites)
        self.page = min(self.page, max(0,(len(entries)-1)//PAGE))
        start = self.page * PAGE
        for path in entries[start:start+PAGE]:
            card = ttk.Frame(self.grid)
            group = isinstance(path, ModelFolder)
            directory = not group and path.is_dir()
            title = path.name or str(path)
            art = None
            try:
                if group:
                    art = folder_art(self.cover_settings(path))
                elif directory:
                    data = settings(path)
                    title = data["title"] or title
                    art = folder_art(data)
                elif path.suffix.lower() in PICTURES:
                    art = load_image(path, 128)
            except (ValueError, OSError):
                art = None
            if art is not None:
                art.thumbnail((128, 100), Image.Resampling.LANCZOS)
            action = self.open_group if group else self.open_directory if directory else os.startfile
            button = ttk.Button(card, compound="top", command=lambda p=path, fn=action: fn(p))
            button.place(x=1, y=1, relwidth=1, relheight=1, width=-2, height=-2)
            detail = f"{path.name} · {len(path.sets)} sets" if group else str(path)
            button.bind("<Enter>", lambda e, value=detail: self.location.configure(text=value))
            button.bind("<Leave>", lambda e: self.location.configure(text=str(self.group_label or self.folder or "My folders")))
            if directory or group:
                edit = ttk.Button(card, text="✎", width=2, command=lambda p=path: self.editor(p))
                edit.place(relx=1, x=-2, y=2, anchor="ne")
            if group or directory:
                marked = favorite_key(path) in favorites
                def show_menu(event, entry=path, enabled=marked):
                    self.folder_menu(event, entry, enabled)
                for widget in card.winfo_children():
                    widget.bind("<Button-3>", show_menu)
                card.bind("<Button-3>", show_menu)
                if marked:
                    heart = ttk.Label(card, text="♥", foreground="#bc2548")
                    heart.place(x=3, y=2)
                    heart.bind("<Button-3>", show_menu)
                    heart.bind("<Button-1>", lambda e, b=button: b.invoke())
            self.tiles.append((card, button, art, title))
        self.schedule_layout()
        if not entries:
            empty = "No favorites in this view." if self.filter_mode.get() == "Favorite" else "No items in this view."
            ttk.Label(self.grid, text=empty, padding=18).grid()
        self.prev.configure(state="normal" if start else "disabled")
        self.next.configure(state="normal" if start+PAGE<len(entries) else "disabled")
        self.count.configure(text=f"{start+1 if entries else 0}–{min(start+PAGE,len(entries))} of {len(entries)} items")
        self.canvas.yview_moveto(0)

    def cover_settings(self, folder):
        if isinstance(folder, ModelFolder):
            row = self.db.execute("SELECT settings FROM model_covers WHERE model=?", (folder.name.casefold(),)).fetchone()
            return {**DEFAULT, **(json.loads(row[0]) if row else {})}
        return settings(folder)

    def store_cover(self, folder, data):
        if isinstance(folder, ModelFolder):
            with self.db:
                self.db.execute("INSERT OR REPLACE INTO model_covers VALUES(?,?)",
                                (folder.name.casefold(), json.dumps(data, separators=(",", ":"))))
        else:
            save_settings(folder, data)
            self.remember(folder)

    def editor(self, folder):
        model = isinstance(folder, ModelFolder)
        data = self.cover_settings(folder)
        source_folder = folder.sets[0] if model else folder
        dialog = tk.Toplevel(self.root)
        dialog.title("Model folder cover" if model else "Customize folder")
        dialog.transient(self.root)
        dialog.grab_set()
        body = ttk.Frame(dialog, padding=12)
        body.pack(fill="both", expand=True)
        ttk.Label(body, text=folder.name if model else str(folder), wraplength=480).pack()
        art = ttk.Label(body)
        art.pack(pady=4)
        title = tk.StringVar(value=data["title"] or folder.name)
        if not model:
            ttk.Label(body, text="Display name").pack(anchor="w")
            ttk.Entry(body, textvariable=title).pack(fill="x")
        source = None
        if data.get("cover"):
            with Image.open(io.BytesIO(base64.b64decode(data["cover"]))) as img:
                source = img.convert("RGBA")

        def redraw(*args):
            art.image = ImageTk.PhotoImage(folder_art(data, source))
            art.configure(image=art.image)

        def choose(path):
            nonlocal source
            if path:
                source = load_image(path, 1024)
                data.pop("cover", None)
                redraw()

        def color():
            value = colorchooser.askcolor(data["color"], parent=dialog)[1]
            if value:
                data["color"] = value
                redraw()

        def plain():
            nonlocal source
            source = None
            data.pop("cover", None)
            redraw()

        buttons = ttk.Frame(body)
        buttons.pack(pady=5)
        for label, cmd in [("Choose picture…", lambda: choose(filedialog.askopenfilename(
                parent=dialog, initialdir=source_folder, filetypes=[("Pictures", " ".join("*"+e for e in sorted(PICTURES)))]))),
                ("Border color…", color), ("Plain folder", plain)]:
            ttk.Button(buttons, text=label, command=cmd).pack(side="left")
        if model:
            ttk.Label(body, text="Pictures from set").pack(anchor="w")
            set_picker = ttk.Combobox(body, values=[str(p) for p in folder.sets], state="readonly")
            set_picker.current(0)
            set_picker.pack(fill="x")
        strip = ttk.Frame(body)
        strip.pack()
        def load_strip(event=None):
            nonlocal source_folder
            if model:
                source_folder = folder.sets[set_picker.current()]
            for child in strip.winfo_children():
                child.destroy()
            try:
                pictures = sorted((p for p in source_folder.iterdir() if p.suffix.lower() in PICTURES
                                   and p.is_file() and not (p.name.startswith("folder-picture-") and p.suffix.lower()==".ico")),
                                  key=lambda p: p.name.casefold())
            except OSError:
                pictures = []
            if not pictures:
                ttk.Label(strip, text="Use Choose picture to browse for an image.").pack()
                return
            offset = 0
            def show_strip(start):
                nonlocal offset
                offset = start
                for child in strip.winfo_children():
                    child.destroy()
                ttk.Button(strip, text="‹", width=2, state="normal" if start else "disabled",
                           command=lambda: show_strip(offset-4)).pack(side="left")
                for path in pictures[start:start+4]:
                    try:
                        preview = ImageTk.PhotoImage(load_image(path, 56))
                    except (ValueError, OSError):
                        preview = ""
                    btn = ttk.Button(strip, image=preview, text=path.name[:10], compound="top",
                                     command=lambda p=path: choose(p))
                    btn.image = preview
                    btn.pack(side="left")
                ttk.Button(strip, text="›", width=2, state="normal" if start+4<len(pictures) else "disabled",
                           command=lambda: show_strip(offset+4)).pack(side="left")
            show_strip(0)
        if model:
            set_picker.bind("<<ComboboxSelected>>", load_strip)
        load_strip()
        for key, label, low, high in [("x","Horizontal position",0,100),("y","Vertical position",0,100),
                                     ("width","Stretch width",100,400),("height","Stretch height",100,400)]:
            row = ttk.Frame(body)
            row.pack(fill="x")
            ttk.Label(row, text=label, width=20).pack(side="left")
            def move(value, k=key):
                data[k] = int(float(value))
                redraw()
            bar = tk.Scale(row, from_=low, to=high, orient="horizontal", command=move)
            bar.set(data[key])
            bar.pack(side="left", expand=True, fill="x")

        def apply():
            data["title"] = title.get().strip()
            if source is not None:
                data["cover"] = encode_cover(source)
            self.store_cover(folder, data)
            dialog.destroy()
            self.draw()
        actions = ttk.Frame(body)
        actions.pack(pady=(8,0))
        ttk.Button(actions, text="Save cover", command=apply).pack(side="left")
        ttk.Button(actions, text="Cancel", command=dialog.destroy).pack(side="left")
        redraw()
        self.root.wait_window(dialog)


if __name__ == "__main__":
    root = tk.Tk()
    Browser(root, sys.argv[1:])
    root.mainloop()
