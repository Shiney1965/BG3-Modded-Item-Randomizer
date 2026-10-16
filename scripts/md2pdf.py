"""md2pdf.py - render MIR's Markdown docs (README.md / INSTALL.md) to PDF with reportlab.

WHY THIS EXISTS. v1.0.1 and v1.1.1 made the PDFs with Word COM (open the .docx, ExportAsFixedFormat).
On 2026-10-16 that stopped working in the build session: Word.Application could be created but
Documents.Open never returned, twice, leaving invisible WINWORD processes that could not be killed
from the shell. Edge headless --print-to-pdf was tried next and is blocked here too - it exits 0
and writes nothing. So the PDFs are now rendered directly from the Markdown, with no external
application involved, which also makes the step reproducible on any machine.

It handles the subset of Markdown these docs use, the same subset md2docx.py handles: ATX
headings, paragraphs, bullet and numbered lists, fenced code blocks, pipe tables, blockquotes,
horizontal rules, and inline **bold**, *italic*, `code`, [text](url) and <https://...>.

Usage:  python md2pdf.py <in.md> <out.pdf> "<Document title>"
"""
import html
import re
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (HRFlowable, KeepTogether, ListFlowable, ListItem, PageBreak,
                                Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle)

BODY_FONT, BOLD_FONT, MONO_FONT = "Times-Roman", "Times-Bold", "Courier"

ss = getSampleStyleSheet()
S = {
    "body": ParagraphStyle("body", parent=ss["Normal"], fontName=BODY_FONT, fontSize=10,
                           leading=13.6, spaceAfter=5, alignment=TA_LEFT),
    "h1": ParagraphStyle("h1", parent=ss["Normal"], fontName=BOLD_FONT, fontSize=19, leading=23,
                         spaceBefore=0, spaceAfter=8, textColor=colors.HexColor("#111111")),
    "h2": ParagraphStyle("h2", parent=ss["Normal"], fontName=BOLD_FONT, fontSize=13.5, leading=17,
                         spaceBefore=13, spaceAfter=5, textColor=colors.HexColor("#1a1a1a")),
    "h3": ParagraphStyle("h3", parent=ss["Normal"], fontName=BOLD_FONT, fontSize=11, leading=14,
                         spaceBefore=9, spaceAfter=3),
    "code": ParagraphStyle("code", parent=ss["Normal"], fontName=MONO_FONT, fontSize=8.2,
                           leading=10.4, textColor=colors.HexColor("#222222")),
    "cell": ParagraphStyle("cell", parent=ss["Normal"], fontName=BODY_FONT, fontSize=8.6,
                           leading=11),
    "cellh": ParagraphStyle("cellh", parent=ss["Normal"], fontName=BOLD_FONT, fontSize=8.6,
                            leading=11),
    "quote": ParagraphStyle("quote", parent=ss["Normal"], fontName=BODY_FONT, fontSize=9.6,
                            leading=13, leftIndent=10, textColor=colors.HexColor("#333333")),
}

INLINE = re.compile(r"(\*\*.+?\*\*|\*[^*\n]+?\*|`[^`\n]+?`|<https?://[^>\s]+>|"
                    r"\[[^\]]+?\]\(https?://[^)\s]+\))")


def inline(text):
    """Markdown inline -> reportlab's mini-HTML. Escapes first so stray <> cannot break it."""
    out = []
    for part in INLINE.split(text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**") and len(part) > 4:
            out.append("<b>%s</b>" % html.escape(part[2:-2]))
        elif part.startswith("*") and part.endswith("*") and len(part) > 2:
            out.append("<i>%s</i>" % html.escape(part[1:-1]))
        elif part.startswith("`") and part.endswith("`") and len(part) > 2:
            out.append('<font face="%s" size="8.6">%s</font>'
                       % (MONO_FONT, html.escape(part[1:-1])))
        elif part.startswith("<http"):
            u = part[1:-1]
            out.append('<link href="%s" color="#14416b">%s</link>' % (html.escape(u), html.escape(u)))
        elif part.startswith("["):
            m = re.match(r"\[([^\]]+?)\]\((https?://[^)\s]+)\)", part)
            if m:
                out.append('<link href="%s" color="#14416b">%s</link>'
                           % (html.escape(m.group(2)), html.escape(m.group(1))))
            else:
                out.append(html.escape(part))
        else:
            out.append(html.escape(part))
    return "".join(out)


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line)]


