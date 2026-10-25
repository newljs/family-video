import json
import os
import secrets
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[3]
load_dotenv(ROOT / ".env")


class Settings:
    def __init__(self, data_dir: Path | None = None):
        path = data_dir or Path(os.getenv("FAMILY_DATA_DIR", "runtime"))
        self.data = path if path.is_absolute() else ROOT / path
        for folder in ("videos", "thumbnails", "temp", "database"):
            (self.data / folder).mkdir(parents=True, exist_ok=True)
        credentials = self.data / "credentials.json"
        try:
            with credentials.open("x", encoding="utf-8") as file:
                json.dump({"admin_key": secrets.token_urlsafe(32), "signing_key": secrets.token_hex(32)}, file)
        except FileExistsError:
            pass
        keys = json.loads(credentials.read_text(encoding="utf-8"))
        self.admin_key = keys["admin_key"]
        self.signing_key = keys["signing_key"]
        self.database = self.data / "database" / "family.sqlite3"
        self.f2_exe = os.getenv("FAMILY_F2_EXE", str(ROOT / ".downloader-venv" / "Scripts" / "f2.exe"))
        self.f2_config = os.getenv("FAMILY_F2_CONFIG")
