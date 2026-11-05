#!/bin/bash
set -euo pipefail

# Generates assets/prisma_og.png (1200x630) for Open Graph / Twitter / Telegram / LinkedIn
# and keeps web/assets/prisma_og.png in sync.

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

CHROME_BIN=""
if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
elif which google-chrome >/dev/null 2>&1; then
  CHROME_BIN="$(which google-chrome)"
elif which chromium >/dev/null 2>&1; then
  CHROME_BIN="$(which chromium)"
fi

if [ -z "$CHROME_BIN" ]; then
  echo "Error: Google Chrome or Chromium is required to generate the card." >&2
  exit 1
fi

ALTENWALD_B64=$(base64 -i "${REPO_ROOT}/web/assets/altenwald_logo_white.png" | tr -d '\n')
PRISMA_B64=$(base64 -i "${REPO_ROOT}/assets/prisma.png" | tr -d '\n')

TMP_HTML=$(mktemp /tmp/prisma_og_card_XXXXXX.html)
TMP_PNG=$(mktemp /tmp/prisma_og_raw_XXXXXX.png)
trap 'rm -f "$TMP_HTML" "$TMP_PNG"' EXIT

cat << HTML_EOF > "$TMP_HTML"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  @import url('https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@500;700&display=swap');

  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    width: 1200px;
    height: 630px;
    overflow: hidden;
    background: #090d16;
    font-family: 'Plus Jakarta Sans', -apple-system, sans-serif;
    color: #ffffff;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .canvas {
    position: relative;
    width: 1200px;
    height: 630px;
    background: radial-gradient(circle at 85% 50%, rgba(37, 99, 235, 0.28) 0%, rgba(15, 23, 42, 0.8) 50%, #090d16 100%),
                linear-gradient(135deg, #090d16 0%, #0c1322 50%, #111c33 100%);
    border: 1px solid rgba(255, 255, 255, 0.08);
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    padding: 60px 70px;
  }

  .grid-overlay {
    position: absolute;
    inset: 0;
    background-image: 
      linear-gradient(to right, rgba(255, 255, 255, 0.02) 1px, transparent 1px),
      linear-gradient(to bottom, rgba(255, 255, 255, 0.02) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
  }

  .glow-orb {
    position: absolute;
    right: 80px;
    top: 50%;
    transform: translateY(-50%);
    width: 480px;
    height: 480px;
    background: radial-gradient(circle, rgba(56, 189, 248, 0.18) 0%, rgba(37, 99, 235, 0.22) 40%, transparent 70%);
    filter: blur(40px);
    pointer-events: none;
  }

  .header {
    display: flex;
    align-items: center;
    gap: 16px;
    z-index: 10;
  }

  .altenwald-logo {
    height: 32px;
    width: auto;
    object-fit: contain;
  }

  .divider {
    width: 1px;
    height: 20px;
    background: rgba(255, 255, 255, 0.2);
  }

  .tag-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    background: rgba(37, 99, 235, 0.15);
    border: 1px solid rgba(56, 189, 248, 0.35);
    border-radius: 9999px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 13px;
    font-weight: 600;
    color: #38bdf8;
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }

  .main-content {
    display: flex;
    align-items: center;
    justify-content: space-between;
    z-index: 10;
    margin-top: 10px;
  }

  .text-column {
    max-width: 650px;
  }

  .title-row {
    display: flex;
    align-items: baseline;
    gap: 16px;
  }

  .title {
    font-size: 82px;
    font-weight: 800;
    letter-spacing: -2px;
    line-height: 1;
    background: linear-gradient(135deg, #ffffff 40%, #93c5fd 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
  }

  .version-tag {
    font-family: 'JetBrains Mono', monospace;
    font-size: 16px;
    font-weight: 600;
    color: #f5962a;
    background: rgba(245, 150, 42, 0.12);
    border: 1px solid rgba(245, 150, 42, 0.3);
    padding: 4px 10px;
    border-radius: 6px;
  }

  .subtitle {
    font-size: 26px;
    font-weight: 600;
    color: #cbd5e1;
    margin-top: 14px;
    line-height: 1.3;
    letter-spacing: -0.3px;
  }

  .description {
    font-size: 17px;
    font-weight: 400;
    color: #94a3b8;
    margin-top: 10px;
    line-height: 1.5;
  }

  .metrics-grid {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 12px;
    margin-top: 28px;
  }

  .metric-card {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    backdrop-filter: blur(10px);
    border-radius: 12px;
    padding: 10px 16px;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .metric-card .icon {
    font-size: 18px;
  }

  .metric-card .label {
    font-size: 14px;
    font-weight: 600;
    color: #e2e8f0;
  }

  .metric-card .highlight {
    color: #38bdf8;
    font-weight: 700;
  }

  .image-column {
    position: relative;
    width: 420px;
    height: 350px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .prism-image {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    filter: drop-shadow(0 20px 30px rgba(37, 99, 235, 0.45));
    transform: scale(1.05);
  }

  .footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    z-index: 10;
    border-top: 1px solid rgba(255, 255, 255, 0.08);
    padding-top: 20px;
    margin-top: 10px;
  }

  .site-url {
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 16px;
    font-weight: 600;
    color: #38bdf8;
  }

  .dot {
    width: 8px;
    height: 8px;
    background: #10b981;
    border-radius: 50%;
    box-shadow: 0 0 10px #10b981;
  }

  .footer-links {
    display: flex;
    align-items: center;
    gap: 20px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 14px;
    color: #64748b;
  }

  .footer-links span {
    color: #94a3b8;
  }
</style>
</head>
<body>
  <div class="canvas">
    <div class="grid-overlay"></div>
    <div class="glow-orb"></div>

    <div class="header">
      <img src="data:image/png;base64,${ALTENWALD_B64}" class="altenwald-logo" alt="Altenwald">
      <div class="divider"></div>
      <div class="tag-badge">
        <span>BEAM Static Type Analyzer</span>
      </div>
    </div>

    <div class="main-content">
      <div class="text-column">
        <div class="title-row">
          <div class="title">PRISMA</div>
          <div class="version-tag">v0.1.0</div>
        </div>
        <div class="subtitle">Fast, Modular Type &amp; Spec Analyzer for Erlang &amp; Elixir</div>
        <div class="description">Modular binary .pplt tables eliminate monolithic rebuilds. Real-world verification on RabbitMQ and OTP with zero external runtime dependencies.</div>

        <div class="metrics-grid">
          <div class="metric-card">
            <span class="icon">⚡</span>
            <span class="label"><span class="highlight">Up to 6.3× faster</span> than Dialyzer</span>
          </div>
          <div class="metric-card">
            <span class="icon">📉</span>
            <span class="label"><span class="highlight">20.8× less CPU</span> consumed</span>
          </div>
          <div class="metric-card">
            <span class="icon">📦</span>
            <span class="label"><span class="highlight">Modular .pplt</span> binary tables</span>
          </div>
          <div class="metric-card">
            <span class="icon">🎯</span>
            <span class="label"><span class="highlight">100% seeded faults</span> caught</span>
          </div>
        </div>
      </div>

      <div class="image-column">
        <img src="data:image/png;base64,${PRISMA_B64}" class="prism-image" alt="Prisma">
      </div>
    </div>

    <div class="footer">
      <div class="site-url">
        <div class="dot"></div>
        <span>https://prisma.altenwald.com</span>
      </div>
      <div class="footer-links">
        <span>github.com/altenwald/prisma</span>
        <span>•</span>
        <span>hex.pm/packages/prisma</span>
      </div>
    </div>
  </div>
</body>
</html>
HTML_EOF

"$CHROME_BIN" --headless --disable-gpu --screenshot="$TMP_PNG" --window-size=1200,630 --default-background-color=00000000 "$TMP_HTML" 2>/dev/null

if which magick >/dev/null 2>&1; then
  magick "$TMP_PNG" -strip -quality 95 "${REPO_ROOT}/assets/prisma_og.png"
else
  cp "$TMP_PNG" "${REPO_ROOT}/assets/prisma_og.png"
fi

cp "${REPO_ROOT}/assets/prisma_og.png" "${REPO_ROOT}/web/assets/prisma_og.png"
echo "Generated ${REPO_ROOT}/assets/prisma_og.png and copied to web/assets/prisma_og.png"
