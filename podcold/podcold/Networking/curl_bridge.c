#include "curl_bridge.h"
#include <curl/curl.h>

void curl_bridge_global_init(void) {
    curl_global_init(CURL_GLOBAL_ALL);
}

CurlHandle curl_bridge_init(void) {
    CURL *h = curl_easy_init();
    /* NOSIGNAL: without it libcurl uses SIGALRM to time out name resolution,
       which is not safe when performing transfers off the main thread. */
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    return h;
}

void curl_bridge_reset(CurlHandle h) {
    curl_easy_reset(h);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);  /* reset clears options, not caches */
}

void curl_bridge_cleanup(CurlHandle h) {
    curl_easy_cleanup(h);
}

void curl_bridge_set_url(CurlHandle h, const char *url) {
    curl_easy_setopt(h, CURLOPT_URL, url);
}

void curl_bridge_set_ssl_noverify(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(h, CURLOPT_SSL_VERIFYHOST, 0L);
}

void curl_bridge_set_follow_redirects(CurlHandle h) {
    curl_easy_setopt(h, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(h, CURLOPT_MAXREDIRS, 10L);
}

void curl_bridge_set_timeout(CurlHandle h, long secs) {
    curl_easy_setopt(h, CURLOPT_TIMEOUT, secs);
}

void curl_bridge_set_connect_timeout(CurlHandle h, long secs) {
    curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT, secs);
}

void curl_bridge_set_low_speed_abort(CurlHandle h, long bytes_per_sec, long secs) {
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, bytes_per_sec);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, secs);
}

void curl_bridge_set_accept_encoding(CurlHandle h) {
    /* "" = advertise every encoding this libcurl was built with (gzip/deflate
       via zlib) and transparently decompress. Feeds are XML: 3-5x smaller. */
    curl_easy_setopt(h, CURLOPT_ACCEPT_ENCODING, "");
}

void curl_bridge_set_write_fn(CurlHandle h, CurlBridgeWriteFn fn, void *userdata) {
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, userdata);
}

void curl_bridge_set_progress_fn(CurlHandle h, CurlBridgeProgressFn fn, void *clientp) {
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, fn);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, clientp);
}

int curl_bridge_perform(CurlHandle h) {
    return (int)curl_easy_perform(h);
}

long curl_bridge_response_code(CurlHandle h) {
    long code = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

const char *curl_bridge_strerror(int code) {
    return curl_easy_strerror((CURLcode)code);
}
