# Varnish caching for StorageGRID

Varnish Cache is a web application accelerator. By placing Varnish in front of an application such as StorageGRID you can dramatically improve performance for objects that are repeatedly fetched. 
The initial fetch of an object from StorageGRID includes a small amount of latency that is inherent with object store architecture. With Varnish cache in front of StorageGRID all subsequent fetches of that object are served from Varnish cache with low latency and very high throughput.

## Varnish Installation

For our lab setup we used the commercial Varnish distribution. We did some basic testing with the Open Source Version to ensure that functionality is working as well. 

We strongly encourage usage of Varnish Enterprise for production usage to be able to use the Varnish Massive Storage Engine (MSE) and SSL. MSE is optimized for caching using disk and memory. The Open Source version is severely limited when using disks for caching and does not provide SSL support out of the box.

Follow the installation steps provided by Varnish to install the software.

## Varnish Configuration

After Varnish is installed, the default configuration file needs to be overwritten. 

### Provide StorageGRID custom VCL

Replace /etc/varnish/default.vcl with the StorageGRID VCL file by using the default.vcl file on GitHub as basis.

Customize the default.vcl to point to your grid

- Provide the DNS name of your load balancer or Gateway node
- Provide port
  - 8082 is default for API Gateway Node HTTPS,
  - 8084 is default for API Gateway Node HTTP
- Set ssl = 1 to enable SSL

### Configure Massive Storage Engine (MSE)

It is recommended to use memory and SSD or NVMe drives for caching for best performance. Follow the steps provided by Varnish to configure MSE. An example mse.conf file is provided on GitHub. Copy the mse.conf file /var/lib/mse/mse.conf and customize it for your environment.

**Note:** The parameter database_size should be configured to account for 100 Bytes per object cached.

The database directory should be stored on low latency storage, otherwise it will negatively impact small object throughput.
Ensure that you initialize your MSE configuration using

```
mkfs.mse -f -c /var/lib/mse/mse.conf
```

### Configure Hitch to use your SSL certificate

Follow the steps provided by Varnish for setting up Client SSL/TLS termination.

Provide the SSL certificate that matches the DNS name of your StorageGRID S3 endpoint – typically VIP on load balancer or Gateway node.

Copy your SSL certificate in PEM format to /etc/hitch
Modify /etc/hitch/hitch.conf

Set front end to desired port:

```
frontend = {
    host = "*"
    port = "443"
```

Set pem-file to your SSL cert:

````
pem-file = "/etc/hitch/your_ssl_cert.pem"
```

### Restart services and test

Configure Varnish to listen on the port of your choice. StorageGRID defaults to 8082, many customers will choose to use the standard HTTPS port 443.

Make sure to have the following settings included `vsl_mask=+Hash` and `http_gzip_support=off`. The first setting adds the hash to the logging to simplify debugging. The second disables gzip which would break S3 authentication if enabled. 

This is an example of varnishd parameters

```
/usr/sbin/varnishd -F -a :8443 -s mse,/var/lib/mse/mse.conf -p vsl_mask=+Hash -f /etc/varnish/default.vcl -p http_gzip_support=off
```

Restart the varnish service. At this point you should be able to fetch an object from StorageGRID through varnish via AWS CLI or similar client.