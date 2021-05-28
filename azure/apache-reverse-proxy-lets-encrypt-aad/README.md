# Apache-based reverse proxy with Let's Encrypt and Azure Active Directory authentication

## Why Apache?

There are plenty of good examples of how to set up an nginx-based reverse proxy with Let's Encrypt
HTTPS certificates and Azure Active Directory authentication. Unfortunately, authentication
with Azure Aztive Directory is only available for the premium nginx and I needed a free option.


## Getting Started

Getting started with Apache HTTP Server is easy enough. If you want to expose a directory via
the dockerized version it's enough just to run:

```bash
docker run -d --name apache-directory -p 80:80 -v $DIRECTORY:/usr/local/apache2/htdocs/ httpd:2.4
```


## Minimal Config File

The example above comes with an implicit config file. However, to work out a reverse proxy,
add Let's Encrypt HTTPS certificates and Azure Active Directory authentication we will need
our own config file. Let's start with a minimal one like this one:

```
ServerRoot "/usr/local/apache2"

PidFile logs/httpd.pid

Listen *:80

LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule dir_module modules/mod_dir.so

User daemon
Group daemon

<Directory />
  AllowOverride None
  Require all denied
</Directory>

DocumentRoot "/usr/local/apache2/htdocs"
<Directory "/usr/local/apache2/htdocs">
  Options Indexes FollowSymLinks
  AllowOverride None
  Require all granted
</Directory>

DirectoryIndex index.html

ErrorLog /proc/self/fd/2

LogLevel info
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog /proc/self/fd/1 common

TypesConfig conf/mime.types
```

I took the implicit one and trimmed it down to just the bare essentials. To run it, use this
command (`apache-minimal.httpd.conf` refers to the config file above):

```bash
docker run -d --name apache-minimal -p 80:80 -v $DIRECTORY:/usr/local/apache2/htdocs/ -v $PWD/apache-minimal.httpd.conf:/usr/local/apache2/conf/httpd.conf:ro httpd:2.4
```


## Reverse Proxy

Next comes the reverse proxy config instead of serving a directory. For this we will need a config
file like this one (don't forget to replace `$REVERSE_PROXIED_HOST` with what you want to have
behind Apache):

```
ServerRoot "/usr/local/apache2"

Listen *:80

LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule dir_module modules/mod_dir.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule proxy_connect_module modules/mod_proxy_connect.so
LoadModule proxy_wstunnel_module modules/mod_proxy_wstunnel.so

User daemon
Group daemon

<Directory />
  AllowOverride None
  Require all denied
</Directory>

ErrorLog /proc/self/fd/2

LogLevel info
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog /proc/self/fd/1 common

ProxyRequests Off
ProxyPreserveHost On
ProxyPass / http://$REVERSE_PROXIED_HOST/
ProxyPassReverse / http://$REVERSE_PROXIED_HOST/
```

The command to run the reverse proxy is following (`apache-proxy.httpd.conf` refers to the config file above):

```bash
docker run -d --name apache-proxy -p 80:80 -v $PWD/apache-proxy.httpd.conf:/usr/local/apache2/conf/httpd.conf:ro httpd:2.4-alpine
```


## Userland Reloadable Apache

Before we move on to the next step we need a modified Apache container image which will allow
the server to be gracefully reloaded by a non-root user.

The command to gracefully reload the Apache HTTP Server config is:

```bash
apachectl -k graceful
```

However, under Docker, the command will not be effective when called from within one of the Apache
modules (given that ther are not run as `root`).

Thus, to be able to do a hot reload of the configuration (which is necessary to apply Let's
Encrypt HTTPS certificates) we need to expose the graceful reload in a safe manner. To do it,
the base Apache container image is extended with a script (`apache-graceful-reload.sh`) which
only calls the graceful reload command and does not accept any parameters:

```bash
#!/bin/sh

/usr/local/apache2/bin/apachectl -k graceful
```

Furthermore, the script is owned by the `root` and has `0111` permissions to prevent its modification by regular users. Finally, the container adds a possibility to run
the `apache-graceful-reload.sh` script as `root` by regular users via `sudo`. Here is
the addition to the `sudoers` file which enables that:

```
ALL ALL=(root) NOPASSWD: /usr/local/apache2/bin/apache-graceful-reload.sh
```


## Let's Encrypt

Now, we can use the custom Apache container to inclued HTTPS certificates provisioned
by Let's Encrypt. The config file will now look like this one (don't forget to replace
`$REVERSE_PROXIED_HOST`, `$FQDN` & `$EMAIL` with suitable values):

```
ServerRoot "/usr/local/apache2"

Listen *:80
Listen *:443

LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule dir_module modules/mod_dir.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule proxy_connect_module modules/mod_proxy_connect.so
LoadModule proxy_wstunnel_module modules/mod_proxy_wstunnel.so
LoadModule ssl_module modules/mod_ssl.so
LoadModule watchdog_module modules/mod_watchdog.so
LoadModule md_module modules/mod_md.so

User daemon
Group daemon

<Directory />
  AllowOverride None
  Require all denied
</Directory>

ErrorLog /proc/self/fd/2

LogLevel info
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog /proc/self/fd/1 common

Protocols h2 http/1.1
SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1 -TLSv1.2
SSLHonorCipherOrder Off
SSLSessionTickets Off
ServerName $FQDN

MDContactEmail $EMAIL
MDomain $FQDN
MDCertificateAgreement accepted
MDMessageCmd /bin/sh -c "sudo /usr/local/apache2/bin/apache-graceful-reload.sh"

<VirtualHost *:80>
  ServerAdmin $EMAIL
  MDRequireHttps permanent
</VirtualHost>

<VirtualHost *:443>
  ServerAdmin $EMAIL
  ProxyRequests Off
  ProxyPreserveHost On
  SSLEngine On
  SSLProxyEngine On
  ProxyPass / http://$REVERSE_PROXIED_HOST/
  ProxyPassReverse / http://$REVERSE_PROXIED_HOST/
</VirtualHost>
```

The command to run the HTTPS encrypted reverse proxy is largely unchanged except
for the reference to the modified container image (`apache-https.httpd.conf` refers to
the config file above):

```bash
docker run -d --name apache-proxy -p 80:80 -v $PWD/apache-https.httpd.conf:/usr/local/apache2/conf/httpd.conf:ro altermarkive/httpd-reloadable:2.4.48-alpine
```


## To Be Continued...