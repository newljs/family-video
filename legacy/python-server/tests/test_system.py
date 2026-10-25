import io
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from family_video.config import Settings
from family_video.db import connect
from family_video.downloaders import extract_url
from family_video.main import create_app
from family_video.worker import run_once


@pytest.fixture
def system(tmp_path, monkeypatch):
    # Functional tests should not depend on free space on the host system drive.
    # Low-space rejection is covered independently below.
    monkeypatch.setattr('shutil.disk_usage', lambda _: SimpleNamespace(free=100 * 1024**3))
    settings = Settings(tmp_path)
    client = TestClient(create_app(settings))
    parent = {"Authorization": f"Bearer {settings.admin_key}"}
    return settings, client, parent


def child(client, parent):
    code = client.post('/api/pairing', headers=parent).json()['code']
    response = client.post('/api/pair', json={'code': code, 'name': 'test tablet'})
    assert response.status_code == 200
    assert client.post('/api/pair', json={'code': code, 'name': 'replay'}).status_code == 400
    return {"Authorization": f"Bearer {response.json()['token']}"}, response.json()['device_id']


@pytest.fixture
def video_file(tmp_path):
    file = tmp_path / 'sample.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=green:s=160x120:d=1',
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(file)], check=True)
    return file


def test_upload_publish_range_unpublish_revoke(system, video_file):
    settings, client, parent = system
    kid, device = child(client, parent)
    with video_file.open('rb') as stream:
        result = client.post('/api/uploads', headers=parent, data={'title':'森林'}, files={'file': ('sample.mp4', stream, 'video/mp4')})
    assert result.status_code == 200
    assert run_once(settings)
    assert not run_once(settings)
    tasks = client.get('/api/tasks', headers=parent).json()
    assert tasks[0]['state'] == 'completed'
    assert client.get('/api/videos', headers=kid).json() == []
    video = client.get('/api/videos', headers=parent).json()[0]
    assert client.get(video['media_url']).status_code == 200
    assert client.patch(f"/api/videos/{video['id']}", headers=kid, json={'title':'x','published':True}).status_code == 403
    assert client.patch(f"/api/videos/{video['id']}", headers=parent, json={'title':'森林','published':True}).status_code == 200
    public = client.get('/api/videos', headers=kid).json()[0]
    response = client.get(public['media_url'], headers={'Range':'bytes=0-31'})
    assert response.status_code == 206 and len(response.content) == 32
    assert client.get(public['thumbnail_url']).status_code == 200
    assert client.get(public['media_url'].replace('role='+device, 'role=admin')).status_code == 403
    client.patch(f"/api/videos/{video['id']}", headers=parent, json={'title':'森林','published':False})
    assert client.get(public['media_url']).status_code == 404
    client.patch(f"/api/videos/{video['id']}", headers=parent, json={'title':'森林','published':True})
    client.delete(f'/api/devices/{device}', headers=parent)
    assert client.get('/api/videos',headers=kid).status_code == 401
    assert client.get(public['media_url']).status_code == 403


def test_import_dedup_and_validation(system):
    settings, client, parent = system
    assert client.post('/api/imports',json={'text':'https://v.douyin.com/test/'}).status_code == 401
    body = {'text':'复制这段文字 https://v.douyin.com/test/ 学习','title':'科学'}
    a = client.post('/api/imports',headers=parent,json=body).json()
    b = client.post('/api/imports',headers=parent,json=body).json()
    assert a['id'] == b['id']
    assert client.post('/api/imports',headers=parent,json={'text':'https://127.0.0.1/private'}).status_code == 400
    settings.f2_exe = str(settings.data / 'not-installed.exe')
    assert run_once(settings)
    task = client.get('/api/tasks',headers=parent).json()[0]
    assert task['state'] == 'failed' and 'F2' in task['error']
    assert client.post(f"/api/tasks/{a['id']}/retry",headers=parent).status_code == 200


def test_invalid_upload_is_not_published(system):
    settings, client, parent = system
    assert client.post('/api/uploads',headers=parent,files={'file':('bad.mp4', io.BytesIO(b'not-video'))}).status_code == 200
    assert run_once(settings)
    assert client.get('/api/videos',headers=parent).json() == []
    assert client.get('/api/tasks',headers=parent).json()[0]['state'] == 'failed'


def test_collection_filters_unpublished_and_keeps_order(system,video_file):
    settings, client, parent = system
    kid, _ = child(client,parent)
    ids=[]
    for i in range(2):
        with video_file.open('rb') as stream:
            client.post('/api/uploads',headers=parent,data={'title':str(i)},files={'file':('video.mp4',stream)})
        run_once(settings)
        ids.append(client.get('/api/videos',headers=parent).json()[0]['id'])
    response=client.post('/api/collections',headers=parent,json={'title':'自然','video_ids':ids[::-1]})
    assert response.status_code == 200
    assert client.get('/api/collections',headers=kid).json() == []
    for vid in ids:
        client.patch(f'/api/videos/{vid}',headers=parent,json={'title':vid,'published':True})
    entries=client.get('/api/collections',headers=kid).json()[0]['videos']
    assert [v['id'] for v in entries] == ids[::-1]
    assert client.post('/api/collections',headers=parent,json={'title':'bad','video_ids':['missing']}).status_code == 400


@pytest.mark.parametrize('text',['https://douyin.com.evil.test/a','https://user:pass@www.douyin.com/a','https://www.douyin.com:123/a','not a link'])
def test_reject_unsupported_urls(text):
    with pytest.raises(ValueError):
        extract_url(text)


def test_f2_adapter_isolated_arguments_and_file_validation(system, monkeypatch, tmp_path):
    from family_video.downloaders import download
    settings, _, _ = system
    settings.f2_exe = str(tmp_path / 'f2.exe')
    Path(settings.f2_exe).touch()
    settings.f2_config = str(tmp_path / 'private.yaml')
    folder = tmp_path / 'download'
    folder.mkdir()
    captured = []
    def fake_run(args, **kwargs):
        captured.append((args, kwargs))
        (folder / 'result.mp4').write_bytes(b'test')
        return subprocess.CompletedProcess(args, 0)
    monkeypatch.setattr('family_video.downloaders.subprocess.run', fake_run)
    result = download(settings, 'https://www.douyin.com/video/123', folder)
    assert result.name == 'result.mp4'
    args, kwargs = captured[0]
    assert args[0] == settings.f2_exe
    assert args[args.index('--mode') + 1] == 'one'
    assert args[args.index('--config') + 1] == settings.f2_config
    assert kwargs.get('shell', False) is False
    assert kwargs['stderr'] == subprocess.DEVNULL
    (folder / 'extra.mp4').touch()
    with pytest.raises(ValueError, match='未生成单个视频'):
        download(settings, 'https://www.douyin.com/video/123', folder)


def test_upload_rejects_low_storage(system, monkeypatch):
    _, client, parent = system
    monkeypatch.setattr('shutil.disk_usage', lambda _: SimpleNamespace(free=0))
    response = client.post('/api/uploads', headers=parent, files={'file': ('video.mp4', io.BytesIO(b'test'))})
    assert response.status_code == 507
