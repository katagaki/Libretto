"""Writes the sample documents the App Store screenshots open.

Usage: python3 samples.py <iPhone|iPad> <en|ja>

Prints the directory it wrote the documents to.

The Word documents are put together part by part, as Word lays them out, so
they need nothing beyond the standard library. Everything is set in Kivotos.
"""
import os, sys, tempfile, zipfile
from xml.sax.saxutils import escape

# Device and language are picked from fixed lists rather than taken as given,
# and the documents go into a fresh private directory of the script's own
# making, whose path it prints for capture.sh to copy from and remove.
def choose(value, options):
    for option in options:
        if option == value:
            return option
    sys.exit(__doc__)


if len(sys.argv) != 3:
    sys.exit(__doc__)
DEVICE = choose(sys.argv[1], ("iPhone", "iPad"))
LANG = choose(sys.argv[2], ("en", "ja"))
OUT = tempfile.mkdtemp(prefix=f"libretto-samples-{DEVICE}-{LANG}-")
JA = LANG == "ja"


def t(en, ja):
    return ja if JA else en


# MARK: - Package

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
M = "http://schemas.openxmlformats.org/officeDocument/2006/math"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
CT = "application/vnd.openxmlformats-officedocument.wordprocessingml."
NAMESPACES = f'xmlns:w="{W}" xmlns:r="{R}" xmlns:m="{M}"'
HEAD = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'

# Headings in a face with some presence; the body in a book face.
HEADING_FONT = t("Avenir Next", "Hiragino Sans")
BODY_FONT = t("Georgia", "Hiragino Mincho ProN")
ACCENT = "1F4E79"
DATE = "2026-10-04T09:15:00Z"


def save(name, body, comments=None, footnotes=None, header=None, footer=None, tracking=False):
    """Writes a document from its body and whichever parts it has."""
    parts = {
        "word/styles.xml": STYLES,
        "word/numbering.xml": NUMBERING,
        "word/settings.xml": HEAD + f'<w:settings {NAMESPACES}>'
        + ("<w:trackRevisions/>" if tracking else "") + '<w:defaultTabStop w:val="720"/></w:settings>',
    }
    rels = [("styles", "styles.xml"), ("numbering", "numbering.xml"), ("settings", "settings.xml")]
    types = {"styles.xml": "styles", "numbering.xml": "numbering", "settings.xml": "settings"}
    section = ""
    if header:
        parts["word/header1.xml"] = HEAD + f"<w:hdr {NAMESPACES}>{header}</w:hdr>"
        rels.append(("header", "header1.xml"))
        types["header1.xml"] = "header"
        section += f'<w:headerReference w:type="default" r:id="rId{len(rels)}"/>'
    if footer:
        parts["word/footer1.xml"] = HEAD + f"<w:ftr {NAMESPACES}>{footer}</w:ftr>"
        rels.append(("footer", "footer1.xml"))
        types["footer1.xml"] = "footer"
        section += f'<w:footerReference w:type="default" r:id="rId{len(rels)}"/>'
    if comments:
        parts["word/comments.xml"] = HEAD + f"<w:comments {NAMESPACES}>{comments}</w:comments>"
        rels.append(("comments", "comments.xml"))
        types["comments.xml"] = "comments"
    if footnotes:
        separators = ('<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>'
                      '<w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/>'
                      '</w:r></w:p></w:footnote>')
        parts["word/footnotes.xml"] = HEAD + f"<w:footnotes {NAMESPACES}>{separators}{footnotes}</w:footnotes>"
        rels.append(("footnotes", "footnotes.xml"))
        types["footnotes.xml"] = "footnotes"

    # A4, with Word's usual margins.
    section = (f'<w:sectPr>{section}<w:pgSz w:w="11906" w:h="16838"/>'
               '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
               'w:header="708" w:footer="708" w:gutter="0"/><w:cols w:space="708"/></w:sectPr>')
    parts["word/document.xml"] = HEAD + f"<w:document {NAMESPACES}><w:body>{body}{section}</w:body></w:document>"
    parts["word/_rels/document.xml.rels"] = HEAD + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        + "".join(f'<Relationship Id="rId{i}" Type="{REL}{kind}" Target="{target}"/>'
                  for i, (kind, target) in enumerate(rels, start=1))
        + "</Relationships>")
    parts["_rels/.rels"] = HEAD + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        f'<Relationship Id="rId1" Type="{REL}officeDocument" Target="word/document.xml"/></Relationships>')
    parts["[Content_Types].xml"] = HEAD + (
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        f'<Override PartName="/word/document.xml" ContentType="{CT}document.main+xml"/>'
        + "".join(f'<Override PartName="/word/{part}" ContentType="{CT}{kind}+xml"/>' for part, kind in types.items())
        + "</Types>")

    with zipfile.ZipFile(os.path.join(OUT, name), "w", zipfile.ZIP_DEFLATED) as package:
        # The content types go first, as Word writes them.
        for part in ["[Content_Types].xml"] + [p for p in parts if p != "[Content_Types].xml"]:
            package.writestr(part, parts[part])


