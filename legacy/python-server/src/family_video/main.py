import hashlib
import hmac
import secrets
import shutil
import time
from pathlib import Path
from uuid import uuid4

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from .config import Settings
from .db import connect, initialize
from .downloaders import extract_url


class ImportInput(BaseModel):
    text: str = Field(min_length=1, max_length=10000)
    title: str = Field(default="新收集的视频", min_length=1, max_length=200)


class VideoUpdate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    published: bool


class CollectionInput(BaseModel):
    title: str = Field(min_length=1, max_length=100)
    video_ids: list[str] = Field(default_factory=list, max_length=500)


class PairInput(BaseModel):
    code: str = Field(min_length=6, max_length=6)
    name: str = Field(min_length=1, max_length=80)


def create_app(settings: Settings | None = None):
    settings = settings or Settings()
    initialize(settings)
    app = FastAPI(title="Family Video", version="0.1.0")

    def identity(request: Request):
        token = request.headers.get("authorization", "").removeprefix("Bearer ")
        if secrets.compare_digest(token, settings.admin_key):
            return "admin"
        with connect(settings) as db:
            device = db.execute("SELECT id FROM devices WHERE token_hash=? AND revoked=0",
                                (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        if device:
            return device["id"]
        raise HTTPException(401, "请连接服务器并完成配对")

    def admin(role=Depends(identity)):
        if role != "admin":
            raise HTTPException(403, "需要家长权限")
        return role

    def signature(video_id, resource, expires, role):
        text = f"{video_id}:{resource}:{expires}:{role}".encode()
        return hmac.new(settings.signing_key.encode(), text, hashlib.sha256).hexdigest()

    def present(row, role):
        video = dict(row)
        expires = int(time.time()) + 86400
        for field, resource in (("media_url", "video"), ("thumbnail_url", "thumbnail")):
            sig = signature(video["id"], resource, expires, role)
            video[field] = f"/media/{video['id']}/{resource}?expires={expires}&role={role}&sig={sig}"
        video.pop("path", None)
        return video

    @app.get("/health")
    def health():
        return {"status": "ok", "version": "0.1.0"}

    @app.get("/api/me")
    def me(role=Depends(identity)):
        return {"role": "admin" if role == "admin" else "child"}

    @app.post("/api/pairing", dependencies=[Depends(admin)])
    def pairing():
        with connect(settings) as db:
            db.execute("DELETE FROM pairing")
            code = str(secrets.randbelow(900000) + 100000)
            db.execute("INSERT INTO pairing VALUES(?,?)", (code, int(time.time()) + 600))
        return {"code": code, "expires_in": 600}

    @app.post("/api/pair")
    def pair(body: PairInput):
        with connect(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            item = db.execute("SELECT * FROM pairing WHERE code=? AND expires>?", (body.code, int(time.time()))).fetchone()
            if not item:
                raise HTTPException(400, "配对码错误或过期")
            token = secrets.token_urlsafe(32)
            device_id = uuid4().hex
            db.execute("INSERT INTO devices(id,name,token_hash) VALUES(?,?,?)",
                       (device_id, body.name, hashlib.sha256(token.encode()).hexdigest()))
            db.execute("DELETE FROM pairing WHERE code=?", (body.code,))
        return {"token": token, "device_id": device_id}

    @app.get("/api/devices", dependencies=[Depends(admin)])
    def devices():
        with connect(settings) as db:
            return [dict(r) for r in db.execute("SELECT id,name,revoked FROM devices")]

    @app.delete("/api/devices/{device_id}", dependencies=[Depends(admin)])
    def revoke(device_id: str):
        with connect(settings) as db:
            db.execute("UPDATE devices SET revoked=1 WHERE id=?", (device_id,))
        return {"ok": True}

    @app.post("/api/imports", dependencies=[Depends(admin)])
    def import_link(body: ImportInput):
        try:
            url = extract_url(body.text)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        with connect(settings) as db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute("SELECT * FROM tasks WHERE source=? AND state NOT IN ('failed','cancelled')", (url,)).fetchone()
            if existing:
                return dict(existing)
            task_id = uuid4().hex
            db.execute("INSERT INTO tasks(id,source,title,kind) VALUES(?,?,?,'douyin')", (task_id, url, body.title))
            return dict(db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone())

    @app.post("/api/uploads", dependencies=[Depends(admin)])
    def upload(file: UploadFile = File(), title: str = Form("本地视频")):
        task_id = uuid4().hex
        path = settings.data / "temp" / f"{task_id}.mp4"
        if not 1 <= len(title) <= 200:
            raise HTTPException(400, "标题长度应为 1 到 200 字")
        try:
            if shutil.disk_usage(settings.data).free < 3 * 1024**3:
                raise HTTPException(507, "磁盘剩余空间不足 3GB")
            size = 0
            with path.open("wb") as target:
                while chunk := file.file.read(1024 * 1024):
                    size += len(chunk)
                    if size > 2 * 1024**3:
                        raise HTTPException(413, "单个文件上限 2GB")
                    target.write(chunk)
            if not size:
                raise HTTPException(400, "文件为空")
            with connect(settings) as db:
                db.execute("INSERT INTO tasks(id,source,title,kind) VALUES(?,?,?,'upload')", (task_id, str(path), title))
        except Exception:
            path.unlink(missing_ok=True)
            raise
        finally:
            file.file.close()
        return {"id": task_id, "state": "queued"}

    @app.get("/api/tasks", dependencies=[Depends(admin)])
    def tasks():
        with connect(settings) as db:
            # Do not expose local filesystem paths.
            return [dict(r) for r in db.execute("SELECT id,title,kind,state,error,video_id,attempts FROM tasks ORDER BY created_at DESC,rowid DESC LIMIT 200")]

    @app.post("/api/tasks/{task_id}/retry", dependencies=[Depends(admin)])
    def retry(task_id: str):
        with connect(settings) as db:
            task = db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if not task:
                raise HTTPException(404, "任务不存在")
            if task["state"] != "failed":
                raise HTTPException(409, "只有失败任务可以重试")
            existing = db.execute("SELECT id FROM tasks WHERE source=? AND state NOT IN ('failed','cancelled')", (task["source"],)).fetchone()
            if existing:
                raise HTTPException(409, "同一来源已有任务")
            db.execute("UPDATE tasks SET state='queued',error=NULL WHERE id=?", (task_id,))
        return {"ok": True}

    @app.get("/api/videos")
    def videos(role=Depends(identity)):
        with connect(settings) as db:
            rows = db.execute("SELECT * FROM videos WHERE (?='admin' OR published=1) ORDER BY created_at DESC,rowid DESC", (role,))
            return [present(row, role) for row in rows]

    @app.patch("/api/videos/{video_id}", dependencies=[Depends(admin)])
    def edit_video(video_id: str, body: VideoUpdate):
        with connect(settings) as db:
            result = db.execute("UPDATE videos SET title=?,published=? WHERE id=?", (body.title, body.published, video_id))
            if not result.rowcount:
                raise HTTPException(404, "视频不存在")
        return {"ok": True}

    @app.get("/api/collections")
    def collections(role=Depends(identity)):
        with connect(settings) as db:
            result = []
            for row in db.execute("SELECT * FROM collections ORDER BY rowid DESC"):
                item = dict(row)
                item["videos"] = [present(v, role) for v in db.execute(
                    "SELECT v.* FROM collection_items i JOIN videos v ON v.id=i.video_id WHERE i.collection_id=? AND (?='admin' OR v.published=1) ORDER BY i.position", (item["id"], role))]
                if role == "admin" or item["videos"]:
                    result.append(item)
            return result

    @app.post("/api/collections", dependencies=[Depends(admin)])
    def create_collection(body: CollectionInput):
        collection_id = uuid4().hex
        with connect(settings) as db:
            ids = list(dict.fromkeys(body.video_ids))
            for vid in ids:
                if not db.execute("SELECT id FROM videos WHERE id=?", (vid,)).fetchone():
                    raise HTTPException(400, "合集包含不存在的视频")
            db.execute("INSERT INTO collections VALUES(?,?)", (collection_id, body.title))
            db.executemany("INSERT INTO collection_items VALUES(?,?,?)", [(collection_id, vid, i) for i, vid in enumerate(ids)])
        return {"id": collection_id}

    @app.get("/media/{video_id}/{resource}")
    def media(video_id: str, resource: str, expires: int, role: str, sig: str):
        if resource not in {"video", "thumbnail"} or expires < int(time.time()) or not hmac.compare_digest(sig, signature(video_id, resource, expires, role)):
            raise HTTPException(403, "播放授权无效或过期，请刷新目录")
        with connect(settings) as db:
            if role != "admin" and not db.execute("SELECT id FROM devices WHERE id=? AND revoked=0", (role,)).fetchone():
                raise HTTPException(403, "设备授权已撤销")
            row = db.execute("SELECT * FROM videos WHERE id=? AND (?='admin' OR published=1)", (video_id, role)).fetchone()
        if not row:
            raise HTTPException(404, "视频不存在或已下架")
        path = settings.data / ("videos" if resource == "video" else "thumbnails") / (row["path"] if resource == "video" else f"{video_id}.jpg")
        if not path.is_file():
            raise HTTPException(404, "文件不可用")
        return FileResponse(path, media_type="video/mp4" if resource == "video" else "image/jpeg")

    return app
