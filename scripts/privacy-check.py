#!/usr/bin/env python3
"""发布前的安全与隐私检查：仓库全部历史、提交身份、构建产物。

用法：
  scripts/privacy-check.py                    检查本仓库（当前文件 + 全部历史 + 提交身份）
  scripts/privacy-check.py --repo <目录>      再检查别的仓库，比如 Homebrew tap、官网
  scripts/privacy-check.py --app <Mulee.app>  检查 App 包里所有文件的原始字节（含二进制）
  scripts/privacy-check.py --file <文件>      检查单个文件，比如 appcast.xml、发版说明

私有屏蔽词（内网地址、内部域名、凭据编号等）放在 MULEE_PRIVACY_DENYLIST 指向的文件，
默认 ~/.config/mulee/privacy-denylist.txt。这个文件绝不进仓库；不存在时检查失败，
自己构建的人可以建一个空文件。

有问题时返回 1，并列出位置；没问题返回 0。
"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DENYLIST = os.environ.get(
    "MULEE_PRIVACY_DENYLIST", os.path.expanduser("~/.config/mulee/privacy-denylist.txt")
)
HOME = os.path.expanduser("~")

# 只放本机、绝不能进仓库的文件。
LOCAL_ONLY_NAMES = {"CLAUDE.md", "CLAUDE.local.md", "privacy-denylist.txt", ".env"}
SECRET_FILE = re.compile(
    r"(\.(p8|p12|pfx|pem|key|mobileprovision|keychain|jks)$)|(^|/)\.env(\.|$)|"
    r"(^|/)(id_rsa|id_ed25519)(\.pub)?$|纪要|AuthKey_",
    re.IGNORECASE,
)
# 上游子模块里的测试证书不在本仓库，这里只放本仓库自己的例外。
SECRET_FILE_ALLOW = re.compile(r"^ThirdParty/")

TEXT_PATTERNS = [
    ("私钥", re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+/=]{40}")),
    ("OpenAI 式 API key", re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}")),
    ("AWS access key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(rb"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|github_pat_[A-Za-z0-9_]{40,}")),
    ("Slack token", re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}")),
    ("Google API key", re.compile(rb"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("用户目录路径", re.compile(rb"/Users/(?!Shared/|example/|me/|you/|user/|name/)[A-Za-z0-9._-]+/")),
    ("身份证号", re.compile(rb"(?<![0-9A-Za-z])[1-9][0-9]{5}(19|20)[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9A-Za-z])")),
    ("手机号", re.compile(rb"(?<![0-9A-Za-z.])1[3-9][0-9]{9}(?![0-9A-Za-z])")),
]
# 邮箱只在文本里查；二进制里的上游作者邮箱不算。
EMAIL = re.compile(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
# 允许：GitHub 匿名邮箱、提交尾注、示例域名、图标文件名（icon@2x.png）、上游源码作者。
EMAIL_ALLOW = re.compile(
    rb"(@users\.noreply\.github\.com|^noreply@anthropic\.com|@example\.(com|org|net)|"
    rb"\.example|@[0-9]x\.png|^orsonpeters@gmail\.com)$",
    re.IGNORECASE,
)
IDENTITY_ALLOW = re.compile(r"@users\.noreply\.github\.com$")


def load_denylist() -> list:
    if not os.path.isfile(DENYLIST):
        sys.exit(f"缺少私有屏蔽词文件 {DENYLIST}（可设 MULEE_PRIVACY_DENYLIST；自己构建可建空文件）")
    words = []
    with open(DENYLIST, encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if line and not line.startswith("#"):
                words.append(line)
    return words


def patterns(denylist: list, binary: bool) -> list:
    result = list(TEXT_PATTERNS)
    result.append(("本机用户目录", re.compile(re.escape(HOME.encode()) + rb"(?=/)")))
    for word in denylist:
        result.append((f"私有屏蔽词「{word}」", re.compile(re.escape(word.encode()), re.IGNORECASE)))
    if binary:
        # 二进制里的手机号、身份证形态多半是常量，只查确定性的项。
        result = [item for item in result if item[0] not in ("身份证号", "手机号")]
    return result


def scan_bytes(data: bytes, rules: list, emails: bool) -> list:
    hits = []
    for name, rule in rules:
        match = rule.search(data)
        if match:
            hits.append(f"{name}：{shorten(match.group(0))}")
    if emails:
        for match in EMAIL.finditer(data):
            if not EMAIL_ALLOW.search(match.group(0)):
                hits.append(f"邮箱：{shorten(match.group(0))}")
                break
    return hits


def shorten(value: bytes) -> str:
    text = value.decode("utf-8", "replace")
    return text if len(text) <= 60 else text[:57] + "..."


def git(repo: str, *args: str) -> bytes:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout


def check_repo(repo: str, denylist: list) -> list:
    problems = []
    label = os.path.basename(os.path.abspath(repo))
    rules = patterns(denylist, binary=False)

    # 1. 当前跟踪的文件和历史上出现过的所有路径
    tracked = git(repo, "ls-files", "-z").decode().split("\0")
    for path in filter(None, tracked):
        if os.path.basename(path) in LOCAL_ONLY_NAMES:
            problems.append(f"[{label}] 只放本机的文件被跟踪了：{path}")
    history_paths = set()
    for line in git(repo, "log", "--all", "--format=", "--name-only", "-z").decode().split("\0"):
        history_paths.update(filter(None, line.split("\n")))
    for path in sorted(history_paths):
        if SECRET_FILE_ALLOW.search(path):
            continue
        if SECRET_FILE.search(path) or os.path.basename(path) in LOCAL_ONLY_NAMES:
            problems.append(f"[{label}] 历史里出现过敏感文件名：{path}")

    # 2. 提交身份
    for identity in set(git(repo, "log", "--all", "--format=%an <%ae>%n%cn <%ce>").decode().splitlines()):
        email = identity.rsplit("<", 1)[-1].rstrip(">")
        if identity and not IDENTITY_ALLOW.search(email):
            problems.append(f"[{label}] 提交身份不是 GitHub 匿名邮箱：{identity}")

    # 3. 全部历史的内容（每个提交的补丁 + 提交说明），按提交报告
    log = git(repo, "log", "--all", "-p", "--no-ext-diff", "--no-color", "--format=COMMIT %H%n%B")
    for chunk in re.split(rb"(?m)^COMMIT ", log):
        if not chunk:
            continue
        commit = chunk[:12].decode()
        for hit in scan_bytes(chunk, rules, emails=True):
            problems.append(f"[{label}] 提交 {commit}：{hit}")

    # 4. 工作区里已跟踪文件的当前内容（含未提交的修改），以及还没 git add 的新文件
    #    （不含被忽略的文件）。只扫已跟踪文件会漏掉新建文件，提交后才在历史扫描里报出来。
    untracked = git(repo, "ls-files", "-z", "--others", "--exclude-standard").decode().split("\0")
    for path in filter(None, tracked + untracked):
        full = os.path.join(repo, path)
        if os.path.isfile(full) and not os.path.islink(full):
            with open(full, "rb") as stream:
                for hit in scan_bytes(stream.read(), rules, emails=True):
                    problems.append(f"[{label}] 工作区 {path}：{hit}")

    # 5. gitleaks（装了才跑；已核实的公钥指纹写在仓库的 .gitleaksignore）
    if shutil.which("gitleaks"):
        result = subprocess.run(
            ["gitleaks", "git", "--no-banner", "--redact", "--exit-code", "3", repo],
            capture_output=True, text=True,
        )
        if result.returncode == 3:
            problems.append(f"[{label}] gitleaks 报告疑似密钥：\n{result.stdout.strip()}")
        elif result.returncode != 0:
            problems.append(f"[{label}] gitleaks 运行失败：{result.stderr.strip()[-300:]}")
    else:
        print("提示：没装 gitleaks（brew install gitleaks），跳过通用密钥扫描")
    return problems


def check_path(path: str, denylist: list, emails: bool) -> list:
    problems = []
    rules = patterns(denylist, binary=not emails)
    files = [path] if os.path.isfile(path) else [
        os.path.join(directory, name)
        for directory, _, names in os.walk(path) for name in names
    ]
    for file in files:
        if os.path.islink(file) or not os.path.isfile(file):
            continue
        with open(file, "rb") as stream:
            data = stream.read()
        for hit in scan_bytes(data, rules, emails=emails):
            problems.append(f"{os.path.relpath(file, os.path.dirname(path))}：{hit}")
    return problems


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    repos, apps, files = [], [], []
    while args:
        option = args.pop(0)
        if not args:
            print(__doc__)
            return 2
        {"--repo": repos, "--app": apps, "--file": files}.get(option, []).append(args.pop(0))
    if not (repos or apps or files):
        repos = [ROOT]
    denylist = load_denylist()
    problems = []
    for repo in repos:
        problems.extend(check_repo(repo, denylist))
    for app in apps:
        problems.extend(check_path(app, denylist, emails=False))
    for file in files:
        problems.extend(check_path(file, denylist, emails=True))
    for line in sorted(set(problems)):
        print(line)
    if problems:
        print(f"\n共 {len(set(problems))} 处安全或隐私问题，处理完再发布。")
        return 1
    print(f"安全与隐私检查通过（屏蔽词 {len(denylist)} 条）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
