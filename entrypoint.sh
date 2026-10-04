#!/usr/bin/env bash
# =============================================================================
# Multi-Channel Notification — entrypoint.sh
# =============================================================================
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# ─── Inputs ───────────────────────────────────────────────────────────────────
STATUS="${INPUT_STATUS:-released}"
URLS_INPUT="${INPUT_URLS:-}"

VERSION="${INPUT_VERSION:-}"
RELEASE_URL="${INPUT_RELEASE_URL:-}"
RELEASE_NOTES="${INPUT_RELEASE_NOTES:-}"

REPOSITORY="${GITHUB_REPOSITORY:-unknown/repo}"
AUTHOR="${INPUT_AUTHOR:-${GITHUB_ACTOR:-unknown}}"

ICON_URL="${INPUT_ICON_URL:-https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png}"

ACTION_PATH="${GITHUB_ACTION_PATH:-.}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

# 可选摘要，显示于 Release Notes 上方
SUMMARY="${INPUT_SUMMARY:-}"

TITLE_EMOJI="🚀"
SUMMARY_LABEL="📋 Summary"
NOTES_LABEL="📝 Release Notes"

# Guard
if [[ -z "${URLS_INPUT}" \
        && -z "${INPUT_EMAIL_URL:-}" \
        && -z "${INPUT_TELEGRAM_URL:-}" \
        && -z "${INPUT_BARK_URL:-}" \
        && -z "${INPUT_NTFY_URL:-}" \
        && -z "${INPUT_SLACK_URL:-}" \
        && -z "${INPUT_DINGTALK_URL:-}" ]]; then
    echo "::error::No destination configured."
    exit 1
fi

# ─── Markdown / HTML convert ──────────────────────────────────────────────────
convert_markdown() {
    local mode="$1"
    local text="$2"

    MODE="$mode" TEXT="$text" python3 - <<'PY'
import os
import re
import sys

mode = os.environ.get("MODE", "")
text = os.environ.get("TEXT", "")

def is_markdown(s: str) -> bool:
    return bool(re.search(
        r"(\*\*.*?\*\*|__.*?__|#+\s|-\s|\*\s|`.*?`|\[.*?\]\(.*?\))",
        s
    ))

def escape_plain(s: str) -> str:
    return (
        s.replace("&", "&amp;")
         .replace("<", "&lt;")
         .replace(">", "&gt;")
    )

def md_to_telegram(s: str) -> str:
    md = is_markdown(s)
    # Telegram HTML 必须先转义原始文本 (<, >, &)
    s = escape_plain(s)

    if not md:
        return s.strip()

    # 1. 提取并保护代码块，避免内部字符被后续正则误伤
    blocks = []
    def save_block(m):
        blocks.append(f"<pre>{m.group(1)}</pre>")
        return f"@@CODEBLOCK_{len(blocks)-1}@@"
    s = re.sub(r"```[a-zA-Z0-9]*\n(.*?)\n?```", save_block, s, flags=re.DOTALL)

    # 2. 提取并保护行内代码
    inlines = []
    def save_inline(m):
        inlines.append(f"<code>{m.group(1)}</code>")
        return f"@@INLINE_{len(inlines)-1}@@"
    s = re.sub(r"`([^`\n]+)`", save_inline, s)

    # 3. 处理基础 Markdown
    s = re.sub(r"^(#{1,6})\s+(.*)$", r"<b>\2</b>", s, flags=re.MULTILINE)  # 标题
    s = re.sub(r"\*\*(.*?)\*\*", r"<b>\1</b>", s)                         # 粗体
    s = re.sub(r"__(.*?)__", r"<b>\1</b>", s)                             # 粗体
    s = re.sub(r"(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)", r"<i>\1</i>", s)    # 斜体
    s = re.sub(r"^\s*[-*]\s+(.*)$", r"• \1", s, flags=re.MULTILINE)       # 列表

    # 4. 将 Markdown 链接转为 Telegram HTML 链接
    s = re.sub(r"\[([^\]]*?)\]\((.*?)\)", r'<a href="\2">\1</a>', s)

    # 5. 还原行内代码和代码块
    for i, inline in enumerate(inlines):
        s = s.replace(f"@@INLINE_{i}@@", inline)
    for i, block in enumerate(blocks):
        s = s.replace(f"@@CODEBLOCK_{i}@@", block)

    # 清理多余空行
    s = re.sub(r"\n{3,}", "\n\n", s)

    return s.strip()

def md_to_html(s: str) -> str:
    if not is_markdown(s):
        return escape_plain(s).replace("\n", "<br>")

    # GitHub release notes 常省略列表前的空行，补上，否则 markdown 库
    # 会将 "- item" 视为上一段落的延续，全部输出在同一 <p> 内
    s = re.sub(r'(?m)([^\n])\n([ \t]*[-*] )', r'\1\n\n\2', s)

    try:
        import markdown
        # codehilite 可选，不可用时降级到 extra
        try:
            return markdown.markdown(s, extensions=["extra", "codehilite"])
        except Exception:
            return markdown.markdown(s, extensions=["extra"])
    except Exception:
        # 降级处理
        s = escape_plain(s)

        # 代码块（优先处理，避免内部 * 被误匹配）
        def codeblock(m):
            code = m.group(1).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            return f"<pre><code>{code}</code></pre>"
        s = re.sub(r"```[a-zA-Z0-9]*\n(.*?)\n```", codeblock, s, flags=re.DOTALL)

        # 标题
        s = re.sub(r"(?m)^#{1,6}\s+(.*?)$", r"<b>\1</b>", s)

        # 列表（在 bold/italic 之前处理，避免 * 被误识别为斜体）
        def wrap_lists(text):
            lines = text.split("\n")
            out, in_list = [], False
            for line in lines:
                m = re.match(r"^(\s*)[-*]\s+(.*)", line)
                if m:
                    if not in_list:
                        out.append("<ul>")
                        in_list = True
                    out.append(f"<li>{m.group(2)}</li>")
                else:
                    if in_list:
                        out.append("</ul>")
                        in_list = False
                    out.append(line)
            if in_list:
                out.append("</ul>")
            return "\n".join(out)
        s = wrap_lists(s)

        # bold / italic（italic 限定不紧邻另一个 *）
        s = re.sub(r"\*\*(.*?)\*\*",                       r"<b>\1</b>", s)
        s = re.sub(r"__(.*?)__",                            r"<b>\1</b>", s)
        s = re.sub(r"(?<!\*)\*(?!\*)(.*?)(?<!\*)\*(?!\*)", r"<i>\1</i>", s)

        # 行内代码
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)

        # 链接
        s = re.sub(r"\[([^\]]*)\]\(([^)]*)\)", r'<a href="\2">\1</a>', s)

        # 段落换行（<ul> 行之间不加 <br>）
        lines = s.split("\n")
        out = []
        for line in lines:
            stripped = line.strip()
            if stripped in ("<ul>", "</ul>") or stripped.startswith("<li>"):
                out.append(line)
            elif stripped == "":
                out.append("")
            else:
                out.append(line + "<br>")
        return "\n".join(out)

