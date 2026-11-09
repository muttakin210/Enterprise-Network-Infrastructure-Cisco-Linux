"""Render docs/guide/guide.html to docs/ENL-Lab-Complete-Guide.pdf with headless Chromium (Playwright).

    python docs/guide/build_pdf.py
"""
from pathlib import Path
from playwright.sync_api import sync_playwright

here = Path(__file__).resolve().parent
src = here / "guide.html"
out = here.parent / "ENL-Lab-Complete-Guide.pdf"

footer = ('<div style="font-size:8px;color:#888;width:100%;padding:0 15mm;display:flex;justify-content:space-between">'
          '<span>Enterprise Network Infrastructure with Cisco &amp; Linux: Complete Guide</span>'
          '<span>Page <span class="pageNumber"></span> / <span class="totalPages"></span></span></div>')

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto(src.as_uri(), wait_until="networkidle")
    broken = page.evaluate("[...document.images].filter(i => !i.complete || i.naturalWidth === 0).map(i => i.src)")
    if broken:
        raise SystemExit(f"missing images: {broken}")
    page.pdf(path=str(out), format="A4", print_background=True, display_header_footer=True,
             header_template="<span></span>", footer_template=footer,
             margin={"top": "16mm", "bottom": "18mm", "left": "15mm", "right": "15mm"})
    browser.close()
print(f"wrote {out}")