# MARK: - Styles

def style(kind, id, name, ppr="", rpr="", based="Normal", extra=""):
    based_on = f'<w:basedOn w:val="{based}"/>' if based else ""
    return (f'<w:style w:type="{kind}" w:styleId="{id}"><w:name w:val="{name}"/>{based_on}<w:qFormat/>{extra}'
            + (f"<w:pPr>{ppr}</w:pPr>" if ppr else "") + (f"<w:rPr>{rpr}</w:rPr>" if rpr else "") + "</w:style>")


def fonts(name):
    return f'<w:rFonts w:ascii="{name}" w:hAnsi="{name}" w:eastAsia="{name}" w:cs="{name}"/>'


def heading(level, size, before, color):
    return style("paragraph", f"Heading{level}", f"heading {level}",
                 f'<w:keepNext/><w:keepLines/><w:spacing w:before="{before}" w:after="100"/>'
                 f'<w:outlineLvl w:val="{level - 1}"/>',
                 f'{fonts(HEADING_FONT)}<w:b/><w:color w:val="{color}"/><w:sz w:val="{size}"/>',
                 extra='<w:next w:val="Normal"/>')


def borders(color, inside=True):
    sides = ["top", "left", "bottom", "right"] + (["insideH", "insideV"] if inside else [])
    return "<w:tblBorders>" + "".join(
        f'<w:{side} w:val="single" w:sz="4" w:space="0" w:color="{color}"/>' for side in sides) + "</w:tblBorders>"


