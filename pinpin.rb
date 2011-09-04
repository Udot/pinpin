#!/usr/bin/env ruby
require "rubygems"
require "json"
require "redis"
require 'fog'

require "digest/sha1"
require "yaml"
require "fileutils"

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

@config = YAML.load_file("#{@current_path}/config.yml")[environment]
@redis = Redis.new(:host => @config['redis']['host'], :port => @config['redis']['port'], :password => @config['redis']['password'], :db => @config['redis']['database'])

def logger(severity, message)
  file = File.open(@config['logfile'], "a")
  case severity
  when "info"
    file.puts "I :: #{Time.now.to_s} : INFO : " + message
  when "error"
    file.puts "E :: #{Time.now.to_s} : ERROR : " + message
  when "fatal"
    file.puts "F :: #{Time.now.to_s} : FATAL : " + message
  end
  file.close
end

def build(repository = nil, version = nil, backoffice = false, cuddy_token)
  if cuddy_token
    redis_deploy = Redis.new(:host => @config['redis']['host'], :port => @config['redis']['port'], :password => @config['redis']['password'], :db => 1)
  end
  logger("info", "build for #{repository} #{version} starts.")
  status = JSON.parse(@redis.get(repository)) if (@redis.get(repository) != nil)
  start_time = status['started_at'] 
  if status != nil
    if (status["status"] == ("building" || "built"))
      logger("info", "already built or being built elsewhere")
      return true
    end
  end
  status = {"status" => "building", "version" => version, "started_at" => start_time, "finished_at" => "", "error" => {"message" => "", "backtrace" => ""}}.to_json
  @redis.set(repository, status)
  begin
    return true if ((repository == nil) && (version == nil))
    current_path = File.expand_path(File.dirname(__FILE__))
    path = repository.split('/').last.gsub(/.git$/,'')
    FileUtils.mkdir("#{@config["build"]["root"]}") unless File.exist?("#{@config["build"]["root"]}")
    FileUtils.rm_rf("#{@config["build"]["root"]}/#{path}/#{version}") if (File.exist?("#{@config["build"]["root"]}/#{path}") && File.exist?("#{@config["build"]["root"]}/#{path}/#{version}"))

    logger("info", "cloning #{repository} #{version}")
    checkout_cmd = "git clone --depth 1 #{repository} #{version}"
    FileUtils.mkdir("#{@config["build"]["root"]}/#{path}") unless File.exist?("#{@config["build"]["root"]}/#{path}")
    Dir.chdir("#{@config["build"]["root"]}/#{path}")
    checkout_log = `#{checkout_cmd}`
    raise SystemCallError, checkout_log unless $?.to_i == 0

    img = ""
    rs_dir = ""
    img_cmd = ""
    img_root = "#{@config["build"]["root"]}"
    logger("info", "bundle install #{repository} #{version}")
    FileUtils.mkdir_p("#{@config["build"]["root"]}/#{path}/#{version}/vendor/bundle")
    bundle_log = `cd #{@config["build"]["root"]}/#{path}/#{version} && bundle install --deployment --without development,test`
    raise SystemCallError, bundle_log unless $?.to_i == 0
    raise ArgumentError, "bundled in the wrong place" unless File.exist?("#{@config["build"]["root"]}/#{path}/#{version}/vendor/bundle")
    
    if is_linux?  
      img = "#{path}-#{version}.tgz"
      rs_dir = "sqshed_apps"
    elsif is_mac?
      img = "#{path}-#{version}.tgz"
      rs_dir = "sqshed_apps_test"
    else
      raise ArgumentError, "platform is not correct"
    end
    img_cmd = "tar -czf #{img} #{path}/#{version}"
    Dir.chdir(img_root)
    img_log = `#{img_cmd}`
    raise SystemCallError, img_log unless $?.to_i == 0
    logger("info", "creating image #{repository} #{version}")

    storage = Fog::Storage.new(:provider => 'Rackspace', :rackspace_auth_url => @config["rackspace_auth_url"], :rackspace_api_key => @config["rackspace_api_key"], :rackspace_username => @config['rackspace_username'])
    directory = storage.directories.get(rs_dir)
    directory.files.create(:key => "#{img}", :body => File.open("#{@config["build"]["root"]}/#{img}"))
    FileUtils.rm_rf("#{@config["build"]["root"]}/#{path}") if File.exist?("#{@config["build"]["root"]}/#{path}")
  rescue => e
    p e.message
    p e.backtrace
    logger("error", e.message)
    status = {"status" => "failed", "version" => version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => e.message, "backtrace" => e.backtrace}}.to_json
    @redis.set(repository, status)
  end
  logger("info", "built and uploaded #{repository} #{version}")
  status = {"status" => "built", "version" => version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
  @redis.set(repository, status)
  #  {"version" => integer,      # the version number
  #   "name" => string,           # the name of the app
  #   "status" => string,         # starts with "waiting"
  #   "started_at" => datetime,   # the time when the app was added in the queue
  #   "finished_at" => datetime,  # the time when the app was properly deployed
  #   "backoffice" => boolean,      # is the app a backoffice thing (will not create db and use different init script)
  #   "config" => { "unicorn" => { "workers" => integer },      # only if not back office
  #     "db" => {"hostname" => string, "database" => string, "username" => string, "token" => string}   # only if not back office
  #   }
  if cuddy_token
    status = {"name" => path, "version" => version, "started_at" => start_time, "finished_at" => Time.now, "backoffice" => backoffice}.to_json
    redis_deploy.set(cuddy_token,status)
  end
end

logger("info", "starting")

while true
  queue = JSON.parse(@redis.get("queue"))
  logger("info", "QUEUE is #{queue.count} deep") if queue.count > 0
  while queue.count != 0
    repository = queue.pop
    @redis.set("queue",queue.to_json)
    status = {"status" => "queued", "version" => repository['version'], "started_at" => Time.now, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
    @redis.set(repository['repository'], status)
    logger("info", "starting work on #{repository['repository']}")
    build(repository['repository'], repository['version'], repository['backoffice'] || false, repository['cuddy_token'])
  end
  Signal.trap("QUIT") do
    logger("info", "quitting (received SIGQUIT)")
    exit
  end
  Signal.trap("KILL") do
    logger("info", "quitting (received SIGKILL)")
    exit
  end
  Signal.trap("TERM") do
    logger("info", "quitting (received SIGTERM)")
    exit
  end
end
