import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path
from uuid import uuid4

from .config import Settings
from .db import connect, initialize
from .downloaders import download


def process_media(path: Path, thumbnail: Path) -> dict:
    result = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
                            capture_output=True, timeout=30, check=True)
    info = json.loads(result.stdout)
    stream = next((s for s in info["streams"] if s["codec_type"] == "video"), None)
    if not stream:
        raise ValueError("文件不包含视频轨道")
    duration = float(info["format"].get("duration", 0))
    if duration <= 0:
        raise ValueError("视频时长无效")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-frames:v", "1",
                    "-vf", "scale=480:-2", str(thumbnail)], capture_output=True, check=True, timeout=30)
    return {"duration": duration, "width": stream["width"], "height": stream["height"]}


def normalize_media(source: Path, target: Path):
    """Write a real MP4 container and transcode only incompatible input codecs."""
    info = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(source)],
                          capture_output=True, check=True, timeout=30)
    streams = json.loads(info.stdout)["streams"]
    compatible = all(s.get("codec_name") in {"h264", "aac"} for s in streams if s["codec_type"] in {"video", "audio"})
    args = ["ffmpeg", "-v", "error", "-y", "-i", str(source), "-map", "0:v:0", "-map", "0:a:0?"]
    args += ["-c", "copy"] if compatible else ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac"]
    subprocess.run(args + ["-movflags", "+faststart", str(target)], capture_output=True, check=True, timeout=900)


def run_once(settings) -> bool:
    with connect(settings) as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM tasks WHERE state='queued' ORDER BY created_at, rowid LIMIT 1").fetchone()
        if not row:
            return False
        task = dict(row)
        db.execute("UPDATE tasks SET state='running', attempts=attempts+1, error=NULL WHERE id=?", (task["id"],))
    video_id = uuid4().hex
    folder = settings.data / "temp" / task["id"]
    folder.mkdir(exist_ok=True)
    target = settings.data / "videos" / f"{video_id}.mp4"
    thumbnail = settings.data / "thumbnails" / f"{video_id}.jpg"
    try:
        path = Path(task["source"]) if task["kind"] == "upload" else download(settings, task["source"], folder)
        if shutil.disk_usage(settings.data).free < max(path.stat().st_size * 3, 1024**3):
            raise ValueError("磁盘空间不足，请先清理视频库")
        normalize_media(path, target)
        meta = process_media(target, thumbnail)
        with connect(settings) as db:
            db.execute("INSERT INTO videos(id,title,source_url,path,duration,width,height) VALUES(?,?,?,?,?,?,?)",
                       (video_id, task["title"], task["source"] if task["kind"] == "douyin" else None,
                        target.name, meta["duration"], meta["width"], meta["height"]))
            db.execute("UPDATE tasks SET state='completed', video_id=? WHERE id=?", (video_id, task["id"]))
        if task["kind"] == "upload":
            path.unlink(missing_ok=True)
        shutil.rmtree(folder)
    except Exception as exc:
        target.unlink(missing_ok=True)
        thumbnail.unlink(missing_ok=True)
        error = str(exc) if isinstance(exc, ValueError) else "文件处理失败，请检查 FFmpeg、文件格式及磁盘空间"
        with connect(settings) as db:
            db.execute("UPDATE tasks SET state='failed',error=? WHERE id=?", (error, task["id"]))
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    settings = Settings()
    initialize(settings)
    # One worker process per data directory. OS releases the lock on crash.
    lock_file = (settings.data / "worker.lock").open("a+b")
    lock_file.seek(0)
    lock_file.write(b"0")
    lock_file.flush()
    lock_file.seek(0)
    if __import__("os").name == "nt":
        import msvcrt
        msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    with connect(settings) as db:
        db.execute("UPDATE tasks SET state='queued' WHERE state='running'")
    while True:
        work = run_once(settings)
        if args.once:
            break
        if not work:
            time.sleep(2)


if __name__ == "__main__":
    main()
