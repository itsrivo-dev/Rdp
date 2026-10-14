#!/usr/bin/env python3
"""Turn the vendored noVNC application page into the Cloud PC desktop page.

noVNC ships ``vnc.html``: a full user interface whose bootstrap fetches
``defaults.json``/``mandatory.json`` and connects with the settings the user
typed into the on-screen dialog. We want the same interface, but connecting
automatically to the local gateway with the VNC password handed out by the
authenticated ``/api/session`` endpoint.

This script rewrites the bootstrap in place, renames the page to ``index.html``
(so ``/vnc/`` serves it) and asserts that every expected marker was found - a
silent mismatch after a noVNC upgrade would be worse than a failed build.

Usage: build_novnc_page.py <novnc-directory>
"""

from __future__ import annotations

import os
import re
import sys

TITLE_MARKER = "<title>noVNC</title>"
THEME_MARKER = '<meta name="theme-color" content="#313131">'

BOOTSTRAP = r"""
    <script type="module">
        /*
         * Ubuntu Cloud PC desktop page.
         *
         * Generated from noVNC's vnc.html by docker/tools/build_novnc_page.py.
         * The interface is unchanged noVNC; only the bootstrap is replaced so
         * that the page waits for the desktop, authenticates with the password
         * from /api/session and connects without asking the user anything.
         */
        import UI from "./app/ui.js";
        import * as Log from './core/util/logging.js';

        const RETRY_FAST = 1500;      // ms between the first attempts
        const RETRY_SLOW = 3000;      // ms after the desktop is clearly booting
        const MAX_ATTEMPTS = 80;      // ~4 minutes before we admit defeat

        const style = document.createElement('style');
        style.textContent = `
            #cloudpc_overlay {
                position: fixed; inset: 0; z-index: 1000;
                display: flex; align-items: center; justify-content: center;
                background: radial-gradient(circle at 50% 0%, #4a0033 0%, #2c001e 45%, #170010 100%);
                color: #f0e8ec; text-align: center; padding: 1.5rem;
                font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
                transition: opacity .4s ease;
            }
            #cloudpc_overlay.cloudpc_hidden { opacity: 0; pointer-events: none; }
            #cloudpc_overlay .card { max-width: 26rem; }
            #cloudpc_overlay h2 { margin: 1rem 0 .5rem; font-size: 1.2rem; font-weight: 600; }
            #cloudpc_overlay p { margin: .35rem 0; color: #cbb6c2; font-size: .92rem; }
            #cloudpc_overlay .hint { font-size: .8rem; opacity: .75; }
            #cloudpc_overlay button {
                margin-top: 1rem; padding: .7rem 1.1rem; font-size: .95rem; font-weight: 600;
                color: #fff; background: #e95420; border: 0; border-radius: .5rem; cursor: pointer;
            }
            #cloudpc_spinner {
                width: 2.5rem; height: 2.5rem; margin: 0 auto;
                border: 3px solid rgba(255,255,255,.25); border-top-color: #e95420;
                border-radius: 50%; animation: cloudpc_spin 1s linear infinite;
            }
            @keyframes cloudpc_spin { to { transform: rotate(360deg); } }
            #cloudpc_overlay .sad { display: none; font-size: 2rem; }
            #cloudpc_overlay.error .sad { display: block; }
            #cloudpc_overlay.error #cloudpc_spinner { display: none; }
        `;
        document.head.appendChild(style);

        const overlay = document.createElement('div');
        overlay.id = 'cloudpc_overlay';
        overlay.innerHTML = `
            <div class="card">
                <div id="cloudpc_spinner"></div>
                <div class="sad">&#9888;</div>
                <h2 id="cloudpc_title">Starting your Ubuntu desktop</h2>
                <p id="cloudpc_message">Waiting for the VNC server&hellip;</p>
                <p class="hint" id="cloudpc_hint">This page connects by itself &mdash; keep it open.</p>
                <button id="cloudpc_button" style="display:none">Reload</button>
            </div>`;
        document.body.appendChild(overlay);

        const title = document.getElementById('cloudpc_title');
        const message = document.getElementById('cloudpc_message');
        const hint = document.getElementById('cloudpc_hint');
        const button = document.getElementById('cloudpc_button');

        button.addEventListener('click', () => window.location.reload());
        overlay.addEventListener('click', (event) => {
            if (event.target === overlay && UI.connected) {
                overlay.classList.add('cloudpc_hidden');
            }
        });

        function fail(text) {
            overlay.classList.add('error');
            title.textContent = 'The desktop is not reachable';
            message.textContent = text;
            hint.textContent = 'Open /health for the service status, or check the deploy logs.';
            button.style.display = 'inline-block';
        }

        async function fetchSession() {
            let response;
            try {
                response = await fetch('../api/session', { cache: 'no-store', credentials: 'same-origin' });
            } catch (err) {
                return null;
            }
            if (response.status === 401) {
                // The session expired while the page was open.
                window.location.replace('../');
                return null;
            }
            if (!response.ok) {
                return null;
            }
            try {
                return await response.json();
            } catch (err) {
                return null;
            }
        }

        let session = null;
        for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
            session = await fetchSession();
            if (session && session.desktop && session.desktop.ready) {
                break;
            }
            session = null;
            const seconds = Math.round((attempt * (attempt < 12 ? RETRY_FAST : RETRY_SLOW)) / 1000);
            if (attempt > 1) {
                message.textContent = 'Waiting for the VNC server\\u2026 (' + seconds + 's)';
            }
            await new Promise((resolve) => setTimeout(resolve,
                attempt < 12 ? RETRY_FAST : RETRY_SLOW));
        }

        if (!session) {
            fail('The desktop did not become ready in time.');
        } else {
            Log.Info('starting noVNC session for ' + (session.desktop_name || 'Ubuntu'));

            UI.start({
                settings: {
                    defaults: {
                        host: '',
                        port: 0,
                        encrypt: (window.location.protocol === 'https:'),
                        path: session.ws_path || 'websockify',
                        password: session.vnc_password,
                        autoconnect: true,
                        reconnect: true,
                        reconnect_delay: 2000,
                        resize: 'scale',
                        view_clip: false,
                        shared: true,
                        bell: 'off',
                        view_only: false,
                        show_dot: true,
                        quality: 6,
                        compression: 2,
                        logging: 'warn'
                    },
                    mandatory: {}
                }
            });

            const poll = setInterval(() => {
                if (UI.connected) {
                    clearInterval(poll);
                    overlay.classList.add('cloudpc_hidden');
                    message.textContent = '';
                }
            }, 250);

            setTimeout(() => {
                if (!UI.connected && !overlay.classList.contains('error')) {
                    hint.textContent = 'Still connecting. If this does not finish, reload the page.';
                    button.style.display = 'inline-block';
                }
            }, 30000);
        }
    </script>
"""