STYLES = HEAD + (
    f'<w:styles {NAMESPACES}><w:docDefaults><w:rPrDefault><w:rPr>{fonts(BODY_FONT)}'
    '<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-GB" w:eastAsia="ja-JP"/></w:rPr></w:rPrDefault>'
    '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="288" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
    "</w:docDefaults>"
    '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
    + style("paragraph", "Title", "Title", '<w:spacing w:after="60" w:line="240" w:lineRule="auto"/>',
            f'{fonts(HEADING_FONT)}<w:b/><w:color w:val="{ACCENT}"/><w:sz w:val="56"/>', extra='<w:next w:val="Normal"/>')
    + style("paragraph", "Subtitle", "Subtitle", '<w:spacing w:after="320"/>'
            '<w:pBdr><w:bottom w:val="single" w:sz="8" w:space="8" w:color="2E75B6"/></w:pBdr>',
            f'{fonts(HEADING_FONT)}<w:color w:val="595959"/><w:sz w:val="26"/>', extra='<w:next w:val="Normal"/>')
    + heading(1, 32, 360, ACCENT)
    + heading(2, 26, 240, "2E75B6")
    + style("paragraph", "Quote", "Quote", '<w:spacing w:before="240" w:after="240"/><w:ind w:left="720" w:right="720"/>'
            '<w:jc w:val="center"/>', '<w:i/><w:color w:val="2E75B6"/><w:sz w:val="24"/>')
    + style("paragraph", "ListParagraph", "List Paragraph", '<w:spacing w:after="80"/><w:ind w:left="720"/>')
    + style("paragraph", "Caption", "caption", '<w:spacing w:before="80" w:after="240"/>',
            f'{fonts(HEADING_FONT)}<w:i/><w:color w:val="595959"/><w:sz w:val="18"/>')
    + style("paragraph", "Header", "header", '<w:spacing w:after="0"/>',
            f'{fonts(HEADING_FONT)}<w:color w:val="7F7F7F"/><w:sz w:val="17"/>')
    + style("paragraph", "Footer", "footer", '<w:spacing w:after="0"/><w:jc w:val="center"/>',
            f'{fonts(HEADING_FONT)}<w:color w:val="7F7F7F"/><w:sz w:val="17"/>')
    + style("paragraph", "FootnoteText", "footnote text", '<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>',
            '<w:sz w:val="18"/>')
    + style("character", "FootnoteReference", "footnote reference", rpr='<w:vertAlign w:val="superscript"/>',
            based=None)
    + style("character", "Hyperlink", "Hyperlink", rpr='<w:color w:val="0563C1"/><w:u w:val="single"/>', based=None)
    + '<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>'
    '<w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>'
    '<w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/>'
    "</w:tblCellMar></w:tblPr></w:style>"
    # Word's Grid Table 4 Accent 1, in the document's blue.
    '<w:style w:type="table" w:styleId="GridTable4-Accent1"><w:name w:val="Grid Table 4 Accent 1"/>'
    '<w:basedOn w:val="TableNormal"/><w:pPr><w:spacing w:before="40" w:after="40" w:line="240" w:lineRule="auto"/>'
    f'</w:pPr><w:rPr>{fonts(HEADING_FONT)}<w:sz w:val="20"/></w:rPr><w:tblPr><w:tblStyleRowBandSize w:val="1"/>'
    f'<w:tblStyleColBandSize w:val="1"/>{borders("9DC3E6")}</w:tblPr>'
    '<w:tblStylePr w:type="firstRow"><w:rPr><w:b/><w:color w:val="FFFFFF"/></w:rPr><w:tblPr/>'
    f'<w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="{ACCENT}"/></w:tcPr></w:tblStylePr>'
    '<w:tblStylePr w:type="lastRow"><w:rPr><w:b/></w:rPr><w:tblPr/><w:tcPr><w:tcBorders>'
    f'<w:top w:val="double" w:sz="4" w:space="0" w:color="{ACCENT}"/></w:tcBorders></w:tcPr></w:tblStylePr>'
    '<w:tblStylePr w:type="firstCol"><w:rPr><w:b/></w:rPr></w:tblStylePr>'
    '<w:tblStylePr w:type="band1Horz"><w:tblPr/><w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="DEEBF7"/>'
    "</w:tcPr></w:tblStylePr></w:style>"
    "</w:styles>")

NUMBERING = HEAD + (
    f"<w:numbering {NAMESPACES}>"
    '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/>'
    '<w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>'
    '<w:rPr><w:color w:val="2E75B6"/></w:rPr></w:lvl></w:abstractNum>'
    '<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>'
    '<w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>'
    '<w:rPr><w:b/><w:color w:val="1F4E79"/></w:rPr></w:lvl></w:abstractNum>'
    '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
    '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>'
    "</w:numbering>")


# MARK: - Content

def r(text, b=False, i=False, color=None, highlight=None, style=None, size=None):
    """A run of text with the formatting given."""
    props = ""
    if style:
        props += f'<w:rStyle w:val="{style}"/>'
    if b:
        props += "<w:b/>"
    if i:
        props += "<w:i/>"
    if color:
        props += f'<w:color w:val="{color}"/>'
    if size:
        props += f'<w:sz w:val="{size}"/>'
    if highlight:
        props += f'<w:highlight w:val="{highlight}"/>'
    rpr = f"<w:rPr>{props}</w:rPr>" if props else ""
    return f'<w:r>{rpr}<w:t xml:space="preserve">{escape(text)}</w:t></w:r>'


def p(*runs, style=None, num=None, jc=None, keep=False):
    """A paragraph of runs; plain strings are runs without formatting."""
    props = ""
    if style:
        props += f'<w:pStyle w:val="{style}"/>'
    if keep:
        props += "<w:keepNext/>"
    if num:
        props += f'<w:numPr><w:ilvl w:val="0"/><w:numId w:val="{num}"/></w:numPr>'
    if jc:
        props += f'<w:jc w:val="{jc}"/>'
    content = "".join(run if run.startswith("<") else r(run) for run in runs)
    return f"<w:p>{f'<w:pPr>{props}</w:pPr>' if props else ''}{content}</w:p>"


def field(instruction, shown):
    return (f'<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> {instruction} '
            f'</w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>{r(shown)}'
            '<w:r><w:fldChar w:fldCharType="end"/></w:r>')


def footnote_reference(id):
    return f'<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="{id}"/></w:r>'


