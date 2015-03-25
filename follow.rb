#!/usr/bin/env ruby

require 'yaml'
require 'twitter'
require 'redis'
require 'mail'
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
redis.del "#{CONFIG['redis']['namespace']}:ftm:buffer"

wait_until = Time.now.to_i

sleep_seconds = CONFIG['twitter']['sleep_between_follow']
sleep_margin = (CONFIG['twitter']['sleep_between_follow'] * 10 / 100).abs

sclient.filter(:track => CONFIG['twitter']['topics'].join(",")) do |object|
  next unless object.is_a? Twitter::Tweet

  if wait_until > Time.now.to_i or redis.llen("#{CONFIG['redis']['namespace']}:ftm:buffer") == 0
    tweet = object

    if redis.sismember("#{CONFIG['redis']['namespace']}:ftm:followed", tweet.user.id.to_s)
      puts "#{tweet.user.screen_name} already followed in the past! Skipping..."
      next
    end

    if tweet.text.match /[\u{1F600}-\u{1F6FF}]/ and tweet.in_reply_to_user_id.nil? and !tweet.retweeted? and !tweet.text.include? 'RT @'
      if CONFIG['twitter']['excluded_phrases'].any? { |w| tweet.text.downcase.include? w.downcase }
        puts "'#{tweet.text}' contains an excluded phrase..."
        next
      end
      puts "Tweet queued in the buffer"
      redis.lpush "#{CONFIG['redis']['namespace']}:ftm:buffer", Marshal.dump(tweet)
      redis.ltrim "#{CONFIG['redis']['namespace']}:ftm:buffer", 0, 99
    end
  else
    tweet = Marshal.load(redis.lpop "#{CONFIG['redis']['namespace']}:ftm:buffer")
    puts tweet.user.screen_name + ': ' + tweet.text
    begin
      client.favorite(tweet)
      client.follow!(tweet.user)
      redis.sadd("#{CONFIG['redis']['namespace']}:ftm:followed", tweet.user.id.to_s)
      redis.zadd("#{CONFIG['redis']['namespace']}:ftm:followed_to_check", Time.now.to_i.to_f, JSON.generate(tweet.user.attrs))
      wait_until = Time.now.to_i + (rand((sleep_seconds - sleep_margin)...(sleep_seconds + sleep_margin)))
    rescue Twitter::Error::Forbidden => e
      if e.to_s.include? 'You are unable to follow more people at this time'
        # Wait until following is < 2000 or ratio is acceptable
      end
      puts client.get('/1.1/application/rate_limit_status.json')[:body]
      error_hash = {:class => e.class.name, :rate_limit => "Limit: #{e.rate_limit.limit}. Remaining: #{e.rate_limit.remaining}. Reset in: #{e.rate_limit.reset_in}", :message => e.to_s, :timestamp => Time.now.to_i}
      error_string = ''
      error_hash.each { |key, value| error_string += "#{key}: #{value}\n" }
      puts error_string
      mail = Mail.new do
        from     'andrea@usu.li'
        to       'andreausu@gmail.com'
        subject  File.dirname(__FILE__).split('/').last + " #{e.class.name} error!"
        body     error_string
      end
      mail.delivery_method :sendmail
      mail.deliver
      redis.rpush "#{CONFIG['redis']['namespace']}:ftm:errors", JSON.generate(error_hash)
      if e.rate_limit.reset_in
        sleep e.rate_limit.reset_in
      else
        sleep 300
      end
    rescue Twitter::Error::TooManyRequests => e
      puts client.get('/1.1/application/rate_limit_status.json')[:body]
      error_hash = {:class => e.class.name, :rate_limit => "Limit: #{e.rate_limit.limit}. Remaining: #{e.rate_limit.remaining}. Reset in: #{e.rate_limit.reset_in}", :message => e.to_s, :timestamp => Time.now.to_i}
      error_string = ''
      error_hash.each { |key, value| error_string += "#{key}: #{value}\n" }
      puts error_string
      mail = Mail.new do
        from     'andrea@usu.li'
        to       'andreausu@gmail.com'
        subject  File.dirname(__FILE__).split('/').last + " #{e.class.name} error!"
        body     error_string
      end
      mail.delivery_method :sendmail
      mail.deliver
      redis.rpush "#{CONFIG['redis']['namespace']}:ftm:errors", JSON.generate(error_hash)
      if e.rate_limit.reset_in
        sleep e.rate_limit.reset_in
      else
        sleep 300
      end
    rescue Twitter::Error => e
      error_hash = {:class => e.class.name, :rate_limit => "Limit: #{e.rate_limit.limit}. Remaining: #{e.rate_limit.remaining}. Reset in: #{e.rate_limit.reset_in}", :message => e.to_s, :timestamp => Time.now.to_i}
      error_string = ''
      error_hash.each { |key, value| error_string += "#{key}: #{value}\n" }
      puts error_string
      mail = Mail.new do
        from     'andrea@usu.li'
        to       'andreausu@gmail.com'
        subject  File.dirname(__FILE__).split('/').last + " #{e.class.name} error!"
        body     error_string
      end
      mail.delivery_method :sendmail
      redis.rpush "#{CONFIG['redis']['namespace']}:ftm:errors", JSON.generate(error_hash)
      unless e.is_a? Twitter::Error::NotFound
        mail.deliver
        sleep 180
      end
    end
  end
end
