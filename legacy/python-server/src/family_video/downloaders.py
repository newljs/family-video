"""F2 CLI adapter. Upstream runs in a separate environment; no shell execution."""
import re
import subprocess
from pathlib import Path
from urllib.parse import urlparse


def extract_url(text: str) -> str:
    match = re.search(r"https?://[^\s<>\"，。；！]+", text)
    if not match:
        raise ValueError("分享内容中没有有效链接")
    url = match.group().rstrip(".,;!)/")
    parsed = urlparse(url)
    if parsed.hostname not in {"v.douyin.com", "www.douyin.com", "douyin.com"}:
        raise ValueError("目前只接收抖音分享链接")
    if parsed.username or parsed.password or parsed.port not in (None, 80, 443):
        raise ValueError("链接格式不受支持")
    return url


def download(settings, url: str, folder: Path) -> Path:
    if not Path(settings.f2_exe).is_file():
        raise ValueError("F2 尚未安装，请运行 scripts/setup-downloader.ps1")
    args = [settings.f2_exe, "douyin", "--url", url, "--mode", "one", "--path", str(folder),
            "--music", "false", "--cover", "false", "--desc", "false", "--max-counts", "1"]
    if settings.f2_config:
        args += ["--config", settings.f2_config]
    try:
        # Do not return upstream output to clients: it may contain cookies/config.
        result = subprocess.run(args, cwd=folder, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=300)
    except subprocess.TimeoutExpired as exc:
        raise ValueError("下载超时，请检查网络或登录配置后重试") from exc
    files = list(folder.rglob("*.mp4"))
    if result.returncode or len(files) != 1:
        raise ValueError("F2 未生成单个视频，请检查链接、登录配置或平台接口；图集暂不支持")
    return files[0]