def footnote(id, text):
    return (f'<w:footnote w:id="{id}"><w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>'
            f'<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>{r(" " + text)}</w:p>'
            "</w:footnote>")


def table(rows, widths, right_from=1, last_row=False):
    """A table in the document's style, its first row a header, numbers to the right."""
    look = (f'<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="{1 if last_row else 0}" w:firstColumn="1" '
            'w:lastColumn="0" w:noHBand="0" w:noVBand="1"/>')
    grid = "".join(f'<w:gridCol w:w="{w}"/>' for w in widths)
    body = ""
    for row in rows:
        cells = ""
        for c, (text, w) in enumerate(zip(row, widths)):
            jc = '<w:jc w:val="right"/>' if c >= right_from else ""
            cells += (f'<w:tc><w:tcPr><w:tcW w:w="{w}" w:type="dxa"/></w:tcPr>'
                      f"<w:p><w:pPr>{jc}</w:pPr>{r(text)}</w:p></w:tc>")
        body += f"<w:tr>{cells}</w:tr>"
    return (f'<w:tbl><w:tblPr><w:tblStyle w:val="GridTable4-Accent1"/><w:tblW w:w="{sum(widths)}" w:type="dxa"/>'
            f"{look}</w:tblPr><w:tblGrid>{grid}</w:tblGrid>{body}</w:tbl>")


# MARK: - Schale activity report

def report():
    body = (
        p(t("Schale Activity Report", "シャーレ活動報告書"), style="Title")
        + p(t("October 2026  ·  Prepared by Arona for Sensei", "2026年10月　作成：アロナ（先生へ）"), style="Subtitle")
        + p(t("Summary", "概要"), style="Heading1")
        + p(t("October was a busy month across Kivotos. Schale answered ", "10月はキヴォトス全体で忙しい月でした。シャーレは9つの学園から"),
            r(t("42 requests", "42件の依頼"), b=True),
            t(" from nine schools, helped the Foreclosure Task Force make its ",
              "に対応し、対策委員会の"),
            r(t("largest repayment yet", "過去最大の返済"), i=True),
            t(", and kept the Joint Festival on schedule.", "を手伝い、合同祭の準備も予定どおりに進めました。"),
            footnote_reference(1))
        + p(t("Highlights", "主なできごと"), style="Heading2")
        + p(t("Abydos paid ", "アビドスがカイザーローンに"), r(t("788,000 credits", "788,000クレジット"), b=True),
            t(" towards the Kaiser Loan.", "を返済しました。"), style="ListParagraph", num=1)
        + p(t("The Game Development Department shipped a ", "ゲーム開発部が新作ゲームの"),
            r(t("playable demo", "体験版"), highlight="yellow"),
            t(" of their new game.", "を公開しました。"), style="ListParagraph", num=1)
        + p(t("The Prefect Team and the Justice Task Force patrolled the festival grounds together.",
              "風紀委員会と正義実現委員会が合同で会場を巡回しました。"), style="ListParagraph", num=1)
        + p(t("Requests by school", "学園別の依頼件数"), style="Heading1", keep=True)
        + table([
            [t("School", "学園"), t("Requests", "依頼"), t("Resolved", "解決"), t("Rate", "解決率")],
            [t("Abydos", "アビドス"), "9", "9", "100%"],
            [t("Millennium", "ミレニアム"), "11", "10", "91%"],
            [t("Gehenna", "ゲヘナ"), "8", "6", "75%"],
            [t("Trinity", "トリニティ"), "7", "7", "100%"],
            [t("Hyakkiyako", "百鬼夜行"), "4", "3", "75%"],
            [t("Other schools", "その他"), "3", "3", "100%"],
            [t("Total", "合計"), "42", "38", "90%"],
        ], [3226, 1900, 1900, 1900], last_row=True)
        + p(t("Table 1. Requests that reached Schale in October.", "表1　10月にシャーレに届いた依頼"), style="Caption")
        + p(t("Next month", "来月の予定"), style="Heading1")
        + p(t("In November, Schale will focus on the opening of the Joint Festival on ",
              "11月は、"),
            r(t("14 November", "11月14日"), b=True),
            t(". Sensei is asked to approve the fireworks permit before the end of the month, so that Problem Solver 68 "
              "can begin setting up.",
              "の合同祭の開幕に向けた準備に力を入れます。便利屋68が設営を始められるよう、先生には月末までに花火の許可をお願いします。"))
        + p(t("“Sensei, please remember to get some sleep, too!” — Arona",
              "「先生、ちゃんと寝てくださいね！」――アロナ"), style="Quote")
        + p(t("Paperwork", "書類"), style="Heading2")
        + p(t("Activity reports for September have been filed for every club. Reports for October are due on ",
              "9月分の活動報告書はすべての部活から提出されました。10月分の締め切りは"),
            r(t("31 October", "10月31日"), b=True),
            t(", and Yuuka has offered to check the Seminar's figures before they are sent.",
              "です。セミナーの数字は、送る前にユウカが確認してくれることになっています。"))
    )
    header = p(t("Schale  ·  Federal Investigation Club", "シャーレ　連邦捜査部"), style="Header", jc="right")
    footer = p(field("PAGE", "1"), style="Footer")
    notes = footnote(1, t("Requests are counted when they reach Schale, not when they are resolved.",
                          "依頼は解決した時点ではなく、シャーレに届いた時点で数えています。"))
    save(t("Schale Activity Report.docx", "シャーレ活動報告書.docx"), body, footnotes=notes, header=header, footer=footer)


