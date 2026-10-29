<?php
/**
 * Plugin Name: Test server guard
 * Description: Put on every test copy by wordpressServers/bin/write-config.sh. A copy of a
 *              client's site must never email their customers or be indexed by Google.
 */

// No outgoing mail, ever. A copied site still holds real users, orders and form recipients.
add_filter( 'pre_wp_mail', '__return_false' );

// noindex whatever the copied database says, and say it in a header too.
add_filter( 'pre_option_blog_public', '__return_zero' );
add_action( 'send_headers', function () {
	header( 'X-Robots-Tag: noindex, nofollow', true );
} );
