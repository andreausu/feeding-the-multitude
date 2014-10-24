#!/usr/bin/env ruby

require 'yaml'
require 'twitter'
require 'redis'
require 'json'

Encoding.default_external = "utf-8"

config_file = File.dirname(__FILE__) + '/config.yml'

if !File.exist?(config_file)
  raise "Configuration file " + config_file + " missing!"
end

CONFIG = YAML.load_file(config_file)

client = Twitter::REST::Client.new do |config|
  config.consumer_key = CONFIG['twitter']['consumer_key']
  config.consumer_secret = CONFIG['twitter']['consumer_secret']
  config.access_token = CONFIG['twitter']['oauth_token']
  config.access_token_secret = CONFIG['twitter']['oauth_token_secret']
end

redis = Redis.new(:host => CONFIG['redis']['host'], :port => CONFIG['redis']['port'], :db => CONFIG['redis']['db'])

whitelist = redis.zrangebyscore("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", "-inf", "+inf")
whitelist.map! {|user| JSON.parse(user)['id']}

following = client.friend_ids.to_a
followers = client.follower_ids.to_a

to_unfollow = following - followers

sleep_seconds = CONFIG['twitter']['sleep_between_unfollow']
sleep_margin = (sleep_seconds * 15 / 100).abs

to_unfollow.each do |user_id|
  unless whitelist.include? user_id
    begin
      client.unfollow(user_id)
      puts "Unfollowed #{user_id}"
      actual_sleep = rand((sleep_seconds - sleep_margin)...(sleep_seconds + sleep_margin))
      puts "Sleeping for #{actual_sleep} seconds..."
      sleep actual_sleep
    rescue Twitter::Error::NotFound => error
      puts "User #{user_id} not found!"
    end
  end
end