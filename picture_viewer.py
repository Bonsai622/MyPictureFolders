"""Keyboard-driven viewer for an ordered list of original photos."""
from pathlib import Path
import tkinter as tk

from PIL import Image, ImageOps, ImageTk


class PictureViewer:
    def __init__(self, parent, paths, selected):
        self.paths = paths
        self.index = paths.index(selected)
        self.window = tk.Toplevel(parent)
        self.window.geometry(f"{parent.winfo_width()}x{parent.winfo_height()}{parent.winfo_rootx():+d}{parent.winfo_rooty():+d}")
        if parent.tk.getboolean(parent.attributes("-fullscreen")):
            self.window.attributes("-fullscreen", True)
        elif parent.state() == "zoomed":
            self.window.state("zoomed")
        self.window.transient(parent)
        self.canvas = tk.Canvas(self.window, background="#151719", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.image = None
        self.bitmap = None
        self.drag = None
        self.job = None
        self.window.bind("<Left>", lambda e: self.step(-1))
        self.window.bind("<Right>", lambda e: self.step(1))
        self.window.bind("<Escape>", self.close)
        self.window.protocol("WM_DELETE_WINDOW", self.close)
        self.canvas.bind("<Control-MouseWheel>", self.wheel)
        self.canvas.bind("<Control-Button-4>", lambda e: self.zoom_at(e.x, e.y, 1.25))
        self.canvas.bind("<Control-Button-5>", lambda e: self.zoom_at(e.x, e.y, 0.8))
        self.canvas.bind("<ButtonPress-1>", self.start_drag)
        self.canvas.bind("<B1-Motion>", self.pan)
        self.canvas.bind("<Configure>", self.schedule)
        self.window.grab_set()
        self.canvas.focus_set()
        self.load()

    def close(self, event=None):
        if self.job is not None:
            self.window.after_cancel(self.job)
        if self.image is not None:
            self.image.close()
        self.window.destroy()
        return "break"

    def step(self, direction):
        position = self.index + direction
        if 0 <= position < len(self.paths):
            self.index = position
            self.load()
        return "break"

    def load(self):
        path = self.paths[self.index]
        if self.image is not None:
            self.image.close()
        self.image = None
        self.bitmap = None
        self.drag = None
        self.zoom = 1.0
        self.error = ""
        try:
            with Image.open(path) as original:
                self.image = ImageOps.exif_transpose(original).convert("RGBA")
            self.cx, self.cy = self.image.width / 2, self.image.height / 2
        except (OSError, ValueError, Image.DecompressionBombError) as exc:
            self.error = f"Could not open {Path(path).name}\n{exc}"
        self.window.title(f"{Path(path).name}   ·   {self.index+1} of {len(self.paths)}   ·   MyPictureFolders")
        self.schedule()

    def scale(self):
        return min(self.canvas.winfo_width() / self.image.width,
                   self.canvas.winfo_height() / self.image.height, 1.0) * self.zoom

    def wheel(self, event):
        if event.delta:
            self.zoom_at(event.x, event.y, 1.25 if event.delta > 0 else 0.8)
        return "break"

    def zoom_at(self, x, y, factor):
        if self.image is not None:
            old = self.scale()
            self.zoom = min(32.0, max(0.25, self.zoom * factor))
            dx = x - self.canvas.winfo_width()/2
            dy = y - self.canvas.winfo_height()/2
            self.cx += dx * (1/old - 1/self.scale())
            self.cy += dy * (1/old - 1/self.scale())
            self.schedule()
        return "break"

    def start_drag(self, event):
        self.drag = (event.x, event.y)

    def pan(self, event):
        if self.image is not None and self.drag:
            self.cx += (self.drag[0] - event.x) / self.scale()
            self.cy += (self.drag[1] - event.y) / self.scale()
            self.drag = (event.x, event.y)
            self.schedule()

    def schedule(self, event=None):
        if self.job is None:
            self.job = self.window.after_idle(self.paint)

    def paint(self):
        self.job = None
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        self.canvas.delete("all")
        if self.image is None:
            self.canvas.create_text(w/2, h/2, text=self.error, fill="white", width=max(1,w-30))
            return
        scale = self.scale()
        half_w, half_h = w/(2*scale), h/(2*scale)
        def center(value, half, length):
            return length/2 if 2*half >= length else min(length-half, max(half,value))
        self.cx = center(self.cx, half_w, self.image.width)
        self.cy = center(self.cy, half_h, self.image.height)
        # Resample just the viewport so zooming does not allocate a giant bitmap.
        box = (self.cx-half_w, self.cy-half_h, self.cx+half_w, self.cy+half_h)
        viewport = self.image.transform((w,h), Image.Transform.EXTENT, box, Image.Resampling.BILINEAR)
        self.bitmap = ImageTk.PhotoImage(viewport)
        self.canvas.create_image(0,0,anchor="nw",image=self.bitmap)
