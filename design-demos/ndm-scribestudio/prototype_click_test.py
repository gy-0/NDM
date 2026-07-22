from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).parent
CASES = [
    ("direction-01-dark-editorial.html", ".ndm-window", ".scribe-window", "#handoff"),
    ("direction-02-play-native.html", ".ndm", ".scribe", ".handoff"),
    ("direction-03-braun-system.html", ".ndm", ".scribe", "#bridgeButton"),
]


def visible(page, selector):
    return page.locator(selector).evaluate(
        "(node) => getComputedStyle(node).display !== 'none'"
    )


with sync_playwright() as playwright:
    browser = playwright.chromium.launch()
    for filename, ndm, scribe, handoff in CASES:
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on(
            "console",
            lambda message: errors.append(message.text)
            if message.type == "error"
            else None,
        )
        page.goto((ROOT / filename).as_uri())

        page.locator("button[data-mode='ndm']").click()
        assert visible(page, ndm)
        assert not visible(page, scribe)

        page.locator("button[data-mode='scribe']").click()
        assert visible(page, scribe)
        assert not visible(page, ndm)

        page.locator("button[data-mode='both']").click()
        assert visible(page, ndm)
        assert visible(page, scribe)
        page.locator(handoff).click()

        assert errors == [], f"{filename}: {errors}"
        print(f"PASS {filename}: NDM / ScribeStudio / 联动")
        page.close()
    browser.close()
