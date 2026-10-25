"""Resolve one Douyin work using F2; media transfer belongs to the Go worker.

Only this file imports the upstream platform implementation. Cookie values and
raw upstream errors must never be included in the protocol or written to logs.
"""
import argparse
import asyncio
import contextlib
import io
import json
import logging
import re
import sys
from pathlib import Path


class Discard(io.TextIOBase):
    def write(self, text):
        return len(text)

    def flush(self):
        pass


async def resolve(source, config):
    import f2
    from ruamel.yaml import YAML
    from f2.apps.douyin.handler import DouyinHandler
    from f2.apps.douyin.utils import AwemeIdFetcher, ClientConfManager
    from f2.log.logger import logger, trace_logger

    for log in (logger, trace_logger):
        for handler in list(log.handlers):
            log.removeHandler(handler)
            handler.close()
        log.disabled = True
        log.propagate = False
    logging.disable(logging.CRITICAL)
    yaml = YAML(typ="safe")
    base_path = Path(f2.__file__).parent / "conf" / "app.yaml"
    kwargs = (yaml.load(base_path.read_text(encoding="utf-8")) or {}).get("douyin", {})
    if config:
        custom = (yaml.load(Path(config).read_text(encoding="utf-8-sig")) or {}).get("douyin", {})
        kwargs.update(custom)
    headers = {"User-Agent": ClientConfManager.user_agent(), "Referer": ClientConfManager.referer()}
    kwargs.update(headers=headers, proxies=ClientConfManager.proxies(), timeout=12,
                  max_retries=1, enable_bark=False)
    work_id = await AwemeIdFetcher.get_aweme_id(source, proxies=kwargs.get("proxies"))
    video = await DouyinHandler(kwargs).fetch_one_video(work_id)
    urls = video.video_play_addr or []
    if isinstance(urls, str):
        urls = [urls]
    urls = list(dict.fromkeys(u for u in urls if isinstance(u, str) and len(u) <= 4096))[:8]
    if not urls:
        return {"error": {"code": "unsupported", "message": "该作品没有可下载视频，可能为图集或已不可访问"}}
    return {"id": str(video.aweme_id), "title": (video.desc or "")[:4000], "urls": urls,
            "headers": headers}


def classify(error):
    # Inspect privately, emit fixed codes only. Upstream exceptions often embed
    # signed URLs and headers; never serialize str(error) into a task response.
    text = str(error).lower()
    status = re.search(r"(?:status(?:[ _]*code)?\s*[:=]?\s*|client error\s*['\"]?)(401|403|404|429)\b", text)
    code = status.group(1) if status else ""
    if code in ("401", "403") or "cookie" in text:
        return {"code": "login_required", "message": "抖音作品接口拒绝访问，请检查电脑上的抖音登录配置"}
    if code == "429":
        return {"code": "rate_limited", "message": "抖音请求过于频繁，请稍后重试"}
    if code == "404":
        return {"code": "not_found", "message": "作品不存在、已删除或不可访问"}
    if isinstance(error, (ImportError, ModuleNotFoundError)):
        return {"code": "setup_required", "message": "下载器依赖不完整，请运行 scripts/setup-downloader.ps1"}
    if isinstance(error, (FileNotFoundError, PermissionError)):
        return {"code": "config_error", "message": "抖音下载配置无法读取，请检查电脑上的配置文件"}
    if "timeout" in text or "connect" in type(error).__name__.lower():
        return {"code": "network_error", "message": "连接抖音作品接口失败，请检查电脑网络"}
    return {"code": "resolve_failed", "message": "暂时无法解析作品，请确认分享链接并检查下载器适配"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--config", default="")
    args = parser.parse_args()
    with contextlib.redirect_stdout(Discard()), contextlib.redirect_stderr(Discard()):
        try:
            result = asyncio.run(resolve(args.url, args.config))
        except Exception as error:
            result = {"error": classify(error)}
    sys.stdout.write(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return 1 if "error" in result else 0


if __name__ == "__main__":
    raise SystemExit(main())
