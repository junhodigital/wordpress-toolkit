<?php
/**
 * Runs on the TEST copy: `wp eval-file - post <id>...` or `wp eval-file - option <name>...`.
 * Sent by bin/publish.py, never run by hand. Reads only.
 *
 * Prints @@REPORT@@ and then JSON: the raw database rows (post, all its meta, its terms by
 * slug; or the raw option value), so live receives exactly what the copy holds. For an
 * attachment it also lists the upload files that belong to it.
 */
global $wpdb;

function vc_export_post( $id ) {
	global $wpdb;
	$p = $wpdb->get_row( $wpdb->prepare( "SELECT * FROM $wpdb->posts WHERE ID = %d", $id ), ARRAY_A );
	if ( ! $p ) {
		return null;
	}
	$meta  = $wpdb->get_results( $wpdb->prepare( "SELECT meta_key, meta_value FROM $wpdb->postmeta WHERE post_id = %d ORDER BY meta_id", $id ), ARRAY_N );
	$terms = array();
	foreach ( get_object_taxonomies( $p['post_type'] ) as $tax ) {
		$t = wp_get_object_terms( $id, $tax );
		if ( is_wp_error( $t ) ) {
			continue;
		}
		$terms[ $tax ] = array_map(
			function ( $x ) {
				$parent = $x->parent ? get_term( $x->parent ) : null;
				return array(
					'slug'   => $x->slug,
					'name'   => $x->name,
					'parent' => ( $parent && ! is_wp_error( $parent ) ) ? $parent->slug : '',
				);
			},
			$t
		);
	}
	$files = array();
	if ( 'attachment' === $p['post_type'] ) {
		$rel = get_post_meta( $id, '_wp_attached_file', true );
		if ( $rel ) {
			$up      = 'wp-content/uploads/';
			$sub     = dirname( $rel ) === '.' ? '' : dirname( $rel ) . '/';
			$files[] = $up . $rel;
			$md      = wp_get_attachment_metadata( $id );
			foreach ( ( $md['sizes'] ?? array() ) as $s ) {
				if ( ! empty( $s['file'] ) ) {
					$files[] = $up . $sub . $s['file'];
				}
			}
			if ( ! empty( $md['original_image'] ) ) {
				$files[] = $up . $sub . $md['original_image'];
			}
		}
	}
	return array( 'post' => $p, 'meta' => $meta, 'terms' => $terms, 'files' => array_values( array_unique( $files ) ) );
}

$kind = array_shift( $args );
$out  = array( 'home' => home_url(), 'items' => array() );
foreach ( $args as $arg ) {
	if ( 'post' === $kind ) {
		$item = vc_export_post( (int) $arg );
	} elseif ( 'option' === $kind ) {
		$row  = $wpdb->get_row( $wpdb->prepare( "SELECT option_value, autoload FROM $wpdb->options WHERE option_name = %s", $arg ), ARRAY_A );
		$item = $row ? array( 'name' => $arg, 'value' => $row['option_value'], 'autoload' => $row['autoload'] ) : null;
	} else {
		fwrite( STDERR, "unknown kind $kind\n" );
		exit( 1 );
	}
	if ( ! $item ) {
		fwrite( STDERR, "$kind $arg does not exist on the test copy\n" );
		exit( 1 );
	}
	$out['items'][] = $item;
}
echo '@@REPORT@@' . wp_json_encode( $out );