if mode == "telegram":
    print(md_to_telegram(text), end="")
elif mode == "html":
    print(md_to_html(text), end="")
elif mode == "plain":
    print(escape_plain(text), end="")
else:
    print(text, end="")
PY
}

# ─── Changelog 预处理 ────────────────────────────────────────────────────────
# 用法：preprocess_changelog <mode> <text>
#   mode=telegram : 移除 commit id + 将 t.me Markdown 链接转为 @username
#   mode=其他     : 仅移除 commit id
preprocess_changelog() {
    local mode="$1"
    local text="$2"

    MODE="$mode" TEXT="$text" python3 - <<'PY'
import os
import re

mode = os.environ.get("MODE", "")
text = os.environ.get("TEXT", "")

# 全局移除 commit id：匹配行内 40 位十六进制 + ': '
text = re.sub(r'(?m)\b[0-9a-f]{40}:\s*', '', text)

if mode in ("telegram", "telegram_rich"):
    # t.me 链接转为 @username
    text = re.sub(
        r'\[[^\]]*\]\(https://t\.me/([^)]+)\)',
        r'@\1',
        text
    )

    # 保留 GitHub commit 短 hash，并让它可点击
    source = re.sub(
        r'\(\[`([0-9a-f]{4,40})`\]\((https://[^)]+/commit/[^)]+)\)\)',
        r'([`\1`](\2))',
        source,
    )

    # 移除 Markdown badge
    text = re.sub(
        r'(?m)^[ \t]*(?:!\[[^\]]*\]\([^)]*\)[ \t]*)+\n?',
        '',
        text
    )

    if mode == "telegram":
        # 普通 Telegram HTML 模式不能识别 table，
        # 继续保留旧的清理逻辑，供旧式 HTML 模板使用。
        text = re.sub(
            r'(?ms)<(div|table|thead|tbody|tr|th|td|br|img)[^>]*>.*?</\1>',
            '',
            text
        )
        text = re.sub(r'<[a-zA-Z][^>]*/>', '', text)

    # Rich Message 模式不能删除 table/div，
    # 后面的 HTML → RichBlock 转换器会负责处理。
    text = re.sub(r'\n{3,}', '\n\n', text)

# ─── 智能长度截断逻辑 ──────────────────────────────────────────────────────────
# 保护 Telegram / Discord 等渠道的单条消息长度限制（Telegram是4096）
if mode != "telegram_rich":
    limit = 3500 if mode == "telegram" else 6000

    if len(text) > limit:
        text = text[:limit]

        if text.count("```") % 2 != 0:
            text += "\n```"

        text += "\n\n... *(Release notes truncated due to length limits)*"

print(text, end="")
PY
}

sanitize_telegram_html() {
    local text="$1"

    TEXT="$text" python3 - <<'PY'
import os
import re

text = os.environ.get("TEXT", "")

text = re.sub(
    r"&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)",
    "&amp;",
    text
)

print(text, end="")
PY
}

build_telegram_rich_template() {
    local source="$1"

    local source_file
    local template_file

    source_file=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/telegram-rich-source-XXXXXX")
    template_file=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/telegram-rich-XXXXXX.json")

    printf '%s' "$source" > "$source_file"

    if ! TITLE="$TITLE" \
        SUMMARY="$SUMMARY" \
        RELEASE_URL="$RELEASE_URL" \
        python3 - "$source_file" "$template_file" <<'PY'
import json
import os
import re
import sys
from html.parser import HTMLParser


SOURCE_FILE = sys.argv[1]
OUTPUT_FILE = sys.argv[2]

TITLE = os.environ.get("TITLE", "")
SUMMARY = os.environ.get("SUMMARY", "")
RELEASE_URL = os.environ.get("RELEASE_URL", "")


# ---------------------------------------------------------------------------
# HTML DOM
# ---------------------------------------------------------------------------

VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img",
    "input", "link", "meta", "param", "source", "track", "wbr",
}


class Node:
    __slots__ = ("tag", "attrs", "children", "text")

    def __init__(self, tag=None, attrs=None, text=None):
        self.tag = tag
        self.attrs = dict(attrs or [])
        self.children = []
        self.text = text


class TreeParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("__root__")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.stack[-1].children.append(Node(tag.lower(), attrs))

    def handle_endtag(self, tag):
        tag = tag.lower()
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        if data:
            self.stack[-1].children.append(Node(None, text=data))

    def handle_comment(self, data):
        # GitHub HTML comments such as <!-- Android --> do not belong in Telegram output.
        pass


# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

def descendants(node, tag):
    result = []
    for child in node.children:
        if child.tag == tag:
            result.append(child)
        result.extend(descendants(child, tag))
    return result


def text_content(node, preserve=False):
    parts = []

    def walk(current):
        if current.tag is None:
            parts.append(current.text or "")
            return
        if current.tag == "img":
            parts.append(current.attrs.get("alt", ""))
            return
        if current.tag == "br":
            parts.append("\n")
            return
        for child in current.children:
            walk(child)

    walk(node)
    text = "".join(parts)
    if preserve:
        return text
    return re.sub(r"\s+", " ", text).strip()


def merge_rich(parts):
    result = []
    for part in parts:
        if part is None or part == "" or part == []:
            continue
        if isinstance(part, list):
            result.extend(part)
        else:
            result.append(part)
    if not result:
        return ""
    if len(result) == 1:
        return result[0]
    return result


# ---------------------------------------------------------------------------
# RichText (inline)
# ---------------------------------------------------------------------------

def render_inline_nodes(nodes):
    parts = []

    def filename_from_url(url: str) -> str:
        """从下载链接提取干净的文件名（支持无后缀名的二进制文件）"""
        if not url:
            return ""
        # 去掉查询参数和锚点
        path = url.split('?')[0].split('#')[0]
        name = path.rstrip('/').split('/')[-1]

        # 只要最后一段不是空的，就认为是文件名
        # （支持无后缀名的 Linux 二进制文件）
        if name and not name.startswith('.'):
            return name
        return ""

    def get_img_alt(node):
        """只返回真正的 alt，没有就返回空字符串"""
        return (node.attrs.get("alt") or "").strip()

    for node in nodes:
        if node.tag is None:
            if node.text:
                parts.append(node.text)
            continue

        tag = node.tag

        if tag == "br":
            parts.append("\n")

        elif tag == "img":
            # 单独出现的图片（不在 <a> 里）才处理
            alt = get_img_alt(node)
            if alt:
                parts.append(alt)
            # 没有 alt 就忽略，避免产生无意义文字

        elif tag in ("b", "strong"):
            parts.append({
                "type": "bold",
                "text": merge_rich(render_inline_nodes(node.children)),
            })

        elif tag in ("i", "em"):
            parts.append({
                "type": "italic",
                "text": merge_rich(render_inline_nodes(node.children)),
            })

        elif tag in ("u", "ins"):
            parts.append({
                "type": "underline",
                "text": merge_rich(render_inline_nodes(node.children)),
            })

        elif tag in ("s", "strike", "del"):
            parts.append({
                "type": "strikethrough",
                "text": merge_rich(render_inline_nodes(node.children)),
            })

        elif tag == "mark":
            parts.append({
                "type": "marked",
                "text": merge_rich(render_inline_nodes(node.children)),
            })

        elif tag == "tg-spoiler":
            parts.append({
                "type": "spoiler",
                "text": merge_rich(render_inline_nodes(node.children)),
            })

        elif tag == "code":
            parts.append({
                "type": "code",
                "text": text_content(node, preserve=True),
            })

        elif tag == "a":
            href = node.attrs.get("href", "")

            # 检查这个链接是否主要是「图片链接」（badge 下载按钮）
            img_nodes = [c for c in node.children if c.tag == "img"]
            text_nodes = [c for c in node.children if c.tag is None and (c.text or "").strip()]
            other_nodes = [c for c in node.children if c.tag not in (None, "img", "br")]

            is_image_link = (
                len(img_nodes) >= 1
                and not text_nodes
                and not other_nodes
            )

            if is_image_link:
                # ========== 你要求的规则 ==========
                # 1. 优先用 img 的 alt
                alt = get_img_alt(img_nodes[0])
                if alt:
                    display = alt
                else:
                    # 2. 没有 alt → 用 href 的文件名
                    display = filename_from_url(href) or href
                # =================================

                if href:
                    parts.append({
                        "type": "url",
                        "text": display,
                        "url": href,
                    })
                else:
                    parts.append(display)
            else:
                # 普通链接：正常渲染子节点
                child = merge_rich(render_inline_nodes(node.children))
                if href and child:
                    parts.append({
                        "type": "url",
                        "text": child,
                        "url": href,
                    })
                elif child:
                    parts.append(child)
                elif href:
                    short = filename_from_url(href) or href.split('/')[-1] or href
                    parts.append({
                        "type": "url",
                        "text": short,
                        "url": href,
                    })

        else:
            # 透明未知标签
            parts.append(render_inline_nodes(node.children))

    return parts


# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------

def render_paragraph(node):
    rich = merge_rich(render_inline_nodes(node.children))
    if not rich or (isinstance(rich, str) and not rich.strip()):
        return None
    return {
        "type": "paragraph",
        "text": rich,
    }