# MARK: - Joint festival proposal

class Changes:
    """Hands out ids to tracked changes and comments."""
    def __init__(self):
        self.next_id = 1
        self.comments = ""

    def change(self, kind, author, text, day):
        id = self.next_id
        self.next_id += 1
        tag = "w:delText" if kind == "del" else "w:t"
        return (f'<w:{kind} w:id="{id}" w:author="{author}" w:date="2026-10-0{day}T10:00:00Z">'
                f'<w:r><{tag} xml:space="preserve">{escape(text)}</{tag}></w:r></w:{kind}>')

    def ins(self, author, text, day):
        return self.change("ins", author, text, day)

    def delete(self, author, text, day):
        return self.change("del", author, text, day)

    def comment(self, author, initials, note, day, *runs):
        id = self.next_id
        self.next_id += 1
        self.comments += (f'<w:comment w:id="{id}" w:author="{author}" w:date="2026-10-0{day}T11:00:00Z" '
                          f'w:initials="{initials}"><w:p>{r(note)}</w:p></w:comment>')
        content = "".join(run if run.startswith("<") else r(run) for run in runs)
        return (f'<w:commentRangeStart w:id="{id}"/>{content}<w:commentRangeEnd w:id="{id}"/>'
                f'<w:r><w:commentReference w:id="{id}"/></w:r>')


YUUKA = t("Yuuka", "ユウカ")
HINA = t("Hina", "ヒナ")
NAGISA = t("Nagisa", "ナギサ")
FUUKA = t("Fuuka", "フウカ")


