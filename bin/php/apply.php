<?php
/**
 * Runs on the LIVE site: `wp eval-file - <payload.json>`. Sent by bin/publish.py, never run
 * by hand. Payload mode "check" only reads; mode "apply" writes, and only if every item
 * passed its checks. Prints @@REPORT@@ and then JSON: items, errors, warnings, the live rows
 * as they were before the write (for rollback), and their state after.
 *
 * Checks, per post:
 *  - live has not changed it since the refresh (post_modified_gmt equals the manifest's),
 *    unless forced;
 *  - an ID free on live, or holding the same post type, so IDs stay the same on both sides
 *    and every reference (images, synced patterns, parents) keeps pointing at the right row;
 *  - every image, pattern or parent it uses already exists on live or is in the same batch.
 *
 * Addresses: the test copy's address becomes live's, in plain and JSON-escaped form. Meta
 * and option values are unserialized before the swap and stored through WordPress, so
 * serialized lengths stay correct. Writes use wp_slash() and kses_remove_filters(): wp-cli
 * runs without a user, and without both a level of backslashes or markup would be lost.
 */
global $wpdb;

define( 'VC_FIELDS', array( 'post_author', 'post_date', 'post_date_gmt', 'post_content', 'post_title', 'post_excerpt', 'post_status', 'comment_status', 'ping_status', 'post_password', 'post_name', 'post_parent', 'menu_order', 'post_type', 'post_mime_type' ) );
define( 'VC_SKIP_META', array( '_edit_lock', '_edit_last' ) );

function vc_swap( $v, $swap ) {
	if ( is_string( $v ) ) {
		return $swap ? strtr( $v, $swap ) : $v;
	}
	if ( is_array( $v ) ) {
		foreach ( $v as $k => $x ) {
			$v[ $k ] = vc_swap( $x, $swap );
		}
	} elseif ( is_object( $v ) && ! $v instanceof __PHP_Incomplete_Class ) {
		foreach ( get_object_vars( $v ) as $k => $x ) {
			$v->$k = vc_swap( $x, $swap );
		}
	}
	return $v;
}

function vc_mentions( $v, $needle ) {
	if ( is_string( $v ) ) {
		return false !== strpos( $v, $needle );
	}
	if ( is_array( $v ) || is_object( $v ) ) {
		foreach ( (array) $v as $x ) {
			if ( vc_mentions( $x, $needle ) ) {
				return true;
			}
		}
	}
	return false;
}

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
		if ( ! is_wp_error( $t ) ) {
			$terms[ $tax ] = array_map(
				function ( $x ) {
					$parent = $x->parent ? get_term( $x->parent ) : null;
					return array( 'slug' => $x->slug, 'name' => $x->name, 'parent' => ( $parent && ! is_wp_error( $parent ) ) ? $parent->slug : '' );
				},
				$t
			);
		}
	}
	return array( 'post' => $p, 'meta' => $meta, 'terms' => $terms );
}

function vc_meta_map( $meta, $swap = null ) {
	$m = array();
	foreach ( $meta as $row ) {
		if ( in_array( $row[0], VC_SKIP_META, true ) ) {
			continue;
		}
		$m[ $row[0] ][] = null === $swap ? $row[1] : maybe_serialize( vc_swap( maybe_unserialize( $row[1] ), $swap ) );
	}
	return $m;
}

function vc_term_map( $terms ) {
	$m = array();
	foreach ( $terms as $tax => $list ) {
		$s = array_column( $list, 'slug' );
		sort( $s );
		$m[ $tax ] = $s;
	}
	ksort( $m );
	return $m;
}