def render_list(node):
    items = []

    for li in [child for child in node.children if child.tag == "li"]:
        content_nodes = [
            child for child in li.children
            if child.tag not in ("ul", "ol")
        ]

        blocks = []
        rich = merge_rich(render_inline_nodes(content_nodes))
        if rich:
            blocks.append({
                "type": "paragraph",
                "text": rich,
            })

        for nested in [child for child in li.children if child.tag in ("ul", "ol")]:
            blocks.extend(render_blocks(nested))

        item = {
            "blocks": blocks or [{"type": "paragraph", "text": ""}]
        }

        # GitHub / Markdown task list checkbox
        checkbox = next(
            (
                child for child in li.children
                if child.tag == "input" and child.attrs.get("type") == "checkbox"
            ),
            None,
        )
        if checkbox is not None:
            item["has_checkbox"] = True
            item["is_checked"] = "checked" in checkbox.attrs

        if node.tag == "ol":
            item["value"] = len(items) + 1

        items.append(item)

    if not items:
        return None

    return {
        "type": "list",
        "items": items,
    }


def render_table(node):
    rows = descendants(node, "tr")
    output_rows = []

    for row in rows:
        cells = []
        for cell in [child for child in row.children if child.tag in ("th", "td")]:
            cell_obj = {
                "text": merge_rich(render_inline_nodes(cell.children)) or ""
            }

            if cell.tag == "th":
                cell_obj["is_header"] = True

            for attr, key in (("rowspan", "rowspan"), ("colspan", "colspan")):
                try:
                    value = int(cell.attrs.get(attr, "1"))
                    if value > 1:
                        cell_obj[key] = value
                except (TypeError, ValueError):
                    pass

            align = cell.attrs.get("align")
            if align in ("left", "center", "right"):
                cell_obj["align"] = align

            valign = cell.attrs.get("valign")
            if valign in ("top", "middle", "bottom"):
                cell_obj["valign"] = valign

            cells.append(cell_obj)

        if cells:
            output_rows.append(cells)

    if not output_rows:
        return None

    max_columns = max(len(row) for row in output_rows)

    # Official limit: max 20 columns
    if max_columns > 20:
        return {
            "type": "paragraph",
            "text": "Table omitted: more than 20 columns.",
        }

    # Soft limit to avoid exploding block count
    if len(output_rows) > 80:
        return {
            "type": "paragraph",
            "text": f"Table omitted: too many rows ({len(output_rows)}).",
        }

    table = {
        "type": "table",
        "cells": output_rows,
        "is_bordered": True,
        "is_striped": True,
        "is_compact": True,
    }

    caption = next(
        (child for child in node.children if child.tag == "caption"),
        None,
    )
    if caption:
        caption_text = merge_rich(render_inline_nodes(caption.children))
        if caption_text:
            table["caption"] = caption_text

    return table


def render_blocks(node):
    result = []
    tag = node.tag

    if tag in (
        "__root__", "div", "section", "article", "main",
        "thead", "tbody", "tfoot",
    ):
        for child in node.children:
            result.extend(render_blocks(child))
        return result

    if tag == "p":
        block = render_paragraph(node)
        return [block] if block else []

    if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
        rich = merge_rich(render_inline_nodes(node.children))
        if not rich:
            return []
        return [{
            "type": "heading",          # Official type is "heading"
            "text": rich,
            "size": int(tag[1]),
        }]

    if tag == "pre":
        code = next(iter(descendants(node, "code")), None)
        raw = text_content(node, preserve=True).strip("\n")
        block = {
            "type": "pre",
            "text": raw,
        }
        if code:
            match = re.search(
                r"(?:^|\s)language-([\w+-]+)",
                code.attrs.get("class", ""),
            )
            if match:
                block["language"] = match.group(1)
        return [block]

    if tag == "hr":
        return [{"type": "divider"}]

    if tag in ("ul", "ol"):
        block = render_list(node)
        return [block] if block else []

    if tag == "blockquote":
        if "expandable" in node.attrs:
            rich = merge_rich(render_inline_nodes(node.children))
            if rich:
                return [{
                    "type": "expandable_blockquote",
                    "text": rich,
                }]
            return []

        inner = []
        for child in node.children:
            inner.extend(render_blocks(child))
        if inner:
            return [{
                "type": "blockquote",
                "blocks": inner,
            }]
        return []

    if tag == "table":
        block = render_table(node)
        return [block] if block else []

    if tag is None:
        text = re.sub(r"\s+", " ", node.text or "").strip()
        if text:
            return [{
                "type": "paragraph",
                "text": text,
            }]
        return []

    # Unknown tags: treat as transparent unless pure inline content
    rich = merge_rich(render_inline_nodes(node.children))
    child_has_block = any(
        child.tag in (
            "p", "h1", "h2", "h3", "h4", "h5", "h6",
            "ul", "ol", "blockquote", "table", "pre", "hr",
        )
        for child in node.children
    )

    if rich and not child_has_block:
        return [{
            "type": "paragraph",
            "text": rich,
        }]

    for child in node.children:
        result.extend(render_blocks(child))
    return result


# ---------------------------------------------------------------------------
# Markdown -> HTML -> Rich Blocks
# ---------------------------------------------------------------------------

def markdown_to_root(source):
    try:
        import markdown
    except ImportError as exc:
        raise RuntimeError("Python package 'markdown' is required.") from exc

    html = markdown.markdown(
        source,
        extensions=["extra"],   # includes tables, fenced_code, etc.
    )

    parser = TreeParser()
    parser.feed(html)
    parser.close()
    return parser.root


# ---------------------------------------------------------------------------
# Preprocessing
# ---------------------------------------------------------------------------

with open(SOURCE_FILE, "r", encoding="utf-8") as f:
    source = f.read()

# 1. Global cleanups (same as preprocess_changelog for telegram_rich)
source = re.sub(r'(?m)\b[0-9a-f]{40}:\s*', '', source)

source = re.sub(
    r'\[[^\]]*\]\(https://t\.me/([^)]+)\)',
    r'@\1',
    source,
)

