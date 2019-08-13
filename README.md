# Varnish caching for StorageGRID

## Introduction

Varnish Cache is a web application accelerator. By placing Varnish in front of an application such as StorageGRID you can dramatically improve performance for objects that are repeatedly fetched.

The initial fetch of an object from StorageGRID includes a small amount of latency that is inherent with object store architecture. With Varnish cache in front of StorageGRID all subsequent fetches of that object are served from Varnish cache with low latency and very high throughput.

The solution is designed to be completely transparent to any client and ensures that for all requests authentication and authorization is checked.

![Varnish Cache Workflow for StorageGRID](varnish.png "Varnish Cache Workflow for StorageGRID")

## Varnish lab configuration

For our proof of concept we deployed a single Varnish Enterprise instance (commercial distribution) on a bare metal server:

- OS: Centos 7.6 
- 2 x 8 Core Intel(R) Xeon(R) CPU E5-2640 v2 @ 2.00GHz
- 192 GB Memory
- 8 x 512 GB NVMe disks
- Varnish Enterprise 6.0.3r9 – Commercial distribution

StorageGRID Configuration
•	StorageGRID 11.2.0.2
•	6x Virtual Machine Storage Node, 4 x StorageGRID Appliance SG5612, 4 x Storage Node running on Docker
•	Load balancer: Gateway node
WAN connection between Cache and S3 endpoint: 1GbE
Load generator and testing: S3tester

###	Varnish Installation

This solution was build and tested with Varnish Enterprise which is optimized for production usage and offers additional features relevant for this solution like the Varnish Massive Storage Engine (MSE) and SSL. MSE is optimized for caching using disk and memory.

**Note:** The VCL requires at least Varnish Enterprise 6.0.3r9 as some required bug fixes and features are only available since that release.

Follow the [installation steps provided by Varnish](https://docs.varnish-software.com/varnish-cache-plus/installation/) to install the software.

## Varnish Configuration

After Varnish is installed, the default configuration file needs to be overwritten. 

### Provide StorageGRID custom VCL

Replace /etc/varnish/default.vcl with the StorageGRID VCL file by using the [default.vcl](default.vcl) file on GitHub as basis.

Customize the default.vcl to point to your grid

- Provide the DNS name of your load balancer or Gateway node
- Provide port
  - 8082 is default for API Gateway Node HTTPS,

### Configure Massive Storage Engine (MSE)

It is recommended to use memory and SSD or NVMe drives for caching for best performance. Follow the [steps provided by Varnish to configure MSE](https://docs.varnish-software.com/varnish-cache-plus/features/mse/). An example [mse.conf](mse.conf) file is provided on GitHub. Copy the mse.conf file /var/lib/mse/mse.conf and customize it for your environment.

**Note:** The parameter database_size should be configured to account for 100 Bytes per object cached.

The database directory should be stored on low latency storage, otherwise it will negatively impact small object throughput.
Ensure that you initialize your MSE configuration using

```
mkfs.mse -f -c /var/lib/mse/mse.conf
```

### Configure Hitch to use your SSL certificate

Follow the steps provided by Varnish for [setting up Client SSL/TLS termination](https://docs.varnish-software.com/varnish-cache-plus/features/client-ssl/).

Provide the SSL certificate that matches the DNS name of your StorageGRID S3 endpoint – typically VIP on load balancer or Gateway node.

Copy your SSL certificate in PEM format to /etc/hitch
Modify /etc/hitch/hitch.conf

Set front end to desired port:

```
frontend = {
    host = "*"
    port = "443"
```

Hitch requires a single file containing the concatenation of private key, certificate and CA certificate(s). From the certificate and private key used in StorageGRID for the Object Storage endpoint, you can concatenate them with

```
cat example.key example.crt ca.crt > example.pem
```

Make sure to either copy the file to the default location, which is /etc/hitch/testcert.pem or change the default location in /etc/hitch/hitch.conf to the match the location of the PEM file

```
pem-file = "/etc/hitch/example.pem"
```

Ensure that the hitch service is started (refer to the documentation to persist service start at system startup)

```
service hitch start
```

### Restart services and test

Configure Varnish to listen on the port of your choice. StorageGRID defaults to 8082, many customers will choose to use the standard HTTPS port 443.

Make sure to have the following settings included `vsl_mask=+Hash` and `http_gzip_support=off`. The first setting adds the hash to the logging to simplify debugging. The second disables gzip which would break S3 authentication if enabled. 

This is an example of varnishd parameters

```
/usr/sbin/varnishd -a :80 -a :8443 -s mse,/var/lib/mse/mse.conf -p vsl_mask=+Hash -p http_gzip_support=off -f /etc/varnish/default.vcl
```

Restart the varnish service. At this point you should be able to fetch an object from StorageGRID through varnish via AWS CLI or similar client.

## Docker deployment

To simplify testing and to provide a working setup to start from, this repository contains a docker-compose example.

**Note**: To use this setup, you need docker and docker-compose to be available.

Then run the following steps:

Clone the GitHub repository

```
git clone https://github.com/NetApp-StorageGRID/varnish.git
```

Change to the varnish directory

```
cd varnish
```

Create a RHEL/Centos yum repository file to access the Varnish Enterprise files (contact Varnish for a trial or purchase of Varnish Enterprise):

```
vi varnish-6.0-plus.repo
```

Modify the default.vcl and mse.conf files according to your setup. As a minimum, change the endpoint in vcl_init in default.vcl and provide directory and filename for the books in mse.conf.

Then run the container using docker-compose. You may want to use the `--build` paramater to recreate the Docker image, if you changed default.vcl or mse.conf.

```
docker-compose up --build
```