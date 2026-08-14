<?php
/**
 * Plugin Name: Texas Hold 'Em Live Viewer
 * Description: Displays the public sp_TexasHoldEm_Public game as a live poker table without reloading the page.
 * Version: 0.2.0
 * Requires at least: 6.5
 * Requires PHP: 8.2
 * Author: Brent Ozar Unlimited
 * License: MIT
 */

if (!defined('ABSPATH')) {
    exit;
}

const BRENT_OZAR_TEXAS_HOLDEM_VIEWER_VERSION = '0.2.0';

/**
 * Use the asset timestamp for cache busting, with a safe fallback for partial deploys.
 */
function brentozar_texas_holdem_viewer_asset_version(string $path): string
{
    $modified_at = is_readable($path) ? @filemtime($path) : false;
    return $modified_at === false
        ? BRENT_OZAR_TEXAS_HOLDEM_VIEWER_VERSION
        : (string) $modified_at;
}

/**
 * Render [texas_holdem_viewer].
 *
 * Set TEXAS_HOLDEM_API_URL in wp-config.php or pass endpoint="https://..."
 * in the shortcode while testing.
 *
 * @param array<string, string> $attributes Shortcode attributes.
 */
function brentozar_texas_holdem_viewer_shortcode($attributes): string
{
    $default_endpoint = defined('TEXAS_HOLDEM_API_URL')
        ? (string) constant('TEXAS_HOLDEM_API_URL')
        : '';

    $attributes = shortcode_atts(
        array('endpoint' => $default_endpoint),
        $attributes,
        'texas_holdem_viewer'
    );
    $endpoint = esc_url_raw((string) $attributes['endpoint'], array('https'));

    if ($endpoint === '') {
        if (current_user_can('manage_options')) {
            return '<p><strong>Texas Hold ’Em viewer:</strong> set TEXAS_HOLDEM_API_URL in wp-config.php.</p>';
        }

        return '<p>The poker table is not configured yet.</p>';
    }

    $plugin_url = plugin_dir_url(__FILE__);
    $plugin_path = plugin_dir_path(__FILE__);
    wp_enqueue_style(
        'brentozar-texas-holdem-fonts',
        'https://fonts.googleapis.com/css2?family=Lilita+One&family=Nunito:wght@600;700;800&display=swap',
        array(),
        null
    );
    wp_enqueue_style(
        'brentozar-texas-holdem-viewer',
        $plugin_url . 'assets/poker-viewer.css',
        array('brentozar-texas-holdem-fonts'),
        brentozar_texas_holdem_viewer_asset_version($plugin_path . 'assets/poker-viewer.css')
    );
    wp_enqueue_script(
        'brentozar-texas-holdem-viewer',
        $plugin_url . 'assets/poker-viewer.js',
        array(),
        brentozar_texas_holdem_viewer_asset_version($plugin_path . 'assets/poker-viewer.js'),
        true
    );
    wp_script_add_data('brentozar-texas-holdem-viewer', 'strategy', 'defer');

    return sprintf(
        '<section class="texas-holdem-viewer" data-texas-holdem-viewer data-endpoint="%1$s" aria-label="Live Texas Hold ’Em table">
            <div class="texas-holdem-viewer__shell">
                <header class="texas-holdem-viewer__topbar">
                    <div class="texas-holdem-viewer__brand" aria-label="T-SQL Hold ’Em — nothing at stake">
                        <div class="texas-holdem-viewer__wordmark">T-SQL HOLD’EM</div>
                        <div class="texas-holdem-viewer__sticker">NOTHING AT STAKE</div>
                    </div>
                    <div class="texas-holdem-viewer__status-pill">
                        <span class="texas-holdem-viewer__status-dot" data-role="status-dot" aria-hidden="true"></span>
                        <span class="texas-holdem-viewer__status-text" data-role="status" aria-live="polite">Dealer is checking the table…</span>
                    </div>
                </header>

                <div class="texas-holdem-viewer__scaler" data-role="scaler">
                    <div class="texas-holdem-viewer__table" data-role="table">
                        <div class="texas-holdem-viewer__rail" aria-hidden="true">
                            <div class="texas-holdem-viewer__felt"></div>
                            <div class="texas-holdem-viewer__felt-line"></div>
                        </div>

                        <div class="texas-holdem-viewer__center">
                            <div class="texas-holdem-viewer__street" data-role="street">SHUFFLING</div>
                            <div class="texas-holdem-viewer__board" data-role="board" aria-label="Community cards"></div>
                            <div class="texas-holdem-viewer__pot">
                                <div class="texas-holdem-viewer__pot-chips" aria-hidden="true">
                                    <span class="texas-holdem-viewer__chip texas-holdem-viewer__chip--red"></span>
                                    <span class="texas-holdem-viewer__chip texas-holdem-viewer__chip--blue"></span>
                                    <span class="texas-holdem-viewer__chip texas-holdem-viewer__chip--black"></span>
                                </div>
                                <div>
                                    <div class="texas-holdem-viewer__pot-label">POT</div>
                                    <div class="texas-holdem-viewer__pot-value" data-role="pot">$0</div>
                                </div>
                            </div>
                        </div>

                        <div class="texas-holdem-viewer__seats" data-role="seats" aria-label="Players"></div>
                    </div>
                </div>

                <p class="texas-holdem-viewer__footnote">Dealt by a stored procedure. Blame the query plan, not the cards.</p>
                <noscript><p class="texas-holdem-viewer__noscript">JavaScript is required to watch this table update.</p></noscript>
            </div>
        </section>',
        esc_url($endpoint)
    );
}
add_shortcode('texas_holdem_viewer', 'brentozar_texas_holdem_viewer_shortcode');