# 保留 GitHub commit 短 hash，并让它可点击
source = re.sub(
    r'\(\[`([0-9a-f]{4,40})`\]\((https://[^)]+/commit/[^)]+)\)\)',
    r'([`\1`](\2))',
    source,
)

# Remove badge-only Markdown lines
source = re.sub(
    r'(?m)^[ \t]*(?:!\[[^\]]*\]\([^)]*\)[ \t]*)+\n?',
    '',
    source,
)

source = re.sub(r'\n{3,}', '\n\n', source)

# 2. Task list enhancement: convert - [ ] / - [x] to HTML checkboxes
#    so the later checkbox detection works.
def convert_task_lists(text: str) -> str:
    def replacer(m):
        indent = m.group(1)
        checked = ' checked' if m.group(2).lower() == 'x' else ''
        content = m.group(3)
        return f'{indent}- <input type="checkbox"{checked} disabled> {content}'
    return re.sub(
        r'(?m)^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$',
        replacer,
        text,
    )

source = convert_task_lists(source)


root = markdown_to_root(source)
release_blocks = render_blocks(root)


# ---------------------------------------------------------------------------
# Header / summary / footer
# ---------------------------------------------------------------------------

blocks = []

if TITLE:
    blocks.append({
        "type": "heading",
        "text": TITLE,
        "size": 2,
    })

blocks.append({"type": "divider"})

if SUMMARY:
    summary_root = markdown_to_root(SUMMARY)
    summary_blocks = render_blocks(summary_root)
    blocks.append({
        "type": "details",
        "summary": "📋 Summary",
        "is_open": True,
        "blocks": summary_blocks or [{
            "type": "paragraph",
            "text": SUMMARY,
        }],
    })

blocks.append({
    "type": "heading",
    "text": "📝 Release Notes",
    "size": 3,
})


MAX_TEMPLATE_BYTES = 32000   # closer to official ~32768 char limit
MAX_BLOCKS = 480             # official limit is 500, leave headroom


def footer_block():
    if RELEASE_URL:
        return {
            "type": "footer",
            "text": [{
                "type": "url",
                "text": "View on GitHub →",
                "url": RELEASE_URL,
            }],
        }
    return {
        "type": "footer",
        "text": "View on GitHub →",
    }


def make_payload(release):
    return {
        "blocks": blocks + release + [footer_block()]
    }


def payload_size(value):
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    return len(encoded.encode("utf-8"))


def count_blocks(blks):
    total = 0
    for b in blks:
        if not isinstance(b, dict):
            continue
        total += 1
        if "blocks" in b:
            total += count_blocks(b["blocks"])
        if "items" in b:
            for item in b.get("items", []):
                total += count_blocks(item.get("blocks", []))
        if "cells" in b:
            # each cell counts toward the block budget
            total += sum(len(row) for row in b["cells"])
    return total


payload = make_payload(release_blocks)


def is_too_large(p):
    return (
        payload_size(p) > MAX_TEMPLATE_BYTES
        or count_blocks(p["blocks"]) > MAX_BLOCKS
    )


# Trim whole release blocks rather than corrupting mid-table / mid-code
if is_too_large(payload):
    while release_blocks and is_too_large(payload):
        release_blocks.pop()
        payload = make_payload(release_blocks)

    release_blocks.append({
        "type": "footer",
        "text": "… Release notes truncated due to length limits.",
    })
    payload = make_payload(release_blocks)


# Final cleanup: remove any completely empty blocks
payload["blocks"] = [b for b in payload["blocks"] if b]


with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
    json.dump(
        payload,
        f,
        ensure_ascii=False,
        separators=(",", ":"),
    )
PY
    then
        rm -f "$source_file" "$template_file"
        return 1
    fi

    rm -f "$source_file"
    printf '%s\n' "$template_file"
}


build_summary_section_html() {
    local summary="$1"
    [[ -z "$summary" ]] && return 0

    local summary_html
    summary_html=$(convert_markdown "html" "$summary")

    cat <<HEREDOC
<div class="summary-callout">
  <div class="summary-callout-label">${SUMMARY_LABEL}</div>
  <div class="summary-callout-body">${summary_html}</div>
</div>
HEREDOC
}

# 用 <blockquote> 包裹，label 加粗，内容用 telegram 模式转换
build_summary_section_telegram() {
    local summary="$1"
    [[ -z "$summary" ]] && return 0

    local summary_tg
    summary_tg=$(convert_markdown "telegram" "$summary")
    printf '<blockquote>%s</blockquote>\n&#8203;\n\n' "$summary_tg"
}

detect_template_kind() {
    local tpl_file="$1"

    if [[ ! -f "$tpl_file" ]]; then
        echo "text"
        return 0
    fi

    # 显式标记优先
    if grep -qiE '<!--[[:space:]]*apprise-template:[[:space:]]*telegram[[:space:]]*-->' "$tpl_file"; then
        echo "telegram_html"
        return 0
    fi

    if grep -qiE '<!--[[:space:]]*apprise-template:[[:space:]]*html[[:space:]]*-->' "$tpl_file"; then
        echo "html_doc"
        return 0
    fi

    case "${tpl_file##*.}" in
        md|markdown) echo "markdown"; return 0 ;;
        txt|text)    echo "text";     return 0 ;;
    esac

    # 依据模板内容判断
    if grep -qiE '<!doctype[[:space:]]+html|<html[[:space:]>]' "$tpl_file"; then
        echo "html_doc"
    else
        echo "telegram_html"
    fi
}

# Summary Section
SUMMARY_SECTION_HTML=""
SUMMARY_SECTION_MD=""
SUMMARY_SECTION_TG=""
SUMMARY_SECTION_TEXT=""

