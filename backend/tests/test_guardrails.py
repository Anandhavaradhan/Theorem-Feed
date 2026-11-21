"""§15.8 / §15.9 guardrail greps, comment-aware.

- No ads anywhere (backend + mobile).
- No discovery / adjacent / explore in backend code.
Comments and docstrings are excluded (they *document* the bans).
"""
import io
import re
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADS = re.compile(r"\b(ads|admob|ad_unit|adslot)\b", re.I)
DISCOVERY = re.compile(r"\b(discovery|adjacent|explore)\b", re.I)
SKIP_DIRS = {".venv", "__pycache__", ".dart_tool", "build", "tests", ".git", "alembic"}


def _files(base: Path, exts: tuple[str, ...]):
    for p in base.rglob("*"):
        if p.suffix in exts and not SKIP_DIRS & set(p.relative_to(ROOT).parts):
            yield p


def _python_code(src: str) -> str:
    """Python source minus comments and docstrings/bare string statements."""
    out, prev = [], tokenize.INDENT
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type == tokenize.COMMENT:
            continue
        if tok.type == tokenize.STRING and prev in (tokenize.INDENT, tokenize.DEDENT, tokenize.NEWLINE):
            prev = tok.type
            continue  # docstring
        if tok.type not in (tokenize.NL,):
            prev = tok.type
        out.append(tok.string)
    return " ".join(out)


def _dart_code(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(line.split("//")[0] if "://" not in line else line for line in src.splitlines())


def _code(p: Path) -> str:
    s = p.read_text(encoding="utf-8")
    return _python_code(s) if p.suffix == ".py" else _dart_code(s) if p.suffix == ".dart" else s


def test_no_ads_anywhere():
    hits = [str(p) for p in _files(ROOT, (".py", ".dart", ".yaml", ".json")) if ADS.search(_code(p))]
    assert hits == []


def test_no_discovery_in_backend():
    hits = [str(p) for p in _files(ROOT / "backend", (".py",)) if DISCOVERY.search(_code(p))]
    assert hits == []
