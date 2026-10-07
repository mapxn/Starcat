#!/usr/bin/env python3
"""用本机 gh 发布 Direct DMG/SHA256，校验完成后才公开 Release。

本模块只负责 GitHub 附件，不构建、不修改 DMG，也不上传 appcast。
草稿允许补齐缺失附件；已有附件必须与本地产物一致，绝不使用 --clobber。
因此上传中断可以续跑，而同一版本重新打包造成的内容变化会明确失败。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPOSITORY = "starcat-app/Starcat"


def gh(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    """固定通过参数数组调用 gh，避免发布说明或路径被 shell 解释。"""
    result = subprocess.run(
        ["gh", *args], capture_output=True, text=True, timeout=900
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or "GitHub CLI 执行失败")
    return result


def get_release(tag: str) -> dict | None:
    """仅把明确的 404 当作缺失；鉴权、网络错误不能触发创建流程。"""
    result = gh("api", f"repos/{REPOSITORY}/releases/tags/{tag}", check=False)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or "无法读取 GitHub Release")
    return json.loads(result.stdout)


def file_sha256(path: Path) -> str:
    """流式计算摘要，避免把整个 DMG 放入内存。"""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_notes(changelog: Path, version: str) -> str:
    """只接受目标版本的正式标题，不把待发布内容带入公开 Release。"""
    match = re.search(
        rf"^## {re.escape(version)}\s*\n(.*?)(?=^## |\Z)",
        changelog.read_text(encoding="utf-8"),
        re.MULTILINE | re.DOTALL,
    )
    if not match or not match.group(1).strip():
        raise ValueError(f"Changelog 缺少正式版本内容: {version}")
    return match.group(1).strip() + "\n"


def publish(version: str, dmg: Path, checksum: Path, changelog: Path) -> None:
    """上传草稿、回读实际附件并校验摘要，再公开；已发布的一致版本只回读。"""
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("版本号必须是 X.Y.Z")
    if dmg.name != f"Starcat-{version}-arm64.dmg" or checksum.name != dmg.name + ".sha256":
        raise ValueError("DMG/SHA256 文件名必须与目标版本一致")
    digest = file_sha256(dmg)
    if not re.fullmatch(
        rf"{digest}\s+\*?{re.escape(dmg.name)}", checksum.read_text().strip()
    ):
        raise ValueError("本地 DMG 与 SHA256 不一致，禁止上传")
    notes = release_notes(changelog, version)
    tag = f"v{version}"
    release = get_release(tag)
    if release and release["prerelease"]:
        raise ValueError("目标 tag 已是预发布版本，请先确认发布策略")

    with tempfile.TemporaryDirectory(prefix="starcat-github-release-") as directory:
        work = Path(directory)
        if release is None:
            notes_path = work / "release-notes.md"
            notes_path.write_text(notes, encoding="utf-8")
            gh(
                "release", "create", tag, "--repo", REPOSITORY,
                "--draft", "--verify-tag", "--title", f"Starcat {version}",
                "--notes-file", str(notes_path),
            )
            release = get_release(tag)
            if release is None:
                raise RuntimeError("创建草稿后无法回读 Release")

        existing = {asset["name"] for asset in release["assets"]}
        for artifact in (dmg, checksum):
            if artifact.name not in existing:
                if not release["draft"]:
                    raise ValueError(f"已发布 Release 缺少附件，停止修改: {artifact.name}")
                gh("release", "upload", tag, str(artifact), "--repo", REPOSITORY)
            # 下载真实附件校验；不依赖可能缺失的 API digest，也不只检查同名/大小。
            gh(
                "release", "download", tag, "--repo", REPOSITORY,
                "--pattern", artifact.name, "--dir", str(work),
            )
            if file_sha256(work / artifact.name) != file_sha256(artifact):
                raise ValueError(f"GitHub 附件与本地不同，禁止覆盖或发布: {artifact.name}")

        if release["draft"]:
            gh("release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--latest")
        published = get_release(tag)
        if published is None or published["draft"] or published["prerelease"]:
            raise RuntimeError("Release 尚未正式公开，禁止发布 appcast")
        print(f"GitHub Release 已核验: {published['html_url']}")


def main() -> None:
    """提供给 release-direct.sh 的单一发布入口；失败以非零状态阻断清单上传。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--sha256", required=True, type=Path)
    parser.add_argument("--changelog", required=True, type=Path)
    args = parser.parse_args()
    try:
        publish(args.version, args.dmg, args.sha256, args.changelog)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"[github-release] ERROR: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