if [[ -n "${SUMMARY}" ]]; then
    SUMMARY_SECTION_HTML=$(build_summary_section_html "${SUMMARY}")
    SUMMARY_SECTION_TG=$(build_summary_section_telegram "${SUMMARY}")
    SUMMARY_SECTION_MD="${SUMMARY}"$'\n\n'"---"$'\n\n'
    SUMMARY_SECTION_TEXT="${SUMMARY}"$'\n'"────────────"$'\n\n'
fi

# VERSION
if [[ -z "${VERSION}" ]]; then
    GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

    if [[ -n "${GIT_TAG}" ]]; then
        VERSION="${GIT_TAG}"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/tags/ ]]; then
        VERSION="${GITHUB_REF#refs/tags/}"
    elif [[ "${GITHUB_REF:-}" =~ ^refs/heads/ ]]; then
        VERSION="${GITHUB_REF#refs/heads/}"
    else
        VERSION="${GITHUB_REF:-unknown}"
    fi
fi

# Release URL
if [[ -z "${RELEASE_URL}" ]]; then
    if [[ "${VERSION}" != "unknown" \
            && "${VERSION}" != "main" \
            && "${VERSION}" != "master" ]]; then
        RELEASE_URL="${GITHUB_SERVER_URL}/${REPOSITORY}/releases/tag/${VERSION}"
    else
        RELEASE_URL="${GITHUB_SERVER_URL}/${REPOSITORY}/releases"
    fi
fi

# Status
case "${STATUS,,}" in
    success|released)
        STATUS_TEXT="Released"
        NOTIFY_TYPE="success"
        ;;
    failure|failed)
        STATUS_TEXT="Failed"
        NOTIFY_TYPE="failure"
        ;;
    cancelled)
        STATUS_TEXT="Cancelled"
        NOTIFY_TYPE="warning"
        ;;
    *)
        STATUS_TEXT="${STATUS}"
        NOTIFY_TYPE="info"
        ;;
esac

# VERSION 赋值完成后，TITLE 构建之前插入：
if [[ "${VERSION}" =~ (alpha|beta|rc|pre|alpa) ]]; then
    TITLE_EMOJI="🚧"
fi

# Title
if [[ -n "${INPUT_TITLE:-}" ]]; then
    TITLE="${INPUT_TITLE}"
else
    case "${NOTIFY_TYPE}" in
        success)
            TITLE="${TITLE_EMOJI} ${REPOSITORY} updated to ${VERSION}"
            ;;
        failure)
            TITLE="❌ ${REPOSITORY} updated to ${VERSION} — failed"
            ;;
        warning)
            TITLE="⚠️ ${REPOSITORY} updated to ${VERSION} — cancelled"
            ;;
        *)
            TITLE="📢 ${REPOSITORY} updated to ${VERSION}"
            ;;
    esac
fi

# Release notes
if [[ -z "${INPUT_MESSAGE:-}" ]] && [[ -z "${RELEASE_NOTES}" ]]; then
    PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")

    if [[ -n "${PREV_TAG}" ]]; then
        RAW_LOG=$(git log --no-merges --pretty=format:"%s" "${PREV_TAG}..HEAD" 2>/dev/null || echo "")
        if [[ -n "${RAW_LOG}" ]]; then
            RELEASE_NOTES=$(echo "${RAW_LOG}" | sed 's/^/- /')
        else
            RELEASE_NOTES="No new commits since ${PREV_TAG}."
        fi
    else
        RAW_LOG=$(git log --no-merges --pretty=format:"%s" 2>/dev/null | head -20 || echo "")
        if [[ -n "${RAW_LOG}" ]]; then
            RELEASE_NOTES=$(echo "${RAW_LOG}" | sed 's/^/- /')
        fi
    fi
fi

RAW_MESSAGE="${INPUT_MESSAGE:-}"
if [[ -z "$RAW_MESSAGE" ]]; then
    RAW_MESSAGE="${RELEASE_NOTES:-}"
fi

if [[ -z "$RAW_MESSAGE" ]]; then
    RAW_MESSAGE="No release notes provided."
fi

MESSAGE="$RAW_MESSAGE"

# URL decoration
decorate_url() {
    local url="$1"
    local icon="$2"

    local scheme sep encoded_icon

    scheme=$(echo "$url" | sed 's|://.*||' | tr '[:upper:]' '[:lower:]')

    if [[ "$url" == *"?"* ]]; then
        sep="&"
    else
        sep="?"
    fi

    encoded_icon=$(python3 -c \
        "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" \
        "$icon")

    case "$scheme" in
        bark*)
            [[ "$url" != *"icon="*  ]] && url="${url}${sep}icon=${encoded_icon}" && sep="&"
            [[ "$url" != *"group="* ]] && url="${url}${sep}group=GitHub_Release"
            [[ "$url" != *"format="* ]] && url="${url}${sep}format=markdown"
            ;;
        ntfy*)
            [[ "$url" != *"avatar_url="* ]] && url="${url}${sep}avatar_url=${encoded_icon}" && sep="&"
            if [[ "$url" != *"tags="* ]]; then
                url="${url}${sep}tags=GitHub_Release"
                sep="&"
            else
                url=$(echo "$url" | sed 's/\(tags=[^&]*\)/\1,GitHub_Release/')
            fi
            [[ "$url" != *"format="* ]] && url="${url}${sep}format=markdown"
            ;;
        discord)
            [[ "$url" != *"avatar="*     ]] && url="${url}${sep}avatar=yes" && sep="&"
            [[ "$url" != *"avatar_url="* ]] && url="${url}${sep}avatar_url=${encoded_icon}"
            ;;
        mailto|mailtos)
            [[ "$url" != *"from="* ]] && url="${url}${sep}from=GitHub_Actions"
            ;;
    esac

    echo "$url"
}

