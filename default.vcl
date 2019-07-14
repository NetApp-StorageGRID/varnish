vcl 4.1;
# load director support for loadbalancing
import directors;

# define backends
backend gw1 {
    .host = "10.65.59.40";
    .port = "8084";
    .probe = {
        .request = 
          "OPTIONS / HTTP/1.1"
          "Host: localhost"
          "Connection: close"
          "User-Agent: Varnish Health Probe";

        .timeout = 1s;
        .interval = 10s;
        .window = 5;
        .threshold = 3;
    }
    .between_bytes_timeout = 0s;
    .connect_timeout = 60s;
}
backend gw2 {
    .host = "10.65.59.41";
    .port = "8084";
    .probe = {
        .request = 
          "OPTIONS / HTTP/1.1"
          "Host: localhost"
          "Connection: close"
          "User-Agent: Varnish Health Probe";
          
        .timeout = 1s;
        .interval = 60s;
        .window = 5;
        .threshold = 3;
    }
    .between_bytes_timeout = 0s;
    .connect_timeout = 60s;
}

# custom VCL for handling S3 requests

sub vcl_init {
    # create a director to loadbalance between available backends
    new bar = directors.round_robin();
    bar.add_backend(gw1);
    bar.add_backend(gw2);
}

sub vcl_recv {
    # send all traffic to the bar director:
    set req.backend_hint = bar.backend();

    # TODO: handle server side encryption custom key headers
    # TODO: handle if-* headers

    # only process HTTP GET requests
    if (req.method == "GET") {
        # we need to treat range reads specially as the range may be a signed header by the client and varnish is not yet optimized for storing and combining range read responses
        if (req.http.Range) {
            set req.http.x-range = req.http.Range;
        }

        if (req.restarts == 0) {
            # first check if the requested object is in the cache
            set req.http.x-state = "cache_check";
            return (hash);
        } else if (req.http.x-state == "backend_check") {
            # if object is cached, we still need to send the request to the backend for authentication
            return (pass);
        } else {
            # return the object
            return (hash);
        }
    } else {
        # bypass varnish for all other HTTP methods (e.g. PUT, DELETE, HEAD)
        return (pipe);
    }
}

sub vcl_hash {
    # if it is a range request, add range to lookup
    if (req.http.x-range) {
        hash_data(req.http.x-range);
        unset req.http.Range;
    }
    # query parameters need to be removed to allow direct retrieval of the object from the cache
    hash_data(regsub(req.url, "\?.*$", ""));
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
    return (lookup);
}

sub vcl_hit {
	if (req.http.x-state == "cache_check" && obj.http.etag) {
		set req.http.x-state = "backend_check";
		set req.http.etag = obj.http.etag;
		return (restart);
	} else {
		return (deliver);
	}
}

sub vcl_backend_fetch {
    # if it is a range request, add the range header back
    if (bereq.http.x-range) {
        set bereq.http.Range = bereq.http.x-range;
    }

	if (bereq.http.x-state == "backend_check") {
        # use if-none-match header to ask S3 if the ETag of the cached object is the one being requested
        set bereq.http.if-none-match = bereq.http.etag;
	}
}

sub vcl_backend_response {
    # only cache responses which have an ETag (e.g. object retrieval and not bucket listing)
    if (beresp.http.etag) {
        if (bereq.http.x-range && beresp.status == 206) {
            set beresp.http.x-content-range = beresp.http.content-range;
        }

        if (bereq.http.etag && bereq.http.etag != beresp.http.etag) {
            ban("obj.http.etag == " + bereq.http.etag);
        }
        # as we validate the cache on every request, we can cache the file forever
        set beresp.ttl = 100y;
    } else {
        set beresp.uncacheable = true;
    }
}

sub vcl_deliver {
    if (resp.http.x-content-range) {
        set resp.http.Content-Range = resp.http.x-content-range;
        unset resp.http.x-content-range;
    }

	if (req.http.x-state == "backend_check" && resp.status == 304) {
		unset req.http.x-state;
		return (restart);
	} else {
        unset req.http.x-state;
    }
}
