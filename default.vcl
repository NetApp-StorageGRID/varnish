#
# NetApp StorageGRID
# v1.1
#

vcl 4.1;

import goto;
import kvstore;
import std;
import urlplus;
import utils;

# define health check for S3 endpoint
probe healthcheck { 
    .request = 
        "OPTIONS / HTTP/1.1"
        "Connection: close"
        "User-Agent: Varnish Health Probe";
    .timeout = 1s;
    .interval = 10s;
    .window = 5;
    .threshold = 3;
}

backend default {
    .host = "10.65.59.40";
}

# custom VCL for handling S3 requests

sub vcl_init {
    # define S3 endpoint using Varnish GOTO director
    new endpoint = goto.dns_director(s="https://s3.muccbc.hq.netapp.com:8082",probe=healthcheck);

    # initialize hit counter as normal cache hit counter does not work due to backend lookups for all requests
    new hits = kvstore.init();
}

sub vcl_recv
{
    # send all traffic to the director
    set req.backend_hint = endpoint.backend();

    # Only cache GET requests
    if (req.method == "GET") {
        # Save the range
        if (req.http.Range) {
            set req.http.x-range = req.http.Range;
            unset req.http.Range;
        }
        return (hash);
    } else {
        return (pass);
    }
}

sub vcl_hash
{
    # Range fragment caching
    if (req.http.x-range) {
        hash_data(req.http.x-range);
    }

    # Strip query params
    hash_data(urlplus.url_get());

    # Hash on host
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }

    return (lookup);
}

sub vcl_hit
{
    return (pass);
}

sub vcl_backend_fetch
{
    # Restore the range
    if (bereq.http.x-range) {
        set bereq.http.Range = bereq.http.x-range;
        unset bereq.http.x-range;
    }
}

sub vcl_backend_response
{
    # Errors
    if (beresp.status >= 400 && beresp.status != 404) {
	return (error(beresp.status, beresp.reason));
    }

    # We do not have an actual object
    if (!beresp.http.etag) {
        set beresp.uncacheable = true;
        return (deliver);
    }

    # Calculate a hit counter
    if (beresp.was_304) {
        hits.counter(urlplus.url_get(), 1);
    } else {
        hits.delete(urlplus.url_get());
    }

    # Workaround to allow 206 responses to be ETagged in future requests
    unset beresp.http.X-206;
    if (beresp.status == 206) {
        set beresp.http.X-206 = "true";
        set beresp.status = 200;
        if (beresp.http.Content-Range) {
            set beresp.http.x-content-range = beresp.http.Content-Range;
            unset beresp.http.Content-Range;
        }
    }

    # TTL
    set beresp.ttl = 0.000001s;
    set beresp.grace = 0s;
    set beresp.keep = 10y;

    utils.fast_304();

    return (deliver);
}

sub vcl_backend_error
{
    set beresp.ttl = 0s;
    set beresp.grace = 0s;
    set beresp.keep = 0s;
    set beresp.uncacheable = true;
    return (deliver);
}

sub vcl_deliver
{
    # Restore 206 response
    if (resp.http.X-206 == "true") {
        set resp.status = 206;
        unset resp.http.X-206;
    }
    if (resp.http.x-content-range) {
        set resp.http.Content-Range = resp.http.x-content-range;
        unset resp.http.x-content-range;
    }

    # Hits
    set resp.http.x-hits = hits.counter(urlplus.url_get(), 0);
}