def proposal():
    c = Changes()
    body = (
        p(t("Kivotos Joint Festival", "キヴォトス合同祭"), style="Title")
        + p(t("Proposal for the General Student Council  ·  Draft 3", "連邦生徒会への企画書　第3稿"), style="Subtitle")
        + p(t("Purpose", "目的"), style="Heading1")
        + p(t("The Joint Festival brings every school in Kivotos together for ",
              "合同祭は、キヴォトスのすべての学園が中央広場に集まり、"),
            c.delete(YUUKA, t("two days", "2日間"), 3),
            c.comment(YUUKA, "Y", t("Three days means a bigger budget. Please send me the new figures by Friday.",
                                    "3日間にするなら予算も増えます。金曜日までに新しい数字を送ってください。"), 3,
                      c.ins(YUUKA, t("three days", "3日間"), 3)),
            t(" of food, games and music in the main square. Every school is invited to run a stall or a booth, "
              "and Schale will look after the schedule.",
              "、食べ物やゲーム、音楽を楽しむお祭りです。各学園には屋台やブースの出店をお願いし、日程はシャーレが管理します。"))
        + p(t("Programme", "プログラム"), style="Heading1")
        + p(t("Opening ceremony, with fireworks by Problem Solver 68", "便利屋68の花火による開会式"),
            c.ins(HINA, t(", once the permit is granted", "（許可が下りしだい）"), 4),
            style="ListParagraph", num=2)
        + p(c.comment(FUUKA, "F", t("Please keep the Gourmet Research Society out of the kitchen this time.",
                                    "今回は美食研究会を厨房に入れないでください。"), 5,
                      t("Food stalls run by the School Lunch Club", "給食部による屋台")),
            style="ListParagraph", num=2)
        + p(t("A game booth from the Game Development Department", "ゲーム開発部のゲームブース"),
            style="ListParagraph", num=2)
        + p(t("A tea party hosted by Trinity", "トリニティ主催のお茶会"),
            c.delete(NAGISA, t(" on the last evening", "（最終日の夜）"), 5),
            style="ListParagraph", num=2)
        + p(t("Budget", "予算"), style="Heading1")
        + p(t("The festival will cost ", "開催費用は"),
            c.delete(YUUKA, t("1,200,000", "1,200,000"), 3),
            c.ins(YUUKA, t("1,650,000", "1,650,000"), 3),
            t(" credits, ", "クレジットで、"),
            c.comment(NAGISA, "N", t("Trinity is happy to cover the tea party on its own.",
                                     "お茶会の費用はトリニティが負担します。"), 5,
                      t("shared between the schools by the number of students taking part",
                        "参加する生徒の人数に応じて各学園で分担します")),
            t(". The Seminar will keep the accounts and report to Schale each week.",
              "。会計はセミナーが担当し、毎週シャーレに報告します。"))
        + p(t("Safety", "安全対策"), style="Heading1")
        + p(t("The Prefect Team and the Justice Task Force will share patrols, with the Remedial Knights on hand "
              "for first aid. ", "風紀委員会と正義実現委員会が合同で巡回し、救護騎士団が救護を担当します。"),
            c.ins(HINA, t("No one is to bring explosives onto the festival grounds.", "会場への爆発物の持ち込みは禁止します。"), 4))
    )
    save(t("Festival Proposal.docx", "合同祭企画書.docx"), body, comments=c.comments, tracking=True)


# MARK: - Railgun notes

def math_run(text, plain=False):
    # Set larger than the text around it, so the equations read even with the page fitted to a phone.
    style = ('<m:rPr><m:sty m:val="p"/></m:rPr>' if plain else "") + '<w:rPr><w:sz w:val="36"/></w:rPr>'
    return f"<m:r>{style}<m:t>{escape(text)}</m:t></m:r>"


def frac(num, den):
    return f"<m:f><m:num>{num}</m:num><m:den>{den}</m:den></m:f>"


def sup(base, power):
    return f"<m:sSup><m:e>{base}</m:e><m:sup>{power}</m:sup></m:sSup>"


def sub(base, index):
    return f"<m:sSub><m:e>{base}</m:e><m:sub>{index}</m:sub></m:sSub>"


def subsup(base, index, power):
    return f"<m:sSubSup><m:e>{base}</m:e><m:sub>{index}</m:sub><m:sup>{power}</m:sup></m:sSubSup>"


def sqrt(inner):
    return f'<m:rad><m:radPr><m:degHide m:val="1"/></m:radPr><m:deg/><m:e>{inner}</m:e></m:rad>'


def nary(char, low, high, inner):
    return (f'<m:nary><m:naryPr><m:chr m:val="{char}"/></m:naryPr><m:sub>{low}</m:sub><m:sup>{high}</m:sup>'
            f"<m:e>{inner}</m:e></m:nary>")


def equation(*parts):
    return f'<w:p><w:pPr><w:jc w:val="center"/></w:pPr><m:oMathPara><m:oMath>{"".join(parts)}</m:oMath></m:oMathPara></w:p>'


