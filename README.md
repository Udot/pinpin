# Pinpin, the app packager

> Pinpin is a great person, even if what he says
> can sound crazy some times

Pinpin is a Ruby app packager. It use a Redis server as queue every 30 seconds (on a mac, aka my dev platform, 300 seconds on a linux aka my hosting platform) shallow clone each repository passed there, bundle install in the app directory, then pack the directory in a tar gz ball (squasfs was a good idea until Debian squeeze told me that it didn't know how to speak squashfs). In the end it uploads the resulting file to a RackSpace CloudFiles directory.

## A word about the state

Obviously from the previous paragraph you know that this is a early version and mostly a proof of concept. Lots of details could be improved.

## How it works exactly

### Installation

To setup and launch Pinpin you *must avoid* using *bundler* not that I don't like the guy but because it will cause trouble and failure of the process. The reason is simple : Pinpin use bundler to install the gems in _vendor/bundle_ directory in your app folder (so you _can user bundler for the apps to be packaged_). Calling _bundle install_ from a ruby app using _bundler_ is calling for trouble, so instead rely either on the system gems, or better still, on a _rvm gemset_ (or equivalent).

### Configuration

The configuration happens in the _config.yml_ file :

```
  "development":
    "sleeptime": 30
    "redis":
      "host": "localhost"
      "port": 6379
      "password": ""
      "db": 0
    "build":
      "root": "build/"
    "rackspace_auth_url": "https://lon.auth.api.rackspacecloud.com/v1.0"
    "rackspace_api_key": "thekey"
    "rackspace_username": "theusername"
  "production":
    "sleeptime": 300
    "redis":
      "host": "theremote.host"
      "port": 6379
      "password": "somepassword"
      "db" : 0
    "build":
      "root": "/var/build"
    "rackspace_auth_url": "https://lon.auth.api.rackspacecloud.com/v1.0"
      "rackspace_api_key": "thekey"
      "rackspace_username": "theusername"
```

Here is sample. You can see two main sections : _dev_ and _prod_. Pinpin loads one of those section as _config_ depending on the platform it is being run on. So if your workstation is running GNU/Linux beware it will go in production mode.


You need a Redis server. You can configure the details in the _config.yml_ file but you need to know that Pinpin will except some stuff from the Redis server. Namely : a _jsoned_ _queue_ key containing an array of one or more hash like this one :

```
  {"repository" => "git://github.com/mcansky/Pinpin-builder.git", "version" => "0.3", "backoffice" => true/false, "cuddy_token" => "sometoken"}
```

To be clear, in Ruby you'd tell your Redis something like this :

```
  redis.set "queue", [{"repository" => "git://github.com/mcansky/Pinpin-builder.git", "version" => "0.1", "backoffice" => true/false, "cuddy_token" => "sometoken"}].to_json
```

Each run, Pinpin will grab this queue and pop the repositories hash one by one, and do the build thing for each. At the end it reset the queue key. For each build, Pinpin will insert an object using the repository address as key and the following similar jsoned hash :

```
  {"status" => "failed", "version" => version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => e.message, "backtrace" => e.backtrace}}
```

Hopefully in a near future Pinpin will know how to say hello to a remote companion in order for him to get that hash without checking the Redis from time to time.

'til then, cheerio ...