append_url_param() {
    local url="$1"
    local key="$2"
    local value="$3"

    local sep encoded

    if [[ "$url" == *"?"* ]]; then
        sep="&"
    else
        sep="?"
    fi

    encoded=$(python3 -c \
        'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' \
        "$value")

    printf '%s%s%s=%s\n' \
        "$url" \
        "$sep" \
        "$key" \
        "$encoded"
}

# Template render
render_template() {
    local tpl_file="$1"
    local fmt="$2"

    local template_kind
    template_kind=$(detect_template_kind "$tpl_file")

    local processed_msg=""
    local summary_section=""

    case "$template_kind" in
        html_doc)
            local _msg_clean
            _msg_clean=$(preprocess_changelog "email" "$MESSAGE")
            if [[ -z "$_msg_clean" && -n "$MESSAGE" ]]; then
                _msg_clean="$MESSAGE"
            fi

            processed_msg=$(convert_markdown "html" "$_msg_clean")
            if [[ -z "$processed_msg" && -n "$_msg_clean" ]]; then
                processed_msg="$_msg_clean"
            fi

            summary_section="${SUMMARY_SECTION_HTML}"
            ;;

        telegram_html)
            local _msg_clean
            _msg_clean=$(preprocess_changelog "telegram" "$MESSAGE")
            if [[ -z "$_msg_clean" && -n "$MESSAGE" ]]; then
                _msg_clean="$MESSAGE"
            fi

            processed_msg=$(convert_markdown "telegram" "$_msg_clean")
            if [[ -z "$processed_msg" && -n "$_msg_clean" ]]; then
                processed_msg="$_msg_clean"
            fi

            summary_section="${SUMMARY_SECTION_TG}"
            ;;

        markdown)
            processed_msg=$(preprocess_changelog "markdown" "$MESSAGE")
            if [[ -z "$processed_msg" && -n "$MESSAGE" ]]; then
                processed_msg="$MESSAGE"
            fi

            summary_section="${SUMMARY_SECTION_MD}"
            ;;

        *)
            processed_msg=$(preprocess_changelog "text" "$MESSAGE")
            if [[ -z "$processed_msg" && -n "$MESSAGE" ]]; then
                processed_msg="$MESSAGE"
            fi

            summary_section="${SUMMARY_SECTION_TEXT}"
            ;;
    esac

    TITLE="$TITLE" \
    MESSAGE="$processed_msg" \
    SUMMARY="${SUMMARY}" \
    SUMMARY_SECTION="${summary_section}" \
    STATUS="${STATUS,,}" \
    STATUS_TEXT="$STATUS_TEXT" \
    REPOSITORY="$REPOSITORY" \
    AUTHOR="$AUTHOR" \
    VERSION="$VERSION" \
    RELEASE_URL="$RELEASE_URL" \
    RELEASE_NOTES="$RELEASE_NOTES" \
    TEMPLATE_KIND="$template_kind" \
    python3 - "$tpl_file" <<'PYEOF'
import sys
import os
from html import escape as h

with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()

kind = os.environ.get("TEMPLATE_KIND", "")

def safe(val, already_html=False):
    # HTML 模板中的裸文本变量需要转义；已经是 HTML 的变量直接透传
    if kind in ("html_doc", "telegram_html") and not already_html:
        return h(val, quote=False)
    return val

substitutions = [
    ("{TITLE}",           "TITLE",           False),
    ("{MESSAGE}",         "MESSAGE",         True),
    ("{SUMMARY}",         "SUMMARY",         False),
    ("{SUMMARY_SECTION}",  "SUMMARY_SECTION", True),
    ("{STATUS}",          "STATUS",          False),
    ("{STATUS_TEXT}",     "STATUS_TEXT",     False),
    ("{REPOSITORY}",      "REPOSITORY",      False),
    ("{AUTHOR}",          "AUTHOR",          False),
    ("{VERSION}",         "VERSION",         False),
    ("{RELEASE_URL}",     "RELEASE_URL",     False),
    ("{RELEASE_NOTES}",   "RELEASE_NOTES",   False),
]

for placeholder, env_key, already_html in substitutions:
    val = os.environ.get(env_key, "")
    content = content.replace(placeholder, safe(val, already_html))

print(content, end="")
PYEOF
}

# Run apprise
run_apprise() {
    local label="$1"
    local body="$2"
    local fmt="$3"
    local url="$4"
    local fatal="${5:-true}"

    echo "📤 [${label}] Sending..."

    if apprise \
        -vv \
        --title "${TITLE}" \
        --body "${body}" \
        --input-format "${fmt}" \
        --notification-type "${NOTIFY_TYPE}" \
        "${url}"; then
        echo "✅ [${label}] Sent."
    else
        echo "::error::[${label}] Failed."
        [[ "$fatal" == "true" ]] && return 1
    fi
}