function vc_refs( $blocks, &$out ) {
	foreach ( $blocks as $b ) {
		$a = $b['attrs'] ?? array();
		$n = $b['blockName'] ?? '';
		if ( in_array( $n, array( 'core/image', 'core/cover', 'core/video', 'core/audio', 'core/file' ), true ) && ! empty( $a['id'] ) ) {
			$out[] = (int) $a['id'];
		}
		if ( 'core/media-text' === $n && ! empty( $a['mediaId'] ) ) {
			$out[] = (int) $a['mediaId'];
		}
		if ( 'core/block' === $n && ! empty( $a['ref'] ) ) {
			$out[] = (int) $a['ref'];
		}
		if ( 'core/gallery' === $n && ! empty( $a['ids'] ) ) {
			foreach ( (array) $a['ids'] as $x ) {
				$out[] = (int) $x;
			}
		}
		if ( ! empty( $b['innerBlocks'] ) ) {
			vc_refs( $b['innerBlocks'], $out );
		}
	}
}

$d = json_decode( file_get_contents( $args[0] ), true );
if ( ! is_array( $d ) ) {
	fwrite( STDERR, "unreadable payload\n" );
	exit( 1 );
}
$apply = 'apply' === $d['mode'];
$force = ! empty( $d['force'] );
$R     = array( 'items' => array(), 'errors' => array(), 'warnings' => array(), 'before' => array(), 'after' => array() );

$swap     = array();
$fromhost = null;
if ( rtrim( $d['from'], '/' ) !== rtrim( $d['to'], '/' ) ) {
	$to       = rtrim( $d['to'], '/' );
	$fromhost = preg_replace( '#^https?://#', '', rtrim( $d['from'], '/' ) );
	foreach ( array( 'https://', 'http://' ) as $scheme ) {
		$swap[ $scheme . $fromhost ]                          = $to;
		$swap[ str_replace( '/', '\/', $scheme . $fromhost ) ] = str_replace( '/', '\/', $to );
	}
}

