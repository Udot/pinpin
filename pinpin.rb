#!/usr/bin/env ruby
require "rubygems"
require "json"
require "redis"
require 'fog'
require "digest/sha1"
require "yaml"
require "fileutils"

class SimpleLogger
  def initialize(file)
    @log_file = file
  end

  def info(msg)
    write("info",msg)
  end
  def warn(msg)
    write("warn",msg)
  end
  def error(msg)
    write("error",msg)
  end
  def write(level, msg)
    File.open(log_file, "a") { |f| f.puts "#{level[0].capitalize} :: #{Time.now.to_s} : #{msg}"}
  end
end

def is_mac?
  RUBY_PLATFORM.downcase.include?("darwin")
end

def is_linux?
   RUBY_PLATFORM.downcase.include?("linux")
end

def environment
  return "development" if is_mac?
  return "production" if is_linux?
end

@current_path = File.expand_path(File.dirname(__FILE__))
require "#{@current_path}/lib/remote_syslog"
LOGGER = RemoteSyslog.new(Settings.remote_log_host,Settings.remote_log_port) if environment == "production"
LOGGER = SimpleLogger.new("sinatra.log") if environment == "development"
@config = YAML.load_file("#{@current_path}/config.yml")[environment]
# queue in
@redis = Redis.new(:host => @config['redis']['host'], :port => @config['redis']['port'], :password => @config['redis']['password'], :db => @config['redis']['db'])
# queue out
@redis_cuddy = Redis.new(:host => @config['redis']['host'], :port => @config['redis']['port'], :password => @config['redis']['password'], :db => @config['redis']['cuddy_db'])
# global status db
@redis_global = Redis.new(:host => @config['redis']['host'], :port => @config['redis']['port'], :password => @config['redis']['password'], :db => @config['redis']['status_db'])

def logger
  LOGGER
end