def notes():
    v2 = sup(math_run("v"), math_run("2"))
    body = (
        p(t("Railgun Calibration Notes", "レールガン調整ノート"), style="Title")
        + p(t("Engineering Department  ·  Utaha, Hibiki and Kotori", "エンジニア部　ウタハ・ヒビキ・コトリ"), style="Subtitle")
        + p(t("Energy at the muzzle", "砲口でのエネルギー"), style="Heading1")
        + p(t("A slug of mass m leaving the rails at speed v carries the kinetic energy",
              "質量 m の弾体が速さ v でレールを離れるとき、その運動エネルギーは"))
        + equation(sub(math_run("E"), math_run("k", plain=True)), math_run("="), frac(math_run("1"), math_run("2")),
                   math_run("m"), v2)
        + p(t("so the speed we can expect from the energy the capacitors deliver is",
              "となる。したがって、コンデンサが供給するエネルギーから期待できる速さは"))
        + equation(math_run("v"), math_run("="), sqrt(frac(math_run("2") + sub(math_run("E"), math_run("k", plain=True)),
                                                           math_run("m"))))
        + p(t("Losses", "損失"), style="Heading1")
        + p(t("Over a run of n shots, the energy lost to heat in the rails adds up as",
              "n 発撃ったときにレールで熱として失われるエネルギーの合計は"))
        + equation(sub(math_run("E"), math_run("loss", plain=True)), math_run("="),
                   nary("∑", math_run("i=1"), math_run("n"),
                        subsup(math_run("I"), math_run("i"), math_run("2")) + math_run("R") + sub(math_run("t"), math_run("i"))))
        + p(t("Trials", "試射の結果"), style="Heading1", keep=True)
        + table([
            [t("Trial", "試射"), t("Charge (kJ)", "充電 (kJ)"), t("Speed (m/s)", "速度 (m/s)"), t("Rail temp. (°C)", "レール温度 (°C)")],
            ["1", "120", "1,940", "86"],
            ["2", "150", "2,170", "104"],
            ["3", "180", "2,360", "131"],
            ["4", "210", "2,510", "167"],
        ], [1600, 2475, 2475, 2476])
        + p(t("Table 1. Trials in the Millennium test range, 2 October.", "表1　10月2日、ミレニアム試験場での試射"),
            style="Caption")
        + p(t("Trial 4 came within 3% of the speed the formula predicts. The rails need cooling before a fifth shot; "
              "Hibiki is designing a water jacket for them.",
              "試射4の速度は、式による予測との差が3%以内だった。5発目の前にはレールの冷却が必要なため、ヒビキが水冷ジャケットを設計中。"))
    )
    save(t("Railgun Notes.docx", "レールガン調整ノート.docx"), body)


# MARK: - Source code

def code():
    comment = lambda en, ja: "// " + t(en, ja)
    # Lines are kept short enough to fit across an iPhone without running off the edge.
    source = f"""import Foundation

{comment("A party member in the new game.", "新作ゲームのパーティーメンバー。")}
struct Member {{
    let name: String
    var health: Int
    var attack: Int
    var isGuarding = false

    var isDown: Bool {{ health <= 0 }}
}}

enum Action {{
    case attack(target: Int)
    case defend
    case skill(String)
}}

final class Battle {{
    private(set) var party: [Member]
    private(set) var turn = 1

    init(party: [Member]) {{
        self.party = party
    }}

    {comment("Guarding halves the damage.", "防御中はダメージが半分。")}
    func damage(to target: Member,
                by user: Member) -> Int {{
        let base = user.attack * 3 / 2
        return target.isGuarding
            ? base / 2 : base
    }}

    func perform(_ action: Action,
                 by index: Int) {{
        let name = party[index].name
        switch action {{
        case .attack(let target):
            let hit = damage(
                to: party[target],
                by: party[index])
            party[target].health -= hit
            print("\\(name): \\(hit)!")
        case .defend:
            party[index].isGuarding = true
        case .skill(let skill):
            print("\\(name) {t("uses", "の")} \\(skill)!")
        }}
        turn += 1
    }}
}}

let battle = Battle(party: [
    Member(name: "{t("Aris", "アリス")}", health: 120, attack: 42),
    Member(name: "{t("Momoi", "モモイ")}", health: 90, attack: 30),
    Member(name: "{t("Midori", "ミドリ")}", health: 95, attack: 28),
    Member(name: "{t("Yuzu", "ユズ")}", health: 80, attack: 25),
])
battle.perform(.skill("{t("Light of Salvation", "光よ！")}"), by: 0)
"""
    with open(os.path.join(OUT, "Battle.swift"), "w", encoding="utf-8") as f:
        f.write(source)


# MARK: - Markdown

def markdown():
    with open(os.path.join(OUT, t("Club Notes.md", "部活メモ.md")), "w", encoding="utf-8") as f:
        f.write(t("""# Club notes

## Game Development Department

- Finish the **demo** for the festival
- Ask Yuuka about the *budget* again
""", """# 部活メモ

## ゲーム開発部

- 合同祭までに**体験版**を完成させる
- *予算*についてユウカにもう一度相談する
"""))


report()
proposal()
notes()
code()
markdown()
print(OUT)
