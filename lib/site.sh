#!/usr/bin/env bash

rw_generate_site() {
    local force=${1:-false} tmp output
    output="${RW_SITE_DIR}/index.html"
    install -d -m 0755 "$RW_SITE_DIR" "${RW_SITE_DIR}/assets/fonts"

    if [[ $force == true || ! -s $output ]]; then
        tmp=$(mktemp "${RW_SITE_DIR}/.index.XXXXXX")
        rw_log "Генерирую уникальный сайт (seed: $SITE_SEED)..."
        python3 "$RW_INSTALL_DIR/run.py" --seed "$SITE_SEED" --output "$tmp" --quiet
        install -m 0644 "$tmp" "$output"
        rm -f "$tmp"
    fi

    install -m 0644 "$RW_INSTALL_DIR/assets/site/robots.txt" "${RW_SITE_DIR}/robots.txt"
    install -m 0644 "$RW_INSTALL_DIR/assets/site/favicon.svg" "${RW_SITE_DIR}/favicon.svg"
    cp -f "$RW_INSTALL_DIR"/assets/fonts/*.woff2 "${RW_SITE_DIR}/assets/fonts/"
    chmod 0644 "${RW_SITE_DIR}"/assets/fonts/*.woff2

    cat >"${RW_SITE_DIR}/sitemap.xml.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc></url>
</urlset>
EOF
    rw_atomic_install "${RW_SITE_DIR}/sitemap.xml.tmp" "${RW_SITE_DIR}/sitemap.xml" 0644
    rm -f "${RW_SITE_DIR}/sitemap.xml.tmp"
    chown -R root:root "$RW_SITE_DIR"
}

rw_verify_site_assets() {
    local font
    [[ -s ${RW_SITE_DIR}/index.html ]] || return 1
    ! grep -Eiq 'fonts\.googleapis\.com|fonts\.gstatic\.com' "${RW_SITE_DIR}/index.html" || return 1
    for font in golos-text-cyrillic golos-text-latin unbounded-cyrillic unbounded-latin \
        pt-serif-cyrillic-regular pt-serif-latin-regular pt-serif-cyrillic-bold \
        pt-serif-latin-bold pt-serif-cyrillic-italic pt-serif-latin-italic \
        ibm-plex-mono-cyrillic ibm-plex-mono-latin; do
        [[ -s ${RW_SITE_DIR}/assets/fonts/${font}.woff2 ]] || return 1
    done
}