if ( 'post' === $d['kind'] ) {
	$batch = array();
	foreach ( $d['items'] as $it ) {
		$batch[ (int) $it['post']['ID'] ] = true;
	}
	$plan = array();
	foreach ( $d['items'] as $it ) {
		$id   = (int) $it['post']['ID'];
		$live = $wpdb->get_row( $wpdb->prepare( "SELECT ID, post_type, post_modified_gmt FROM $wpdb->posts WHERE ID = %d", $id ), ARRAY_A );
		$line = array(
			'id'      => $id,
			'type'    => $it['post']['post_type'],
			'title'   => $it['post']['post_title'],
			'action'  => ! empty( $it['absent'] ) ? 'delete' : ( $live ? 'update' : 'create' ),
			'changes' => array(),
		);
		if ( ! empty( $it['absent'] ) ) {
			if ( $live ) {
				$plan[] = array( $id, null, $live );
			}
			$R['items'][] = $line;
			continue;
		}
		$was = $d['manifest'][ (string) $id ] ?? null;
		if ( $live && $live['post_type'] !== $it['post']['post_type'] ) {
			$R['errors'][] = "#$id is a {$live['post_type']} on live but a {$it['post']['post_type']} on the copy";
		} elseif ( ! $force ) {
			if ( $live && null === $was ) {
				$R['errors'][] = "#$id was created on live after the last refresh";
			} elseif ( $live && $live['post_modified_gmt'] !== $was ) {
				$R['errors'][] = "#$id was edited on live since the last refresh ($was -> {$live['post_modified_gmt']})";
			} elseif ( ! $live && null !== $was ) {
				$R['errors'][] = "#$id was deleted on live since the last refresh";
			}
		}
		$new         = $it;
		$new['post'] = vc_swap( $it['post'], $swap );
		$new['terms'] = vc_swap( $it['terms'], $swap );
		$want_meta   = vc_meta_map( $it['meta'], $swap );
		$meta_values = array();
		foreach ( $want_meta as $vals ) {
			foreach ( $vals as $raw ) {
				$meta_values[] = maybe_unserialize( $raw );
			}
		}
		if ( $fromhost && ( vc_mentions( $new['post'], $fromhost ) || vc_mentions( $meta_values, $fromhost ) ) ) {
			$R['warnings'][] = "#$id still mentions $fromhost after the address swap";
		}

		$refs = array();
		preg_match_all( '/wp-image-(\d+)/', $new['post']['post_content'], $m );
		foreach ( $m[1] as $x ) {
			$refs[] = (int) $x;
		}
		vc_refs( parse_blocks( $new['post']['post_content'] ), $refs );
		foreach ( $want_meta['_thumbnail_id'] ?? array() as $x ) {
			$refs[] = (int) $x;
		}
		if ( (int) $new['post']['post_parent'] > 0 ) {
			$refs[] = (int) $new['post']['post_parent'];
		}
		foreach ( array_unique( $refs ) as $ref ) {
			if ( $ref > 0 && empty( $batch[ $ref ] ) && ! get_post( $ref ) ) {
				$R['errors'][] = "#$id uses #$ref, which is not on live yet: publish post $ref first, or in the same command";
			}
		}

		if ( $live ) {
			$cur = vc_export_post( $id );
			foreach ( VC_FIELDS as $f ) {
				if ( (string) $cur['post'][ $f ] !== (string) $new['post'][ $f ] ) {
					$line['changes'][] = 'post_content' === $f ? sprintf( 'content %d -> %d chars', strlen( $cur['post'][ $f ] ), strlen( $new['post'][ $f ] ) ) : $f;
				}
			}
			$have = vc_meta_map( $cur['meta'] );
			$mc   = count( array_diff_key( $want_meta, $have ) ) + count( array_diff_key( $have, $want_meta ) );
			foreach ( $have as $k => $v ) {
				if ( isset( $want_meta[ $k ] ) && $want_meta[ $k ] !== $v ) {
					++$mc;
				}
			}
			if ( $mc ) {
				$line['changes'][] = "$mc meta field(s)";
			}
			if ( vc_term_map( $cur['terms'] ) !== vc_term_map( $new['terms'] ) ) {
				$line['changes'][] = 'categories/terms';
			}
		}
		$R['items'][] = $line;
		$plan[]       = array( $id, array( 'post' => $new['post'], 'meta' => $want_meta, 'terms' => $new['terms'] ), $live );
	}

	if ( $apply && ! $R['errors'] ) {
		kses_remove_filters();
		foreach ( $plan as list( $id, $new, $live ) ) {
			$R['before'][] = $live ? vc_export_post( $id ) : array( 'post' => array( 'ID' => $id, 'post_type' => $new['post']['post_type'], 'post_title' => $new['post']['post_title'] ), 'absent' => true );
			if ( null === $new ) {
				wp_delete_post( $id, true );
				$R['after'][ (string) $id ] = null;
				continue;
			}
			$f = array_intersect_key( $new['post'], array_flip( VC_FIELDS ) );
			if ( 'attachment' === $new['post']['post_type'] ) {
				$f['guid'] = $new['post']['guid'];
			}
			if ( $live ) {
				$f['ID'] = $id;
				$r       = wp_update_post( wp_slash( $f ), true );
			} else {
				$f['import_id'] = $id;
				$r              = wp_insert_post( wp_slash( $f ), true );
			}
			if ( is_wp_error( $r ) || (int) $r !== $id ) {
				$R['errors'][] = "#$id: write failed: " . ( is_wp_error( $r ) ? $r->get_error_message() : "WordPress gave it ID $r" );
				if ( ! is_wp_error( $r ) && $r && ! $live ) {
					wp_delete_post( $r, true );
				}
				break;
			}
			$have = vc_meta_map( vc_export_post( $id )['meta'] );
			foreach ( array_keys( $have ) as $k ) {
				if ( ! isset( $new['meta'][ $k ] ) ) {
					delete_post_meta( $id, $k );
				}
			}
			foreach ( $new['meta'] as $k => $vals ) {
				if ( ( $have[ $k ] ?? null ) === $vals ) {
					continue;
				}
				delete_post_meta( $id, $k );
				foreach ( $vals as $raw ) {
					add_post_meta( $id, wp_slash( $k ), wp_slash( maybe_unserialize( $raw ) ) );
				}
			}
			foreach ( $new['terms'] as $tax => $list ) {
				if ( ! taxonomy_exists( $tax ) ) {
					$R['warnings'][] = "#$id: taxonomy $tax does not exist on live, skipped";
					continue;
				}
				$ids = array();
				foreach ( $list as $t ) {
					$term = get_term_by( 'slug', $t['slug'], $tax );
					if ( ! $term ) {
						$targs = array( 'slug' => $t['slug'] );
						if ( $t['parent'] && ( $pt = get_term_by( 'slug', $t['parent'], $tax ) ) ) {
							$targs['parent'] = $pt->term_id;
						}
						$ins = wp_insert_term( $t['name'], $tax, $targs );
						if ( is_wp_error( $ins ) ) {
							$R['warnings'][] = "#$id: could not create {$tax} '{$t['slug']}': " . $ins->get_error_message();
							continue;
						}
						$ids[] = (int) $ins['term_id'];
					} else {
						$ids[] = (int) $term->term_id;
					}
				}
				wp_set_object_terms( $id, $ids, $tax );
			}
			clean_post_cache( $id );
			$R['after'][ (string) $id ] = $wpdb->get_var( $wpdb->prepare( "SELECT post_modified_gmt FROM $wpdb->posts WHERE ID = %d", $id ) );
		}
	}
} elseif ( 'option' === $d['kind'] ) {
	$plan = array();
	foreach ( $d['items'] as $it ) {
		$name = $it['name'];
		$cur  = $wpdb->get_row( $wpdb->prepare( "SELECT option_value, autoload FROM $wpdb->options WHERE option_name = %s", $name ), ARRAY_A );
		$line = array( 'name' => $name, 'action' => ! empty( $it['absent'] ) ? 'delete' : ( $cur ? 'update' : 'create' ), 'changes' => array() );
		$was  = $d['manifest'][ $name ] ?? null;
		if ( ! $force ) {
			if ( $cur && null === $was ) {
				$R['errors'][] = "option $name was created on live after the last refresh";
			} elseif ( $cur && md5( $cur['option_value'] ) !== $was ) {
				$R['errors'][] = "option $name was changed on live since the last refresh";
			} elseif ( ! $cur && null !== $was ) {
				$R['errors'][] = "option $name was deleted on live since the last refresh";
			}
		}
		$val = null;
		if ( empty( $it['absent'] ) ) {
			$val = vc_swap( maybe_unserialize( $it['value'] ), $swap );
			if ( $fromhost && vc_mentions( $val, $fromhost ) ) {
				$R['warnings'][] = "option $name still mentions $fromhost after the address swap";
			}
			$line['changes'][] = ( $cur && maybe_serialize( $val ) === $cur['option_value'] ) ? 'no change' : sprintf( '%d -> %d chars', strlen( $cur['option_value'] ?? '' ), strlen( maybe_serialize( $val ) ) );
		}
		$R['items'][] = $line;
		$plan[]       = array( $name, $val, $cur, $it['autoload'] ?? null, ! empty( $it['absent'] ) );
	}
	if ( $apply && ! $R['errors'] ) {
		foreach ( $plan as list( $name, $val, $cur, $autoload, $absent ) ) {
			$R['before'][] = $cur ? array( 'name' => $name, 'value' => $cur['option_value'], 'autoload' => $cur['autoload'] ) : array( 'name' => $name, 'absent' => true );
			if ( $absent ) {
				delete_option( $name );
			} elseif ( $cur ) {
				update_option( $name, $val );
			} else {
				$al = in_array( $autoload, array( 'yes', 'on', 'auto-on' ), true ) ? true : ( in_array( $autoload, array( 'no', 'off', 'auto-off' ), true ) ? false : null );
				add_option( $name, $val, '', $al );
			}
			$after                 = $wpdb->get_var( $wpdb->prepare( "SELECT option_value FROM $wpdb->options WHERE option_name = %s", $name ) );
			$R['after'][ $name ] = null === $after ? null : md5( $after );
		}
	}
} else {
	$R['errors'][] = 'unknown kind ' . $d['kind'];
}

if ( $apply && ! $R['errors'] ) {
	wp_cache_flush();
	do_action( 'litespeed_purge_all' );
}
echo '@@REPORT@@' . wp_json_encode( $R );