class Build
  attr_accessor :name, :repository, :version, :cuddy_token, :start_time, :db_string, :current_path
  attr_accessor :config, :redis_cuddy, :redis_global
  def initialize(name, repository, db_string, cuddy_token)
    logger.info("initializing build for #{name}")
    @config = YAML.load_file("#{@current_path}/config.yml")[environment]
    @name = name
    @repository = repository
    @cuddy_token = cuddy_token
    @current_path = File.expand_path(File.dirname(__FILE__))
    @db_string = db_string
    @start_time = start_time_from_redis
    repositories = Hash.new
    repositories = YAML.load_file(@current_path + "/config/repositories.yml") if File.exist?(@current_path + "/config/repositories.yml")
    if repositories[name] == nil
      repositories[name] = {"name" => name, "repository" => repository, "version" => "1"}
      FileUtils.mkdir(@current_path + "/config") unless File.exist?(@current_path + "/config")
      File.open(@current_path + "/config/repositories.yml", 'w' ) do |out|
        YAML.dump(repositories, out)
      end
    end
    @version = repositories[name]["version"]
    # queue out
    @redis_cuddy = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['cuddy_db'])
    # global status db
    @redis_global = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['status_db'])
    
  end

  def next_version
    return version + 1
  end

  def start_time_from_redis
    node = redis_global.get(name)
    return JSON.parse(node)['started_at'] if node != nil
    return Time.now
  end

  def run
    status = {"status" => "building", "version" => build.version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
    redis_global.set(build.name, status)
    logger.info("cloning build for #{name}")
    self.version = next_version
    FileUtils.mkdir("/var/build/#{name}") unless File.exist?("/var/build/#{name}")
    Dir.chdir("/var/build/#{name}")
    clone_shallow = `git clone --depth 1 #{repository} #{version}`
    FileUtils.rm_rf("#{version}/.git")
    logger.info("bundling #{name} v#{version} in /var/build/#{name}/#{version}")
    Dir.chdir("/var/build/#{name}/#{version}")
    log = `bundle install --deployment --without development test`
    Dir.chdir("/var/build/#{name}")
    logger.info("packing #{name} v#{version}")
    log = `tar -czf /var/build/#{name}/#{name}-#{version}.tar.gz #{version}`
    logger.info("cleaning up #{name} #{version} build folder")
    FileUtils.rm_rf("/var/build/#{name}/#{version}")
  end

  def save
    logger.info("saving #{name} version (v#{version})")
    repositories = YAML.load_file(@current_path + "/config/repositories.yml") if File.exist?(@current_path + "/config/repositories.yml")
    repositories[name] = {"name" => name, "repository" => repository, "version" => version}
    FileUtils.mkdir(@current_path + "/config") unless File.exist?(@current_path + "/config")
    File.open(@current_path + "/config/repositories.yml", 'w' ) do |out|
      YAML.dump(repositories, out)
    end
  end

  def upload
    logger.info("uploading #{name} v#{version} in the Cloud")
    current_path = File.expand_path(File.dirname(__FILE__))
  	config = YAML.load_file(current_path + "/config.yml")
  	rs_dir = "sqshed_apps"
  	storage = Fog::Storage.new(:provider => 'Rackspace', :rackspace_auth_url => config["rackspace_auth_url"], :rackspace_api_key => config["rackspace_api_key"], :rackspace_username => config['rackspace_username'])
    directory = storage.directories.get(rs_dir)
    directory.files.create(:key => "#{name}-#{version}.tar.gz", :body => File.open("/var/build/#{name}/#{name}-#{version}.tar.gz"))
    FileUtils.rm_rf("/var/build/#{name}/#{name}-#{version}.tar.gz") if File.exist?("/var/build/#{name}/#{name}-#{version}.tar.gz")
    status = {"status" => "uploaded", "version" => build.version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
    redis_global.set(build.name, status)
  end

  # removes old stuff from the cloud
  def cleanup
    # keep the last 4 versions in the cloud
    if version > 4
      logger.info("deleting old files from the cloud")
      storage = Fog::Storage.new(:provider => 'Rackspace', :rackspace_auth_url => config["rackspace_auth_url"], :rackspace_api_key => config["rackspace_api_key"], :rackspace_username => config['rackspace_username'])
      directory = storage.directories.get("sqshed_apps")
      img = "#{name}-#{version - 4}.tar.gz"
      img_file = directory.files.get(img)
      img_file.destroy if img_file != nil
    end
  end

  # pass the ball to the next player (cuddy)
  def register
    puts "register"
    current_path = File.expand_path(File.dirname(__FILE__))
  	config = YAML.load_file(current_path + "/config.yml")
  	#  {"version" => integer,      # the version number
    #   "name" => string,           # the name of the app
    #   "status" => string,         # starts with "waiting"
    #   "started_at" => datetime,   # the time when the app was added in the queue
    #   "finished_at" => datetime,  # the time when the app was properly deployed
    #     "db" => {"hostname" => string, "database" => string, "username" => string, "token" => string}
    #   }
    # }
    status = {"status" => "queued for deployment", "version" => version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
    redis_global.set(build.name, status)
    # passing the ball to cuddy
    # key is token of the cuddy node, value is array, each item using following format : 
    #   {  "name" => string,           # the name of the app
    #      "version" => integer,       # the version number of the app
    #      "db_string" => string,      # basis for pwd
    # }
    status_hash = {"name" => name, "version" => version, "db_string" => db_string}
    queue = JSON.parse(redis_cuddy.get(cuddy_token)) if redis_cuddy.get(cuddy_token)
    queue ||= Array.new
    queue << status_hash
    redis_cuddy.set(cuddy_token, queue.to_json)
  end
end

logger.info("Starting the wait cycle")
while true
  queue = JSON.parse(@redis.get("queue"))
  while queue.count != 0
    app = queue.pop
    # queue is a array v0.1
    # each item has following format :
    #   {  "name" => string,           # the name of the app
    #      "repository" => string,     # the url of the git repository
    #       "db_string" => string,     # basis for the pwd, passed down "as is" to deployer node
    #      "cuddy_token" => string     # the token of the host that will host it
    #   }
    build = Build.new(app['name'], app['repository'], app['db_string'], app['cuddy_token'])
    start_time = build.start_time_from_redis
    @redis.set("queue",queue.to_json)
    # global status v0.1
    # the key is the name of the app (unique in the db, a uid could be used)
    # {  "status" => "queued for build",        # status of the app
    #    "version" => repository['version'],    # version currently in the pipe
    #    "started_at" => Time.now,              # start time of the process (push from the front)
    #    "finished_at" => Time.now,             # finish time of the process (time of the current status)
    #    "error" => {"message" => "", "backtrace" => ""}
    #    }
    # todo remove this line should be done by front
    status = {"status" => "queued for build", "version" => build.version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
    @redis_global.set(build.name, status)
    logger.info("starting work on #{build.name}")
    fork do
      build.run
      build.save
      build.upload
      build.register
      build.cleanup
    end
  end
  
  Signal.trap("QUIT") do
    logger.info("quitting (received SIGQUIT)")
    exit
  end
  Signal.trap("KILL") do
    logger.info("quitting (received SIGKILL)")
    exit
  end
  Signal.trap("TERM") do
    logger.info("quitting (received SIGTERM)")
    exit
  end
end