def replace_bootstrap(html: str) -> str:
    """Replace the first inline module script that calls UI.start()."""
    pattern = re.compile(r"[ \t]*<script type=\"module\">(?:(?!</script>).)*UI\.start\(.*?</script>",
                         re.DOTALL)
    matches = list(pattern.finditer(html))
    if len(matches) != 1:
        raise SystemExit("expected exactly one UI.start() bootstrap, found %d" % len(matches))
    return html[: matches[0].start()] + BOOTSTRAP.strip("\n") + html[matches[0].end():]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    source = os.path.join(root, "vnc.html")
    target = os.path.join(root, "index.html")

    if not os.path.isfile(source):
        raise SystemExit("noVNC page not found: %s" % source)

    with open(source, "r", encoding="utf-8") as handle:
        html = handle.read()

    if TITLE_MARKER not in html:
        raise SystemExit("noVNC page no longer contains %r - the patch needs updating" % TITLE_MARKER)
    if "noVNC_container" not in html or "noVNC_setting_resize" not in html:
        raise SystemExit("noVNC page structure changed - refusing to patch blindly")

    html = html.replace(TITLE_MARKER, "<title>Ubuntu Desktop</title>", 1)
    if THEME_MARKER in html:
        html = html.replace(
            THEME_MARKER,
            THEME_MARKER
            + '\n    <meta name="mobile-web-app-capable" content="yes">'
            + '\n    <meta name="apple-mobile-web-app-title" content="Ubuntu Desktop">'
            + '\n    <link rel="manifest" href="/manifest.webmanifest">'
            + '\n    <link rel="icon" type="image/png" href="/static/icon-192.png">',
            1,
        )
    html = replace_bootstrap(html)

    with open(target, "w", encoding="utf-8") as handle:
        handle.write(html)
    os.unlink(source)

    # The lite page bypasses the UI (and therefore the gateway settings), so
    # it would only confuse: remove it and keep the licence files.
    lite = os.path.join(root, "vnc_lite.html")
    if os.path.isfile(lite):
        os.unlink(lite)

    print("wrote %s (%d bytes)" % (target, os.path.getsize(target)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
