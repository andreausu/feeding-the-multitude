#!/usr/bin/env ruby

require 'yaml'
require 'twitter'
require 'redis'
require 'json'

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

sclient = Twitter::Streaming::Client.new do |config|
  config.consumer_key = CONFIG['twitter']['consumer_key']
  config.consumer_secret = CONFIG['twitter']['consumer_secret']
  config.access_token = CONFIG['twitter']['oauth_token']
  config.access_token_secret = CONFIG['twitter']['oauth_token_secret']
end

redis = Redis.new(:host => CONFIG['redis']['host'], :port => CONFIG['redis']['port'], :db => CONFIG['redis']['db'])

to_follow = []

wait_until = Time.now.to_i

sleep_seconds = CONFIG['twitter']['sleep_between_follow']
sleep_margin = (CONFIG['twitter']['sleep_between_follow'] * 10 / 100).abs

sclient.filter(:track => CONFIG['twitter']['topics'].join(",")) do |object|
  next unless object.is_a?(Twitter::Tweet) && wait_until < Time.now.to_i
  tweet = object

  if redis.sismember("#{CONFIG['redis']['namespace']}:ftm:followed", tweet.user.id.to_s)
    puts "#{tweet.user.screen_name} already followed in the past! Skipping..."
    next
  end

  if tweet.user.friends_count > 10
    if tweet.text.match /[\u{1F600}-\u{1F6FF}]/ and tweet.in_reply_to_user_id.nil? and !tweet.retweeted? and !tweet.text.include? 'RT @'
        puts tweet.user.screen_name + ': ' + tweet.text
        client.favorite(tweet)
        client.follow(tweet.user)
        redis.sadd("#{CONFIG['redis']['namespace']}:ftm:followed", tweet.user.id.to_s)
        redis.zadd("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", Time.now.to_i.to_f, JSON.generate(tweet.user.attrs))
        wait_until += (rand((sleep_seconds - sleep_margin)...(sleep_seconds + sleep_margin)))
    end
  end

end

#puts client.get('/1.1/application/rate_limit_status.json')[:body]