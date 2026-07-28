#ifndef curl_bridge_h
#define curl_bridge_h

#include <stddef.h>

typedef void *CurlHandle;

/* Write callback: return number of bytes processed (must equal size*nmemb or curl aborts) */
typedef size_t (*CurlBridgeWriteFn)(const void *ptr, size_t size, size_t nmemb, void *userdata);

/* Progress callback (xferinfo style, curl_off_t = long long).
   Return 0 to continue, non-zero to abort. */
typedef int (*CurlBridgeProgressFn)(void *clientp,
                                    long long dltotal, long long dlnow,
                                    long long ultotal, long long ulnow);

void        curl_bridge_global_init(void);
CurlHandle  curl_bridge_init(void);
/* Clears all options but KEEPS the connection cache, DNS cache and TLS session
   cache, so a reused handle skips the handshake on subsequent requests to the
   same host. Call instead of cleanup+init when reusing a handle. */
void        curl_bridge_reset(CurlHandle h);
void        curl_bridge_cleanup(CurlHandle h);
void        curl_bridge_set_url(CurlHandle h, const char *url);
void        curl_bridge_set_ssl_noverify(CurlHandle h);
void        curl_bridge_set_follow_redirects(CurlHandle h);
void        curl_bridge_set_timeout(CurlHandle h, long secs);
void        curl_bridge_set_connect_timeout(CurlHandle h, long secs);
/* Abort if the transfer stays below bytes_per_sec for secs — lets a large
   download run past any total-time cap as long as it keeps making progress. */
void        curl_bridge_set_low_speed_abort(CurlHandle h, long bytes_per_sec, long secs);
void        curl_bridge_set_accept_encoding(CurlHandle h);
void        curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata);
void        curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp);
int         curl_bridge_perform(CurlHandle h);
long        curl_bridge_response_code(CurlHandle h);
const char *curl_bridge_strerror(int code);

#endif /* curl_bridge_h */
