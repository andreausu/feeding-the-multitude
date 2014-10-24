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

two_days_ago = (Time.now - (2 * 24 * 60 * 60)).to_i.to_f
#two_days_ago = Time.now.to_i.to_f

redis = Redis.new(:host => CONFIG['redis']['host'], :port => CONFIG['redis']['port'], :db => CONFIG['redis']['db'])

to_unfollow = []
to_unfollow = redis.zrangebyscore("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", "-inf", two_days_ago)

my_followers = client.follower_ids.to_a unless to_unfollow.length == 0

sleep_seconds = CONFIG['twitter']['sleep_between_unfollow']
sleep_margin = (sleep_seconds * 15 / 100).abs

to_unfollow.each do |user|
  user = JSON.parse(user)
  if !my_followers.include? user['id']
    begin
      client.unfollow(user['id'])
      puts "Unfollowed @#{user['screen_name']} (ID: #{user['id'].to_s})"
      actual_sleep = rand((sleep_seconds - sleep_margin)...(sleep_seconds + sleep_margin))
      puts "Sleeping for #{actual_sleep} seconds..."
      sleep actual_sleep
    rescue Twitter::Error::NotFound => error
      puts "User @#{user['screen_name']} (ID: #{user['id'].to_s}) not found!"
    end
  else
    puts "@#{user['screen_name']} followed us back \\o/ :)"
  end
end

redis.zremrangebyscore("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", '-inf', two_days_ago)

#puts client.get('/1.1/application/rate_limit_status.json')[:body]