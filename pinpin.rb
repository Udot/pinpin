#!/usr/bin/env ruby
require "rubygems"
require "bundler/setup"

# get all the gems in
Bundler.require(:default)
require "digest/sha1"
require "yaml"
require "fileutils"

def is_mac?
  RUBY_PLATFORM.downcase.include?("darwin")
end

def is_linux?
   RUBY_PLATFORM.downcase.include?("linux")
end

def build(repository = nil, version = nil)
  current_path = File.expand_path(File.dirname(__FILE__))
  config = YAML.load_file("#{current_path}/config.yml")["dev"] if is_mac?
  config = YAML.load_file("#{current_path}/config.yml")["prod"] if is_linux?
  redis = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['database'])
  status = JSON.parse(redis.get(repository)) if (redis.get(repository) != nil)
  start_time = Time.now
  if status != nil
    return true if (status["status"] == ("building" || "built"))
  end
  status = {"status" => "building", "version" => version, "started_at" => start_time, "finished_at" => "", "error" => {"message" => "", "backtrace" => ""}}.to_json
  begin
    redis.set(repository, status)
    exit if ((repository == nil) && (version == nil))
    current_path = File.expand_path(File.dirname(__FILE__))
    path = repository.split('/').last.gsub(/.git$/,'')
    FileUtils.mkdir("#{config["build"]["root"]}") unless File.exist?("#{config["build"]["root"]}")
    FileUtils.rm_rf("#{config["build"]["root"]}/#{path}/#{version}") if File.exist?("#{config["build"]["root"]}/#{path}/#{version}")
    FileUtils.mkdir_p("#{config["build"]["root"]}/#{path}/#{version}")
    checkout_cmd = "cd #{config["build"]["root"]}/#{path} && git clone --depth 1 #{repository} #{version}"
    checkout_log = `#{checkout_cmd}`
    raise SystemCallError, checkout_log unless $?.to_i == 0
    build_cmd = "cd #{config["build"]["root"]}/#{path}/#{version} && bundle install --path .bundled > /dev/null 2>&1"
    build_log = `#{build_cmd}`
    raise SystemCallError, build_log unless $?.to_i == 0
    img = ""
    rs_dir = ""
    img_cmd = ""
    if is_linux?
      img = "#{path}-#{version}.sqsh"
      rs_dir = "sqshed_apps"
      img_cmd = "cd #{config["build"]["root"]}/#{path} && mksquashfs #{path}/#{version} #{img}"
    elsif is_mac?
      img = "#{path}-#{version}.tgz"
      rs_dir = "sqshed_apps_test"
      img_cmd = "cd #{config["build"]["root"]}/#{path} && tar -czf #{img} #{version}"
    else
      raise ArgumentError, "platform is not correct"
    end
    img_log = `#{img_cmd}`
    raise SystemCallError, img_log unless $?.to_i == 0
    storage = Fog::Storage.new(:provider => 'Rackspace', :rackspace_auth_url => config["rackspace_auth_url"], :rackspace_api_key => config["rackspace_api_key"], :rackspace_username => config['rackspace_username'])
    directory = storage.directories.get(rs_dir)
    directory.files.create(:key => "#{img}", :body => File.open("#{config["build"]["root"]}/#{path}/#{img}"))
  rescue => e
    p e.message
    p e.backtrace
    status = {"status" => "failed", "version" => version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => e.message, "backtrace" => e.backtrace}}.to_json
    redis.set(repository, status)
  end
  status = {"status" => "built", "version" => version, "started_at" => start_time, "finished_at" => Time.now, "error" => {"message" => "", "backtrace" => ""}}.to_json
  redis.set(repository, status)
end

current_path = File.expand_path(File.dirname(__FILE__))
config = YAML.load_file("#{current_path}/config.yml")["dev"] if is_mac?
config = YAML.load_file("#{current_path}/config.yml")["prod"] if is_linux?
redis = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['database'])

loop do
  queue = JSON.parse(redis.get("queue"))
  while queue.count != 0
    repository = queue.pop
    status = JSON.parse(redis.get(repository)) if (redis.get(repository) != nil)
    if (status == nil) || (status['status'] != ("building" || "built"))
      build(repository['repository'], repository['version'])
    end
  end
  redis.set("queue", [].to_json)
  sleep config['sleeptime']
end
