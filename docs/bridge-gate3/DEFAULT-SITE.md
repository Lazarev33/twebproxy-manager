# Bundled default website

`sites/podmoskovye/` is the fixed bundled default «Культурные маршруты Подмосковья».
Its HTML/CSS and original CC0 SVG illustrations ship in the distribution; no
runtime font, CDN, analytics, advert or external script is needed. Content covers
Kolomna, Sergiev Posad, Zaraysk, architecture and crafts. Museum/UNESCO references
are documented; the site declares its independent status. It is not a site builder.

The normal first-run/quick setup's first website choice uses `SITE_MODE=default`.
Custom directory and loopback upstream choices remain. Legacy `placeholder`
records are still readable; their existing files are preserved, not replaced
silently. A preexisting generated page is not automatically migrated over edits.

`tools/default-site-bundle.py` builds MANIFEST.json and pins its SHA in Manager.
The runtime checks the manifest digest, exact file set/content, safe paths and
absence of symlinks. An invalid package stops deployment. Installation copies
verified assets into the versioned root-owned Manager cache
`/opt/twebproxy-manager/default-site-<manifest-sha>`; an existing modified cache
is rejected, not overwritten. Installed Manager can use this cache without its
original source directory. Each new domain receives its own copy at
`/srv/twebproxy/<hostname>`, files 0644/directories 0755. Provenance is root-only
`/etc/twebproxy/instances/<hostname>/default-site.json`, outside the public site.

Any existing nonempty live site with index.html is preserved byte for byte,
including operator edits, additional files and intentional deletions. Repairs,
Manager/bundle reinstallations and future bundle versions do not refresh it.
A nonempty conflicting directory without index.html fails without deleting it.
Custom directory repair also preserves existing files and does not require the
original upload directory to remain accessible. Upstream mode creates no static
files. A versioned distribution cache is not a user website update target.

To edit a deployed site, back up and edit its live directory; the relay reads
static files at startup, so restart its instance afterwards (this closes relay
sessions). Do not publish keys/proxy secrets in that public directory. Explicit
hostname deletion removes its website and provenance after service shutdown;
core-uninstall retains the default bundle with the retained Manager. No arbitrary
user directories or unrelated website files are purged by bundle maintenance.

Tests: actual default deployment on martins.ortositi.ru through the normal
installed wizard; checksum/permission match; desktop/mobile public TLS browser
rendering with no horizontal overflow or external runtime requests; live edited
files preserved across Bridge repair/removal, local repair and bundle reinstall;
filesystem tests for corrupt manifests/assets, unknown files/symlinks, modified
cache, existing user files, custom-directory repair and upstream mode.