# ─── Send channel ─────────────────────────────────────────────────────────────
send_channel() {
    local label="$1"
    local raw_url="$2"
    local user_tpl="$3"
    local fmt="$4"
    local builtin_tpl="$5"

    [[ -z "$raw_url" ]] && return 0

    # -------------------------------------------------------------------------
    # Telegram 默认使用 Telegram Rich Message
    #
    # Apprise v2.0.1 会根据 ?template= 直接调用 Telegram sendRichMessage，
    # 而不是传统的 sendMessage(parse_mode=HTML)。
    # -------------------------------------------------------------------------
    if [[ "$label" == "Telegram" && -z "$user_tpl" ]]; then
        echo "📄 [Telegram] Using Telegram Rich Message."

        local rich_template
        local url
        local rc

        if ! rich_template=$(build_telegram_rich_template "$MESSAGE"); then
            echo "::error::[Telegram] Failed to build Rich Message template."
            return 1
        fi

        url=$(decorate_url "$raw_url" "$ICON_URL")
        url=$(append_url_param "$url" "template" "$rich_template")

        if run_apprise \
            "Telegram" \
            "$MESSAGE" \
            "html" \
            "$url" \
            "true"; then

            rm -f "$rich_template"
            return 0
        else
            rc=$?
            rm -f "$rich_template"
            return "$rc"
        fi
    fi

    # -------------------------------------------------------------------------
    # Telegram 自定义 JSON 模板：
    # 用户可以直接提供 Apprise Rich Message JSON。
    # -------------------------------------------------------------------------
    if [[ "$label" == "Telegram" \
            && -n "$user_tpl" \
            && "${user_tpl,,}" == *.json \
            && -f "${GITHUB_WORKSPACE:-/github/workspace}/${user_tpl}" ]]; then

        local rich_template
        local url

        rich_template="${GITHUB_WORKSPACE:-/github/workspace}/${user_tpl}"

        echo "📄 [Telegram] Using Rich Message template: ${user_tpl}"

        url=$(decorate_url "$raw_url" "$ICON_URL")
        url=$(append_url_param "$url" "template" "$rich_template")

        run_apprise \
            "Telegram" \
            "$MESSAGE" \
            "html" \
            "$url" \
            "true"

        return $?
    fi

    # -------------------------------------------------------------------------
    # 其它渠道 / Telegram 旧式 HTML 自定义模板
    # -------------------------------------------------------------------------
    local tpl_file

    if [[ -n "$user_tpl" \
            && -f "${GITHUB_WORKSPACE:-/github/workspace}/${user_tpl}" ]]; then

        tpl_file="${GITHUB_WORKSPACE:-/github/workspace}/${user_tpl}"

        echo "📄 [${label}] Using custom template: ${user_tpl}"

    else
        tpl_file="$builtin_tpl"
    fi

    local body url

    body=$(render_template "$tpl_file" "$fmt")

    # Telegram 旧式 HTML 模板仍然需要这个兜底。
    # Rich Message 模式不会进入这里。
    if [[ "$label" == "Telegram" && "$fmt" == "html" ]]; then
        body=$(sanitize_telegram_html "$body")
    fi

    url=$(decorate_url "$raw_url" "$ICON_URL")

    run_apprise \
        "${label}" \
        "${body}" \
        "${fmt}" \
        "${url}" \
        "true"
}

# Send built-in channels
TDIR="${ACTION_PATH}/templates"

send_channel "Email"    "${INPUT_EMAIL_URL:-}"    "${INPUT_EMAIL_TEMPLATE:-}"    "html"     "${TDIR}/email.html"
send_channel "Telegram" "${INPUT_TELEGRAM_URL:-}" "${INPUT_TELEGRAM_TEMPLATE:-}" "html"     "${TDIR}/telegram.html"
send_channel "Bark"     "${INPUT_BARK_URL:-}"     "${INPUT_BARK_TEMPLATE:-}"     "markdown" "${TDIR}/bark.md"
send_channel "Ntfy"     "${INPUT_NTFY_URL:-}"     "${INPUT_NTFY_TEMPLATE:-}"     "markdown" "${TDIR}/ntfy.md"
send_channel "Slack"    "${INPUT_SLACK_URL:-}"    "${INPUT_SLACK_TEMPLATE:-}"    "markdown" "${TDIR}/slack.md"
send_channel "DingTalk" "${INPUT_DINGTALK_URL:-}" "${INPUT_DINGTALK_TEMPLATE:-}" "markdown" "${TDIR}/dingtalk.md"

# Generic URLs
if [[ -n "${URLS_INPUT}" ]]; then
    echo "─── Generic URLs ────────────────────────────────────────────────"

    while IFS= read -r raw_url || [[ -n "$raw_url" ]]; do
        raw_url=$(echo "$raw_url" | tr -d ' ,')
        [[ -z "$raw_url" ]] && continue

        local_scheme="${raw_url%%://*}"
        url=$(decorate_url "$raw_url" "$ICON_URL")

        fmt="text"
        case "${local_scheme,,}" in
            ntfy*|slack*|dingtalk*|mattermost*|matrix*|rocket*|discord*|telegram|bark*)
                fmt="markdown"
                ;;
            email|mailto|mailtos)
                fmt="html"
                ;;
        esac

        if [[ "$fmt" == "html" ]]; then
            formatted_message=$(convert_markdown "html" "$MESSAGE")
            generic_body="${SUMMARY_SECTION_HTML}${formatted_message}<br><br><a href=\"${RELEASE_URL}\">${RELEASE_URL}</a>"
        elif [[ "$fmt" == "markdown" ]]; then
            generic_body="${SUMMARY_SECTION_MD}${MESSAGE}"$'\n\n'"${RELEASE_URL}"
        else
            generic_body="${SUMMARY_SECTION_TEXT}${MESSAGE}"$'\n\n'"${RELEASE_URL}"
        fi

        run_apprise "generic:${local_scheme}" "${generic_body}" "${fmt}" "${url}" "false"

    done < <(echo "${URLS_INPUT}" | tr ',' '\n')
fi

echo "──────────────────────────────────────────────────────────────────"
echo "✅ All notifications processed."