def build(md, width):
    flow, i, lines = [], 0, md.split("\n")
    while i < len(lines):
        ln = lines[i]
        st = ln.strip()

        if not st:
            i += 1
            continue

        if st.startswith("```"):                                   # fenced code
            i += 1
            buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            body = html.escape("\n".join(buf)).replace(" ", "&nbsp;").replace("\n", "<br/>")
            t = Table([[Paragraph(body, S["code"])]], colWidths=[width])
            t.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#f4f4f4")),
                ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#d8d8d8")),
                ("LEFTPADDING", (0, 0), (-1, -1), 6), ("RIGHTPADDING", (0, 0), (-1, -1), 6),
                ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))
            flow += [Spacer(1, 4), t, Spacer(1, 6)]
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", st)                     # heading
        if m:
            lvl = min(len(m.group(1)), 3)
            flow.append(Paragraph(inline(m.group(2)), S["h%d" % lvl]))
            if lvl == 1:
                flow.append(HRFlowable(width="100%", thickness=1.1,
                                       color=colors.HexColor("#444444"), spaceAfter=7))
            i += 1
            continue

        if re.match(r"^(---+|\*\*\*+|___+)$", st):                 # rule
            flow.append(HRFlowable(width="100%", thickness=0.6,
                                   color=colors.HexColor("#cccccc"),
                                   spaceBefore=7, spaceAfter=7))
            i += 1
            continue

        if st.startswith("|") and i + 1 < len(lines) and re.match(
                r"^\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1].strip()):  # pipe table
            header = split_row(lines[i])
            i += 2
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            ncol = max([len(header)] + [len(r) for r in rows]) or 1
            def pad(r):
                return r + [""] * (ncol - len(r))
            data = [[Paragraph(inline(c), S["cellh"]) for c in pad(header)]]
            for r in rows:
                data.append([Paragraph(inline(c), S["cell"]) for c in pad(r)])
            # first column a little wider: it is the label column in every table these docs use
            if ncol == 1:
                widths = [width]
            else:
                first = width * (0.34 if ncol <= 3 else 0.26)
                widths = [first] + [(width - first) / (ncol - 1)] * (ncol - 1)
            t = Table(data, colWidths=widths, repeatRows=1)
            t.setStyle(TableStyle([
                ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#b4b4b4")),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#ececec")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 4), ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3)]))
            flow += [Spacer(1, 4), t, Spacer(1, 7)]
            continue

        if st.startswith(">"):                                     # blockquote
            buf = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                buf.append(lines[i].strip().lstrip(">").strip())
                i += 1
            flow.append(Paragraph(inline(" ".join(buf)), S["quote"]))
            continue

        if re.match(r"^[-*+]\s+", st) or re.match(r"^\d+[.)]\s+", st):   # list
            items, ordered = [], bool(re.match(r"^\d+[.)]\s+", st))
            while i < len(lines):
                raw = lines[i]
                s2 = raw.strip()
                if not s2:
                    break
                m2 = re.match(r"^([-*+]|\d+[.)])\s+(.*)$", s2)
                if not m2:
                    if items and raw.startswith(("  ", "\t")):       # continuation line
                        items[-1] = items[-1] + " " + s2
                        i += 1
                        continue
                    break
                items.append(m2.group(2))
                i += 1
            flow.append(ListFlowable(
                [ListItem(Paragraph(inline(x), S["body"]), leftIndent=14) for x in items],
                bulletType="1" if ordered else "bullet", start="1" if ordered else None,
                bulletFontName=BODY_FONT, bulletFontSize=9, leftIndent=14, spaceAfter=5))
            continue

        buf = []                                                   # paragraph
        while i < len(lines) and lines[i].strip() and not re.match(
                r"^(#{1,6}\s|\||```|>|[-*+]\s|\d+[.)]\s|---+$)", lines[i].strip()):
            buf.append(lines[i].strip())
            i += 1
        if buf:
            flow.append(Paragraph(inline(" ".join(buf)), S["body"]))
        else:
            i += 1
    return flow


def main(src, dst, title):
    md = open(src, encoding="utf-8").read().replace("\r\n", "\n")
    doc = SimpleDocTemplate(dst, pagesize=LETTER, title=title, author="Serpentine",
                            leftMargin=18 * mm, rightMargin=18 * mm,
                            topMargin=17 * mm, bottomMargin=17 * mm)
    width = LETTER[0] - 36 * mm

    def footer(canvas, d):
        canvas.saveState()
        canvas.setFont(BODY_FONT, 8)
        canvas.setFillColor(colors.HexColor("#666666"))
        canvas.drawCentredString(LETTER[0] / 2.0, 10 * mm, str(canvas.getPageNumber()))
        canvas.restoreState()

    doc.build(build(md, width), onFirstPage=footer, onLaterPages=footer)
    import os
    print("wrote %s (%d bytes)" % (dst, os.path.getsize(dst)))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
