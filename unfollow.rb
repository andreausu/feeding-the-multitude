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

some_time_ago = (Time.now - (CONFIG['twitter']['minutes_after_unfollow'] * 60)).to_i.to_f

redis = Redis.new(:host => CONFIG['redis']['host'], :port => CONFIG['redis']['port'], :db => CONFIG['redis']['db'])

to_unfollow = []
to_unfollow = redis.zrangebyscore("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", "-inf", some_time_ago)

options = {:count => 200}
result = []
favorites = []
last_id = 0
old_last_id = 0
loop do
  begin
    options[:max_id] = last_id if last_id > 0
    result = client.favorites(options).to_a
    favorites += result
    puts favorites.length
    result.each { |res| last_id = res.id if res.id < last_id || last_id == 0 }
    break if old_last_id == last_id
    old_last_id = last_id
  rescue Twitter::Error::TooManyRequests => error
    puts "Too many requests! Sleeping for #{error.rate_limit.reset_in} seconds..."
    sleep error.rate_limit.reset_in
    retry
  end
end

my_followers = client.follower_ids.to_a
my_following = client.friend_ids.to_a

sleep_seconds = CONFIG['twitter']['sleep_between_unfollow']
sleep_margin = (sleep_seconds * 15 / 100).abs

favorites.each do |favorite|
  if my_followers.include? favorite.user.id or my_following.include? favorite.user.id
    puts "We follow this user! #{favorite.user.id}"
  else
    begin
      client.unfavorite(favorite.id)
      puts "Unfavorited #{favorite.id}"
      actual_sleep = rand((sleep_seconds - sleep_margin)...(sleep_seconds + sleep_margin))
      puts "Sleeping for #{actual_sleep} seconds..."
      sleep actual_sleep
    rescue Twitter::Error::NotFound
      puts "Tweet #{favorite.id} not found!"
    end
  end
end

to_unfollow.each do |user|
  user = JSON.parse(user)
  if !my_followers.include? user['id']
    begin
      client.unfollow(user['id'])
      puts "Unfollowed @#{user['screen_name']} (ID: #{user['id'].to_s})"
      actual_sleep = rand((sleep_seconds - sleep_margin)...(sleep_seconds + sleep_margin))
      puts "Sleeping for #{actual_sleep} seconds..."
      sleep actual_sleep
    rescue Twitter::Error::NotFound
      puts "User @#{user['screen_name']} (ID: #{user['id'].to_s}) not found!"
    end
  else
    puts "@#{user['screen_name']} followed us back \\o/ :)"
  end
end

redis.zremrangebyscore("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", '-inf', some_time_ago)
