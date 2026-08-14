<?php
/**
 * Plugin Name: Texas Hold 'Em Live Viewer
 * Description: Displays the public sp_TexasHoldEm game and refreshes it without reloading the WordPress page.
 * Version: 0.1.0
 * Requires at least: 6.5
 * Requires PHP: 8.2
 * Author: Brent Ozar Unlimited
 * License: MIT
 */

if (!defined('ABSPATH')) {
    exit;
}

const BRENT_OZAR_TEXAS_HOLDEM_VIEWER_VERSION = '0.1.0';

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
        'brentozar-texas-holdem-viewer',
        $plugin_url . 'assets/poker-viewer.css',
        array(),
        brentozar_texas_holdem_viewer_asset_version($plugin_path . 'assets/poker-viewer.css')
    );
    wp_enqueue_script(
        'brentozar-texas-holdem-viewer',
        $plugin_url . 'assets/poker-viewer.js',
        array(),
        brentozar_texas_holdem_viewer_asset_version($plugin_path . 'assets/poker-viewer.js'),
        true
    );

    return sprintf(
        '<section class="texas-holdem-viewer" data-texas-holdem-viewer data-endpoint="%1$s">
            <p class="texas-holdem-viewer__status" data-role="status" aria-live="polite">Loading the poker table…</p>
            <h2>Current hand</h2>
            <div data-role="hand"></div>
            <h2>Players</h2>
            <div data-role="seats"></div>
            <h2>What now</h2>
            <div data-role="what-now"></div>
            <h2>What happened</h2>
            <div data-role="history"></div>
        </section>',
        esc_url($endpoint)
    );
}
add_shortcode('texas_holdem_viewer', 'brentozar_texas_holdem_viewer_shortcode');
